# Move-Mode Abstraction — Implementation Plan

> **For agentic workers:** Pure refactor — **behavior must not change**. Execute task-by-task; after each task, build AND manually re-verify the regression matrix before committing. Steps use checkbox (`- [ ]`).

**Goal:** Extract the two window-move gestures (drag move, no-drag move) into a small `WindowMoveMode` abstraction so the shared title-bar-drag lifecycle is unified and the differing trigger/track/end logic lives in one focused type per mode; rename all `NoButton*` → `NoDrag*`.

**Architecture:** Conservative — `DragEngine` keeps the tap lifecycle, gating, event-routing skeleton, and the legacy maximize/middle/resize gestures. Each relevant handler offers the event to the move modes first (`.handled` → return; `.notHandled` → legacy). `DragEngine` conforms to `MoveContext`; the modes borrow only the narrow capabilities they need. `NoDragMoveMode` owns its gesture state behind its own lock; `DragMoveMode` only wraps a `TitleBarDragStrategy`.

**Tech Stack:** Swift 5.9, AppKit, CGEvent tap. No XCTest target → verify by clean build + on-device manual run.

**Spec:** `docs/superpowers/specs/2026-06-02-move-mode-abstraction-design.md`

**Regression matrix (must behave identically to `587e57c` after every task):**
1. modifier + left-drag → window moves; release → stops.
2. dedicated modifier + move (no button) → window follows; release modifier → stops, no jump.
3. buttons-inert: press/drag/release a real button mid no-drag move → window keeps following; no stuck, no jump.
4. release modifier while left held (deferred end) → ends cleanly on button release.
5. left double-click + modifier → maximize/restore (legacy).
6. right-drag → resize; right-click → TilingPanel (legacy).
7. middle (drag / tile-by-direction) (legacy).
8. mouseMoved gating: with feature off, no mouseMoved processing; with feature on, only while modifier held.
9. stop()/AX-revoke and re-grant → clean teardown/restart.

---

## File structure

| File | Responsibility | Change |
|---|---|---|
| `AnyDrag/Sources/Move/WindowTarget.swift` | the `(pid, windowID, frame, app)` data | **Create** |
| `AnyDrag/Sources/Move/MoveContext.swift` | `MoveContext` + `WindowMoveMode` + `EventDisposition` protocols | **Create** |
| `AnyDrag/Sources/Move/DragMoveMode.swift` | modifier + left-drag move | **Create** |
| `AnyDrag/Sources/Move/NoDragMoveMode.swift` | dedicated modifier + mouse-move move | **Create** |
| `AnyDrag/Sources/DragEngine.swift` | tap lifecycle, gating, routing, legacy gestures, `MoveContext` conformance | **Modify** |
| `AnyDrag/Sources/Preferences.swift` | rename key + string | **Modify** |
| `AnyDrag/Sources/Settings/AdvancedPaneViewController.swift` | rename chip row + l10n keys | **Modify** |
| `AnyDrag/Resources/{en,zh-Hans}.lproj/Localizable.strings` | rename keys + reword copy | **Modify** |

XcodeGen note: sources are globbed by `project.yml` (the `AnyDrag/Sources` path), so new files under `AnyDrag/Sources/Move/` are picked up by `xcodegen generate`. Run it before building.

---

## Task 1 — Scaffold + full NoButton→NoDrag rename (no behavior change)

Introduce the new types and rename everything, *without* yet moving logic into the modes. After this task the modes exist but are unused; the engine still runs the (renamed) inline logic.

**Files:** create the four `Move/*.swift`; modify `DragEngine.swift`, `Preferences.swift`, `AdvancedPaneViewController.swift`, both `.strings`.

- [ ] **Step 1: Create `WindowTarget`**
`AnyDrag/Sources/Move/WindowTarget.swift`:
```swift
import CoreGraphics

/// The window AnyDrag is acting on: the CG window id, owning pid, current CG
/// frame (top-left origin), and the owner app name (for logs). Replaces the
/// anonymous (pid, windowID, frame, app) tuple that used to be repeated across
/// DragEngine.
struct WindowTarget: Equatable {
    let pid: pid_t
    let windowID: CGWindowID
    let frame: CGRect
    let app: String
}
```

- [ ] **Step 2: Create `MoveContext` + `WindowMoveMode`**
`AnyDrag/Sources/Move/MoveContext.swift`:
```swift
import CoreGraphics

/// Result of offering an event to a move mode.
enum EventDisposition {
    /// Not for this mode — the engine should keep handling it (legacy path).
    case notHandled
    /// The mode consumed it; the engine returns this value from the tap.
    case handled(Unmanaged<CGEvent>?)
}

/// The narrow set of engine capabilities a move mode borrows, so modes depend on
/// an interface rather than the whole DragEngine. Implemented by DragEngine.
protocol MoveContext: AnyObject {
    func windowUnderCursor(at point: CGPoint) -> WindowTarget?
    func isOnPrimaryMenuBar(_ point: CGPoint) -> Bool
    /// Belt-and-suspenders AX-trust check at an AX call site; false → caller bails.
    func axGuard(_ site: String) -> Bool
    /// Post a marked synthetic leftMouseUp at the HID tap (NoDragMoveMode uses it
    /// to close its synthesized drag on modifier release).
    func postSyntheticLeftUp(at point: CGPoint)
    func log(_ message: String)
}

/// One self-contained window-move gesture recognizer + driver. Both concrete
/// modes share TitleBarDragStrategy for the coordinate work; this protocol
/// captures only the parts that differ (trigger / track source / end / cancel).
protocol WindowMoveMode: AnyObject {
    var isActive: Bool { get }
    func handle(_ event: CGEvent, type: CGEventType, context: MoveContext) -> EventDisposition
    func abort(context: MoveContext)
}
```

- [ ] **Step 3: Create empty `DragMoveMode` / `NoDragMoveMode` skeletons**
`AnyDrag/Sources/Move/DragMoveMode.swift` and `NoDragMoveMode.swift` — minimal conforming stubs that compile and are inert (`isActive=false`, `handle` returns `.notHandled`, `abort` no-op). Each holds `let strategy = TitleBarDragStrategy()` and the config properties they will need (`modifiers`, `enabled`, forwarded `titleBarYOffset`/`showDebugDot`). NoDragMoveMode also declares its `OSAllocatedUnfairLock<State>` with the moved fields (phase enum, target, lastCursor, yOffset, realLeftDown, pendingEnd). They are NOT wired into the engine yet. (Full bodies land in Tasks 2–3.)

- [ ] **Step 4: Rename `NoButton*` → `NoDrag*` across the codebase**
Apply the §6 mapping from the spec, in place (engine still runs the logic inline; we only rename):
- `DragEngine.swift`: `noButtonMoveModifiers`→`noDragMoveModifiers`, `NoButtonPhase`→`NoDragPhase`, `noButtonPhase`→`noDragPhase`, `noButtonStrategy`→`noDragStrategy`, `noButtonTarget/LastCursor/YOffset/RealLeftDown/PendingEnd/ModifierHeld`→`noDrag…`, `matchesNoButtonModifier`→`matchesNoDragModifier`, `finishNoButtonGesture`→`finishNoDragGesture`, plus log strings and comments mentioning "no-button".
- `Preferences.swift`: constant `noButtonMoveModifierFlags`→`noDragMoveModifierFlags`; string value `"AnyDragNoButtonMoveModifierFlags"`→`"AnyDragNoDragMoveModifierFlags"`.
- `AdvancedPaneViewController.swift`: `noButtonModifierChipRow`→`noDragModifierChipRow`, `noButtonHint`→`noDragHint`; l10n keys `experimental.noButtonMove.label/.hint`→`experimental.noDragMove.label/.hint`; analytics key `"nobutton_move_modifier"`→`"nodrag_move_modifier"`.
- `en.lproj` / `zh-Hans.lproj`: rename keys `experimental.noButtonMove.*`→`experimental.noDragMove.*`; reword the values away from "no-button/无键" (e.g. en: `"Modifier + move (no button)"` label / hint describing the behavior; zh: `"修饰键 + 移动鼠标"` label, hint unchanged in meaning). Keep them descriptive and unambiguous.

- [ ] **Step 5: Generate + build**
```bash
cd /Users/joey/Code/AnyDrag/.claude/worktrees/nobutton-move-prototype
xcodegen generate >/dev/null
xcodebuild -project AnyDrag.xcodeproj -scheme AnyDrag -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```
Expected: `** BUILD SUCCEEDED **`. (Modes exist but unused; the renamed inline logic still runs.)

- [ ] **Step 6: Launch + regression-check** rows 1–9. Behavior identical to before.

- [ ] **Step 7: Commit**
```bash
git add AnyDrag project.yml AnyDrag.xcodeproj 2>/dev/null; git add -A
git commit -m "refactor(move): scaffold WindowMoveMode abstraction + rename NoButton→NoDrag"
```

---

## Task 2 — Extract `DragMoveMode`

Move the modifier+left-drag lifecycle out of the engine into `DragMoveMode`. Maximize, stale-gesture cleanup, tilingPanel, and middle-drag stay in the engine.

**Files:** `DragMoveMode.swift`, `DragEngine.swift`.

- [ ] **Step 1: Implement `DragMoveMode`**
Holds `private let strategy = TitleBarDragStrategy()`; config `var modifiers`, `var enabled`, forwarded `titleBarYOffset`/`showDebugDot`. `isActive { strategy.isActive }`.
`handle(event,type,context)`:
- `.leftMouseDown`: if `strategy.isActive` is false, `enabled`, `clickState != 2`, `context`-matched modifier (move the engine's `matchesConfiguredModifier` flag logic into a `matches(_:)` here OR pass a precomputed match — see Step 2), not on menu bar, and `windowUnderCursor` returns a target, and `axGuard` passes → `strategy.reset()`; `context.log("drag start …")`; return `.handled(strategy.handleMouseDown(pid:windowID:windowFrame:event:))`. Otherwise `.notHandled`.
- `.leftMouseDragged`: `guard strategy.isActive else { return .notHandled }`; return `.handled(strategy.handleMouseDragged(event:))`.
- `.leftMouseUp`: `guard strategy.isActive else { return .notHandled }`; capture `didDrag`; `let r = strategy.handleMouseUp(event:)`; if didDrag, fire drag analytics on main; return `.handled(r)`.
- default: `.notHandled`.
`abort(context)`: `strategy.reset()`.

> Modifier matching: `DragMoveMode` needs the main modifier + the "+Option augmentation" rule. Move `matchesConfiguredModifier` into `DragMoveMode` (it only needs `event.flags` and `modifiers`), or keep it on the engine and have the engine pre-gate before delegating. **Decision:** keep `matchesConfiguredModifier` on the engine (other legacy handlers use it too) and have `DragMoveMode` receive the already-matched decision is awkward; instead give `DragMoveMode` its own `matches(_ flags:)` copy of that small pure function. (Duplication is ~6 lines of pure logic; acceptable and keeps the mode self-contained.)

- [ ] **Step 2: Wire the engine to delegate the left-drag path**
In `DragEngine`:
- Add `private let dragMode = DragMoveMode()`; in `Preferences.apply`/config, set `dragMode.modifiers = modifiers`, `dragMode.enabled = dragEnabled`; forward `titleBarYOffset`/`showDebugDot` to `dragMode.strategy` too. Keep `dragMode.modifiers` in sync wherever `modifiers`/`dragEnabled` change.
- `handleMouseDown`: after the no-drag inert hook and the maximize (double-click) branch and the stale-cleanup, replace the inline `strategy.handleMouseDown(...)` left-drag block with: `if case .handled(let r) = dragMode.handle(event, type: .leftMouseDown, context: self) { return r }` then fall through. (Maximize and stale-cleanup stay in the engine, BEFORE delegating; `dragMode` returns `.notHandled` for double-clicks so maximize still runs.)
- `handleMouseDragged`: `if case .handled(let r) = dragMode.handle(event, type: .leftMouseDragged, context: self) { return r }` then existing fallthrough.
- `handleMouseUp`: same with `.leftMouseUp`.
- `stop()` / tap-disabled: call `dragMode.abort(context: self)` (replaces the `strategy.reset()` that served left-drag; the engine's `strategy` now serves only middle-drag).
- Conform `DragEngine: MoveContext` (expose `windowUnderCursor`→`WindowTarget`, `isOnPrimaryMenuBar`, `axGuard`→`axGuardOrAbort`, `postSyntheticLeftUp`, `log`). Note `windowUnderCursor` currently returns a tuple → change it to return `WindowTarget` and update all call sites (middle/right/maximize too).

- [ ] **Step 3: Generate + build** (same commands as Task 1 Step 5). Expected `BUILD SUCCEEDED`.
- [ ] **Step 4: Launch + regression-check** rows 1, 5, 6, 7 especially (left-drag move, maximize, resize, middle) — all unchanged.
- [ ] **Step 5: Commit**
```bash
git add -A
git commit -m "refactor(move): extract DragMoveMode for modifier+left-drag"
```

---

## Task 3 — Extract `NoDragMoveMode`

Move the no-drag lifecycle (arm/engage/track + buttons-inert + deferred end) into `NoDragMoveMode`. The mouseMoved-tap gating stays in the engine.

**Files:** `NoDragMoveMode.swift`, `DragEngine.swift`.

- [ ] **Step 1: Implement `NoDragMoveMode`**
- State behind `OSAllocatedUnfairLock<State>` where `State { phase: NoDragPhase, target: WindowTarget?, lastCursor: CGPoint, yOffset: CGFloat, realLeftDown: Bool, pendingEnd: Bool }`.
- Owns `private let strategy = TitleBarDragStrategy()`, `var modifiers`, and `func matches(_ flags: CGEventFlags) -> Bool` (the renamed `matchesNoDragModifier`: flags-only exact match, guard on `eventFlags` non-empty).
- `isActive { lock.withLock { $0.phase != .idle } }`.
- `handle(event,type,context)`: port the current bodies verbatim, replacing `cbState`→the mode's lock, `noButtonStrategy`→`strategy`, `finishNoButtonGesture()`→`finish(context:)`, the synth-up post→`context.postSyntheticLeftUp`, `windowUnderCursor`/`isOnPrimaryMenuBar`/`axGuardOrAbort`→`context.…`, logs→`context.log`. Specifically:
  - `.mouseMoved` → the current `handleMouseMoved` body (arm/engage/track), minus the engine-level `noDragMoveModifiers.isEmpty` short-circuit (the gating already ensures we only get mouseMoved while held; keep a cheap `guard matches(event.flags) ...` for the idle arm).
  - `.flagsChanged` → the END/defer half only (finish / deferEnd). The held-edge gating stays in the engine (Step 2). Return `.notHandled` (engine still passes the event through and runs gating).
  - `.leftMouseDown` → if `phase == .dragging`: set `realLeftDown=true`, return `.handled(nil)`; else `.notHandled`.
  - `.leftMouseDragged` → if `phase == .dragging`: update lastCursor, return `.handled(strategy.handleMouseDragged(event:))`; else `.notHandled`.
  - `.leftMouseUp` → if `phase == .dragging`: the current atomic `notEngaged/swallow/rewriteEnd` block → `.handled(nil)` or `.handled(strategy.handleMouseUp(event:))`; else `.notHandled`.
  - `.rightMouseDown/.rightMouseUp/.otherMouseDown/.otherMouseDragged/.otherMouseUp` → if `phase == .dragging`: inert → `.handled(nil)`; else `.notHandled`.
  - default `.notHandled`.
- `abort(context)`: under lock capture+reset; `strategy.reset()`; if was engaged and `!realLeftDown`, `context.postSyntheticLeftUp(at: lastCursor offset)`. (= the renamed `finishNoDragGesture` minus the now-engine-owned bits.)

- [ ] **Step 2: Wire the engine to delegate + keep gating**
- Add `private let noDragMode = NoDragMoveMode()`; set `noDragMode.modifiers` from `noDragMoveModifiers`; forward offset/debugDot to `noDragMode.strategy`.
- Each handler offers to `noDragMode` FIRST (before `dragMode`/legacy): `handleMouseDown/Dragged/Up`, `handleRight*`, `handleOther*`, `handleMouseMoved`: `if case .handled(let r) = noDragMode.handle(event, type: <type>, context: self) { return r }`.
- `handleFlagsChanged`: keep the engine's gating block (held-edge via `noDragMode.matches(event.flags)` → enable/disable `mouseMovedTap`), THEN offer the event to `noDragMode` for end/defer: `_ = noDragMode.handle(event, type: .flagsChanged, context: self)`; return passthrough.
- Remove the now-moved inline no-drag code from the engine (the `cbState` no-drag fields, `noDragStrategy`, `matchesNoDragModifier`, `finishNoDragGesture`, the `handleMouseMoved` body, the no-drag halves of the button handlers). Keep `noDragModifierHeld` + `mouseMovedTap` (gating) in `cbState`.
- `stop()` / tap-disabled: `noDragMode.abort(context: self)` replaces `finishNoDragGesture()`.
- `noDragMoveModifiers` didSet: set `noDragMode.modifiers`, reset gating (`noDragModifierHeld=false`, disable tap) as today.

- [ ] **Step 3: Generate + build.** Expected `BUILD SUCCEEDED`. If the type-checker flags slow expressions, split locals (project has hit this before).
- [ ] **Step 4: Launch + full regression matrix (rows 1–9).** Pay special attention to rows 2, 3, 4, 8.
- [ ] **Step 5: Commit**
```bash
git add -A
git commit -m "refactor(move): extract NoDragMoveMode; engine keeps tap gating"
```

---

## Task 4 — Final review

- [ ] **Step 1: Codex review** (when its auth is restored — `codex login`). Scope: the whole refactor diff `git diff 587e57c..HEAD -- AnyDrag/Sources`. Ask for: behavior-equivalence vs the pre-refactor logic, the new lock discipline in `NoDragMoveMode`, the delegation order correctness (no event double-handled or dropped), and `MoveContext` boundary. Fix every `[bug]`. If Codex is unavailable, do a careful self-review of the same diff against the regression matrix and note it.
- [ ] **Step 2: Final clean build + launch**, regression matrix rows 1–9 one more time.

---

## Self-review (done while writing)

- **Spec coverage:** WindowTarget §4.1→T1S1; MoveContext/WindowMoveMode §4.2–4.3→T1S2; DragMoveMode §4.4→T2; NoDragMoveMode §4.5→T3; engine delegation §4.6→T2S2/T3S2; concurrency §5→T3S1 (per-mode lock) + T2 (strategy pattern); rename §6→T1S4; staged commits §7→T1/T2/T3; risks/verification §8–9→regression matrix + T4.
- **Placeholder scan:** the one judgment call (DragMoveMode owning a `matches` copy vs engine pre-gate) is decided explicitly in T2S1, not left open.
- **Type/name consistency:** `WindowTarget`, `MoveContext`, `WindowMoveMode`, `EventDisposition`, `DragMoveMode`, `NoDragMoveMode`, `NoDragPhase`, `noDragMoveModifiers`, `matchesNoDragModifier`/`matches`, `finishNoDragGesture`/`abort` used consistently; `windowUnderCursor` returns `WindowTarget` everywhere after T2S2.
