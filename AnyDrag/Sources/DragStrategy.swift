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
    private(set) var didDrag = false
    private var yOffset: CGFloat = 0
    private var dragPoint: CGPoint = .zero
    private var needsInitialMouseDown = false
    private var rewriteToLeftButton = false

    /// Modifier flags stripped from injected/rewritten title-bar events.
    ///
    /// Only Control is stripped: AppKit converts Control+leftMouseDown to a
    /// "secondary click" (Finder pops the toolbar context menu, etc.) at the
    /// NSResponder layer, breaking the title-bar drag.
    ///
    /// Option was tried briefly but does NOT achieve full suppression of the
    /// macOS "Hold option key while dragging windows to tile" feature: macOS
    /// reads the physical Option key state independently of the event flags,
    /// so stripping the flag only hides the overlay while the snap-on-release
    /// still fires. Half-suppression is worse than passing through, so Option
    /// is left intact. To fully suppress, we'd have to synthesize an Option
    /// keyUp into the system before the drag (with side effects on other
    /// apps' keyboard listeners) — not worth it.
    private static let modifierFlagsToStrip: CGEventFlags = [.maskControl]

    private let debugDot = DebugDotOverlay()

    /// Vertical offset from the window's top edge to the synthesized title-bar
    /// click. The default works for stock AppKit windows; some custom-rendered
    /// apps (e.g. WeChat) have non-draggable strips at the very top and need a
    /// larger offset. Tunable from Settings → General → Diagnostics.
    var titleBarYOffset: CGFloat = 3

    /// When true, every drag flashes a marker at the synthesized click point.
    /// Diagnostics aid; off by default.
    var showDebugDot: Bool = false

    func handleMouseDown(pid: pid_t, windowID: CGWindowID, windowFrame: CGRect, event: CGEvent, rewriteToLeftButton: Bool = false) -> Unmanaged<CGEvent>? {
        let cursorPos = event.location

        // Drag point: cursor's X (on an exposed part of the window), Y near the top of
        // the title bar. The default 3px is a narrow strip that's always draggable on
        // stock AppKit windows; the offset is tunable for apps with custom top regions.
        dragPoint = CGPoint(x: cursorPos.x, y: windowFrame.origin.y + titleBarYOffset)

        // Diagnostic: show where we're targeting the synthesized click.
        if showDebugDot {
            debugDot.flash(at: dragPoint)
        }

        // Only Y needs an offset — X stays at the cursor position
        yOffset = dragPoint.y - cursorPos.y

        // Activate the target app and raise the window to front.
        // We suppress the mouseDown and defer the actual click to the first mouseDragged,
        // giving the window server ~8ms to finish reordering before the click arrives.
        if pid == getpid() {
            // Same-process AX raise crashes here: AXUIElementPerformAction(kAXRaiseAction)
            // is dispatched in-process to -[NSWindow makeKeyAndOrderFront:], which is
            // main-thread-only, but this strategy runs on the event-tap thread. Use
            // the NSWindow APIs directly on main instead.
            let targetNumber = Int(windowID)
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                // NSWindow.windowNumber is Int and can be negative for offscreen
                // windows; compare on the Int side to avoid the unsigned trap.
                if let window = NSApp.windows.first(where: { $0.windowNumber == targetNumber }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        } else {
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

            if let axWindow = findAXWindow(pid: pid, windowFrame: windowFrame) {
                let raiseResult = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                if raiseResult != .success {
                    // Fallback for apps that don't support kAXRaiseAction (e.g. some Electron apps)
                    AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
                }
            }
        }

        isActive = true
        didDrag = false
        needsInitialMouseDown = true
        self.rewriteToLeftButton = rewriteToLeftButton
        return nil  // suppress — the mouseDown will be sent on first drag
    }

    func handleMouseDragged(event: CGEvent) -> Unmanaged<CGEvent>? {
        didDrag = true
        event.flags = event.flags.subtracting(Self.modifierFlagsToStrip)
        if needsInitialMouseDown {
            needsInitialMouseDown = false
            // Convert this mouseDragged into a mouseDown at the title bar.
            // By now the window is frontmost (activation happened ~8ms ago).
            event.type = .leftMouseDown
            if rewriteToLeftButton {
                event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
            }
            event.location = dragPoint
            return Unmanaged.passRetained(event)
        }

        if rewriteToLeftButton {
            event.type = .leftMouseDragged
            event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        }

        // Shift Y so the window server sees movement relative to the title bar click.
        // X is unchanged (xOffset = 0), so horizontal movement is 1:1 with the cursor.
        let pos = event.location
        event.location = CGPoint(x: pos.x, y: pos.y + yOffset)
        return Unmanaged.passRetained(event)
    }

    func handleMouseUp(event: CGEvent) -> Unmanaged<CGEvent>? {
        if needsInitialMouseDown {
            // Released before any drag — was a click, not a drag.
            // For middle-button entry we suppress the up so the engine can replay
            // a synthesized middle-click at the original location (preserving
            // browser/IDE middle-click behavior). Left-button keeps original behavior.
            let suppressForReplay = rewriteToLeftButton
            needsInitialMouseDown = false
            isActive = false
            return suppressForReplay ? nil : Unmanaged.passRetained(event)
        }

        if rewriteToLeftButton {
            event.type = .leftMouseUp
            event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        }

        event.flags = event.flags.subtracting(Self.modifierFlagsToStrip)
        let pos = event.location
        event.location = CGPoint(x: pos.x, y: pos.y + yOffset)
        isActive = false
        return Unmanaged.passRetained(event)
    }

    func reset() {
        isActive = false
        didDrag = false
        yOffset = 0
        dragPoint = .zero
        needsInitialMouseDown = false
        rewriteToLeftButton = false
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
