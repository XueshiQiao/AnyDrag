import Cocoa
import os

/// Move gesture: hold a **dedicated modifier** and move the mouse with **no
/// button**. The window server only moves a window while a button is held, so we
/// synthesize one with the title-bar trick:
///   - arm on the first qualifying move (raise the target, defer one tick),
///   - on the next move **rewrite** it into a `leftMouseDown` at the title bar and
///     return it (the window server grabs the title bar; the cursor never jumps
///     because we rewrite-and-return rather than post),
///   - rewrite each further move into a `leftMouseDragged` at the title-bar-relative
///     point so the window follows the cursor 1:1,
///   - **post** the matching `leftMouseUp` when the modifier is released.
///
/// The closing up is the one event we must post (the move ends on a modifier
/// release, with no mouse event to rewrite). It is posted from a source whose
/// `localEventsSuppressionInterval` is 0 — the default 0.25s would suppress the
/// start of the *next* move's real mouse movement, starving its opening drag and
/// making rapid back-to-back moves fail in clusters (the bug that made this feature
/// look unreliable). The post warps the cursor to the title-bar point, so we warp
/// it back under the user's hand immediately after.
///
/// **Stuck-drag safety.** Every teardown path posts the closing up (modifier
/// release, abort, tap-disabled), and a watchdog force-releases past
/// `watchdogSeconds`, so the window server can't be left thinking a drag is in
/// flight for more than a few seconds.
///
/// Real mouse buttons are inert while engaged; the move ends only on modifier
/// release (or the safety backstops).
final class NoDragMoveMode: WindowMoveMode {

    /// idle → armed (first qualifying move; down deferred) → dragging.
    enum Phase { case idle, armed, dragging }

    /// Dedicated modifier (kept in sync by the engine). Empty = feature off.
    var modifiers: ModifierCombination = []

    /// Used to raise/activate the target window at arm time, and for its tunable
    /// `titleBarYOffset`. The drag coordinates are rewritten here in the mode.
    let strategy = TitleBarDragStrategy()

    /// Absolute cap on a single move; the watchdog force-releases past this so a
    /// synthesized drag can never be left open indefinitely.
    private static let watchdogSeconds: TimeInterval = 8

    private struct State {
        var phase: Phase = .idle
        var target: WindowTarget? = nil
        /// Title-bar Y minus the cursor Y at engage — added to every move's Y so the
        /// window-server drag tracks the cursor 1:1 from the title-bar grab.
        var yOffset: CGFloat = 0
        /// Last rewritten (title-bar-relative) drag point — where the closing
        /// `leftMouseUp` is posted, matching the window server's drag position.
        var lastDragPoint: CGPoint = .zero
        /// A synthesized drag is in flight (an up is owed to release it).
        var engaged: Bool = false
        /// Bumped on every engage/teardown so a stale watchdog no-ops.
        var generation: Int = 0
        /// Monotonic time of the last arm/engage/track activity. The watchdog
        /// force-releases only after `watchdogSeconds` of *inactivity*, so an active
        /// long drag is never dropped mid-move.
        var lastActivityNanos: UInt64 = 0
    }
    /// Own lock. Read-decide-mutate happens inside the lock; side effects (post
    /// events, log) happen outside it.
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
        case .leftMouseDragged:
            return inertWhileDragging()   // no physical button drives us; swallow strays
        case .leftMouseDown:
            return handleLeftDown(event, context: context)
        case .leftMouseUp:
            return inertWhileDragging()
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
            state.withLock { st in
                st.target = target
                st.phase = .armed
                st.engaged = false
            }
            strategy.reset()
            context.log("no-drag move arm: app=\"\(target.app)\" wid=\(target.windowID)")
            // Suppress this move and raise/activate the target. The synthesized
            // leftMouseDown is sent on the next move (one tick lets the raise settle).
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

        enum Step { case engage(down: CGPoint, generation: Int); case track(relabeled: CGPoint) }
        let step: Step = state.withLock { st in
            st.lastActivityNanos = DispatchTime.now().uptimeNanoseconds
            if st.phase == .armed, let t = st.target {
                let phys = event.location
                let titleBarY = t.frame.origin.y + strategy.titleBarYOffset
                st.yOffset = titleBarY - phys.y
                st.phase = .dragging
                st.engaged = true
                st.generation += 1
                let down = CGPoint(x: phys.x, y: titleBarY)
                st.lastDragPoint = down
                return .engage(down: down, generation: st.generation)
            }
            let relabeled = CGPoint(x: event.location.x, y: event.location.y + st.yOffset)
            st.lastDragPoint = relabeled
            return .track(relabeled: relabeled)
        }

        switch step {
        case .engage(let down, let generation):
            // Rewrite this move into a leftMouseDown at the title bar and RETURN it
            // (not posted) — so the cursor doesn't jump to the title bar and back.
            armWatchdog(generation: generation, context: context)
            event.type = .leftMouseDown
            event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
            event.location = down
            event.flags = event.flags.subtracting(.maskControl)
            return .handled(Unmanaged.passUnretained(event))

        case .track(let relabeled):
            // Feed the window server a leftMouseDragged at the title-bar-relative
            // point. Returned (not posted), so the cursor stays under the hand.
            event.type = .leftMouseDragged
            event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
            event.location = relabeled
            // Control turns a left action into a secondary click at the AppKit layer.
            event.flags = event.flags.subtracting(.maskControl)
            return .handled(Unmanaged.passUnretained(event))
        }
    }

    // MARK: - flagsChanged (end)

    private func handleFlags(_ event: CGEvent, context: MoveContext) {
        let stillHeld = matches(event.flags)
        let shouldFinish = state.withLock { $0.phase != .idle && !stillHeld }
        if shouldFinish { finish(context: context) }
    }

    // MARK: - buttons inert while engaged

    private func handleLeftDown(_ event: CGEvent, context: MoveContext) -> EventDisposition {
        let phase = state.withLock { $0.phase }
        if phase == .dragging {
            return .handled(nil)   // real left press during the synth drag — swallow
        }
        if phase == .armed {
            finish(context: context)   // not engaged yet — reset, let the click proceed
        }
        return .notHandled
    }

    private func handleOtherButtonDown(_ event: CGEvent, type: CGEventType, context: MoveContext) -> EventDisposition {
        let phase = state.withLock { $0.phase }
        if phase == .dragging {
            if type == .rightMouseDown { return .handled(nil) }
            if event.getIntegerValueField(.mouseEventButtonNumber) == 2 { return .handled(nil) }
            return .notHandled
        }
        if phase == .armed {
            finish(context: context)
        }
        return .notHandled
    }

    private func inertWhileDragging() -> EventDisposition {
        state.withLock({ $0.phase == .dragging }) ? .handled(nil) : .notHandled
    }

    // MARK: - watchdog (stuck-drag backstop)

    private func armWatchdog(generation gen: Int, context: MoveContext, after delay: TimeInterval? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? Self.watchdogSeconds)) { [weak self, weak context] in
            guard let self, let context else { return }
            enum Action { case ignore, release, rearm(TimeInterval) }
            let action: Action = self.state.withLock { st in
                guard st.phase == .dragging, st.generation == gen, st.engaged else { return .ignore }
                // Idle-based: only release after watchdogSeconds with no activity, so
                // a genuinely active long drag re-arms instead of being dropped.
                let idle = Double(DispatchTime.now().uptimeNanoseconds &- st.lastActivityNanos) / 1_000_000_000
                return idle >= Self.watchdogSeconds ? .release : .rearm(Self.watchdogSeconds - idle)
            }
            switch action {
            case .ignore:
                break
            case .release:
                context.log("no-drag move WATCHDOG: idle \(Int(Self.watchdogSeconds))s — force-releasing")
                self.finish(context: context)
            case .rearm(let remaining):
                self.armWatchdog(generation: gen, context: context, after: remaining)
            }
        }
    }

    // MARK: - finish

    /// End an in-flight gesture: reset, and (if a drag was engaged) post the closing
    /// `leftMouseUp` so the window server can't be left mid-drag.
    private func finish(context: MoveContext) {
        let snap: (engaged: Bool, upPoint: CGPoint, app: String, windowID: CGWindowID, armFrame: CGRect)? = state.withLock { st in
            guard st.phase != .idle else { return nil }
            let s = (st.engaged, st.lastDragPoint,
                     st.target?.app ?? "?", st.target?.windowID ?? 0, st.target?.frame ?? .zero)
            st.phase = .idle
            st.target = nil
            st.yOffset = 0
            st.lastDragPoint = .zero
            st.engaged = false
            st.generation += 1   // invalidate any pending watchdog
            return s
        }
        guard let snap else { return }
        strategy.reset()
        guard snap.engaged else { return }
        // Reliability monitor: did the window server actually move the window?
        // A run of moved=false would mean the no-drag synth drag is failing again.
        let moved = Self.currentFrame(of: snap.windowID).map { now in
            abs(now.origin.x - snap.armFrame.origin.x) > 1 || abs(now.origin.y - snap.armFrame.origin.y) > 1
        }
        context.log("no-drag move end: app=\"\(snap.app)\" moved=\(moved.map(String.init) ?? "unknown")")
        context.postSyntheticLeftUp(at: snap.upPoint)
        let mods = modifiers
        DispatchQueue.main.async {
            Analytics.trackDrag(trigger: .modifier, modifier: mods)
        }
    }

    /// Live frame of a window by id (top-left origin), or nil. Powers the
    /// reliability monitor in `finish`.
    private static func currentFrame(of windowID: CGWindowID) -> CGRect? {
        guard windowID != 0,
              let infos = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = infos.first,
              let boundsValue = info[kCGWindowBounds as String]
        else { return nil }
        let boundsDict = boundsValue as! CFDictionary
        return CGRect(dictionaryRepresentation: boundsDict)
    }
}
