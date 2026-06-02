import Cocoa
import os

/// Move gesture: hold a **dedicated modifier** and move the mouse with **no
/// button**. The window server only moves a window while a button is held, so
/// this mode synthesizes the whole held-left-button via `TitleBarDragStrategy`:
/// arm on the first qualifying move (defer one tick), inject a `leftMouseDown` at
/// the title bar on the next move, rewrite subsequent moves to `leftMouseDragged`,
/// and post a synthetic `leftMouseUp` when the modifier is released.
///
/// Real mouse buttons are inert while engaged: a held left button keeps driving
/// the same synth drag (so the window keeps following), and the move ends only on
/// modifier release. We never HID-inject the closing up while a physical left
/// button is down (that would swallow the real release and wedge the button); if
/// the modifier is released while the left button is held, the end is deferred
/// and the real `leftUp` itself, rewritten, closes the drag.
///
/// The high-frequency `mouseMoved` tap that feeds this mode is enabled/disabled by
/// `DragEngine` (gated on the dedicated modifier being held); that gating is
/// engine plumbing and stays there.
final class NoDragMoveMode: WindowMoveMode {

    /// idle → armed (first qualifying move; click deferred) → dragging.
    enum Phase { case idle, armed, dragging }

    /// Dedicated modifier (kept in sync by the engine). Empty = feature off.
    var modifiers: ModifierCombination = []

    /// Coordinate engine; tunables forwarded by the engine's setters.
    let strategy = TitleBarDragStrategy()

    private struct State {
        var phase: Phase = .idle
        var target: WindowTarget? = nil
        var lastCursor: CGPoint = .zero
        /// Title-bar Y offset captured at arm time, so the closing up lands right.
        var yOffset: CGFloat = 0
        /// A physical left button is currently held during an engaged move.
        var realLeftDown: Bool = false
        /// Modifier was released while the left button was still held — end on the
        /// real leftUp instead of HID-injecting now.
        var pendingEnd: Bool = false
    }
    /// Own lock — the same protection the engine's `cbState` gave this state, now
    /// encapsulated. Read-decide-mutate happens inside the lock; side effects
    /// (post up, log) happen outside it.
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    var isActive: Bool { state.withLock { $0.phase != .idle } }

    /// Exact flag match against the dedicated modifier (no Hyper, no Option
    /// augmentation). Empty target — or a flag-less combination — never matches,
    /// so plain pointer movement can't trigger the gesture.
    func matches(_ flags: CGEventFlags) -> Bool {
        let targetFlags = modifiers.eventFlags
        guard !targetFlags.isEmpty else { return false }
        let active = flags.subtracting(.maskNonCoalesced).intersection(Self.relevantModifierMask)
        return active == targetFlags
    }

    private static let relevantModifierMask = CGEventFlags([
        .maskAlternate, .maskCommand, .maskControl, .maskShift, ModifierCombination.fnEventFlag
    ])

    func handle(_ event: CGEvent, type: CGEventType, context: MoveContext) -> EventDisposition {
        switch type {
        case .mouseMoved:
            return handleMoved(event, context: context)
        case .flagsChanged:
            handleFlags(event, context: context)
            return .notHandled   // engine still passes it through + runs gating
        case .leftMouseDown:
            return handleLeftDown(event, context: context)
        case .leftMouseDragged:
            return handleLeftDragged(event)
        case .leftMouseUp:
            return handleLeftUp(event, context: context)
        case .rightMouseDown, .otherMouseDown:
            return handleOtherButtonDown(event, type: type, context: context)
        case .rightMouseDragged, .rightMouseUp:
            return inertWhileDragging()
        case .otherMouseDragged, .otherMouseUp:
            // Only the middle button is inert; side buttons (3,4) pass through.
            guard event.getIntegerValueField(.mouseEventButtonNumber) == 2 else { return .notHandled }
            return inertWhileDragging()
        default:
            return .notHandled
        }
    }

    func abort(context: MoveContext) {
        finish(context: context)
    }

    // MARK: - mouseMoved (arm / engage / track)

    private func handleMoved(_ event: CGEvent, context: MoveContext) -> EventDisposition {
        let phase = state.withLock { $0.phase }

        if phase == .idle {
            guard matches(event.flags) else { return .notHandled }
            if context.isAnotherGestureActive { return .notHandled }
            let screenPoint = event.location
            guard !context.isOnPrimaryMenuBar(screenPoint) else { return .notHandled }
            guard let target = context.windowUnderCursor(at: screenPoint) else { return .notHandled }
            guard context.axGuard("noDrag.arm") else { return .notHandled }

            // yOffset must match what `strategy` computes internally
            // (windowTop + titleBarYOffset − cursorAtArm.y) so the posted up lands right.
            let windowTop = target.frame.origin.y
            let yOffset = windowTop + strategy.titleBarYOffset - screenPoint.y
            state.withLock { st in
                st.target = target
                st.phase = .armed
                st.lastCursor = screenPoint
                st.yOffset = yOffset
                st.realLeftDown = false
                st.pendingEnd = false
            }
            strategy.reset()
            context.log("no-drag move arm: app=\"\(target.app)\" wid=\(target.windowID)")
            // Suppress this move; activate/raise + arm the deferred leftMouseDown.
            return .handled(strategy.handleMouseDown(
                pid: target.pid, windowID: target.windowID, windowFrame: target.frame,
                event: event, rewriteToLeftButton: true
            ))
        }

        // armed / dragging — must still hold the modifier.
        guard matches(event.flags) else {
            finish(context: context)
            return .handled(Unmanaged.passUnretained(event))
        }
        state.withLock { st in
            st.lastCursor = event.location
            if st.phase == .armed { st.phase = .dragging }
        }
        // First call after arming sends the leftMouseDown (engage); later calls
        // become leftMouseDragged. Returned (not re-injected), so they flow to the
        // window server without re-entering our tap.
        return .handled(strategy.handleMouseDragged(event: event))
    }

    // MARK: - flagsChanged (end / defer)

    private func handleFlags(_ event: CGEvent, context: MoveContext) {
        let stillHeld = matches(event.flags)
        enum Action { case ignore, deferEnd, finishNow }
        let action: Action = state.withLock { st in
            guard st.phase != .idle else { return .ignore }
            if stillHeld { st.pendingEnd = false; return .ignore }
            if st.realLeftDown { st.pendingEnd = true; return .deferEnd }
            return .finishNow
        }
        switch action {
        case .deferEnd:
            context.log("no-drag: modifier released while left held — deferring end")
        case .finishNow:
            finish(context: context)
        case .ignore:
            break
        }
    }

    // MARK: - buttons-inert

    private func handleLeftDown(_ event: CGEvent, context: MoveContext) -> EventDisposition {
        // Record the physical-down atomically with the phase read.
        let phase = state.withLock { st -> Phase in
            if st.phase == .dragging { st.realLeftDown = true }
            return st.phase
        }
        if phase == .dragging {
            // Window keeps following via the leftMouseDragged events that follow;
            // don't let this real down reach the window server.
            return .handled(nil)
        }
        if phase == .armed {
            // Not yet engaged (no synth drag) — reset and let the click proceed.
            finish(context: context)
        }
        return .notHandled
    }

    private func handleLeftDragged(_ event: CGEvent) -> EventDisposition {
        guard state.withLock({ $0.phase == .dragging }) else { return .notHandled }
        state.withLock { $0.lastCursor = event.location }
        return .handled(strategy.handleMouseDragged(event: event))
    }

    private func handleLeftUp(_ event: CGEvent, context: MoveContext) -> EventDisposition {
        enum Up { case notEngaged, swallow, rewriteEnd }
        let up: Up = state.withLock { st in
            guard st.phase == .dragging else { return .notEngaged }
            st.realLeftDown = false
            guard st.pendingEnd else { return .swallow }
            st.phase = .idle
            st.target = nil
            st.yOffset = 0
            st.lastCursor = .zero
            st.pendingEnd = false
            return .rewriteEnd
        }
        switch up {
        case .rewriteEnd:
            // Rewrite this real up into the synth drag's closing leftMouseUp
            // (coordinate-correct → no jump; not HID-injected → nothing swallowed).
            context.log("no-drag move end (via real leftUp, rewritten)")
            return .handled(strategy.handleMouseUp(event: event))
        case .swallow:
            // Modifier still held — keep the move alive; mouseMoved resumes the follow.
            return .handled(nil)
        case .notEngaged:
            return .notHandled
        }
    }

    private func handleOtherButtonDown(_ event: CGEvent, type: CGEventType, context: MoveContext) -> EventDisposition {
        let phase = state.withLock { $0.phase }
        if phase == .dragging {
            // Right button is inert; for otherMouse only the middle button is inert.
            if type == .rightMouseDown { return .handled(nil) }
            if event.getIntegerValueField(.mouseEventButtonNumber) == 2 { return .handled(nil) }
            return .notHandled
        }
        if phase == .armed {
            // Reset the (not-yet-engaged) gesture and let the click proceed.
            finish(context: context)
        }
        return .notHandled
    }

    private func inertWhileDragging() -> EventDisposition {
        state.withLock({ $0.phase == .dragging }) ? .handled(nil) : .notHandled
    }

    // MARK: - finish

    /// End an in-flight gesture: reset, and (if a drag was engaged and no physical
    /// left button is down) post the closing synthetic leftMouseUp.
    private func finish(context: MoveContext) {
        let snap: (engaged: Bool, yOffset: CGFloat, lastCursor: CGPoint, realLeftDown: Bool)? = state.withLock { st in
            guard st.phase != .idle else { return nil }
            let engaged = (st.phase == .dragging)
            let s = (engaged, st.yOffset, st.lastCursor, st.realLeftDown)
            st.phase = .idle
            st.target = nil
            st.yOffset = 0
            st.lastCursor = .zero
            st.realLeftDown = false
            st.pendingEnd = false
            return s
        }
        guard let snap else { return }
        strategy.reset()
        context.log("no-drag move end (engaged=\(snap.engaged))")
        guard snap.engaged else { return }
        // Physical left button still down (only via stop()/tap-disabled mid-hold —
        // the modifier-release paths defer instead). Don't HID-inject: leave the
        // drag for the real release to end.
        guard !snap.realLeftDown else {
            context.log("no-drag finish: skipping HID up (physical left button down)")
            return
        }
        let upPoint = CGPoint(x: snap.lastCursor.x, y: snap.lastCursor.y + snap.yOffset)
        context.postSyntheticLeftUp(at: upPoint)
        let mods = modifiers
        DispatchQueue.main.async {
            Analytics.trackDrag(trigger: .modifier, modifier: mods)
        }
    }
}
