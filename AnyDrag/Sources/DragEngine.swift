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
        case .fn:             return CGEventFlags(rawValue: 0x800000) // maskSecondaryFn
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
}

// MARK: - Drag State

private struct DragState {
    let pid: pid_t
    let windowFrame: CGRect
    let startCursor: CGPoint
    var startWindowOrigin: CGPoint
    var axWindow: AXUIElement?     // resolved lazily on first drag
    var dragActivated: Bool
}

// MARK: - DragEngine

final class DragEngine {

    var isEnabled: Bool = true
    var modifierKey: ModifierKey = .option

    private var dragState: DragState?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?

    private let dragThreshold: CGFloat = 3.0

    // MARK: - Lifecycle

    func start() {
        guard eventTap == nil else { return }

        let eventMask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) |
                                     (1 << CGEventType.leftMouseDragged.rawValue) |
                                     (1 << CGEventType.leftMouseUp.rawValue)

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
        dragState = nil
    }

    // MARK: - Event Handling

    fileprivate func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
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
        default:
            return Unmanaged.passRetained(event)
        }
    }

    // MARK: - Mouse Down (lightweight — no AX calls)

    private func handleMouseDown(event: CGEvent) -> Unmanaged<CGEvent>? {
        let flags = event.flags
        let targetRaw = modifierKey.eventFlags.rawValue
        let cleaned = flags.rawValue & ~CGEventFlags.maskNonCoalesced.rawValue
        let relevantMask: UInt64 = CGEventFlags.maskAlternate.rawValue |
                                    CGEventFlags.maskCommand.rawValue |
                                    CGEventFlags.maskControl.rawValue |
                                    CGEventFlags.maskShift.rawValue |
                                    0x800000
        let activeModifiers = cleaned & relevantMask

        guard activeModifiers == targetRaw else {
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

        // Store pid + frame for lazy AX lookup; use CGWindowList bounds as start origin
        dragState = DragState(
            pid: windowInfo.pid,
            windowFrame: windowInfo.frame,
            startCursor: screenPoint,
            startWindowOrigin: windowInfo.frame.origin,
            axWindow: nil,
            dragActivated: false
        )

        return nil
    }

    // MARK: - Mouse Dragged

    private func handleMouseDragged(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard var state = dragState else {
            return Unmanaged.passRetained(event)
        }

        let screenPoint = event.location

        if !state.dragActivated {
            let dx = screenPoint.x - state.startCursor.x
            let dy = screenPoint.y - state.startCursor.y
            if dx * dx + dy * dy < dragThreshold * dragThreshold {
                return nil
            }

            // Threshold exceeded — resolve AX window now (one-time cost)
            guard let axWin = findAXWindow(pid: state.pid, expectedFrame: state.windowFrame) else {
                dragState = nil
                return Unmanaged.passRetained(event)
            }

            // Get precise AX position (may differ slightly from CGWindowList bounds)
            var posRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &posRef)
            if let posValue = posRef, CFGetTypeID(posValue) == AXValueGetTypeID() {
                var pos = CGPoint.zero
                AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
                state.startWindowOrigin = pos
            }

            state.axWindow = axWin
            state.dragActivated = true
            dragState = state
        }

        guard let axWindow = state.axWindow else {
            return Unmanaged.passRetained(event)
        }

        let dx = screenPoint.x - state.startCursor.x
        let dy = screenPoint.y - state.startCursor.y
        var newOrigin = CGPoint(
            x: state.startWindowOrigin.x + dx,
            y: state.startWindowOrigin.y + dy
        )

        if let value = AXValueCreate(.cgPoint, &newOrigin) {
            AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, value)
        }

        return nil
    }

    // MARK: - Mouse Up

    private func handleMouseUp(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let state = dragState else {
            return Unmanaged.passRetained(event)
        }

        dragState = nil

        if !state.dragActivated {
            if let syntheticDown = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: state.startCursor,
                mouseButton: .left
            ) {
                syntheticDown.post(tap: .cgSessionEventTap)
            }
            return Unmanaged.passRetained(event)
        }

        return nil
    }

    // MARK: - Window Detection

    private func windowUnderCursor(at point: CGPoint) -> (pid: pid_t, windowID: CGWindowID, frame: CGRect)? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else {
            return nil
        }

        for info in windowList {
            guard
                let layer = info[kCGWindowLayer] as? Int, layer == 0,
                let boundsDict = info[kCGWindowBounds] as? [String: CGFloat],
                let pid = info[kCGWindowOwnerPID] as? pid_t,
                let windowID = info[kCGWindowNumber] as? CGWindowID
            else { continue }

            if let ownerName = info[kCGWindowOwnerName] as? String, ownerName == "Dock" {
                continue
            }

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

// MARK: - C-level Event Tap Callback

private let eventTapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passRetained(event) }
    let engine = Unmanaged<DragEngine>.fromOpaque(userInfo).takeUnretainedValue()
    return engine.handleEvent(proxy: proxy, type: type, event: event)
}
