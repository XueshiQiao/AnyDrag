import Cocoa

/// Move gesture: hold the main modifier and drag with the **left button**. The
/// user's real left button supplies the held-button state the window server
/// needs; this mode only recognizes the trigger and drives `TitleBarDragStrategy`
/// to rewrite coordinates. Maximize (double-click) and the legacy middle/right
/// gestures stay in `DragEngine`.
final class DragMoveMode: WindowMoveMode {

    /// Main modifier combination (kept in sync by the engine).
    var modifiers: ModifierCombination = .option
    /// Mirrors `DragEngine.dragEnabled`.
    var enabled: Bool = true

    /// The coordinate engine. Its tunables are forwarded by the engine's setters.
    let strategy = TitleBarDragStrategy()

    /// Real CGEventFlags this mode considers (mirrors `DragEngine`'s mask).
    private static let relevantModifierMask = CGEventFlags([
        .maskAlternate, .maskCommand, .maskControl, .maskShift, ModifierCombination.fnEventFlag
    ])

    var isActive: Bool { strategy.isActive }

    /// Modifier match with the same rules as the engine's button gestures:
    /// virtual Hyper (CapsLock) when selected + held, exact flag match, or the
    /// base combo plus an extra Option (so macOS's own Option-tiling still works).
    private func matches(_ flags: CGEventFlags, hyperHeld: Bool) -> Bool {
        if modifiers.contains(.hyper) && hyperHeld { return true }
        let active = flags.subtracting(.maskNonCoalesced).intersection(Self.relevantModifierMask)
        let target = modifiers.eventFlags
        guard !target.isEmpty else { return false }
        if active == target { return true }
        guard modifiers.supportsOptionAugmentation else { return false }
        return active == target.union(.maskAlternate)
    }

    func handle(_ event: CGEvent, type: CGEventType, context: MoveContext) -> EventDisposition {
        switch type {
        case .leftMouseDown:
            // Don't consume a double-click (engine does maximize) or a non-matching
            // / disabled / already-active case — let the engine's legacy path run.
            guard !strategy.isActive, enabled else { return .notHandled }
            guard event.getIntegerValueField(.mouseEventClickState) != 2 else { return .notHandled }
            guard matches(event.flags, hyperHeld: context.isHyperHeld) else { return .notHandled }
            let screenPoint = event.location
            guard !context.isOnPrimaryMenuBar(screenPoint) else { return .notHandled }
            guard let target = context.windowUnderCursor(at: screenPoint) else { return .notHandled }
            guard context.axGuard("DragMoveMode.begin") else { return .notHandled }
            context.clearStrandedGesturesForMoveStart()
            strategy.reset()
            context.log("drag start: app=\"\(target.app)\" wid=\(target.windowID)")
            return .handled(strategy.handleMouseDown(
                pid: target.pid, windowID: target.windowID, windowFrame: target.frame, event: event
            ))

        case .leftMouseDragged:
            guard strategy.isActive else { return .notHandled }
            return .handled(strategy.handleMouseDragged(event: event))

        case .leftMouseUp:
            guard strategy.isActive else { return .notHandled }
            let didDrag = strategy.didDrag
            let mods = modifiers
            let result = strategy.handleMouseUp(event: event)
            if didDrag {
                DispatchQueue.main.async {
                    Analytics.trackDrag(trigger: .modifier, modifier: mods)
                }
            }
            return .handled(result)

        default:
            return .notHandled
        }
    }

    func abort(context: MoveContext) {
        strategy.reset()
    }
}
