# No-button Move Prototype — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a prototype trigger — "hold a dedicated modifier and move the mouse (no button) → the window under the cursor follows" — fully isolated behind an opt-in modifier, to evaluate feel and performance before building issue #13's full trigger→action decoupling.

**Architecture:** The window server only moves a window while a button is held, and AX per-frame positioning is forbidden. So we synthesize a held left button using the existing native-title-bar-drag trick: on a qualifying `mouseMoved` we activate the window and (one tick later) inject a `leftMouseDown` at its title bar, rewrite subsequent `mouseMoved` into `leftMouseDragged`, and post a synthetic `leftMouseUp` when the modifier is released (detected via `flagsChanged`). A **dedicated modifier** (separate from the main one) means it never competes with the existing left-drag move.

**Tech Stack:** Swift 5.9, AppKit, CGEvent tap. No third-party deps. XcodeGen project. No XCTest target — verification is build + on-device manual testing (project convention).

**Testing note:** This codebase has no unit-test target, and the mechanism (CGEvent tap + window-server native drag) is fundamentally not unit-testable — it needs real mouse events and a live window server. So tasks end in a **build** check, and the final task is structured **manual on-device verification**. Where a step says "Expected", that is the compiler/app result to confirm before moving on.

**Baseline (already done):** Worktree `worktree-nobutton-move-prototype`; `xcodegen generate` + Debug build succeed.

---

## File structure

| File | Responsibility | Change |
|---|---|---|
| `AnyDrag/Sources/Preferences.swift` | Persistence | New key + apply for the dedicated modifier |
| `AnyDrag/Sources/Settings/ModifierChipRow.swift` | Modifier chip UI | Defaulted `includeHyper` param |
| `AnyDrag/Sources/DragEngine.swift` | Event tap + gesture orchestration | New property, mask entries, state, matcher, `mouseMoved`/`flagsChanged` handlers, finish, cleanup hooks |
| `AnyDrag/Sources/Settings/AdvancedPaneViewController.swift` | Advanced settings pane | New "Experimental" card |
| `AnyDrag/Resources/{en,zh-Hans}.lproj/Localizable.strings` | Localized strings | New keys |

`DragStrategy.swift` and `Analytics.swift` are intentionally **unchanged** (see spec §5.4 / §11).

---

## Task 1: Preferences — dedicated-modifier key

**Files:**
- Modify: `AnyDrag/Sources/Preferences.swift`

- [ ] **Step 1: Add the key**

In `enum Key`, after the `middleAction` key (around `Preferences.swift:15`), add:

```swift
        // Experimental (issue #13 prototype): dedicated modifier for the
        // "modifier + mouse-move, no button → move window" trigger. Absent /
        // empty = feature off. Kept separate from `modifierFlags` so it never
        // competes with the main button-drag gesture.
        static let noButtonMoveModifierFlags = "AnyDragNoButtonMoveModifierFlags"
```

- [ ] **Step 2: Apply it to the engine**

In `static func apply(to engine:)`, after the `middleAction` block (around `Preferences.swift:148`), add:

```swift
        // Experimental no-button move modifier (flags-only; no Hyper). Absent
        // or empty means the feature is off.
        if let raw = d.object(forKey: Key.noButtonMoveModifierFlags) as? UInt {
            engine.noButtonMoveModifiers = ModifierCombination(rawValue: raw)
        } else {
            engine.noButtonMoveModifiers = []
        }
```

- [ ] **Step 3: Build** — `engine.noButtonMoveModifiers` does not exist yet, so this WON'T compile alone. Defer the build to Task 3 Step 9 (which adds the property). Do **not** commit Task 1 by itself.

> Tasks 1–3 land together as one compilable unit; commit at the end of Task 3.

---

## Task 2: ModifierChipRow — optional Hyper chip

**Files:**
- Modify: `AnyDrag/Sources/Settings/ModifierChipRow.swift`

- [ ] **Step 1: Add a defaulted `includeHyper` parameter**

Replace the `init(initial:)` signature and its chip-creation loop. Change:

```swift
    init(initial: ModifierCombination) {
        self.selection = initial
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        setAccessibilityRole(.group)
        setAccessibilityLabel(NSLocalizedString("Modifier Keys", comment: ""))

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        for spec in specs {
```

to:

```swift
    init(initial: ModifierCombination, includeHyper: Bool = true) {
        self.selection = initial
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        setAccessibilityRole(.group)
        setAccessibilityLabel(NSLocalizedString("Modifier Keys", comment: ""))

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let activeSpecs = includeHyper ? specs : specs.filter { $0.element != .hyper }
        for spec in activeSpecs {
```

(The existing main-modifier usage `ModifierChipRow(initial:)` is unaffected — `includeHyper` defaults to `true`.)

- [ ] **Step 2: Build**

Run:
```bash
cd /Users/joey/Code/AnyDrag/.claude/worktrees/nobutton-move-prototype
xcodebuild -project AnyDrag.xcodeproj -scheme AnyDrag -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **` (this change is self-contained).

- [ ] **Step 3: Commit**

```bash
git add AnyDrag/Sources/Settings/ModifierChipRow.swift
git commit -m "feat(settings): optional includeHyper flag on ModifierChipRow"
```

---

## Task 3: DragEngine — no-button move mechanism

**Files:**
- Modify: `AnyDrag/Sources/DragEngine.swift`

All steps edit `DragEngine.swift`. They are interdependent; build only at the end (Step 11).

- [ ] **Step 1: Add the dedicated-modifier property**

After the `var modifiers` block (ends around `DragEngine.swift:202`), add:

```swift
    /// Experimental (issue #13 prototype): dedicated modifier for the
    /// "modifier + mouse-move, no button → move window" trigger. Empty = off.
    /// Read on the tap thread, written on main — same lock-free cross-thread
    /// pattern as `modifiers` (a UInt-backed value; arm64 word reads are atomic).
    var noButtonMoveModifiers: ModifierCombination = []
```

- [ ] **Step 2: Add the dedicated strategy instance**

Next to `private let strategy = TitleBarDragStrategy()` (around `DragEngine.swift:333`), add:

```swift
    /// Separate title-bar-drag strategy instance for the no-button move, so its
    /// state can never collide with the left/middle-drag `strategy`.
    private let noButtonStrategy = TitleBarDragStrategy()
```

- [ ] **Step 3: Sync the tunable offsets to the new strategy**

The no-button strategy must use the same title-bar offset and debug-dot setting. Update the two computed setters.

Change `titleBarYOffset` (around `DragEngine.swift:230`):

```swift
    var titleBarYOffset: CGFloat {
        get { strategy.titleBarYOffset }
        set { strategy.titleBarYOffset = newValue }
    }
```
to:
```swift
    var titleBarYOffset: CGFloat {
        get { strategy.titleBarYOffset }
        set {
            strategy.titleBarYOffset = newValue
            noButtonStrategy.titleBarYOffset = newValue
        }
    }
```

Change `showDebugDot` (around `DragEngine.swift:247`):

```swift
    var showDebugDot: Bool {
        get { strategy.showDebugDot }
        set {
            strategy.showDebugDot = newValue
            resizeStrategy.showDebugDot = newValue
        }
    }
```
to:
```swift
    var showDebugDot: Bool {
        get { strategy.showDebugDot }
        set {
            strategy.showDebugDot = newValue
            resizeStrategy.showDebugDot = newValue
            noButtonStrategy.showDebugDot = newValue
        }
    }
```

- [ ] **Step 4: Add the gesture phase enum + CallbackState fields**

Immediately above `private struct CallbackState {` (around `DragEngine.swift:282`), add the enum:

```swift
    /// Lifecycle of the experimental no-button move gesture.
    /// idle → armed (first qualifying move, click deferred) → dragging.
    private enum NoButtonPhase { case idle, armed, dragging }
```

Inside `struct CallbackState`, after the `lastDiagMissAt` field (around `DragEngine.swift:314`), add:

```swift
        // Experimental no-button move (modifier + mouse-move, no button).
        // Written by the tap thread (mouseMoved/flagsChanged) and by main
        // (stop()), so guarded here with the rest of the shared state.
        var noButtonPhase: NoButtonPhase = .idle
        var noButtonTarget: (pid: pid_t, windowID: CGWindowID, frame: CGRect, app: String)? = nil
        var noButtonLastCursor: CGPoint = .zero
        // Title-bar Y offset captured at arm time, so the engine can post the
        // closing leftMouseUp at the right point without touching strategy state.
        var noButtonYOffset: CGFloat = 0
```

- [ ] **Step 5: Add `.mouseMoved` and `.flagsChanged` to the tap mask**

In `start()`, change the `maskedTypes` array (around `DragEngine.swift:380`):

```swift
        let maskedTypes: [CGEventType] = [
            .leftMouseDown, .leftMouseDragged, .leftMouseUp,
            .rightMouseDown, .rightMouseDragged, .rightMouseUp,
            .otherMouseDown, .otherMouseDragged, .otherMouseUp,
        ]
```
to:
```swift
        let maskedTypes: [CGEventType] = [
            .leftMouseDown, .leftMouseDragged, .leftMouseUp,
            .rightMouseDown, .rightMouseDragged, .rightMouseUp,
            .otherMouseDown, .otherMouseDragged, .otherMouseUp,
            // Experimental no-button move: needs mouse-move tracking and
            // flagsChanged to detect modifier release while stationary.
            .mouseMoved, .flagsChanged,
        ]
```

> Prototype tradeoff (spec §5.2): the mask always includes `mouseMoved`; the
> fast-path bail in Step 7 keeps the disabled cost negligible. The shipping
> version should make the mask conditional on the feature being enabled.

- [ ] **Step 6: Route the new event types**

In `handleEvent(proxy:type:event:)`, in the main `switch type {` (around `DragEngine.swift:756`), add two cases before `default:`:

```swift
        case .mouseMoved:
            return handleMouseMoved(event: event)
        case .flagsChanged:
            return handleFlagsChanged(event: event)
```

- [ ] **Step 7: Add the matcher + the two handlers + finish**

Add this block immediately after `handleMouseUp(event:)` (after the left-button section, around `DragEngine.swift:889`):

```swift
    // MARK: - Experimental No-button Move (modifier + mouse-move, no button)
    //
    // The window server only moves a window while a button is held, and AX
    // per-frame positioning is off the table. So we synthesize a held left
    // button via the title-bar trick (same as the middle-button rewrite path):
    // arm on a qualifying mouseMoved (defer one tick for window reordering),
    // inject a leftMouseDown at the title bar on the next move, rewrite further
    // moves to leftMouseDragged, and post a synthetic leftMouseUp when the
    // dedicated modifier is released.

    /// Exact-match against the dedicated modifier (flags only — no Hyper, no
    /// Option augmentation). Empty target never matches.
    private func matchesNoButtonModifier(_ flags: CGEventFlags) -> Bool {
        let target = noButtonMoveModifiers
        guard !target.isEmpty else { return false }
        let active = flags.subtracting(.maskNonCoalesced).intersection(Self.relevantModifierMask)
        return active == target.eventFlags
    }

    private func handleMouseMoved(event: CGEvent) -> Unmanaged<CGEvent>? {
        // Cheapest bail when the feature is off. If a gesture was somehow live
        // when the modifier got cleared, end it cleanly.
        if noButtonMoveModifiers.isEmpty {
            let live = cbState.withLock { $0.noButtonPhase != .idle }
            if live { finishNoButtonGesture(lastCursor: event.location) }
            return Unmanaged.passUnretained(event)
        }

        let phase = cbState.withLock { $0.noButtonPhase }

        if phase == .idle {
            guard matchesNoButtonModifier(event.flags) else {
                return Unmanaged.passUnretained(event)
            }
            // Never start while another gesture owns the mouse.
            if strategy.isActive || resizeStrategy.isActive {
                return Unmanaged.passUnretained(event)
            }
            let hasTile = cbState.withLock { $0.tileTarget != nil }
            if hasTile { return Unmanaged.passUnretained(event) }

            let screenPoint = event.location
            if Self.isOnPrimaryMenuBar(screenPoint) {
                return Unmanaged.passUnretained(event)
            }
            guard let windowInfo = windowUnderCursor(at: screenPoint) else {
                return Unmanaged.passUnretained(event)
            }
            guard axGuardOrAbort("noButton.arm") else {
                return Unmanaged.passUnretained(event)
            }

            // yOffset must match what noButtonStrategy computes internally
            // (windowFrame.top + titleBarYOffset − cursorAtArm.y) so the posted
            // mouseUp lands consistently.
            let yOffset = windowInfo.frame.origin.y + strategy.titleBarYOffset - screenPoint.y
            cbState.withLock { state in
                state.noButtonTarget = windowInfo
                state.noButtonPhase = .armed
                state.noButtonLastCursor = screenPoint
                state.noButtonYOffset = yOffset
            }
            noButtonStrategy.reset()
            Self.log.info("no-button move arm: app=\"\(windowInfo.app)\" wid=\(windowInfo.windowID)")
            // Suppress this move; activates/raises the window and arms the
            // deferred leftMouseDown (sent on the next move).
            return noButtonStrategy.handleMouseDown(
                pid: windowInfo.pid,
                windowID: windowInfo.windowID,
                windowFrame: windowInfo.frame,
                event: event,
                rewriteToLeftButton: true
            )
        }

        // phase == .armed or .dragging — must still hold the modifier.
        guard matchesNoButtonModifier(event.flags) else {
            finishNoButtonGesture(lastCursor: event.location)
            return Unmanaged.passUnretained(event)
        }
        cbState.withLock { state in
            state.noButtonLastCursor = event.location
            if state.noButtonPhase == .armed { state.noButtonPhase = .dragging }
        }
        // First call after arming sends the leftMouseDown (engage); subsequent
        // calls become leftMouseDragged.
        return noButtonStrategy.handleMouseDragged(event: event)
    }

    private func handleFlagsChanged(event: CGEvent) -> Unmanaged<CGEvent>? {
        let active = cbState.withLock { $0.noButtonPhase != .idle }
        guard active else { return Unmanaged.passUnretained(event) }
        if !matchesNoButtonModifier(event.flags) {
            let lastCursor = cbState.withLock { $0.noButtonLastCursor }
            finishNoButtonGesture(lastCursor: lastCursor)
        }
        return Unmanaged.passUnretained(event)
    }

    /// End an in-flight no-button gesture: reset the strategy and, if a drag was
    /// actually engaged, post a synthetic leftMouseUp to close the native drag.
    /// Safe from the tap thread (mouseMoved/flagsChanged/button-down) and from
    /// main (stop()).
    private func finishNoButtonGesture(lastCursor: CGPoint) {
        let snapshot: (engaged: Bool, yOffset: CGFloat)? = cbState.withLock { state in
            guard state.noButtonPhase != .idle else { return nil }
            let engaged = (state.noButtonPhase == .dragging)
            let yOff = state.noButtonYOffset
            state.noButtonPhase = .idle
            state.noButtonTarget = nil
            state.noButtonYOffset = 0
            return (engaged, yOff)
        }
        guard let snap = snapshot else { return }
        noButtonStrategy.reset()
        Self.log.info("no-button move end (engaged=\(snap.engaged))")
        guard snap.engaged else { return }

        let upPoint = CGPoint(x: lastCursor.x, y: lastCursor.y + snap.yOffset)
        let marker = Self.synthesizedEventMarker
        let mods = noButtonMoveModifiers
        // Post off the tap thread — posting inside the callback can re-enter our
        // own tap synchronously (same reasoning as replayMiddleClick).
        DispatchQueue.main.async {
            if let source = CGEventSource(stateID: .hidSystemState) {
                source.userData = marker
                if let up = CGEvent(
                    mouseEventSource: source,
                    mouseType: .leftMouseUp,
                    mouseCursorPosition: upPoint,
                    mouseButton: .left
                ) {
                    up.post(tap: .cghidEventTap)
                } else {
                    Self.log.warn("no-button finish: failed to create leftMouseUp")
                }
            } else {
                Self.log.warn("no-button finish: CGEventSource creation failed")
            }
            Analytics.trackDrag(trigger: .modifier, modifier: mods)
        }
    }
```

- [ ] **Step 8: Abort the no-button gesture when a real button is pressed**

Add, as the FIRST statement inside each of the three button-down handlers, so a real click during a no-button move ends it cleanly first.

In `handleMouseDown(event:)` (after the line `private func handleMouseDown(event: CGEvent) -> Unmanaged<CGEvent>? {`, around `DragEngine.swift:782`):

```swift
        // A real click while a no-button move is live: end it first.
        let nbActiveL = cbState.withLock { $0.noButtonPhase != .idle }
        if nbActiveL { finishNoButtonGesture(lastCursor: event.location) }
```

In `handleRightMouseDown(event:)` (around `DragEngine.swift:902`), same, with a distinct local name:

```swift
        let nbActiveR = cbState.withLock { $0.noButtonPhase != .idle }
        if nbActiveR { finishNoButtonGesture(lastCursor: event.location) }
```

In `handleOtherMouseDown(event:)` (around `DragEngine.swift:1017`), same:

```swift
        let nbActiveM = cbState.withLock { $0.noButtonPhase != .idle }
        if nbActiveM { finishNoButtonGesture(lastCursor: event.location) }
```

- [ ] **Step 9: Clean up on stop()**

In `stop()`, right after the existing `abortTileGesture()` call (around `DragEngine.swift:506`), add:

```swift
        // End any in-flight no-button move so the window server doesn't keep a
        // dangling drag after teardown.
        let nbLast = cbState.withLock { $0.noButtonLastCursor }
        finishNoButtonGesture(lastCursor: nbLast)
```

- [ ] **Step 10: Clean up on tap-disabled**

In `handleEvent`, inside the `if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {` block, right after the existing `abortTileGesture()` call (around `DragEngine.swift:741`), add:

```swift
            // Same for an in-flight no-button move: the tap missed events while
            // disabled, so drop the gesture (post the up if it was engaged).
            let nbLastDisabled = cbState.withLock { $0.noButtonLastCursor }
            finishNoButtonGesture(lastCursor: nbLastDisabled)
```

- [ ] **Step 11: Build (Tasks 1 + 3 together)**

Run:
```bash
cd /Users/joey/Code/AnyDrag/.claude/worktrees/nobutton-move-prototype
xcodebuild -project AnyDrag.xcodeproj -scheme AnyDrag -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | tail -8
```
Expected: `** BUILD SUCCEEDED **`. If the type-checker complains about the `yOffset` arithmetic line being slow, split it into two `let` statements (this repo has hit Swift type-check-budget issues before — see project memory).

- [ ] **Step 12: Commit**

```bash
git add AnyDrag/Sources/Preferences.swift AnyDrag/Sources/DragEngine.swift
git commit -m "feat(engine): experimental no-button move (modifier + mouse-move) behind dedicated modifier"
```

---

## Task 4: Settings — Experimental card

**Files:**
- Modify: `AnyDrag/Sources/Settings/AdvancedPaneViewController.swift`

- [ ] **Step 1: Add the chip-row property**

After `private let middleActionPicker = MiddleActionCardPicker(initial: .off)` (around `AdvancedPaneViewController.swift:23`), add:

```swift
    /// Experimental (issue #13 prototype): dedicated modifier for no-button move.
    /// Hyper excluded — the CapsLock source is wired to the main modifier only.
    private let noButtonModifierChipRow = ModifierChipRow(initial: ModifierCombination(), includeHyper: false)
    private let noButtonHint = NSTextField(wrappingLabelWithString: "")
```

- [ ] **Step 2: Build the card in `loadView()`**

In `loadView()`, immediately BEFORE the final `let view = NSView()` (around `AdvancedPaneViewController.swift:159`), add:

```swift
        // ─── Experimental card (issue #13 prototype) ──────────────────
        noButtonModifierChipRow.onChange = { [weak self] proposed in
            guard let self = self else { return false }
            let previous = self.dragEngine.noButtonMoveModifiers
            self.dragEngine.noButtonMoveModifiers = proposed
            UserDefaults.standard.set(proposed.rawValue, forKey: Preferences.Key.noButtonMoveModifierFlags)
            if previous != proposed {
                Analytics.trackPreferenceChanged(key: "nobutton_move_modifier", value: proposed.analyticsKey)
            }
            return true
        }

        noButtonHint.font = .systemFont(ofSize: 11)
        noButtonHint.textColor = .secondaryLabelColor
        noButtonHint.lineBreakMode = .byWordWrapping
        noButtonHint.maximumNumberOfLines = 0
        noButtonHint.stringValue = NSLocalizedString("experimental.noButtonMove.hint", comment: "")

        let noButtonBlock = NSStackView(views: [
            SettingsRowBuilder.subLabel(NSLocalizedString("experimental.noButtonMove.label", comment: "")),
            noButtonModifierChipRow,
            noButtonHint,
        ])
        noButtonBlock.orientation = .vertical
        noButtonBlock.alignment = .leading
        noButtonBlock.spacing = 6

        SettingsCardLayout.addSection(
            to: container,
            header: NSLocalizedString("experimental.section", comment: ""),
            rows: [noButtonBlock],
            bottomSpacing: 0
        )
```

> Note: the existing middle-click card above passes `bottomSpacing: 0` as the
> last card. Change that earlier call (around `AdvancedPaneViewController.swift:156`)
> from `bottomSpacing: 0` back to the default by removing the argument, so the
> Experimental card is now the last one with `bottomSpacing: 0`. Concretely:
> in the middle-click `addSection(...)`, delete the `,\n            bottomSpacing: 0`
> line. Leave its `rows: [middleActionPicker, multiDisplayRow.view]` intact.

- [ ] **Step 3: Reflect saved state in `refreshFromState()`**

In `refreshFromState()`, after `middleActionPicker.selection = dragEngine.middleAction` (around `AdvancedPaneViewController.swift:189`), add:

```swift
        noButtonModifierChipRow.selection = dragEngine.noButtonMoveModifiers
```

- [ ] **Step 4: Build**

Run:
```bash
cd /Users/joey/Code/AnyDrag/.claude/worktrees/nobutton-move-prototype
xcodebuild -project AnyDrag.xcodeproj -scheme AnyDrag -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | tail -8
```
Expected: `** BUILD SUCCEEDED **` (strings keys resolve to their key names until Task 5; that's fine for a build).

- [ ] **Step 5: Commit**

```bash
git add AnyDrag/Sources/Settings/AdvancedPaneViewController.swift
git commit -m "feat(settings): Experimental card with dedicated no-button move modifier"
```

---

## Task 5: Localized strings

**Files:**
- Modify: `AnyDrag/Resources/en.lproj/Localizable.strings`
- Modify: `AnyDrag/Resources/zh-Hans.lproj/Localizable.strings`

- [ ] **Step 1: Append the English strings**

Append to `AnyDrag/Resources/en.lproj/Localizable.strings`:

```
/* Settings — Experimental (issue #13 no-button move prototype) */
"experimental.section" = "Experimental";
"experimental.noButtonMove.label" = "No-button move modifier";
"experimental.noButtonMove.hint" = "Hold this modifier (and no mouse button) and move the pointer — the window under it follows, then stops when you release the modifier. Pick a combination different from your main modifier; leave empty to disable. Experimental.";
```

- [ ] **Step 2: Append the Simplified Chinese strings**

Append to `AnyDrag/Resources/zh-Hans.lproj/Localizable.strings`:

```
/* Settings — Experimental (issue #13 no-button move prototype) */
"experimental.section" = "实验性功能";
"experimental.noButtonMove.label" = "无键移动修饰键";
"experimental.noButtonMove.hint" = "按住此修饰键（不按任何鼠标键）移动指针，指针下的窗口会跟随移动，松开修饰键即停止。请选择与主修饰键不同的组合；留空则关闭。实验性功能。";
```

- [ ] **Step 3: Build**

Run:
```bash
cd /Users/joey/Code/AnyDrag/.claude/worktrees/nobutton-move-prototype
xcodebuild -project AnyDrag.xcodeproj -scheme AnyDrag -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add AnyDrag/Resources/en.lproj/Localizable.strings AnyDrag/Resources/zh-Hans.lproj/Localizable.strings
git commit -m "i18n: strings for the Experimental no-button move card"
```

---

## Task 6: Codex review (per project hard rule)

The user's global rule requires a Codex review after any implementation task, fixing at least every `[bug]`-level finding before declaring done.

- [ ] **Step 1: Dispatch Codex review**

Use the `Agent` tool with `subagent_type: codex:codex-rescue`. Scope: the diff on this branch — `DragEngine.swift` (mask, `handleMouseMoved`/`handleFlagsChanged`, `finishNoButtonGesture`, the abort/stop/tap-disabled hooks, the cross-thread `noButtonMoveModifiers` read, the `cbState` additions), plus `Preferences.swift`, `ModifierChipRow.swift`, `AdvancedPaneViewController.swift`. Ask for: correctness (event-tap re-entrancy, lock discipline, gesture lifecycle edge cases — armed-but-never-engaged, lost flagsChanged, button-during-drag, stop/tap-disabled cleanup), and the synthetic-mouseUp pairing with the synthesized down. Review only — no code writing.

- [ ] **Step 2: Fix every `[bug]`-level finding**

Apply fixes; if disagreeing with a flag, record the reasoning explicitly. Re-build after fixes (Task 3 Step 11 command). Commit fixes with a descriptive message.

---

## Task 7: Manual on-device verification

No XCTest exists; verify by running the real app (project rule: build AND launch).

- [ ] **Step 1: Build and launch**

```bash
cd /Users/joey/Code/AnyDrag/.claude/worktrees/nobutton-move-prototype
xcodebuild -project AnyDrag.xcodeproj -scheme AnyDrag -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | tail -3
open build/DerivedData/Build/Products/Debug/AnyDrag-Debug.app
```
Expected: `** BUILD SUCCEEDED **`, app appears in the menu bar. Grant Accessibility if prompted.

- [ ] **Step 2: Confirm feature is OFF by default**

Open Settings → Advanced. The Experimental card shows no chips selected. Verify all existing gestures still behave exactly as before (modifier+left-drag move, right-drag resize, middle action, double-click maximize).

- [ ] **Step 3: Enable and try the no-button move**

In the Experimental card, pick a modifier **different from the main one** (e.g. if main is ⌥, pick ⌃). Then: hold ⌃ (no button) and move the pointer over a Finder window → the window follows the pointer; release ⌃ → it stops where left. Repeat on Safari, a Chromium app, and a custom-titlebar app (e.g. WeChat) to feel the title-bar-anchor behavior.

- [ ] **Step 4: Edge checks**

- Release the modifier while the pointer is **stationary** → window stops (no stick). 
- Click a real mouse button mid-move → the no-button move ends; no stuck drag.
- Tail the log: `tail -f ~/Library/Logs/AnyDrag/AnyDrag.log` → see `no-button move arm` / `no-button move end (engaged=…)` lines.

- [ ] **Step 5: Record findings**

Capture the feel (too twitchy? grab-point needed? threshold?) and any perf observation, to inform whether/how to take the no-button trigger into issue #13's real design (spec §12).

---

## Self-review (done while writing)

- **Spec coverage:** event-tap mask (§5.1) → T3S5; fast-path bail (§5.2) → T3S7; lifecycle arm/engage/track/end (§5.3) → T3S7; strategy reuse no-change (§5.4) → T3S2/S7 (engine owns finish); preferences (§6) → T1; settings UI + Hyper-excluded chip (§7) → T2 + T4; edge cases (§8: real-button abort → T3S8, stationary release → T3S7 flagsChanged, tap-disabled/stop → T3S9/S10, no-window → T3S7, dedicated==main allowed → hint string T5); perf (§9) → T3S5 note; verification (§10) → T7; files (§11) → all tasks; risks (§12) → T7S5.
- **Placeholder scan:** none — every code step has full code; every command has expected output.
- **Type/name consistency:** `noButtonMoveModifiers`, `noButtonStrategy`, `NoButtonPhase`, `noButtonPhase/Target/LastCursor/YOffset`, `matchesNoButtonModifier`, `handleMouseMoved`, `handleFlagsChanged`, `finishNoButtonGesture`, `Preferences.Key.noButtonMoveModifierFlags`, string keys `experimental.section/.noButtonMove.label/.hint` — all used consistently across tasks. `ModifierChipRow(initial:includeHyper:)` matches T2.
