# Move-Mode Abstraction — Design

**Date:** 2026-06-02
**Status:** Design approved (verbal); spec under review
**Kind:** Pure refactor — **no user-visible behavior change**
**Branch:** `worktree-nobutton-move-prototype`

---

## 1. Background & goal

AnyDrag now has two ways to move a window, and they share most of their machinery:

- **Drag move** — hold the main modifier and drag with the left button.
- **No-drag move** — hold a dedicated modifier and move the mouse with no button.

Both drive the *same* coordinate engine (`TitleBarDragStrategy`): suppress the
initiating event, defer one tick, synthesize a `leftMouseDown` on the window's
title bar, then rewrite each subsequent event by a constant Y offset so the
window follows. The only real differences are **how the gesture is triggered,
tracked, and ended** — yet today that logic is scattered across `DragEngine`'s
per-event handlers, interleaved with resize/tile/maximize.

**Goal:** extract a small abstraction so the *shared* lifecycle is written once
and the *differing* parts (trigger / track source / end / cancel) live in one
focused type per mode. Improves maintainability and lays the seam for resize,
tile, and issue #13's trigger→action mapping to adopt later.

**Non-goal:** changing any behavior. This is a structural refactor; the manual
test matrix must pass identically before and after.

## 2. Scope

**In scope**
- New abstraction: `WindowTarget`, `MoveContext`, `WindowMoveMode` (+ `EventDisposition`).
- Two conforming modes: `DragMoveMode`, `NoDragMoveMode`.
- `DragEngine` delegates the two move gestures to these modes; keeps the event-
  routing skeleton and tap lifecycle.
- **Rename `NoButton*` → `NoDrag*` everywhere** (types, vars, methods, the
  `Preferences.Key` constant *and its UserDefaults string*, localization keys,
  and the user-facing copy that literally says "no-button"). Not shipped, so no
  migration is needed.

**Out of scope (untouched, but the protocol is designed so they can adopt it later)**
- Maximize (left double-click), middle-button (drag / tile-by-direction),
  right-button (resize / TilingPanel).
- Tap lifecycle: the main tap, the dedicated `mouseMoved` tap, the
  modifier-held gating, trust/backstop. These stay in `DragEngine` (they are
  plumbing, not gesture logic).

## 3. Architecture (conservative — routing skeleton unchanged)

```
DragEngine (kept)
  ├─ tap lifecycle: main tap + dedicated mouseMoved tap + gating + trust/backstop
  ├─ per-event handlers (kept, slimmed): delegate to move modes first, else legacy
  ├─ legacy gestures (untouched): maximize, middle, right-resize/panel
  ├─ owns: dragMode, noDragMode  (both WindowMoveMode)
  └─ conforms to MoveContext (exposes the helpers the modes need)

WindowMoveMode (protocol)  — one move-gesture recognizer/driver
  ├─ DragMoveMode      — main modifier + left-button drag
  └─ NoDragMoveMode    — dedicated modifier + mouse-move (buttons-inert, deferred end)

Shared
  ├─ WindowTarget (struct)  — replaces the repeated (pid, windowID, frame, app) tuple
  ├─ MoveContext (protocol) — capabilities the modes borrow from the engine
  └─ TitleBarDragStrategy   — unchanged; each mode owns one instance
```

**Delegation rule:** each relevant handler calls a one-line
`offer(event, type)` that walks the modes; on `.handled(result)` the handler
returns `result`; on `.notHandled` it falls through to the legacy logic. The
handlers and the tap routing stay where they are.

## 4. Components & method division

### 4.1 `WindowTarget` (new — pure data)
```swift
struct WindowTarget: Equatable {
    let pid: pid_t
    let windowID: CGWindowID
    let frame: CGRect
    let app: String
}
```
Replaces the anonymous `(pid: pid_t, windowID: CGWindowID, frame: CGRect, app: String)`
tuple repeated ~10× across `DragEngine`.

### 4.2 `MoveContext` (new — protocol; implemented by `DragEngine`)
The narrow set of engine capabilities a move mode needs — so modes depend on an
interface, not the whole engine:
```swift
protocol MoveContext: AnyObject {
    func windowUnderCursor(at point: CGPoint) -> WindowTarget?
    func isOnPrimaryMenuBar(_ point: CGPoint) -> Bool
    func axGuard(_ site: String) -> Bool
    /// Post a marked synthetic leftMouseUp (HID tap) — used by NoDragMoveMode to
    /// close its synth drag on modifier release.
    func postSyntheticLeftUp(at point: CGPoint)
    func log(_ message: String)
}
```
These already exist on `DragEngine` (`windowUnderCursor`, `isOnPrimaryMenuBar`,
`axGuardOrAbort`, the synthetic-up posting inside `finishNoButtonGesture`,
`FileLog`); the refactor just exposes them through this protocol.

### 4.3 `WindowMoveMode` (new — protocol)
```swift
enum EventDisposition {
    case notHandled                      // not for this mode → engine continues
    case handled(Unmanaged<CGEvent>?)    // consumed → engine returns this from the tap
}

protocol WindowMoveMode: AnyObject {
    var isActive: Bool { get }
    func handle(_ event: CGEvent, type: CGEventType, context: MoveContext) -> EventDisposition
    func abort(context: MoveContext)     // for stop() / tap-disabled cleanup
}
```
Each mode is a self-contained state machine: it inspects `type`, runs its own
lifecycle, and reports whether it consumed the event.

### 4.4 `DragMoveMode` (new)
- **State:** `private let strategy = TitleBarDragStrategy()`. No extra shared
  state (the strategy follows the existing tap-thread-access / main-thread-reset
  pattern), so **no extra lock**.
- **Config (set by the engine):** `modifiers: ModifierCombination`,
  `enabled: Bool`, plus `titleBarYOffset` / `showDebugDot` forwarded to the strategy.
- **`handle`:** `switch type`
  - `.leftMouseDown` → `begin` *only* for a single click with the configured
    modifier over a window (returns `.notHandled` for double-click so the engine
    still does maximize, and `.notHandled` when the modifier doesn't match).
  - `.leftMouseDragged` → `track` (if active).
  - `.leftMouseUp` → `finish` (if active) + drag analytics.
- **Private:** `begin / track / finish`.
- **`abort`:** `strategy.reset()`.

### 4.5 `NoDragMoveMode` (new)
- **State (its own lock):** an `OSAllocatedUnfairLock<State>` holding
  `phase (idle/armed/dragging)`, `target`, `lastCursor`, `yOffset`,
  `realLeftDown`, `pendingEnd`. (Today these live in the engine's `cbState`;
  encapsulating them here is cleaner and is the maintainability win.)
- **Owns:** `private let strategy = TitleBarDragStrategy()`, the modifier config
  `modifiers`, and the matcher `func matches(_ flags: CGEventFlags) -> Bool`
  (flags-only, exact match — the renamed `matchesNoDragModifier`).
- **`handle`:** `switch type`
  - `.mouseMoved` → `arm` (idle) / `engage` (armed→dragging) / `track` (dragging).
  - `.flagsChanged` → on modifier release: `finish` (no real button) or
    `deferEnd` (real left held); on re-press while pending: clear pending.
  - `.leftMouseDown/.leftMouseDragged/.leftMouseUp` and right/other → **inert**
    when `dragging` (the buttons-inert behavior: absorb, drive the follow, or
    rewrite the closing up).
- **Private:** `arm / engage / track / finish / deferEnd / handleLeft… (inert)`.
- **`abort`:** reset state under the lock; `strategy.reset()`; if engaged and no
  real button is down, post the closing up via `context.postSyntheticLeftUp`.

### 4.6 `DragEngine` (changed)
- **Owns** `dragMode` and `noDragMode`; **conforms to `MoveContext`**.
- **Per-handler delegation order** (this is the load-bearing detail):
  - `handleMouseDown`: offer to `noDragMode` first (absorbs the inert real-down
    while a no-drag move is engaged) → then `dragMode` (begin) → else legacy
    (maximize / stale-gesture cleanup / tilingPanel).
  - `handleMouseDragged` / `handleMouseUp`: offer to `noDragMode` (inert) →
    `dragMode` (track/finish) → else legacy.
  - `handleMouseMoved`: offer to `noDragMode` only.
  - `handleRight*` / `handleOther*`: offer to `noDragMode` (inert when engaged) →
    else legacy resize/tile.
  - `handleFlagsChanged`: **engine** does the mouseMoved-tap gating (held edge →
    enable/disable the dedicated tap), using `noDragMode.matches(flags)`; then
    offers the event to `noDragMode` for end/defer.
- **Retains** (not delegated): cross-gesture stale-state cleanup, maximize, the
  tap lifecycle, and the gating state (`mouseMovedTap`, `noDragModifierHeld`).
- **`stop()` / tap-disabled:** call `dragMode.abort` + `noDragMode.abort`.

## 5. Concurrency model

- **`DragMoveMode`:** only touches its `TitleBarDragStrategy`, which already
  follows the accepted "mutated on the tap thread; `reset()` on main in `stop()`"
  pattern. No new lock.
- **`NoDragMoveMode`:** owns its gesture state behind its **own**
  `OSAllocatedUnfairLock` — the same protection the engine's `cbState` gives that
  state today, just encapsulated. Each public method takes the lock for the
  read-decide-mutate step (mirroring the current atomic blocks), then performs
  side effects (post up, log) outside the lock.
- **Engine `cbState`:** keeps tap/trust/tile/right state and the gating fields
  (`mouseMovedTap`, `noDragModifierHeld`). The modifier config setter that drives
  gating stays coordinated in the engine.
- **Net:** the locking *discipline* is unchanged; it's just split from one big
  `cbState` into engine-plumbing state + one per-mode lock.

## 6. Rename: `NoButton*` → `NoDrag*` (all of it)

| Now | After |
|---|---|
| `NoButtonMoveMode` (planned) | `NoDragMoveMode` |
| `noButtonMoveModifiers` | `noDragMoveModifiers` |
| `NoButtonPhase` / `noButtonPhase` | `NoDragPhase` / `noDragPhase` |
| `noButtonStrategy` | `noDragStrategy` (becomes the mode's `strategy`) |
| `noButtonTarget/LastCursor/YOffset/RealLeftDown/PendingEnd/ModifierHeld` | `noDrag…` |
| `matchesNoButtonModifier` | `matchesNoDragModifier` (→ `NoDragMoveMode.matches`) |
| `finishNoButtonGesture` | `finishNoDragGesture` (→ `NoDragMoveMode.finish/abort`) |
| `Preferences.Key.noButtonMoveModifierFlags` **and its string** `"AnyDragNoButtonMoveModifierFlags"` | `noDragMoveModifierFlags` / `"AnyDragNoDragMoveModifierFlags"` |
| L10n keys `experimental.noButtonMove.*` | `experimental.noDragMove.*` |
| `noButtonModifierChipRow` | `noDragModifierChipRow` |
| User-facing copy literally saying "No-button" / "无键" | reworded to a non-ambiguous description (e.g. "modifier + move" / "按住修饰键移动") |

Changing the UserDefaults string resets the experimental modifier once; the user
re-picks it. Accepted (not shipped).

## 7. Staged commits (each compiles & is verifiable)

The refactor lands as a short series of commits, separate from the gating commit:
1. **Scaffold + rename** — add `WindowTarget`, `MoveContext`, `WindowMoveMode`;
   apply the full `NoButton→NoDrag` rename in place (no behavior change yet).
2. **Extract `DragMoveMode`** — move the left-drag-move lifecycle out of the
   engine into the mode; engine delegates. Build + manual-verify drag move.
3. **Extract `NoDragMoveMode`** — move the no-drag lifecycle (incl. buttons-inert
   + deferred end) into the mode; engine delegates; gating stays in the engine.
   Build + manual-verify no-drag move.

## 8. Risks & mitigation
- **Risk:** relocating the just-stabilized no-drag logic + splitting the lock.
- **Mitigation:** behavior-preserving by construction; staged commits each
  build and pass the **same manual test matrix** (drag move; no-drag move;
  buttons-inert; modifier-release end; deferred end; stop/tap-disabled cleanup;
  legacy resize/tile/maximize unaffected; gating still gates). Codex review at
  the end (when its auth is restored), fixing every `[bug]`.

## 9. Verification
No XCTest target. Per project convention: clean build + on-device manual run
after each stage. Regression matrix: every row of §8's mitigation list behaves
exactly as it does on `587e57c` (pre-refactor).
