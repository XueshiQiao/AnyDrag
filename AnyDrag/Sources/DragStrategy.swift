import Cocoa
import ApplicationServices

// MARK: - How Title Bar Drag Simulation Works
//
// Instead of using the Accessibility API to set window positions (slow, ~5-10ms IPC per frame),
// we trick the window server into thinking the user is dragging the title bar:
//
// 1. modifier+mouseDown: suppress the event, raise and activate only the target window.
// 2. First mouseDragged once the target is exposed (or another app still covers it after
//    250 ms): convert it into a mouseDown at its title bar (Y near the window top, X at the
//    cursor or configured edge insets). The window server sees a title bar click and begins
//    a native drag. The exposure check only delays the press; it never cancels the drag.
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
    private var pendingWindow: CGWindowID?
    private var pendingPID: pid_t = 0
    private var startupDeadline: TimeInterval = 0
    private let activateApplication: (pid_t, NSApplication.ActivationOptions) -> Bool
    private let coveringPID: (CGWindowID, CGPoint) -> pid_t?
    private let now: () -> TimeInterval

    /// How long the synthetic press waits for the compositor to expose the
    /// target before it is sent regardless.
    static let startupGracePeriod: TimeInterval = 0.25

    init(activateApplication: @escaping (pid_t, NSApplication.ActivationOptions) -> Bool = {
        NSRunningApplication(processIdentifier: $0)?.activate(options: $1) ?? false
    }, coveringPID: @escaping (CGWindowID, CGPoint) -> pid_t? = TitleBarDragStrategy.coveringPID(of:at:),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.activateApplication = activateApplication
        self.coveringPID = coveringPID
        self.now = now
    }

    /// The owner of the frontmost normal window that sits above `windowID` at
    /// `point`, or nil when the target itself is exposed there.
    ///
    /// Lists only the windows in front of the target, so the per-event check
    /// during startup costs a fraction of a full on-screen listing. Windows the
    /// compositor cannot see (alpha 0) and non-normal layers do not count as
    /// covering. If the target is no longer on screen the list is empty and the
    /// press goes out as before.
    private static func coveringPID(of windowID: CGWindowID, at point: CGPoint) -> pid_t? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], windowID)
            as? [[CFString: Any]] else { return nil }
        for window in windows {
            guard (window[kCGWindowLayer] as? Int) == 0,
                  (window[kCGWindowAlpha] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.contains(point) else { continue }
            return window[kCGWindowOwnerPID] as? pid_t ?? 0
        }
        return nil
    }

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

    func handleMouseDown(pid: pid_t, windowID: CGWindowID, windowFrame: CGRect, event: CGEvent, rewriteToLeftButton: Bool = false, titleBarYOffset: CGFloat? = nil, titleBarXOffsets: TitleBarXOffsets? = nil, visibleTopInset: CGFloat = 0, activateApp: Bool = true, debugCaption: String? = nil) -> Unmanaged<CGEvent>? {
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

        // Raise the window and activate its app. Activating the app is what
        // makes the synthesized title-bar click land on the window we mean
        // rather than on whatever covers it, and it matches what dragging a
        // real title bar does. The mouseDown is suppressed and the actual click
        // deferred to a later mouseDragged, once the window server has
        // reordered (see `handleMouseDragged`).
        //
        // Activation goes through AppKit without `activateAllWindows`, so only
        // the app's main window comes forward; the target is made main first so
        // a sibling window cannot be the one that rises. (`kAXFrontmostAttribute`
        // was used before and brings every window of the app up.) AXRaise alone
        // is not enough: it can report success while an inactive app's window
        // stays behind another app — observed with 1Password — which is why the
        // press waits for the compositor to actually expose the target.
        //
        // Activation is skipped for a window with no title bar. Those are
        // floating panels — the Codex "ask anything" popup, say — which macOS
        // does not activate their owning app for when you click them, and which
        // sit above other windows anyway, so the click reaches them without
        // help. Forcing the app frontmost there pulls the app's *main* window
        // out from behind whatever the user had in front, which is the
        // complaint in issue #43. The window is still raised below.
        if pid == getpid() {
            // Same-process AX raise crashes here: AXUIElementPerformAction(kAXRaiseAction)
            // is dispatched in-process to -[NSWindow makeKeyAndOrderFront:], which is
            // main-thread-only, but this strategy runs on the event-tap thread. Use
            // the NSWindow APIs directly on main instead.
            let targetNumber = Int(windowID)
            let activate = activateApplication
            DispatchQueue.main.async {
                // NSWindow.windowNumber is Int and can be negative for offscreen
                // windows; compare on the Int side to avoid the unsigned trap.
                if let window = NSApp.windows.first(where: { $0.windowNumber == targetNumber }) {
                    if activateApp {
                        window.makeKeyAndOrderFront(nil)
                        _ = activate(pid, [])
                    } else {
                        window.orderFrontRegardless()
                    }
                }
            }
        } else {
            var selectedWindowReady = false
            if let axWindow = findAXWindow(pid: pid, windowFrame: windowFrame) {
                selectedWindowReady = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString) == .success
                if activateApp || !selectedWindowReady {
                    // Make the target the main window so activation brings it,
                    // not a sibling, forward. Doubles as the fallback for apps
                    // that don't support kAXRaiseAction (e.g. some Electron apps).
                    selectedWindowReady = AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue) == .success
                }
            }
            // Activate only once the target is selected; otherwise a different
            // main window could come forward. When selection fails, or the
            // system declines the activation request — a background menu bar
            // app activating another app is something newer macOS releases may
            // refuse — fall back to the app-wide AXFrontmost that shipped
            // before: sibling windows may rise, but the drag still works.
            if activateApp, !(selectedWindowReady && activateApplication(pid, [])) {
                let appElement = AXUIElementCreateApplication(pid)
                AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            }
        }

        isActive = true
        didDrag = false
        needsInitialMouseDown = true
        pendingWindow = windowID
        pendingPID = pid
        startupDeadline = now() + Self.startupGracePeriod
        self.rewriteToLeftButton = rewriteToLeftButton
        return nil  // suppress — the mouseDown will be sent on first drag
    }

    func handleMouseDragged(event: CGEvent) -> Unmanaged<CGEvent>? {
        didDrag = true
        event.flags = event.flags.subtracting(Self.modifierFlagsToStrip)
        if needsInitialMouseDown {
            if let window = pendingWindow, let coverer = coveringPID(window, dragPoint),
               coverer != pendingPID, now() < startupDeadline {
                // Activation/AXRaise success means a request was accepted, not
                // that the compositor has reordered yet. While another app still
                // covers the click point, hold the press and retry on the next
                // drag event. A window of the target's own app over the point —
                // a sheet, a child window, a transparent helper — is fine: the
                // app gets the click either way, and such a window may never
                // move, so waiting on it would only kill the drag. Past the
                // grace period the press goes out regardless: that is the
                // behaviour that shipped before this check existed, and it keeps
                // a window draggable under an overlay the check cannot see
                // through.
                return nil
            }
            pendingWindow = nil
            needsInitialMouseDown = false
            // Convert this mouseDragged into a mouseDown at the title bar.
            // The selected window is now exposed at this exact click point.
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
            // No synthetic press was sent: a plain click, or the press was still
            // being held back when the button came up. For middle-button entry
            // we suppress the up so the engine can replay a synthesized
            // middle-click at the original location (preserving browser/IDE
            // middle-click behavior). Suppress both buttons after an attempted
            // drag so a held-back press can't leak an unmatched mouse-up.
            let suppressForReplay = rewriteToLeftButton || didDrag
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
        pendingWindow = nil
        pendingPID = 0
        startupDeadline = 0
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
