import AppKit

// MARK: - ResizeFeedback
//
// Pluggable visual indicator shown during a modifier+right-drag resize.
// Implementations draw on top of the target window (mouse-transparent
// borderless panels) to tell the user what's happening — which corner the
// gesture anchored on, how big the window is becoming, etc.
//
// The strategy doesn't know which implementation is wired up; the engine
// picks one at construction time. v1 ships `EdgeGlowFeedback`. v2 will add
// `AnchorDotFeedback` and expose the choice in Settings.
//
// All methods are called on the main thread. The strategy lives on the tap
// thread and dispatches the calls across — implementations don't need to
// worry about thread safety beyond "I'm always on main".

protocol ResizeFeedback: AnyObject {
    /// Gesture started. `windowFrame` is the target window's current frame in
    /// CG screen coords (top-left origin, Y-down). `corner` is the anchor the
    /// strategy picked — it does NOT change for the rest of the gesture.
    func begin(windowFrame: CGRect, corner: ResizeCorner)

    /// Drag in progress. `windowFrame` is the strategy's *predicted* current
    /// frame (derived from cursor delta + the original frame + the corner).
    /// It may diverge from the actual frame if the app enforces a min/max
    /// size — we treat that as acceptable for visual feedback in v1.
    func update(windowFrame: CGRect)

    /// Gesture finished (released, cancelled, or aborted). Implementations
    /// should hide their overlays here. Always paired with a prior `begin`.
    func end()
}

// MARK: - NoResizeFeedback
//
// No-op default. Used when the user has visual feedback turned off (future
// setting) or as the easy null-object in tests. Cheaper to call than an
// optional-and-?. chain on every drag event.

final class NoResizeFeedback: ResizeFeedback {
    func begin(windowFrame: CGRect, corner: ResizeCorner) {}
    func update(windowFrame: CGRect) {}
    func end() {}
}
