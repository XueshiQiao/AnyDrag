import Cocoa
import ApplicationServices

/// Rewrites mouse event coordinates to the window's title bar region.
/// The window server handles movement natively — same speed as dragging a title bar by hand.
final class TitleBarDragStrategy {

    private(set) var isActive = false
    private var xOffset: CGFloat = 0
    private var yOffset: CGFloat = 0

    // Fallback when AX can't locate the zoom button
    private let fallbackDragX: CGFloat = 60
    private let fallbackDragY: CGFloat = 6

    func handleMouseDown(pid: pid_t, windowID: CGWindowID, windowFrame: CGRect, event: CGEvent) -> Unmanaged<CGEvent>? {
        let cursorPos = event.location
        let dragPoint = titleBarDragPoint(pid: pid, windowFrame: windowFrame)

        xOffset = dragPoint.x - cursorPos.x
        yOffset = dragPoint.y - cursorPos.y

        event.location = dragPoint
        isActive = true
        return Unmanaged.passRetained(event)
    }

    func handleMouseDragged(event: CGEvent) -> Unmanaged<CGEvent>? {
        let pos = event.location
        event.location = CGPoint(x: pos.x + xOffset, y: pos.y + yOffset)
        return Unmanaged.passRetained(event)
    }

    func handleMouseUp(event: CGEvent) -> Unmanaged<CGEvent>? {
        let pos = event.location
        event.location = CGPoint(x: pos.x + xOffset, y: pos.y + yOffset)
        isActive = false
        return Unmanaged.passRetained(event)
    }

    func reset() {
        isActive = false
        xOffset = 0
        yOffset = 0
    }

    // MARK: - Title Bar Drag Point

    /// Returns a point just right of the green (zoom) button via AX.
    /// Falls back to hardcoded offset if AX lookup fails.
    private func titleBarDragPoint(pid: pid_t, windowFrame: CGRect) -> CGPoint {
        let fallback = CGPoint(x: windowFrame.origin.x + fallbackDragX, y: windowFrame.origin.y + fallbackDragY)

        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let axWindow = windows.first(where: { axWindowMatches($0, frame: windowFrame) })
        else { return fallback }

        var zoomRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXZoomButtonAttribute as CFString, &zoomRef) == .success,
              let zoomButton = zoomRef
        else { return fallback }

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(zoomButton as! AXUIElement, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(zoomButton as! AXUIElement, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, CFGetTypeID(posVal) == AXValueGetTypeID(),
              let sizeVal = sizeRef, CFGetTypeID(sizeVal) == AXValueGetTypeID()
        else { return fallback }

        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)

        return CGPoint(x: pos.x + size.width + 10, y: pos.y + size.height / 2)
    }

    private func axWindowMatches(_ axWin: AXUIElement, frame: CGRect) -> Bool {
        var posRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &posRef)
        guard let posVal = posRef, CFGetTypeID(posVal) == AXValueGetTypeID() else { return false }
        var pos = CGPoint.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
        return abs(pos.x - frame.origin.x) < 5 && abs(pos.y - frame.origin.y) < 5
    }
}
