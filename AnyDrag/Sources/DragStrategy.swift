import Cocoa
import ApplicationServices

// MARK: - How Title Bar Drag Simulation Works
//
// Instead of using the Accessibility API to set window positions (slow, ~5-10ms IPC per frame),
// we trick the window server into thinking the user is dragging the title bar:
//
// 1. modifier+mouseDown: suppress the event, activate the target app and raise the window.
// 2. First mouseDragged (~8ms later): convert it into a mouseDown at the window's title bar
//    (y = windowFrame.top + 3px, x = cursor's original x). The window server sees a title bar
//    click and begins a native drag. The ~8ms gap ensures window reordering has completed.
// 3. Subsequent mouseDragged: rewrite Y by a fixed offset (yOffset = titleBarY - cursorY) so
//    the window server sees movement relative to the title bar click point. X is unchanged.
//    The delta matches the real mouse movement, so the window follows the cursor 1:1.
// 4. mouseUp: rewrite Y with the same offset, ending the native drag.
//
// Result: zero per-frame IPC. The window server moves the window directly at compositor level,
// identical in performance to manually dragging a title bar.

/// Rewrites mouse event coordinates to the window's title bar region.
/// The window server handles movement natively — same speed as dragging a title bar by hand.
final class TitleBarDragStrategy {

    private(set) var isActive = false
    private var yOffset: CGFloat = 0
    private var dragPoint: CGPoint = .zero
    private var needsInitialMouseDown = false

    func handleMouseDown(pid: pid_t, windowID: CGWindowID, windowFrame: CGRect, event: CGEvent) -> Unmanaged<CGEvent>? {
        let cursorPos = event.location

        // Drag point: cursor's X (on an exposed part of the window), Y at the very top of
        // the title bar (3px from window top edge). This narrow strip is always draggable,
        // even in apps with custom title bars, tabs, or toolbars at the top.
        dragPoint = CGPoint(x: cursorPos.x, y: windowFrame.origin.y + 3)

        // Only Y needs an offset — X stays at the cursor position
        yOffset = dragPoint.y - cursorPos.y

        // Activate the target app and raise the window to front.
        // We suppress the mouseDown and defer the actual click to the first mouseDragged,
        // giving the window server ~8ms to finish reordering before the click arrives.
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        if let axWindow = findAXWindow(pid: pid, windowFrame: windowFrame) {
            let raiseResult = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            if raiseResult != .success {
                // Fallback for apps that don't support kAXRaiseAction (e.g. some Electron apps)
                AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
        }

        isActive = true
        needsInitialMouseDown = true
        return nil  // suppress — the mouseDown will be sent on first drag
    }

    func handleMouseDragged(event: CGEvent) -> Unmanaged<CGEvent>? {
        if needsInitialMouseDown {
            needsInitialMouseDown = false
            // Convert this mouseDragged into a mouseDown at the title bar.
            // By now the window is frontmost (activation happened ~8ms ago).
            event.type = .leftMouseDown
            event.location = dragPoint
            return Unmanaged.passRetained(event)
        }

        // Shift Y so the window server sees movement relative to the title bar click.
        // X is unchanged (xOffset = 0), so horizontal movement is 1:1 with the cursor.
        let pos = event.location
        event.location = CGPoint(x: pos.x, y: pos.y + yOffset)
        return Unmanaged.passRetained(event)
    }

    func handleMouseUp(event: CGEvent) -> Unmanaged<CGEvent>? {
        if needsInitialMouseDown {
            // Released before any drag — was a modifier+click, not a drag.
            needsInitialMouseDown = false
            isActive = false
            return Unmanaged.passRetained(event)
        }

        let pos = event.location
        event.location = CGPoint(x: pos.x, y: pos.y + yOffset)
        isActive = false
        return Unmanaged.passRetained(event)
    }

    func reset() {
        isActive = false
        yOffset = 0
        dragPoint = .zero
        needsInitialMouseDown = false
    }

    // MARK: - AX Window Lookup

    /// Finds the AXUIElement for the window matching the given frame.
    /// Used only for raise/activate on mouseDown — not called during drag.
    private func findAXWindow(pid: pid_t, windowFrame: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement]
        else { return nil }

        return windows.first { axWin in
            var posRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &posRef)
            guard let posVal = posRef, CFGetTypeID(posVal) == AXValueGetTypeID() else { return false }
            var pos = CGPoint.zero
            AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
            return abs(pos.x - windowFrame.origin.x) < 5 && abs(pos.y - windowFrame.origin.y) < 5
        }
    }
}
