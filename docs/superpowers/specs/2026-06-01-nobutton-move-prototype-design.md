# No-button Move Prototype — Design

**Date:** 2026-06-01
**Issue:** #13 — Decouple triggers from actions: configurable gesture → action mapping
**Status:** Design approved (verbal); spec under review
**Scope of THIS spec:** Phase 1 only — a throwaway-able prototype of one new trigger.

---

## 1. Background & why this comes first

Issue #13 asks to split the **trigger** (what gesture you do) from the **action**
(what AnyDrag does) so any trigger can map to any action. The headline-new
capability in that issue is a brand-new trigger:

> **Modifier + mouse move (no button pressed) → move window.**

Everything else in #13 (a trigger→action mapping table, settings UI, migration)
is a clean but medium refactor over mechanisms that already work. The no-button
trigger is the only genuinely uncertain piece, because it collides with the core
mechanism AnyDrag is built on.

The user's decision was to **invert the phasing**: build the risky no-button move
as an isolated prototype first, feel it out (handling + performance), and only
then design the full decouple. This spec covers that prototype.

The mapping/decouple work (left/right-drag swap between Move/Resize, fold the
no-button trigger into a small mapping, settings UI, migration) is **out of scope
here** and will get its own spec after the prototype is evaluated.

## 2. The core problem

AnyDrag never moves windows via the Accessibility API — AX per-frame positioning
is permanently off the table (its latency is the entire reason this project
exists). Instead, `TitleBarDragStrategy` rewrites mouse-event coordinates so the
**window server** performs a native title-bar drag: zero per-frame IPC.

But a native title-bar drag **requires a mouse button to be physically held** —
the window server only keeps moving a window while a button is down in the event
stream. "Modifier + move, no button" has no button-down for it to latch onto.

The only viable resolution that stays inside AnyDrag's architecture is to
**synthesize a held left button**: inject a `leftMouseDown` at the title bar,
rewrite each `mouseMoved` into a `leftMouseDragged`, and inject a `leftMouseUp`
when the gesture ends. This is the same trick the existing middle-button path
already uses (`TitleBarDragStrategy.rewriteToLeftButton`, which fabricates a
left-button drag from `otherMouse*` events) — so the rewrite half is proven.

The genuinely new part is the **gesture lifecycle**: there are no button
transitions to anchor start/end on. Start comes from "modifier held + mouse
moved"; end comes from "modifier released" — which must be detected via
`flagsChanged`, because releasing the modifier while the cursor is stationary
produces no `mouseMoved` and would otherwise leave the window stuck to the cursor.

## 3. Goals / non-goals

### Goals
- Prove the no-button move mechanism works and feels acceptable on real apps.
- Get a real read on the performance cost of tapping `mouseMoved`.
- Keep it fully isolated: **zero impact on existing behavior unless explicitly
  enabled.**

### Non-goals (this phase)
- No-button **resize** (comes after move is validated — cheap once the pattern
  is proven).
- The trigger→action **mapping table** and settings rework.
- Migration of existing preferences.
- Localization polish beyond the strings the prototype needs.
- Hyper/CapsLock support for the dedicated modifier (see §7).

## 4. Key design decision: a dedicated modifier

The prototype uses a **separate modifier from the main one**, so it never
competes with the existing `modifier + left-drag = move` gesture. (Sharing the
main modifier would mean "hold modifier, twitch before clicking" silently starts
a no-button move — the exact conflict #13 flags. A dedicated modifier removes it
from the experiment entirely.)

Semantics mirror the existing main modifier: the dedicated modifier is a
`ModifierCombination`, and **empty = feature off**. Default is empty, so the
prototype is opt-in and costs nothing until the user picks a combination.

## 5. Architecture

### 5.1 Event tap changes (`DragEngine`)
- Add `.mouseMoved` and `.flagsChanged` to the tap's `eventMask`
  (`DragEngine.start()`), alongside the existing 9 button event types.
- Route them in `handleEvent`:
  - `.mouseMoved` → `handleMouseMoved(event:)`
  - `.flagsChanged` → `handleFlagsChanged(event:)`

### 5.2 Fast-path short-circuit (performance)
`handleMouseMoved` must bail as early and cheaply as possible. It does real work
only when **either** the dedicated modifier is non-empty AND currently held,
**or** a no-button gesture is already active. Idle mouse movement (feature off)
costs at most a couple of branch checks beyond the existing per-event
trust/counter bookkeeping.

> **Prototype simplification (documented tradeoff):** the tap mask *always*
> includes `mouseMoved`/`flagsChanged`; we rely on the fast-path bail when the
> feature is off. The per-`mouseMoved` lock+counter still runs, but at typical
> move rates that is negligible CPU. **The shipping version should instead use a
> conditional mask** — only add `mouseMoved`/`flagsChanged` to the tap when the
> dedicated modifier is non-empty, restarting the tap on change — so a disabled
> feature pays exactly zero. We keep the prototype simple to avoid tap-restart
> race surface while evaluating feel.

### 5.3 Gesture lifecycle
State lives in `cbState` (the existing `OSAllocatedUnfairLock<CallbackState>`),
consistent with the other gestures. Fields: the captured target window, the last
cursor point, and a phase flag.

1. **Arm** — a `mouseMoved` arrives, dedicated modifier held, no active gesture,
   and `windowUnderCursor` finds a window (and not on the primary menu bar):
   activate + raise the window (reuse the existing app-activate/AX-raise path),
   record the target, mark the gesture "armed", and **suppress** this event
   (return `nil`). Deferring one tick mirrors the button path, giving the window
   server time to finish reordering before the synthesized click.
2. **Engage** — next `mouseMoved`: inject a `leftMouseDown` at the window's
   title-bar anchor (`windowFrame.top + titleBarYOffset`, the existing offset).
   The window server begins a native title-bar drag.
3. **Track** — subsequent `mouseMoved`: rewrite `type = .leftMouseDragged`,
   button 0, `y += yOffset`. Window follows the cursor 1:1. Continuously record
   the last cursor point for the eventual synthetic mouse-up.
4. **End** — `flagsChanged` shows the dedicated modifier no longer satisfied →
   **post** a synthetic `leftMouseUp` (via `CGEvent` at HID tap, marked with the
   existing `synthesizedEventMarker`) at `lastCursor + yOffset` to close the
   native drag. Reset state.

### 5.4 Strategy reuse (`TitleBarDragStrategy`) — no changes
Validated during planning: **`TitleBarDragStrategy` needs no modification.**
- Use a **dedicated instance** (`noButtonStrategy`) so its state can never
  collide with the left/middle-drag instance.
- Its existing `rewriteToLeftButton: true` path already overwrites the event
  type (`.leftMouseDown` on engage, `.leftMouseDragged` on track) and forces
  button 0 — so a `.mouseMoved` source event flows through unchanged. No new
  entry point is needed.
- The no-button gesture has **no real `mouseUp`** to rewrite, so the **engine**
  synthesizes and posts the closing `leftMouseUp` itself. It can do this without
  reaching into the strategy because it knows the title-bar Y offset from
  arm-time geometry (`windowFrame.origin.y + titleBarYOffset − cursorAtArm.y`).
  After posting, the engine calls `noButtonStrategy.reset()`.
- The strategy's existing Control-flag stripping
  (`modifierFlagsToStrip = [.maskControl]`) is retained as-is — required so a
  synthesized Control+leftMouseDown isn't reinterpreted as a secondary click.

## 6. Preferences

- New key: `AnyDragNoButtonMoveModifierFlags` (`UInt` bitmask), absent → empty →
  off.
- `DragEngine.noButtonMoveModifiers: ModifierCombination`, applied in
  `Preferences.apply(to:)`.
- No migration; this is additive and defaults off.

## 7. Settings UI

A single new **"Experimental"** card (in the Advanced pane, below the existing
cards), containing one control: a modifier chip row for the no-button move,
reusing the existing `ModifierChipRow`. A short hint explains: pick a combination
**different from your main modifier** to enable; leave empty to disable.

- The chip row offers the flag modifiers only (⌘⌥⌃⇧fn). **Hyper/CapsLock is
  excluded** for the prototype: the `HyperCapslockCapsHoldSource` is currently
  wired to the main modifier only, and wiring a second consumer is unnecessary
  coupling for an experiment.
- Wiring mirrors the existing modifier chip: on change, set the engine property,
  persist, fire a `preference_changed` analytics event (key
  `nobutton_move_modifier`).

## 8. Edge cases & conflict handling

- **Mouse buttons during the move — "buttons inert" (revised after testing).**
  The original plan was to *end* the move on a real button press. In practice
  that fought the synthesized left button: an HID-injected closing `leftMouseUp`
  posted while the physical button was down **swallowed the user's real release**
  and wedged the window server's left button down (symptoms: the move got stuck
  until a plain click, and the window jumped its title bar to the cursor when the
  stuck drag finally ended). Confirmed via on-device event logging, not guessed.

  The shipped behavior makes the real button **cooperate** with the synth drag
  instead of fighting it: while a move is **engaged**, real button events are
  inert and never reach the window server. A held left button simply keeps
  driving the *same* synth drag (its `leftMouseDragged` events are rewritten to
  the title-bar offset, so the window keeps following continuously — no freeze,
  no jump). The move ends **only** when the dedicated modifier is released.
  - Right/middle buttons are likewise inert while engaged.
  - **Never HID-inject a closing up while a physical left button is down.** If
    the modifier is released while the left button is still held, the end is
    *deferred* (`pendingEnd`): the window keeps following until the real
    `leftMouseUp`, which is itself **rewritten** into the coordinate-correct
    closing up (no HID injection → nothing swallowed; correct coords → no jump).
- **Modifier released while stationary:** handled by `flagsChanged` (the whole
  reason we tap it). At that point no button is down (a `mouseMoved`-driven move),
  so the HID-injected closing up is safe.
- **tap-disabled / stop():** reset no-button state and post the closing up
  **unless a physical left button is down** (then skip the HID up — the real
  release will end the drag — to avoid re-introducing the wedge during teardown).
- **No window under cursor at arm time:** do nothing (pass through), same as the
  button paths.
- **Dedicated modifier equals / overlaps main modifier:** allowed but pointless;
  the hint warns against it. Not enforced in the prototype.

All the per-handler no-button branches read and mutate the shared phase/flags in
a **single `cbState.withLock`** so a concurrent `stop()`/tap-disabled cleanup
can't interleave between a read and the dependent write; gesture arming also
clears the flags as defense-in-depth.

## 9. Performance notes

- Tap now sees `mouseMoved` (high frequency). The fast-path bail keeps the
  disabled cost to branch checks + the existing per-event lock/counter.
- When **enabled**, the user is feeling the real "always-on `mouseMoved` tap"
  cost — which is exactly the data point this prototype exists to gather. The
  `tapDisabledByTimeout` backstop already in place covers a too-slow callback.

## 10. Verification

No XCTest target exists; verification is a clean build plus on-device manual
testing (per project convention):
- Build and **launch the .app** from DerivedData.
- With the dedicated modifier set: hold it, move over a window → window follows;
  release → window stops where left. Try Finder, Safari, a Chromium app, and a
  custom-titlebar app (e.g. WeChat) for the title-bar-offset behavior.
- Confirm with the feature **off** (empty modifier) that all existing gestures
  behave exactly as before.
- Watch `~/Library/Logs/AnyDrag/AnyDrag.log` (FileLog) for the gesture lifecycle
  lines.

## 11. Files expected to change

- `AnyDrag/Sources/DragEngine.swift` — mask + `handleMouseMoved` /
  `handleFlagsChanged` + lifecycle state + dedicated-modifier matcher +
  dedicated `noButtonStrategy` instance + synthetic finish + button-handler/stop
  cleanup hooks.
- `AnyDrag/Sources/Preferences.swift` — new key + apply.
- `AnyDrag/Sources/Settings/ModifierChipRow.swift` — defaulted `includeHyper`
  parameter so the prototype's chip row can omit ⇪.
- `AnyDrag/Sources/Settings/AdvancedPaneViewController.swift` — Experimental card.
- `AnyDrag/Resources/en.lproj/Localizable.strings` +
  `zh-Hans.lproj/Localizable.strings` — the few new strings.
- **No change** to `DragStrategy.swift` (see §5.4) or `Analytics.swift` (reuse
  the existing `.modifier` drag trigger + `trackPreferenceChanged`).

## 12. Risks / open questions for evaluation

- **Feel:** grab-less following may be too twitchy without an explicit grab
  point. If so, options for the real feature: a small movement threshold before
  engaging, or requiring the modifier to be *pressed* (not already held) at the
  start.
- **Cross-app robustness:** the title-bar anchor trick already varies by app
  (hence the tunable offset); no-button move inherits that.
- **Production perf:** confirm the conditional-mask refinement (§5.2) before
  shipping outside the experiment.
