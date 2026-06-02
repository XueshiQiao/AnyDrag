import CoreGraphics

/// The window AnyDrag is acting on: the CG window id, owning pid, current CG
/// frame (top-left origin), and the owner app name (used in logs). Replaces the
/// anonymous `(pid: pid_t, windowID: CGWindowID, frame: CGRect, app: String)`
/// tuple that used to be repeated across `DragEngine`.
struct WindowTarget: Equatable {
    let pid: pid_t
    let windowID: CGWindowID
    let frame: CGRect
    let app: String
}
