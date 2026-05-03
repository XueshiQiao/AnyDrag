import Cocoa
import ApplicationServices

// MARK: - Modifier Key Model

enum ModifierKey: String, CaseIterable {
    case option = "option"
    case command = "command"
    case control = "control"
    case fn = "fn"
    case optionCommand = "option+command"

    var eventFlags: CGEventFlags {
        switch self {
        case .option:         return .maskAlternate
        case .command:        return .maskCommand
        case .control:        return .maskControl
        case .fn:             return CGEventFlags(rawValue: 0x800000)
        case .optionCommand:  return CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue)
        }
    }

    var displayName: String {
        switch self {
        case .option:         return "Option"
        case .command:        return "Command"
        case .control:        return "Control"
        case .fn:             return "fn"
        case .optionCommand:  return "Option + Command"
        }
    }

    var symbol: String {
        switch self {
        case .option:         return "⌥"
        case .command:        return "⌘"
        case .control:        return "⌃"
        case .fn:             return "fn"
        case .optionCommand:  return "⌥⌘"
        }
    }

    var supportsOptionAugmentation: Bool {
        switch self {
        case .option, .optionCommand:
            return false
        case .command, .control, .fn:
            return true
        }
    }
}

// MARK: - DragEngine

/// Intercepts mouse events via a CGEvent tap and delegates to TitleBarDragStrategy
/// when a configured modifier key is held during a click.
final class DragEngine {

    private static let secondaryFnMask = CGEventFlags(rawValue: 0x800000)
    private static let relevantModifierMask = CGEventFlags([
        .maskAlternate, .maskCommand, .maskControl, .maskShift, secondaryFnMask
    ])

    // Marker carried on synthesized replay events so we ignore them in our own tap.
    private static let synthesizedEventMarker: Int64 = 0x416E794472616701  // "AnyDrag\x01"

    var isEnabled: Bool = true
    var modifierKey: ModifierKey = .option
    var isMiddleClickDragEnabled: Bool = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?

    private let strategy = TitleBarDragStrategy()
    private var savedFrames: [CGWindowID: CGRect] = [:]
    private var tilingPanel: TilingPanel?

    // Tracks the original screen location of a middle-button press so we can
    // replay a synthesized middle-click if the user releases without dragging.
    private var middleClickOrigin: CGPoint?

    // MARK: - Lifecycle

    func start() {
        guard eventTap == nil else { return }

        let eventMask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) |
                                     (1 << CGEventType.leftMouseDragged.rawValue) |
                                     (1 << CGEventType.leftMouseUp.rawValue) |
                                     (1 << CGEventType.rightMouseDown.rawValue) |
                                     (1 << CGEventType.otherMouseDown.rawValue) |
                                     (1 << CGEventType.otherMouseDragged.rawValue) |
                                     (1 << CGEventType.otherMouseUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passRetained(self).toOpaque()
        ) else {
            NSLog("AnyDrag: Failed to create event tap. Check Accessibility permissions.")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source

        // Run the event tap on a dedicated high-priority thread
        let thread = Thread { [weak self] in
            guard let source = self?.runLoopSource else { return }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.qualityOfService = .userInteractive
        thread.name = "com.anydrag.eventtap"
        thread.start()
        tapThread = thread
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
        strategy.reset()
    }

    // MARK: - Event Handling

    fileprivate func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if the system disabled it (happens if callback was slow)
        if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        guard isEnabled else {
            return Unmanaged.passRetained(event)
        }

        switch type {
        case .leftMouseDown:
            return handleMouseDown(event: event)
        case .leftMouseDragged:
            return handleMouseDragged(event: event)
        case .leftMouseUp:
            return handleMouseUp(event: event)
        case .rightMouseDown:
            return handleRightMouseDown(event: event)
        case .otherMouseDown:
            return handleOtherMouseDown(event: event)
        case .otherMouseDragged:
            return handleOtherMouseDragged(event: event)
        case .otherMouseUp:
            return handleOtherMouseUp(event: event)
        default:
            return Unmanaged.passRetained(event)
        }
    }

    // MARK: - Mouse Down

    private func handleMouseDown(event: CGEvent) -> Unmanaged<CGEvent>? {
        // If tiling panel is visible, don't intercept — let clicks reach the panel
        if tilingPanel?.isVisible == true {
            return Unmanaged.passRetained(event)
        }

        // Check if the configured modifier key is held.
        // We also allow an extra Option key for non-Option shortcuts so
        // macOS native tiling can still kick in during an AnyDrag drag.
        guard matchesConfiguredModifier(event.flags) else {
            return Unmanaged.passRetained(event)
        }

        let screenPoint = event.location

        // Ignore clicks on the menu bar
        let menuBarHeight = Double(NSStatusBar.system.thickness)
        if let mainScreen = NSScreen.screens.first {
            let mainFrame = mainScreen.frame
            if screenPoint.x >= mainFrame.origin.x &&
               screenPoint.x <= mainFrame.origin.x + mainFrame.width &&
               screenPoint.y < menuBarHeight {
                return Unmanaged.passRetained(event)
            }
        }

        // Find the topmost normal window (layer 0) under the cursor
        guard let windowInfo = windowUnderCursor(at: screenPoint) else {
            return Unmanaged.passRetained(event)
        }

        // Double-click with modifier: toggle maximize/restore
        let clickCount = event.getIntegerValueField(.mouseEventClickState)
        if clickCount == 2 {
            toggleMaximize(windowID: windowInfo.windowID, pid: windowInfo.pid, windowFrame: windowInfo.frame)
            return nil
        }

        // Clear any orphaned middle-drag origin (e.g. from a tap-disabled
        // gesture where we never received the otherMouseUp).
        middleClickOrigin = nil
        strategy.reset()
        return strategy.handleMouseDown(
            pid: windowInfo.pid,
            windowID: windowInfo.windowID,
            windowFrame: windowInfo.frame,
            event: event
        )
    }

    // MARK: - Mouse Dragged

    private func handleMouseDragged(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard strategy.isActive else {
            return Unmanaged.passRetained(event)
        }
        return strategy.handleMouseDragged(event: event)
    }

    // MARK: - Mouse Up

    private func handleMouseUp(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard strategy.isActive else {
            return Unmanaged.passRetained(event)
        }
        return strategy.handleMouseUp(event: event)
    }

    // MARK: - Right-Click Tiling

    private func handleRightMouseDown(event: CGEvent) -> Unmanaged<CGEvent>? {
        // If tiling panel is visible, suppress right-click (avoid system context menu)
        if tilingPanel?.isVisible == true {
            return nil
        }

        guard matchesConfiguredModifier(event.flags) else {
            return Unmanaged.passRetained(event)
        }

        let screenPoint = event.location

        let menuBarHeight = Double(NSStatusBar.system.thickness)
        if let mainScreen = NSScreen.screens.first {
            let mainFrame = mainScreen.frame
            if screenPoint.x >= mainFrame.origin.x &&
               screenPoint.x <= mainFrame.origin.x + mainFrame.width &&
               screenPoint.y < menuBarHeight {
                return Unmanaged.passRetained(event)
            }
        }

        guard let windowInfo = windowUnderCursor(at: screenPoint) else {
            return Unmanaged.passRetained(event)
        }

        let mouseLocation = NSEvent.mouseLocation
        let capturedInfo = windowInfo

        DispatchQueue.main.async { [weak self] in
            self?.showTilingPanel(at: mouseLocation, for: capturedInfo)
        }

        return nil
    }

    // MARK: - Middle-Click Drag

    private func handleOtherMouseDown(event: CGEvent) -> Unmanaged<CGEvent>? {
        // Only the middle button (button 2) — leave side buttons (3, 4) alone.
        guard event.getIntegerValueField(.mouseEventButtonNumber) == 2 else {
            return Unmanaged.passRetained(event)
        }

        // Skip our own replay events so they don't recurse.
        if event.getIntegerValueField(.eventSourceUserData) == Self.synthesizedEventMarker {
            return Unmanaged.passRetained(event)
        }

        guard isMiddleClickDragEnabled else {
            return Unmanaged.passRetained(event)
        }

        if tilingPanel?.isVisible == true {
            return Unmanaged.passRetained(event)
        }

        // Don't start a middle drag while a left drag is in flight.
        if strategy.isActive {
            return Unmanaged.passRetained(event)
        }

        let screenPoint = event.location

        // Ignore clicks on the menu bar (mirrors handleMouseDown).
        let menuBarHeight = Double(NSStatusBar.system.thickness)
        if let mainScreen = NSScreen.screens.first {
            let mainFrame = mainScreen.frame
            if screenPoint.x >= mainFrame.origin.x &&
               screenPoint.x <= mainFrame.origin.x + mainFrame.width &&
               screenPoint.y < menuBarHeight {
                return Unmanaged.passRetained(event)
            }
        }

        guard let windowInfo = windowUnderCursor(at: screenPoint) else {
            return Unmanaged.passRetained(event)
        }

        middleClickOrigin = screenPoint
        strategy.reset()
        return strategy.handleMouseDown(
            pid: windowInfo.pid,
            windowID: windowInfo.windowID,
            windowFrame: windowInfo.frame,
            event: event,
            rewriteToLeftButton: true
        )
    }

    private func handleOtherMouseDragged(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard event.getIntegerValueField(.mouseEventButtonNumber) == 2,
              strategy.isActive,
              middleClickOrigin != nil
        else {
            return Unmanaged.passRetained(event)
        }
        return strategy.handleMouseDragged(event: event)
    }

    private func handleOtherMouseUp(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard event.getIntegerValueField(.mouseEventButtonNumber) == 2 else {
            return Unmanaged.passRetained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.synthesizedEventMarker {
            return Unmanaged.passRetained(event)
        }

        guard strategy.isActive, middleClickOrigin != nil else {
            return Unmanaged.passRetained(event)
        }

        let didDrag = strategy.didDrag
        let origin = middleClickOrigin
        middleClickOrigin = nil

        let result = strategy.handleMouseUp(event: event)

        // Click without drag: replay a synthesized middle-click at the original
        // location so apps still see the click (browsers, IDEs, etc). Dispatch
        // off the tap thread — posting from inside the callback can re-enter
        // our own tap synchronously on the same run loop.
        if !didDrag, let origin {
            DispatchQueue.main.async { [weak self] in
                self?.replayMiddleClick(at: origin)
            }
        }

        return result
    }

    private func replayMiddleClick(at point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        source.userData = Self.synthesizedEventMarker

        if let down = CGEvent(
            mouseEventSource: source,
            mouseType: .otherMouseDown,
            mouseCursorPosition: point,
            mouseButton: .center
        ) {
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(
            mouseEventSource: source,
            mouseType: .otherMouseUp,
            mouseCursorPosition: point,
            mouseButton: .center
        ) {
            up.post(tap: .cghidEventTap)
        }
    }

    private func showTilingPanel(at point: NSPoint, for windowInfo: (pid: pid_t, windowID: CGWindowID, frame: CGRect)) {
        tilingPanel?.dismiss()

        let panel = TilingPanel()
        panel.onAction = { [weak self] action in
            self?.performTileAction(action, windowInfo: windowInfo)
        }
        panel.show(at: point)
        tilingPanel = panel
    }

    private func matchesConfiguredModifier(_ flags: CGEventFlags) -> Bool {
        let cleanedFlags = flags.subtracting(.maskNonCoalesced)
        let activeModifiers = cleanedFlags.intersection(Self.relevantModifierMask)
        let targetModifiers = modifierKey.eventFlags

        if activeModifiers == targetModifiers {
            return true
        }

        guard modifierKey.supportsOptionAugmentation else {
            return false
        }

        // Allow base shortcut + Option so users can combine AnyDrag with
        // the macOS "Hold Option key while dragging windows to tile" feature.
        return activeModifiers == targetModifiers.union(.maskAlternate)
    }

    private func performTileAction(_ action: TileAction, windowInfo: (pid: pid_t, windowID: CGWindowID, frame: CGRect)) {
        guard let axWindow = findAXWindow(pid: windowInfo.pid, windowFrame: windowInfo.frame) else { return }
        guard let screen = screenVisibleFrame(for: windowInfo.frame) else { return }

        // Save original frame for double-click restore
        let currentFrame = getWindowFrame(axWindow) ?? windowInfo.frame
        savedFrames[windowInfo.windowID] = currentFrame

        switch action {
        // MARK: Move & Resize
        case .leftHalf:
            setWindowFrame(axWindow, frame: CGRect(
                x: screen.minX, y: screen.minY,
                width: screen.width / 2, height: screen.height))

        case .rightHalf:
            setWindowFrame(axWindow, frame: CGRect(
                x: screen.midX, y: screen.minY,
                width: screen.width / 2, height: screen.height))

        case .topHalf:
            setWindowFrame(axWindow, frame: CGRect(
                x: screen.minX, y: screen.minY,
                width: screen.width, height: screen.height / 2))

        case .bottomHalf:
            setWindowFrame(axWindow, frame: CGRect(
                x: screen.minX, y: screen.midY,
                width: screen.width, height: screen.height / 2))

        case .topLeft:
            setWindowFrame(axWindow, frame: CGRect(
                x: screen.minX, y: screen.minY,
                width: screen.width / 2, height: screen.height / 2))

        case .topRight:
            setWindowFrame(axWindow, frame: CGRect(
                x: screen.midX, y: screen.minY,
                width: screen.width / 2, height: screen.height / 2))

        case .bottomLeft:
            setWindowFrame(axWindow, frame: CGRect(
                x: screen.minX, y: screen.midY,
                width: screen.width / 2, height: screen.height / 2))

        case .bottomRight:
            setWindowFrame(axWindow, frame: CGRect(
                x: screen.midX, y: screen.midY,
                width: screen.width / 2, height: screen.height / 2))

        // MARK: Fill & Arrange
        case .fill:
            // Maximize to screen's visible area (keeps title bar)
            setWindowFrame(axWindow, frame: screen)

        case .leftAndRight:
            // Current window → left half, next Z-order window → right half
            setWindowFrame(axWindow, frame: CGRect(
                x: screen.minX, y: screen.minY,
                width: screen.width / 2, height: screen.height))
            if let next = nextWindowOnScreen(after: windowInfo.windowID, screen: screen) {
                savedFrames[next.windowID] = getWindowFrame(next.axWindow) ?? next.frame
                setWindowFrame(next.axWindow, frame: CGRect(
                    x: screen.midX, y: screen.minY,
                    width: screen.width / 2, height: screen.height))
            }

        case .fillRight:
            // Current window → right half, next Z-order window → left half
            setWindowFrame(axWindow, frame: CGRect(
                x: screen.midX, y: screen.minY,
                width: screen.width / 2, height: screen.height))
            if let next = nextWindowOnScreen(after: windowInfo.windowID, screen: screen) {
                savedFrames[next.windowID] = getWindowFrame(next.axWindow) ?? next.frame
                setWindowFrame(next.axWindow, frame: CGRect(
                    x: screen.minX, y: screen.minY,
                    width: screen.width / 2, height: screen.height))
            }

        case .quarters:
            // Top 4 windows by Z-order → quadrants
            let quadrants = [
                CGRect(x: screen.minX, y: screen.minY,
                       width: screen.width / 2, height: screen.height / 2),
                CGRect(x: screen.midX, y: screen.minY,
                       width: screen.width / 2, height: screen.height / 2),
                CGRect(x: screen.minX, y: screen.midY,
                       width: screen.width / 2, height: screen.height / 2),
                CGRect(x: screen.midX, y: screen.midY,
                       width: screen.width / 2, height: screen.height / 2),
            ]
            // Current window → top-left
            setWindowFrame(axWindow, frame: quadrants[0])
            // Next windows → remaining quadrants
            let others = windowsOnScreen(after: windowInfo.windowID, screen: screen, limit: 3)
            for (i, other) in others.enumerated() {
                savedFrames[other.windowID] = getWindowFrame(other.axWindow) ?? other.frame
                setWindowFrame(other.axWindow, frame: quadrants[i + 1])
            }
        }
    }

    // MARK: - Maximize / Restore

    private func toggleMaximize(windowID: CGWindowID, pid: pid_t, windowFrame: CGRect) {
        guard let axWindow = findAXWindow(pid: pid, windowFrame: windowFrame) else { return }

        // Activate the target app and raise the window
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)

        if let savedFrame = savedFrames[windowID] {
            // Restore to original frame
            setWindowFrame(axWindow, frame: savedFrame)
            savedFrames.removeValue(forKey: windowID)
        } else {
            // Save current frame and maximize to screen's visible area
            let currentFrame = getWindowFrame(axWindow) ?? windowFrame
            savedFrames[windowID] = currentFrame
            if let targetFrame = screenVisibleFrame(for: windowFrame) {
                setWindowFrame(axWindow, frame: targetFrame)
            }
        }
    }

    private func setWindowFrame(_ window: AXUIElement, frame: CGRect) {
        // Disable AXEnhancedUserInterface if enabled (Electron apps set this,
        // which causes AX resizing to silently fail). Rectangle does the same.
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let appElement = AXUIElementCreateApplication(pid)

        var enhancedUIRef: CFTypeRef?
        let hadEnhancedUI = AXUIElementCopyAttributeValue(
            appElement, "AXEnhancedUserInterface" as CFString, &enhancedUIRef
        ) == .success && (enhancedUIRef as? NSNumber)?.boolValue == true

        if hadEnhancedUI {
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }

        // Size → Position → Size (Rectangle's proven approach).
        // macOS constrains window size to the current display, so we must:
        // 1. Shrink first (so the window fits before moving)
        // 2. Move to the target position
        // 3. Set size again (in case the display changed and the constraint was wrong)
        var position = frame.origin
        var size = frame.size
        if let sv = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sv)
        }
        if let pv = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pv)
        }
        if let sv = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sv)
        }

        if hadEnhancedUI {
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    private func getWindowFrame(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, CFGetTypeID(posVal) == AXValueGetTypeID(),
              let sizeVal = sizeRef, CFGetTypeID(sizeVal) == AXValueGetTypeID()
        else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    /// Returns the screen's visible area (excluding menu bar and Dock) in CG coordinates
    /// for the screen that contains the given window frame.
    private func screenVisibleFrame(for windowFrame: CGRect) -> CGRect? {
        guard let mainScreen = NSScreen.screens.first else { return nil }
        let mainHeight = mainScreen.frame.height

        // Find which screen contains the window center (convert CG → NS coordinates)
        let centerNS = NSPoint(x: windowFrame.midX, y: mainHeight - windowFrame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(centerNS) } ?? mainScreen

        // Convert NSScreen visibleFrame (bottom-left origin) → CG coordinates (top-left origin)
        let vf = screen.visibleFrame
        return CGRect(
            x: vf.origin.x,
            y: mainHeight - vf.origin.y - vf.height,
            width: vf.width,
            height: vf.height
        )
    }

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

    // MARK: - Multi-Window Lookup

    /// Returns the next window in Z-order on the same screen, skipping the given windowID.
    private func nextWindowOnScreen(after windowID: CGWindowID, screen: CGRect) -> (windowID: CGWindowID, pid: pid_t, frame: CGRect, axWindow: AXUIElement)? {
        return windowsOnScreen(after: windowID, screen: screen, limit: 1).first
    }

    /// Returns up to `limit` windows in Z-order on the same screen, skipping the given windowID.
    private func windowsOnScreen(after windowID: CGWindowID, screen: CGRect, limit: Int) -> [(windowID: CGWindowID, pid: pid_t, frame: CGRect, axWindow: AXUIElement)] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return [] }

        var results: [(windowID: CGWindowID, pid: pid_t, frame: CGRect, axWindow: AXUIElement)] = []

        for info in windowList {
            guard results.count < limit,
                  let layer = info[kCGWindowLayer] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds] as? [String: CGFloat],
                  let pid = info[kCGWindowOwnerPID] as? pid_t,
                  let wID = info[kCGWindowNumber] as? CGWindowID,
                  wID != windowID
            else { continue }

            let ownerName = info[kCGWindowOwnerName] as? String ?? "unknown"
            if ownerName == "Dock" { continue }

            let frame = CGRect(
                x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
            )

            // Check if window center is on the same screen
            let centerX = frame.midX
            let centerY = frame.midY
            guard centerX >= screen.minX && centerX <= screen.maxX &&
                  centerY >= screen.minY && centerY <= screen.maxY else { continue }

            guard let axWindow = findAXWindow(pid: pid, windowFrame: frame) else { continue }
            results.append((wID, pid, frame, axWindow))
        }

        return results
    }

    // MARK: - Window Detection

    /// Finds the topmost normal window at the given screen point using CGWindowListCopyWindowInfo.
    /// Returns nil if no window is found. Skips the Dock and non-normal windows (layer != 0).
    private func windowUnderCursor(at point: CGPoint) -> (pid: pid_t, windowID: CGWindowID, frame: CGRect)? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else {
            return nil
        }

        // CGWindowListCopyWindowInfo returns windows in front-to-back order,
        // so the first hit is the topmost window at that point.
        for info in windowList {
            guard
                let layer = info[kCGWindowLayer] as? Int, layer == 0,
                let boundsDict = info[kCGWindowBounds] as? [String: CGFloat],
                let pid = info[kCGWindowOwnerPID] as? pid_t,
                let windowID = info[kCGWindowNumber] as? CGWindowID
            else { continue }

            let ownerName = info[kCGWindowOwnerName] as? String ?? "unknown"
            if ownerName == "Dock" { continue }

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            if bounds.contains(point) {
                return (pid, windowID, bounds)
            }
        }
        return nil
    }
}

// MARK: - C-level Event Tap Callback

private let eventTapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passRetained(event) }
    let engine = Unmanaged<DragEngine>.fromOpaque(userInfo).takeUnretainedValue()
    return engine.handleEvent(proxy: proxy, type: type, event: event)
}
