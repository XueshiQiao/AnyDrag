import CoreGraphics

/// Result of offering an event to a `WindowMoveMode`.
enum EventDisposition {
    /// Not for this mode — the engine keeps handling the event (legacy path).
    case notHandled
    /// The mode consumed it; the engine returns this value from the tap callback.
    case handled(Unmanaged<CGEvent>?)
}

/// The narrow set of `DragEngine` capabilities a move mode borrows, so the modes
/// depend on an interface rather than the whole engine. Implemented by
/// `DragEngine`.
protocol MoveContext: AnyObject {
    /// Topmost normal window under the given CG screen point (Y-down), or nil.
    func windowUnderCursor(at point: CGPoint) -> WindowTarget?
    /// True when the point is inside the primary screen's menu-bar strip.
    func isOnPrimaryMenuBar(_ point: CGPoint) -> Bool
    /// Belt-and-suspenders AX-trust check at an AX call site; false → caller bails.
    func axGuard(_ site: String) -> Bool
    /// Post a marked synthetic `leftMouseUp` at the HID tap. `NoDragMoveMode`
    /// uses it to close its synthesized title-bar drag on modifier release.
    func postSyntheticLeftUp(at point: CGPoint)
    /// True when the virtual "Hyper" modifier (CapsLock via HyperCapslock) is
    /// currently held — needed by the drag matcher, since Hyper carries no event flag.
    var isHyperHeld: Bool { get }
    /// True when some OTHER gesture (left-drag, middle-drag, resize, tile) owns the
    /// mouse — the no-drag move refuses to arm while one is in flight.
    var isAnotherGestureActive: Bool { get }
    /// Drop any stranded tile/resize gesture state before a fresh move begins
    /// (defensive: a lost otherMouseUp/rightUp could otherwise commit later).
    func clearStrandedGesturesForMoveStart()
    func log(_ message: String)
}

/// One self-contained window-move gesture recognizer + driver. Both concrete
/// modes share `TitleBarDragStrategy` for the actual coordinate work; this
/// protocol captures only the parts that differ between them — which events
/// start the gesture, drive it, and end it.
protocol WindowMoveMode: AnyObject {
    /// True while this mode owns an in-flight gesture.
    var isActive: Bool { get }
    /// Offer an event to the mode. The mode inspects `type`, runs its own state
    /// machine, and reports whether it consumed the event.
    func handle(_ event: CGEvent, type: CGEventType, context: MoveContext) -> EventDisposition
    /// Tear down any in-flight gesture (stop() / tap-disabled cleanup).
    func abort(context: MoveContext)
}
