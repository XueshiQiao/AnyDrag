import Cocoa
import ApplicationServices

// MARK: - Protocol

protocol DragStrategy: AnyObject {
    /// Called on modifier+mouseDown. Return rewritten event to pass through, nil to suppress.
    func handleMouseDown(pid: pid_t, windowID: CGWindowID, windowFrame: CGRect, event: CGEvent) -> Unmanaged<CGEvent>?
    /// Called on mouseDragged while drag is active.
    func handleMouseDragged(event: CGEvent) -> Unmanaged<CGEvent>?
    /// Called on mouseUp while drag is active.
    func handleMouseUp(event: CGEvent) -> Unmanaged<CGEvent>?
    /// Whether a drag is in progress.
    var isActive: Bool { get }
    /// Reset internal state.
    func reset()
}

// MARK: - Title Bar Simulation Strategy

/// Rewrites mouse event coordinates to the window's title bar region.
/// The window server handles movement natively — same speed as dragging a title bar by hand.
final class TitleBarDragStrategy: DragStrategy {

    private(set) var isActive = false
    private var xOffset: CGFloat = 0
    private var yOffset: CGFloat = 0

    // Fallback: right of green button, vertically centered
    private let fallbackDragX: CGFloat = 60
    private let fallbackDragY: CGFloat = 6

    func handleMouseDown(pid: pid_t, windowID: CGWindowID, windowFrame: CGRect, event: CGEvent) -> Unmanaged<CGEvent>? {
        let cursorPos = event.location

        let t0 = CACurrentMediaTime()
        let dragPoint = titleBarDragPoint(pid: pid, windowFrame: windowFrame)
        let elapsed = (CACurrentMediaTime() - t0) * 1000.0
        NSLog("AnyDrag: [perf] titleBarDragPoint=%.1fms -> (\(dragPoint.x), \(dragPoint.y))", elapsed)

        let targetX = dragPoint.x
        let targetY = dragPoint.y

        xOffset = targetX - cursorPos.x
        yOffset = targetY - cursorPos.y

        event.location = CGPoint(x: targetX, y: targetY)
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

    /// Get a safe drag point: just right of the green (zoom) button's right edge, same Y center.
    /// Falls back to hardcoded position if AX lookup fails.
    private func titleBarDragPoint(pid: pid_t, windowFrame: CGRect) -> CGPoint {
        let fallback = CGPoint(x: windowFrame.origin.x + fallbackDragX, y: windowFrame.origin.y + fallbackDragY)

        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let axWindow = windows.first(where: { axWindowMatches($0, frame: windowFrame) })
        else { return fallback }

        // Get the zoom (green) button
        var zoomRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXZoomButtonAttribute as CFString, &zoomRef) == .success,
              let zoomButton = zoomRef
        else { return fallback }

        // Get button position and size
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

        // Place drag point 10px right of green button's right edge, vertically centered
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

// MARK: - Accessibility API Strategy

/// Moves windows via AXUIElementSetAttributeValue. Universal fallback.
final class AccessibilityDragStrategy: DragStrategy {

    private(set) var isActive = false
    private var axWindow: AXUIElement?
    private var startCursor: CGPoint = .zero
    private var startWindowOrigin: CGPoint = .zero
    private let dragThreshold: CGFloat = 3.0
    private var thresholdExceeded = false

    // Perf stats
    private var moveCount = 0
    private var totalAXTime: Double = 0
    private var maxAXTime: Double = 0

    func handleMouseDown(pid: pid_t, windowID: CGWindowID, windowFrame: CGRect, event: CGEvent) -> Unmanaged<CGEvent>? {
        startCursor = event.location
        thresholdExceeded = false
        isActive = true

        // Defer AX lookup to first drag
        // Store info for later
        axWindow = nil
        startWindowOrigin = windowFrame.origin

        // Find AX window eagerly but don't block — it's only ~1-4ms
        if let axWin = findAXWindow(pid: pid, expectedFrame: windowFrame) {
            axWindow = axWin
            var posRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &posRef)
            if let posValue = posRef, CFGetTypeID(posValue) == AXValueGetTypeID() {
                var pos = CGPoint.zero
                AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
                startWindowOrigin = pos
            }
        }

        return nil // suppress
    }

    func handleMouseDragged(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let axWin = axWindow else {
            return Unmanaged.passRetained(event)
        }

        let screenPoint = event.location

        if !thresholdExceeded {
            let dx = screenPoint.x - startCursor.x
            let dy = screenPoint.y - startCursor.y
            if dx * dx + dy * dy < dragThreshold * dragThreshold {
                return nil
            }
            thresholdExceeded = true
        }

        let dx = screenPoint.x - startCursor.x
        let dy = screenPoint.y - startCursor.y
        var newOrigin = CGPoint(x: startWindowOrigin.x + dx, y: startWindowOrigin.y + dy)

        let t0 = CACurrentMediaTime()
        if let value = AXValueCreate(.cgPoint, &newOrigin) {
            AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, value)
        }
        let elapsed = (CACurrentMediaTime() - t0) * 1000.0
        moveCount += 1
        totalAXTime += elapsed
        if elapsed > maxAXTime { maxAXTime = elapsed }

        return nil
    }

    func handleMouseUp(event: CGEvent) -> Unmanaged<CGEvent>? {
        if !thresholdExceeded {
            // Was a click, not a drag — synthesize the original mouseDown
            if let syntheticDown = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: startCursor,
                mouseButton: .left
            ) {
                syntheticDown.post(tap: .cgSessionEventTap)
            }
            isActive = false
            return Unmanaged.passRetained(event)
        }

        let avg = moveCount > 0 ? totalAXTime / Double(moveCount) : 0
        NSLog("AnyDrag: [perf] drag done: AX calls=\(moveCount) avg=%.2fms max=%.1fms total=%.0fms", avg, maxAXTime, totalAXTime)
        isActive = false
        return nil
    }

    func reset() {
        isActive = false
        axWindow = nil
        startCursor = .zero
        startWindowOrigin = .zero
        thresholdExceeded = false
        moveCount = 0
        totalAXTime = 0
        maxAXTime = 0
    }

    // MARK: - AX Window Matching

    private func findAXWindow(pid: pid_t, expectedFrame: CGRect) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        for axWin in windows {
            var posRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &posRef)
            guard let posValue = posRef, CFGetTypeID(posValue) == AXValueGetTypeID() else { continue }
            var pos = CGPoint.zero
            AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)

            if abs(pos.x - expectedFrame.origin.x) < 5 && abs(pos.y - expectedFrame.origin.y) < 5 {
                return axWin
            }
        }

        if windows.count == 1 {
            return windows.first
        }

        return nil
    }
}
