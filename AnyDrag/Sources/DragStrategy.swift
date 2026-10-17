import Cocoa
import ApplicationServices

// MARK: - How Title Bar Drag Simulation Works
//
// Instead of using the Accessibility API to set window positions (slow, ~5-10ms IPC per frame),
// we trick the window server into thinking the user is dragging the title bar:
//
// 1. modifier+mouseDown: suppress the event and raise only the target window.
// 2. First mouseDragged (~8ms later): convert it into a mouseDown at the window's title bar
//    (Y near the window top, X at the cursor or configured edge insets).
//    The window server sees a title bar click and begins a native drag.
//    The ~8ms gap ensures window reordering has completed.
// 3. Subsequent mouseDragged: translate coordinates by a fixed offset so the window
//    server sees movement relative to the title bar click point.
//    Coordinates are rounded consistently so the window follows the cursor on whole points.
// 4. mouseUp: apply the same translation, ending the native drag.
//
// Result: zero per-frame IPC. The window server moves the window directly at compositor level,
// identical in performance to manually dragging a title bar.

/// Rewrites mouse event coordinates to the window's title bar region.
/// The window server handles movement natively — same speed as dragging a title bar by hand.
final class TitleBarDragStrategy {

    private(set) var isActive = false
    private(set) var didDrag = false
    private var xOffset: CGFloat = 0
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
    /// Also read by the engine so `TrailingFlagScrubber` can repeat the same
    /// scrub at the tail of the tap chain, after any downstream tool has
    /// re-asserted the flags we cleared here.
    static let modifierFlagsToStrip: CGEventFlags = [.maskControl]

    private let debugDot = DebugDotOverlay()

    /// Vertical offset from the window's top edge to the synthesized title-bar
    /// click. The default works for stock AppKit windows (and is one point
    /// larger on macOS 27 — see `Preferences.defaultTitleBarYOffset`); some
    /// custom-rendered apps (e.g. WeChat) have non-draggable strips at the very
    /// top and need a larger offset. Tunable from Settings → General →
    /// Diagnostics. The engine overwrites this from UserDefaults at launch.
    var titleBarYOffset: CGFloat = Preferences.defaultTitleBarYOffset
    var useFixedTitleBarX = false
    var titleBarLeftInset: CGFloat = Preferences.defaultTitleBarLeftInset
    var titleBarRightInset: CGFloat = Preferences.defaultTitleBarRightInset

    /// Prefer the left anchor, then the right if the left is offscreen.
    /// Clamp both inside narrow windows; preserve mouse X if neither is visible.
    static func titleBarX(cursorX: CGFloat, windowFrame: CGRect, titleBarY: CGFloat,
                          leftInset: CGFloat, rightInset: CGFloat, displayBounds: [CGRect]) -> CGFloat {
        let margin = min(8, windowFrame.width / 2)
        let candidates = [windowFrame.minX + leftInset, windowFrame.maxX - rightInset]
        for candidate in candidates {
            let x = min(max(candidate, windowFrame.minX + margin), windowFrame.maxX - margin).rounded()
            if displayBounds.contains(where: { $0.contains(CGPoint(x: x, y: titleBarY)) }) {
                return x
            }
        }
        return cursorX.rounded()
    }

    private func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// Distance below the measured top of a window's visible content to aim.
    /// Stays 3 pt on every macOS version, unlike the title-bar default: this
    /// one aims into a window's own content box, well clear of the frame edge
    /// where the window server's title-bar/resize hit regions live, so the
    /// macOS 27 change behind issue #51 does not reach it.
    private static let measuredAimOffset: CGFloat = 3

    /// When true, every drag flashes a marker at the synthesized click point.
    /// Diagnostics aid; off by default.
    var showDebugDot: Bool = false

    func handleMouseDown(pid: pid_t, windowID: CGWindowID, windowFrame: CGRect, event: CGEvent, rewriteToLeftButton: Bool = false, titleBarYOffset: CGFloat? = nil, titleBarXOffsets: TitleBarXOffsets? = nil, visibleTopInset: CGFloat = 0, debugCaption: String? = nil) -> Unmanaged<CGEvent>? {
        let cursorPos = event.location

        // Drag point: cursor's X by default, or configured edge insets;
        // Y near the top of the title bar. The default (3 pt, 4 on macOS 27) is a narrow strip that's
        // always draggable on stock AppKit windows; the offset is tunable for apps
        // with custom top regions.
        // The engine passes a per-app override when one is set; otherwise we fall back
        // to the global `self.titleBarYOffset`.
        // `visibleTopInset` is normally 0. It is non-zero only for windows whose
        // rect is taller than what you can see — an Electron popup reserving a
        // transparent strip for a panel that expands upward (issue #43). There
        // the rect's top edge is empty space, so the click has to start below
        // it, at the top of the visible content. See `DragEngine.visibleTopInset`.
        // The tunable offsets exist to clear a non-draggable strip at the top
        // of a particular app's *title bar*; they mean nothing once we are
        // aiming at a measured content box, so the measured case uses the plain
        // default instead of adding a user value on top of it.
        let effectiveOffset = visibleTopInset > 0 ? Self.measuredAimOffset
                                                  : (titleBarYOffset ?? self.titleBarYOffset)
        // Use the same whole-point grid for the initial click and every later
        // drag/up. High-resolution mouse events contain fractional coordinates;
        // forwarding their fractional displacement can leave the compositor
        // displaying an interpolated window surface after release.
        let titleBarY = (windowFrame.origin.y + visibleTopInset + effectiveOffset).rounded()
        let fixedX = titleBarXOffsets != nil || useFixedTitleBarX
        let titleBarX = fixedX
            ? Self.titleBarX(cursorX: cursorPos.x, windowFrame: windowFrame, titleBarY: titleBarY,
                             leftInset: titleBarXOffsets?.left ?? titleBarLeftInset,
                             rightInset: titleBarXOffsets?.right ?? titleBarRightInset, displayBounds: activeDisplayBounds())
            : cursorPos.x.rounded()
        dragPoint = CGPoint(x: titleBarX, y: titleBarY)

        // Diagnostic: show where we're targeting the synthesized click.
        if showDebugDot {
            debugDot.flash(at: dragPoint, caption: debugCaption)
        }

        // Snapshot both offsets so changing settings mid-drag cannot move the anchor.
        // Preserve the old X rounding behavior when the fixed-X option is disabled.
        xOffset = fixedX ? dragPoint.x - cursorPos.x : 0
        yOffset = dragPoint.y - cursorPos.y

        // Raise only the selected window. Setting the app's AXFrontmost brings
        // sibling windows forward too. The synthesized title-bar click handles
        // normal activation, just as a real click on this one window would.
        // We suppress the mouseDown and defer the actual click to the first mouseDragged,
        // giving the window server ~8ms to finish reordering before the click arrives.
        if pid == getpid() {
            // Same-process AX raise crashes here: AXUIElementPerformAction(kAXRaiseAction)
            // is dispatched in-process to -[NSWindow makeKeyAndOrderFront:], which is
            // main-thread-only, but this strategy runs on the event-tap thread. Use
            // the NSWindow APIs directly on main instead.
            let targetNumber = Int(windowID)
            DispatchQueue.main.async {
                // NSWindow.windowNumber is Int and can be negative for offscreen
                // windows; compare on the Int side to avoid the unsigned trap.
                if let window = NSApp.windows.first(where: { $0.windowNumber == targetNumber }) {
                    window.orderFrontRegardless()
                }
            }
        } else {
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
            // The selected window was raised on mouseDown, roughly 8ms ago.
            event.type = .leftMouseDown
            if rewriteToLeftButton {
                event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
            }
            event.location = dragPoint
            return Unmanaged.passUnretained(event)
        }

        if rewriteToLeftButton {
            event.type = .leftMouseDragged
            event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        }

        // Translate both axes relative to the initial title-bar click.
        // Round both axes like the initial click so the final translation stays integral.
        let pos = event.location
        event.location = CGPoint(x: (pos.x + xOffset).rounded(), y: (pos.y + yOffset).rounded())
        return Unmanaged.passUnretained(event)
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
            return suppressForReplay ? nil : Unmanaged.passUnretained(event)
        }

        if rewriteToLeftButton {
            event.type = .leftMouseUp
            event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        }

        event.flags = event.flags.subtracting(Self.modifierFlagsToStrip)
        let pos = event.location
        event.location = CGPoint(x: (pos.x + xOffset).rounded(), y: (pos.y + yOffset).rounded())
        isActive = false
        return Unmanaged.passUnretained(event)
    }

    func reset() {
        isActive = false
        didDrag = false
        xOffset = 0
        yOffset = 0
        dragPoint = .zero
        needsInitialMouseDown = false
        rewriteToLeftButton = false
    }

    // MARK: - AX Window Lookup

    /// Finds the AXUIElement for the window matching the given frame.
    /// Used only to raise the target on mouseDown — not called during drag.
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
