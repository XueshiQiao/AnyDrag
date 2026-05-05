import Cocoa
import ApplicationServices

// MARK: - Modifier Combination Model

/// User-selectable combination of modifier keys. Any non-empty subset of
/// command/shift/option/control/fn is allowed.
struct ModifierCombination: OptionSet, Equatable, Hashable {
    let rawValue: UInt
    init(rawValue: UInt) { self.rawValue = rawValue }

    static let command = ModifierCombination(rawValue: 1 << 0)
    static let shift   = ModifierCombination(rawValue: 1 << 1)
    static let option  = ModifierCombination(rawValue: 1 << 2)
    static let control = ModifierCombination(rawValue: 1 << 3)
    static let fn      = ModifierCombination(rawValue: 1 << 4)

    static let fnEventFlag = CGEventFlags.maskSecondaryFn

    var eventFlags: CGEventFlags {
        var f: CGEventFlags = []
        if contains(.command) { f.insert(.maskCommand) }
        if contains(.shift)   { f.insert(.maskShift) }
        if contains(.option)  { f.insert(.maskAlternate) }
        if contains(.control) { f.insert(.maskControl) }
        if contains(.fn)      { f.insert(Self.fnEventFlag) }
        return f
    }

    /// Glyph display, e.g. "⌃⌥⇧⌘" or "fn⌘". Order follows Apple HIG (fn ⌃ ⌥ ⇧ ⌘).
    var symbol: String {
        var s = ""
        if contains(.fn)      { s += "fn" }
        if contains(.control) { s += "⌃" }
        if contains(.option)  { s += "⌥" }
        if contains(.shift)   { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s.isEmpty ? "—" : s
    }

    /// Localized name, e.g. "Control + Option + Command".
    var displayName: String {
        var parts: [String] = []
        if contains(.fn)      { parts.append(NSLocalizedString("fn", comment: "")) }
        if contains(.control) { parts.append(NSLocalizedString("Control", comment: "")) }
        if contains(.option)  { parts.append(NSLocalizedString("Option", comment: "")) }
        if contains(.shift)   { parts.append(NSLocalizedString("Shift", comment: "")) }
        if contains(.command) { parts.append(NSLocalizedString("Command", comment: "")) }
        return parts.isEmpty ? "—" : parts.joined(separator: " + ")
    }

    /// True when adding Option to the gesture is allowed (so users can combine
    /// AnyDrag with the macOS "Hold Option while dragging windows to tile" feature).
    var supportsOptionAugmentation: Bool {
        !contains(.option)
    }

    /// Migrate the pre-1.3 `ModifierKey` string preference.
    init?(legacyString: String) {
        switch legacyString {
        case "option":         self = .option
        case "command":        self = .command
        case "control":        self = .control
        case "fn":             self = .fn
        case "option+command": self = [.option, .command]
        default:               return nil
        }
    }
}

// MARK: - Middle Action Model

/// What the middle mouse button does. Mutually exclusive — the user picks one.
enum MiddleAction: String, CaseIterable {
    case off = "off"
    case dragWindow = "drag"
    case tileByDirection = "tile"

    var displayName: String {
        switch self {
        case .off:              return NSLocalizedString("Off", comment: "")
        case .dragWindow:       return NSLocalizedString("Drag window", comment: "")
        case .tileByDirection:  return NSLocalizedString("Tile by direction", comment: "")
        }
    }
}

// MARK: - Tile Zone Model

/// A target region on the screen, selected by drag direction.
enum TileZone {
    case full          // drag up
    case centered      // drag down (~70% × 70%)
    case left, right
    case topLeft, topRight, bottomLeft, bottomRight

    /// Map an 8-sector drag direction (in CG coords — Y increases downward)
    /// to a tile zone. Returns nil if the drag distance is below threshold.
    static func zone(forDx dx: CGFloat, dy: CGFloat, threshold: CGFloat) -> TileZone? {
        guard hypot(dx, dy) >= threshold else { return nil }

        // atan2 with Y-down gives clockwise angles: 0 = right, π/2 = down,
        // π = left, -π/2 = up. Normalize to [0, 2π).
        var angle = atan2(dy, dx)
        if angle < 0 { angle += 2 * .pi }

        // 8 sectors of 45°, centered on the cardinal/diagonal directions.
        let sector = Int((angle + .pi / 8) / (.pi / 4)) % 8
        switch sector {
        case 0: return .right
        case 1: return .bottomRight
        case 2: return .centered     // "down" → centered window
        case 3: return .bottomLeft
        case 4: return .left
        case 5: return .topLeft
        case 6: return .full         // "up" → full screen
        case 7: return .topRight
        default: return nil
        }
    }

    /// Compute the target rect within the screen's visible NSScreen-coord frame
    /// (bottom-left origin). For .centered the window covers 85% × 85%.
    func rect(in v: NSRect, centeredFraction: CGFloat = 0.85) -> NSRect {
        switch self {
        case .full:
            return v
        case .centered:
            let w = v.width * centeredFraction
            let h = v.height * centeredFraction
            return NSRect(x: v.minX + (v.width - w) / 2,
                          y: v.minY + (v.height - h) / 2,
                          width: w, height: h)
        case .left:
            return NSRect(x: v.minX, y: v.minY, width: v.width / 2, height: v.height)
        case .right:
            return NSRect(x: v.midX, y: v.minY, width: v.width / 2, height: v.height)
        case .topLeft:
            return NSRect(x: v.minX, y: v.midY, width: v.width / 2, height: v.height / 2)
        case .topRight:
            return NSRect(x: v.midX, y: v.midY, width: v.width / 2, height: v.height / 2)
        case .bottomLeft:
            return NSRect(x: v.minX, y: v.minY, width: v.width / 2, height: v.height / 2)
        case .bottomRight:
            return NSRect(x: v.midX, y: v.minY, width: v.width / 2, height: v.height / 2)
        }
    }
}

// MARK: - DragEngine

/// Intercepts mouse events via a CGEvent tap and delegates to TitleBarDragStrategy
/// when a configured modifier key is held during a click.
final class DragEngine {

    private static let relevantModifierMask = CGEventFlags([
        .maskAlternate, .maskCommand, .maskControl, .maskShift, ModifierCombination.fnEventFlag
    ])

    // Marker carried on synthesized replay events so we ignore them in our own tap.
    private static let synthesizedEventMarker: Int64 = 0x416E794472616701  // "AnyDrag\x01"

    /// Distance (in points) the middle button must travel before a tile zone is
    /// committed. Pulled out as a constant so we can expose it as a setting later.
    static let tileDirectionThreshold: CGFloat = 30

    private static let log = FileLog("DragEngine")

    var isEnabled: Bool = true
    var modifiers: ModifierCombination = .option
    var dragEnabled: Bool = true
    var maximizeEnabled: Bool = true
    var tilingEnabled: Bool = true
    var middleAction: MiddleAction = .off

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?

    private let strategy = TitleBarDragStrategy()
    private var savedFrames: [CGWindowID: CGRect] = [:]
    private var tilingPanel: TilingPanel?
    private lazy var tileOverlay = TileOverlay()

    // Tracks the original screen location of a middle-button press so we can
    // replay a synthesized middle-click if the user releases without dragging.
    private var middleClickOrigin: CGPoint?

    // Tile-by-direction state. Set in handleOtherMouseDown when middleAction == .tileByDirection,
    // cleared in handleOtherMouseUp.
    private var tileTargetWindow: (pid: pid_t, windowID: CGWindowID, frame: CGRect)?
    private var currentTileZone: TileZone?

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
            Self.log.error("Failed to create event tap. Check Accessibility permissions.")
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

        // Both left-button features off → nothing to do here.
        if !dragEnabled && !maximizeEnabled {
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
            guard maximizeEnabled else { return Unmanaged.passRetained(event) }
            toggleMaximize(windowID: windowInfo.windowID, pid: windowInfo.pid, windowFrame: windowInfo.frame)
            return nil
        }

        guard dragEnabled else {
            return Unmanaged.passRetained(event)
        }

        // Clear any orphaned middle-gesture state (e.g. from a tap-disabled
        // gesture where we never received the otherMouseUp).
        middleClickOrigin = nil
        if tileTargetWindow != nil {
            tileTargetWindow = nil
            currentTileZone = nil
            DispatchQueue.main.async { [weak self] in
                self?.tileOverlay.hide()
            }
        }
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

        guard tilingEnabled else {
            return Unmanaged.passRetained(event)
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

    // MARK: - Middle Button (drag or tile-by-direction)

    private func handleOtherMouseDown(event: CGEvent) -> Unmanaged<CGEvent>? {
        // Only the middle button (button 2) — leave side buttons (3, 4) alone.
        guard event.getIntegerValueField(.mouseEventButtonNumber) == 2 else {
            return Unmanaged.passRetained(event)
        }

        // Skip our own replay events so they don't recurse.
        if event.getIntegerValueField(.eventSourceUserData) == Self.synthesizedEventMarker {
            return Unmanaged.passRetained(event)
        }

        guard middleAction != .off else {
            return Unmanaged.passRetained(event)
        }

        if tilingPanel?.isVisible == true {
            return Unmanaged.passRetained(event)
        }

        // Don't start a middle gesture while a left drag is in flight.
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

        switch middleAction {
        case .off:
            return Unmanaged.passRetained(event)

        case .dragWindow:
            middleClickOrigin = screenPoint
            strategy.reset()
            return strategy.handleMouseDown(
                pid: windowInfo.pid,
                windowID: windowInfo.windowID,
                windowFrame: windowInfo.frame,
                event: event,
                rewriteToLeftButton: true
            )

        case .tileByDirection:
            // Window stays put — we use the middle drag to pick a tile target.
            middleClickOrigin = screenPoint
            tileTargetWindow = windowInfo
            currentTileZone = nil
            return nil  // suppress the down; will replay middle-click on no-drag release
        }
    }

    private func handleOtherMouseDragged(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard event.getIntegerValueField(.mouseEventButtonNumber) == 2 else {
            return Unmanaged.passRetained(event)
        }

        // Tile-by-direction path: update the overlay based on direction, suppress the event.
        if tileTargetWindow != nil, let origin = middleClickOrigin {
            let dx = event.location.x - origin.x
            let dy = event.location.y - origin.y
            let zone = TileZone.zone(forDx: dx, dy: dy, threshold: Self.tileDirectionThreshold)
            currentTileZone = zone

            let cursorScreenPoint = event.location
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let zone, let screen = self.screen(containingCGPoint: cursorScreenPoint) {
                    let target = zone.rect(in: screen.visibleFrame)
                    self.tileOverlay.show(rect: target)
                } else {
                    self.tileOverlay.hide()
                }
            }
            return nil
        }

        // Drag-window path (existing).
        guard strategy.isActive, middleClickOrigin != nil else {
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

        // Tile-by-direction path.
        if let target = tileTargetWindow, let origin = middleClickOrigin {
            let zone = currentTileZone
            let cursorScreenPoint = event.location
            tileTargetWindow = nil
            middleClickOrigin = nil
            currentTileZone = nil

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.tileOverlay.hide()
                if let zone, let screen = self.screen(containingCGPoint: cursorScreenPoint) {
                    self.applyTile(zone: zone, target: target, screen: screen)
                } else {
                    // Below threshold — replay the original middle-click so apps still see it.
                    self.replayMiddleClick(at: origin)
                }
            }
            return nil
        }

        // Drag-window path (existing).
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

    // MARK: - Tile Application

    /// Snap the target window to the tile zone's rect on the given screen.
    /// Saves the original frame in savedFrames so the existing double-click-restore works.
    private func applyTile(zone: TileZone,
                           target: (pid: pid_t, windowID: CGWindowID, frame: CGRect),
                           screen: NSScreen) {
        guard let axWindow = findAXWindow(pid: target.pid, windowFrame: target.frame) else { return }

        let nsRect = zone.rect(in: screen.visibleFrame)
        let cgRect = cgRectFromNSScreenRect(nsRect)

        // Save current frame for double-click restore (matches performTileAction's behavior).
        let currentFrame = getWindowFrame(axWindow) ?? target.frame
        savedFrames[target.windowID] = currentFrame

        setWindowFrame(axWindow, frame: cgRect)
    }

    /// Convert an NSScreen-coord rect (bottom-left origin) into a Quartz CG rect (top-left origin).
    private func cgRectFromNSScreenRect(_ ns: NSRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return ns }
        let primaryHeight = primary.frame.height
        return CGRect(x: ns.origin.x,
                      y: primaryHeight - ns.origin.y - ns.height,
                      width: ns.width, height: ns.height)
    }

    /// Find the NSScreen containing a given CG point (top-left origin, Y-down).
    private func screen(containingCGPoint cg: CGPoint) -> NSScreen? {
        guard let primary = NSScreen.screens.first else { return nil }
        let primaryHeight = primary.frame.height
        let nsPoint = NSPoint(x: cg.x, y: primaryHeight - cg.y)
        return NSScreen.screens.first { $0.frame.contains(nsPoint) } ?? primary
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
        let targetModifiers = modifiers.eventFlags

        // Empty target = no modifier configured; never match (avoids matching
        // every plain click).
        guard !targetModifiers.isEmpty else { return false }

        if activeModifiers == targetModifiers {
            return true
        }

        guard modifiers.supportsOptionAugmentation else {
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
        // Always run on main: same-process AX writes call NSWindow (which
        // requires main); routing every maximize through main also keeps
        // savedFrames mutations single-threaded with the tile paths.
        DispatchQueue.main.async { [weak self] in
            self?.toggleMaximizeImpl(windowID: windowID, pid: pid, windowFrame: windowFrame)
        }
    }

    private func toggleMaximizeImpl(windowID: CGWindowID, pid: pid_t, windowFrame: CGRect) {
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
