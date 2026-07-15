import AppKit
import ApplicationServices

private func linkedResizeAXObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let controller = Unmanaged<LinkedWindowResizeController>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    controller.handleAXNotification(notification as String)
}

enum LinkedTileSlot {
    case left, right, top, bottom

    var opposite: LinkedTileSlot {
        switch self {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }

    var orientation: LinkedDividerOrientation {
        switch self {
        case .left, .right: return .vertical
        case .top, .bottom: return .horizontal
        }
    }
}

enum LinkedDividerOrientation {
    case vertical, horizontal
}

/// Tracks two-window layouts created by AnyDrag and exposes their shared edge
/// as a directly draggable divider. Window frame writes are coalesced by a
/// 60 Hz main-run-loop timer, so slow AX clients drop intermediate cursor
/// positions rather than building a lagging queue.
final class LinkedWindowResizeController {
    private static let log = FileLog("LinkedResize")
    private struct Placement {
        let windowID: CGWindowID
        let pid: pid_t
        let frame: CGRect
        let screenFrame: CGRect
        let slot: LinkedTileSlot
    }

    private struct Member {
        let windowID: CGWindowID
        let pid: pid_t
        let axWindow: AXUIElement
        var frame: CGRect
    }

    private struct Group {
        var leading: Member
        var trailing: Member
        let orientation: LinkedDividerOrientation
        var outerFrame: CGRect

        var divider: CGFloat {
            switch orientation {
            case .vertical: return leading.frame.maxX
            case .horizontal: return leading.frame.maxY
            }
        }
    }

    private static let edgeTolerance: CGFloat = 4
    private static let minimumWidth: CGFloat = 160
    private static let minimumHeight: CGFloat = 120
    private static let handleThickness: CGFloat = 8
    private static let updateInterval: TimeInterval = 1.0 / 60.0
    private static let minimumProbeStride = 4

    private var placements: [CGWindowID: Placement] = [:]
    private var group: Group?
    private lazy var panel: LinkedDividerPanel = {
        let panel = LinkedDividerPanel()
        panel.onMouseDown = { [weak self] point in self?.beginDrag(atNSPoint: point) }
        panel.onMouseDragged = { [weak self] point in self?.updateDrag(atNSPoint: point) }
        panel.onMouseUp = { [weak self] point in self?.endDrag(atNSPoint: point) }
        return panel
    }()

    private var updateTimer: Timer?
    private var pendingDivider: CGFloat?
    private var lastAppliedDivider: CGFloat?
    private var isDragging = false
    private var enhancedAppsToRestore: [AXUIElement] = []
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var cursorIsOverDivider = false
    private let eventStateLock = NSLock()
    private var eventHitRect: CGRect?
    private var eventDragActive = false
    private lazy var cursorOverlay = LinkedDividerCursorOverlay()
    private var leadingMinimumLength: CGFloat = 160
    private var trailingMinimumLength: CGFloat = 160
    private var minimumProbeCounter = 0
    private var latestDragPoint: CGPoint?
    private var axObservers: [pid_t: AXObserver] = [:]
    private var validationWorkItem: DispatchWorkItem?
    private var activeSpaceObserver: Any?
    private var lastValidationAt = Date.distantPast

    deinit {
        tearDownLifecycleObservers()
        updateTimer?.invalidate()
        removeCursorMonitors()
        clearDividerCursor()
    }

    /// Called from DragEngine's event-tap thread. Returns true when the plain
    /// left-button event belongs to the shared divider and must be suppressed.
    func handleMouseEvent(type: CGEventType, location: CGPoint) -> Bool {
        enum Action { case begin, update, end }
        let action: Action?

        eventStateLock.lock()
        switch type {
        case .leftMouseDown:
            if let eventHitRect, eventHitRect.contains(location) {
                eventDragActive = true
                action = .begin
            } else {
                action = nil
            }
        case .leftMouseDragged:
            action = eventDragActive ? .update : nil
        case .leftMouseUp:
            if eventDragActive {
                eventDragActive = false
                action = .end
            } else {
                action = nil
            }
        default:
            action = nil
        }
        eventStateLock.unlock()

        guard let action else { return false }
        DispatchQueue.main.async { [weak self] in
            switch action {
            case .begin: self?.beginDrag(atCGPoint: location)
            case .update: self?.updateDrag(atCGPoint: location)
            case .end: self?.endDrag(atCGPoint: location)
            }
        }
        return true
    }

    func recordTiledWindow(
        windowID: CGWindowID,
        pid: pid_t,
        frame: CGRect,
        screenFrame: CGRect,
        slot: LinkedTileSlot
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        removeWindow(windowID)

        // Only the most recently tiled window can own a given half-screen
        // slot. Drop covered/stale occupants so a new complementary placement
        // cannot accidentally pair with a window hidden underneath it.
        let superseded = placements.values.filter {
            $0.slot == slot && framesMatch($0.screenFrame, screenFrame)
        }.map(\.windowID)
        superseded.forEach(removeWindow)

        let placement = Placement(
            windowID: windowID,
            pid: pid,
            frame: frame,
            screenFrame: screenFrame,
            slot: slot
        )
        placements[windowID] = placement
        Self.log.info("recorded window wid=\(windowID) slot=\(slot) frame=\(frame)")

        guard let complement = placements.values.first(where: {
            $0.windowID != windowID
                && $0.slot == slot.opposite
                && framesMatch($0.screenFrame, screenFrame)
        }) else { return }

        createGroup(from: placement, and: complement)
    }

    func removeWindow(_ windowID: CGWindowID) {
        dispatchPrecondition(condition: .onQueue(.main))
        placements.removeValue(forKey: windowID)
        if group?.leading.windowID == windowID || group?.trailing.windowID == windowID {
            dissolveGroup()
        }
    }

    private func createGroup(from first: Placement, and second: Placement) {
        let leadingPlacement: Placement
        let trailingPlacement: Placement
        switch first.slot.orientation {
        case .vertical:
            leadingPlacement = first.slot == .left ? first : second
            trailingPlacement = first.slot == .right ? first : second
        case .horizontal:
            leadingPlacement = first.slot == .top ? first : second
            trailingPlacement = first.slot == .bottom ? first : second
        }

        guard let leadingAX = findAXWindow(pid: leadingPlacement.pid, frame: leadingPlacement.frame),
              let trailingAX = findAXWindow(pid: trailingPlacement.pid, frame: trailingPlacement.frame)
        else { return }

        let newGroup = Group(
            leading: Member(
                windowID: leadingPlacement.windowID,
                pid: leadingPlacement.pid,
                axWindow: leadingAX,
                frame: leadingPlacement.frame
            ),
            trailing: Member(
                windowID: trailingPlacement.windowID,
                pid: trailingPlacement.pid,
                axWindow: trailingAX,
                frame: trailingPlacement.frame
            ),
            orientation: first.slot.orientation,
            outerFrame: leadingPlacement.frame.union(trailingPlacement.frame)
        )
        guard framesAreAdjacent(newGroup) else { return }

        dissolveGroup()
        group = newGroup
        let defaultMinimum = newGroup.orientation == .vertical
            ? Self.minimumWidth : Self.minimumHeight
        leadingMinimumLength = defaultMinimum
        trailingMinimumLength = defaultMinimum
        Self.log.info(
            "created \(newGroup.orientation) group leading=\(newGroup.leading.windowID) "
                + "trailing=\(newGroup.trailing.windowID) divider=\(newGroup.divider)"
        )
        installCursorMonitors()
        installLifecycleObservers(for: newGroup)
        validateGroup()
    }

    private func beginDrag(atNSPoint point: CGPoint) {
        guard let primary = NSScreen.screens.first else { return }
        beginDrag(atCGPoint: CGPoint(x: point.x, y: primary.frame.height - point.y))
    }

    private func beginDrag(atCGPoint point: CGPoint) {
        guard group != nil else { return }
        Self.log.info("divider mouseDown at \(point)")
        isDragging = true
        latestDragPoint = point
        pendingDivider = dividerCoordinate(fromCGPoint: point)
        lastAppliedDivider = nil
        minimumProbeCounter = 0
        disableEnhancedUIForMembers()

        updateTimer?.invalidate()
        let timer = Timer(timeInterval: Self.updateInterval, repeats: true) {
            [weak self] _ in self?.flushPendingDivider()
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    private func updateDrag(atNSPoint point: CGPoint) {
        guard let primary = NSScreen.screens.first else { return }
        updateDrag(atCGPoint: CGPoint(x: point.x, y: primary.frame.height - point.y))
    }

    private func updateDrag(atCGPoint point: CGPoint) {
        guard isDragging else { return }
        latestDragPoint = point
        pendingDivider = dividerCoordinate(fromCGPoint: point)
    }

    private func endDrag(atNSPoint point: CGPoint) {
        guard let primary = NSScreen.screens.first else { return }
        endDrag(atCGPoint: CGPoint(x: point.x, y: primary.frame.height - point.y))
    }

    private func endDrag(atCGPoint point: CGPoint) {
        guard isDragging else { return }
        latestDragPoint = point
        pendingDivider = dividerCoordinate(fromCGPoint: point)
        flushPendingDivider(forceMinimumProbe: true)
        updateTimer?.invalidate()
        updateTimer = nil
        pendingDivider = nil
        lastAppliedDivider = nil
        isDragging = false
        restoreEnhancedUIForMembers()
        validateGroup()
        latestDragPoint = nil
        clearDividerCursor()
    }

    private func flushPendingDivider(forceMinimumProbe: Bool = false) {
        guard var current = group, let requested = pendingDivider else { return }
        var divider: CGFloat
        minimumProbeCounter += 1
        let shouldProbeMinimum = forceMinimumProbe
            || minimumProbeCounter % Self.minimumProbeStride == 0
        switch current.orientation {
        case .vertical:
            divider = min(
                max(requested, current.outerFrame.minX + leadingMinimumLength),
                current.outerFrame.maxX - trailingMinimumLength
            )
            guard divider != lastAppliedDivider || forceMinimumProbe else { return }
            let leadingFrame = CGRect(
                x: current.outerFrame.minX,
                y: current.outerFrame.minY,
                width: divider - current.outerFrame.minX,
                height: current.outerFrame.height
            )
            let trailingFrame = CGRect(
                x: divider,
                y: current.outerFrame.minY,
                width: current.outerFrame.maxX - divider,
                height: current.outerFrame.height
            )
            if divider < current.divider {
                // Trailing window grows toward the leading window. Move it
                // across the new seam before shrinking the leading window so
                // slow AX calls produce a brief overlap instead of a gap.
                setPosition(current.trailing.axWindow, trailingFrame.origin)
                setSize(current.trailing.axWindow, trailingFrame.size)
                setSize(current.leading.axWindow, leadingFrame.size)
                if shouldProbeMinimum,
                   let actualSize = readAXSize(current.leading.axWindow),
                   actualSize.width > leadingFrame.width + Self.edgeTolerance {
                    leadingMinimumLength = max(leadingMinimumLength, actualSize.width)
                    divider = current.outerFrame.minX + actualSize.width
                    let correctedTrailing = CGRect(
                        x: divider,
                        y: current.outerFrame.minY,
                        width: current.outerFrame.maxX - divider,
                        height: current.outerFrame.height
                    )
                    setPosition(current.trailing.axWindow, correctedTrailing.origin)
                    setSize(current.trailing.axWindow, correctedTrailing.size)
                    current.leading.frame.size.width = actualSize.width
                    current.trailing.frame = correctedTrailing
                    Self.log.info("learned leading minimum width=\(actualSize.width)")
                } else {
                    current.leading.frame = leadingFrame
                    current.trailing.frame = trailingFrame
                }
            } else {
                // Leading window grows across the seam first; then shrink and
                // move the trailing window out from underneath it.
                setSize(current.leading.axWindow, leadingFrame.size)
                setSize(current.trailing.axWindow, trailingFrame.size)
                setPosition(current.trailing.axWindow, trailingFrame.origin)
                if shouldProbeMinimum,
                   let actualSize = readAXSize(current.trailing.axWindow),
                   actualSize.width > trailingFrame.width + Self.edgeTolerance {
                    trailingMinimumLength = max(trailingMinimumLength, actualSize.width)
                    divider = current.outerFrame.maxX - actualSize.width
                    let correctedLeading = CGRect(
                        x: current.outerFrame.minX,
                        y: current.outerFrame.minY,
                        width: divider - current.outerFrame.minX,
                        height: current.outerFrame.height
                    )
                    let correctedTrailingOrigin = CGPoint(x: divider, y: current.outerFrame.minY)
                    setSize(current.leading.axWindow, correctedLeading.size)
                    setPosition(current.trailing.axWindow, correctedTrailingOrigin)
                    current.leading.frame = correctedLeading
                    current.trailing.frame = CGRect(
                        origin: correctedTrailingOrigin,
                        size: actualSize
                    )
                    Self.log.info("learned trailing minimum width=\(actualSize.width)")
                } else {
                    current.leading.frame = leadingFrame
                    current.trailing.frame = trailingFrame
                }
            }

        case .horizontal:
            divider = min(
                max(requested, current.outerFrame.minY + leadingMinimumLength),
                current.outerFrame.maxY - trailingMinimumLength
            )
            guard divider != lastAppliedDivider || forceMinimumProbe else { return }
            let leadingFrame = CGRect(
                x: current.outerFrame.minX,
                y: current.outerFrame.minY,
                width: current.outerFrame.width,
                height: divider - current.outerFrame.minY
            )
            let trailingFrame = CGRect(
                x: current.outerFrame.minX,
                y: divider,
                width: current.outerFrame.width,
                height: current.outerFrame.maxY - divider
            )
            if divider < current.divider {
                setPosition(current.trailing.axWindow, trailingFrame.origin)
                setSize(current.trailing.axWindow, trailingFrame.size)
                setSize(current.leading.axWindow, leadingFrame.size)
                if shouldProbeMinimum,
                   let actualSize = readAXSize(current.leading.axWindow),
                   actualSize.height > leadingFrame.height + Self.edgeTolerance {
                    leadingMinimumLength = max(leadingMinimumLength, actualSize.height)
                    divider = current.outerFrame.minY + actualSize.height
                    let correctedTrailing = CGRect(
                        x: current.outerFrame.minX,
                        y: divider,
                        width: current.outerFrame.width,
                        height: current.outerFrame.maxY - divider
                    )
                    setPosition(current.trailing.axWindow, correctedTrailing.origin)
                    setSize(current.trailing.axWindow, correctedTrailing.size)
                    current.leading.frame.size.height = actualSize.height
                    current.trailing.frame = correctedTrailing
                    Self.log.info("learned leading minimum height=\(actualSize.height)")
                } else {
                    current.leading.frame = leadingFrame
                    current.trailing.frame = trailingFrame
                }
            } else {
                setSize(current.leading.axWindow, leadingFrame.size)
                setSize(current.trailing.axWindow, trailingFrame.size)
                setPosition(current.trailing.axWindow, trailingFrame.origin)
                if shouldProbeMinimum,
                   let actualSize = readAXSize(current.trailing.axWindow),
                   actualSize.height > trailingFrame.height + Self.edgeTolerance {
                    trailingMinimumLength = max(trailingMinimumLength, actualSize.height)
                    divider = current.outerFrame.maxY - actualSize.height
                    let correctedLeading = CGRect(
                        x: current.outerFrame.minX,
                        y: current.outerFrame.minY,
                        width: current.outerFrame.width,
                        height: divider - current.outerFrame.minY
                    )
                    let correctedTrailingOrigin = CGPoint(x: current.outerFrame.minX, y: divider)
                    setSize(current.leading.axWindow, correctedLeading.size)
                    setPosition(current.trailing.axWindow, correctedTrailingOrigin)
                    current.leading.frame = correctedLeading
                    current.trailing.frame = CGRect(
                        origin: correctedTrailingOrigin,
                        size: actualSize
                    )
                    Self.log.info("learned trailing minimum height=\(actualSize.height)")
                } else {
                    current.leading.frame = leadingFrame
                    current.trailing.frame = trailingFrame
                }
            }
        }

        lastAppliedDivider = divider
        group = current
        updatePanelFrame(for: current)
        synchronizeDragCursor(
            requestedDivider: requested,
            effectiveDivider: divider,
            orientation: current.orientation
        )
    }

    private func synchronizeDragCursor(
        requestedDivider: CGFloat,
        effectiveDivider: CGFloat,
        orientation: LinkedDividerOrientation
    ) {
        guard var point = latestDragPoint else { return }
        switch orientation {
        case .vertical: point.x = effectiveDivider
        case .horizontal: point.y = effectiveDivider
        }

        if abs(requestedDivider - effectiveDivider) > 1 {
            CGWarpMouseCursorPosition(point)
            latestDragPoint = point
        }

        guard cursorIsOverDivider, let primary = NSScreen.screens.first else { return }
        let nsPoint = CGPoint(x: point.x, y: primary.frame.height - point.y)
        let cursor: NSCursor = orientation == .vertical ? .resizeLeftRight : .resizeUpDown
        cursorOverlay.show(cursor: cursor, at: nsPoint)
    }

    private func validateGroup() {
        guard !isDragging, var current = group else { return }
        lastValidationAt = Date()
        guard let leadingFrame = readAXFrame(current.leading.axWindow),
              let trailingFrame = readAXFrame(current.trailing.axWindow)
        else {
            dissolveGroup()
            return
        }

        current.leading.frame = leadingFrame
        current.trailing.frame = trailingFrame
        current.outerFrame = leadingFrame.union(trailingFrame)
        guard framesAreAdjacent(current), windowsAreOnScreen(current) else {
            dissolveGroup()
            return
        }

        group = current
        updatePanelFrame(for: current)
        panel.show(aboveWindow: frontmostMemberWindowID(in: current))
        updateCursorForCurrentMouse()
    }

    private func framesAreAdjacent(_ candidate: Group) -> Bool {
        switch candidate.orientation {
        case .vertical:
            return abs(candidate.leading.frame.maxX - candidate.trailing.frame.minX) <= Self.edgeTolerance
                && abs(candidate.leading.frame.minY - candidate.trailing.frame.minY) <= Self.edgeTolerance
                && abs(candidate.leading.frame.maxY - candidate.trailing.frame.maxY) <= Self.edgeTolerance
        case .horizontal:
            return abs(candidate.leading.frame.maxY - candidate.trailing.frame.minY) <= Self.edgeTolerance
                && abs(candidate.leading.frame.minX - candidate.trailing.frame.minX) <= Self.edgeTolerance
                && abs(candidate.leading.frame.maxX - candidate.trailing.frame.maxX) <= Self.edgeTolerance
        }
    }

    private func windowsAreOnScreen(_ candidate: Group) -> Bool {
        let ids = onScreenWindowIDs()
        return ids.contains(candidate.leading.windowID) && ids.contains(candidate.trailing.windowID)
    }

    private func updatePanelFrame(for candidate: Group) {
        let hitRect: CGRect
        switch candidate.orientation {
        case .vertical:
            hitRect = CGRect(
                x: candidate.divider - Self.handleThickness / 2,
                y: candidate.outerFrame.minY,
                width: Self.handleThickness,
                height: candidate.outerFrame.height
            )
        case .horizontal:
            hitRect = CGRect(
                x: candidate.outerFrame.minX,
                y: candidate.divider - Self.handleThickness / 2,
                width: candidate.outerFrame.width,
                height: Self.handleThickness
            )
        }
        eventStateLock.lock()
        eventHitRect = hitRect
        eventStateLock.unlock()

        guard let primary = NSScreen.screens.first else { return }
        let primaryHeight = primary.frame.height
        let panelFrame: NSRect
        switch candidate.orientation {
        case .vertical:
            panelFrame = NSRect(
                x: candidate.divider - Self.handleThickness / 2,
                y: primaryHeight - candidate.outerFrame.maxY,
                width: Self.handleThickness,
                height: candidate.outerFrame.height
            )
        case .horizontal:
            panelFrame = NSRect(
                x: candidate.outerFrame.minX,
                y: primaryHeight - candidate.divider - Self.handleThickness / 2,
                width: candidate.outerFrame.width,
                height: Self.handleThickness
            )
        }
        panel.update(frame: panelFrame, orientation: candidate.orientation)
    }

    private func dividerCoordinate(fromCGPoint point: CGPoint) -> CGFloat {
        guard let orientation = group?.orientation else { return 0 }
        switch orientation {
        case .vertical:
            return point.x
        case .horizontal:
            return point.y
        }
    }

    private func dissolveGroup() {
        if let current = group {
            placements.removeValue(forKey: current.leading.windowID)
            placements.removeValue(forKey: current.trailing.windowID)
        }
        tearDownLifecycleObservers()
        updateTimer?.invalidate()
        updateTimer = nil
        restoreEnhancedUIForMembers()
        isDragging = false
        pendingDivider = nil
        lastAppliedDivider = nil
        latestDragPoint = nil
        group = nil
        eventStateLock.lock()
        eventHitRect = nil
        eventDragActive = false
        eventStateLock.unlock()
        panel.hide()
        clearDividerCursor()
        removeCursorMonitors()
    }

    private func installCursorMonitors() {
        guard globalMouseMonitor == nil, localMouseMonitor == nil else { return }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.updateCursorForCurrentMouse() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] event in
            self?.updateCursorForCurrentMouse()
            return event
        }
    }

    private func removeCursorMonitors() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
    }

    private func updateCursorForCurrentMouse() {
        let isOverDivider = panel.isVisible && panel.frame.contains(NSEvent.mouseLocation)
        guard isOverDivider else {
            clearDividerCursor()
            return
        }
        if !cursorIsOverDivider,
           Date().timeIntervalSince(lastValidationAt) > 0.25 {
            validateGroup()
            guard group != nil, panel.isVisible else { return }
        }
        guard let orientation = group?.orientation else { return }
        let cursor: NSCursor = orientation == .vertical ? .resizeLeftRight : .resizeUpDown
        cursorOverlay.show(cursor: cursor, at: NSEvent.mouseLocation)
        if !cursorIsOverDivider {
            NSCursor.hide()
            Self.log.debug("cursor entered visible divider")
            cursorIsOverDivider = true
        }
    }

    private func clearDividerCursor() {
        if cursorIsOverDivider {
            cursorOverlay.hide()
            NSCursor.unhide()
            cursorIsOverDivider = false
        }
    }

    fileprivate func handleAXNotification(_ notification: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        if notification == kAXUIElementDestroyedNotification as String
            || notification == kAXWindowMiniaturizedNotification as String {
            dissolveGroup()
            return
        }
        guard !isDragging else { return }
        scheduleValidation()
    }

    private func scheduleValidation() {
        validationWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.validateGroup() }
        validationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func installLifecycleObservers(for candidate: Group) {
        tearDownLifecycleObservers()
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let members = [candidate.leading, candidate.trailing]
        let notifications: [String] = [
            kAXMovedNotification,
            kAXResizedNotification,
            kAXUIElementDestroyedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
        ]

        for member in members {
            let observer: AXObserver
            if let existing = axObservers[member.pid] {
                observer = existing
            } else {
                var created: AXObserver?
                guard AXObserverCreate(
                    member.pid, linkedResizeAXObserverCallback, &created
                ) == .success, let created else { continue }
                observer = created
                axObservers[member.pid] = observer
                CFRunLoopAddSource(
                    CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes
                )
            }
            for notification in notifications {
                let result = AXObserverAddNotification(
                    observer, member.axWindow, notification as CFString, refcon
                )
                if result != .success && result != .notificationAlreadyRegistered {
                    Self.log.debug(
                        "AX observer registration failed pid=\(member.pid) "
                            + "notification=\(notification) error=\(result.rawValue)"
                    )
                }
            }
        }

        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.scheduleValidation() }
    }

    private func tearDownLifecycleObservers() {
        validationWorkItem?.cancel()
        validationWorkItem = nil
        for observer in axObservers.values {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes
            )
        }
        axObservers.removeAll()
        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
            self.activeSpaceObserver = nil
        }
    }

    private func disableEnhancedUIForMembers() {
        enhancedAppsToRestore.removeAll()
        guard let current = group else { return }
        for member in [current.leading, current.trailing] {
            let app = AXUIElementCreateApplication(member.pid)
            var value: CFTypeRef?
            let enabled = AXUIElementCopyAttributeValue(
                app, "AXEnhancedUserInterface" as CFString, &value
            ) == .success && (value as? NSNumber)?.boolValue == true
            if enabled {
                AXUIElementSetAttributeValue(
                    app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse
                )
                enhancedAppsToRestore.append(app)
            }
        }
    }

    private func restoreEnhancedUIForMembers() {
        enhancedAppsToRestore.forEach {
            AXUIElementSetAttributeValue(
                $0, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue
            )
        }
        enhancedAppsToRestore.removeAll()
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= Self.edgeTolerance
            && abs(lhs.minY - rhs.minY) <= Self.edgeTolerance
            && abs(lhs.width - rhs.width) <= Self.edgeTolerance
            && abs(lhs.height - rhs.height) <= Self.edgeTolerance
    }

    private func findAXWindow(pid: pid_t, frame: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXWindowsAttribute as CFString, &windowsRef
        ) == .success, let windows = windowsRef as? [AXUIElement] else { return nil }

        return windows.first { window in
            guard let candidate = readAXFrame(window) else { return false }
            return abs(candidate.minX - frame.minX) <= Self.edgeTolerance
                && abs(candidate.minY - frame.minY) <= Self.edgeTolerance
        }
    }

    private func readAXFrame(_ window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXPositionAttribute as CFString, &positionRef
        ) == .success,
        AXUIElementCopyAttributeValue(
            window, kAXSizeAttribute as CFString, &sizeRef
        ) == .success,
        let positionRef,
        let sizeRef,
        CFGetTypeID(positionRef) == AXValueGetTypeID(),
        CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    private func readAXSize(_ window: AXUIElement) -> CGSize? {
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXSizeAttribute as CFString, &sizeRef
        ) == .success,
        let sizeRef,
        CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }

        var size = CGSize.zero
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return size
    }

    private func setSize(_ window: AXUIElement, _ size: CGSize) {
        var mutableSize = size
        guard let value = AXValueCreate(.cgSize, &mutableSize) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    private func setPosition(_ window: AXUIElement, _ position: CGPoint) {
        var mutablePosition = position
        guard let value = AXValueCreate(.cgPoint, &mutablePosition) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    private func onScreenWindowIDs() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[CFString: Any]] else { return [] }
        return Set(list.compactMap { $0[kCGWindowNumber] as? CGWindowID })
    }

    private func frontmostMemberWindowID(in candidate: Group) -> CGWindowID {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[CFString: Any]] else { return candidate.leading.windowID }

        for info in list {
            guard let id = info[kCGWindowNumber] as? CGWindowID else { continue }
            if id == candidate.leading.windowID || id == candidate.trailing.windowID {
                return id
            }
        }
        return candidate.leading.windowID
    }
}

private final class LinkedDividerPanel: NSPanel {
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?

    private let handleView = LinkedDividerHandleView()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .normal
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        collectionBehavior = [.transient, .ignoresCycle]
        contentView = handleView

        handleView.onMouseDown = { [weak self] point in self?.onMouseDown?(point) }
        handleView.onMouseDragged = { [weak self] point in self?.onMouseDragged?(point) }
        handleView.onMouseUp = { [weak self] point in self?.onMouseUp?(point) }
    }

    func update(frame: NSRect, orientation: LinkedDividerOrientation) {
        handleView.orientation = orientation
        setFrame(frame, display: false)
    }

    func show(aboveWindow windowID: CGWindowID) {
        order(.above, relativeTo: Int(windowID))
    }

    func hide() {
        if isVisible { orderOut(nil) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class LinkedDividerHandleView: NSView {
    var orientation: LinkedDividerOrientation = .vertical {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    private var resizeCursor: NSCursor {
        orientation == .vertical ? .resizeLeftRight : .resizeUpDown
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: resizeCursor)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { resizeCursor.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    override func cursorUpdate(with event: NSEvent) { resizeCursor.set() }
    override func mouseDown(with event: NSEvent) { onMouseDown?(NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(NSEvent.mouseLocation) }
}

/// Mouse-transparent replacement for the system cursor while it is over a
/// divider. Foreground apps routinely overwrite `NSCursor.set()` for their own
/// content, so drawing the system resize cursor image in a top-level panel is
/// the only deterministic cross-process presentation.
private final class LinkedDividerCursorOverlay: NSPanel {
    private let imageView = NSImageView()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle]
        contentView = imageView
        imageView.imageScaling = .scaleNone
    }

    func show(cursor: NSCursor, at point: CGPoint) {
        let image = cursor.image
        let size = image.size
        let hotSpot = cursor.hotSpot
        imageView.image = image
        setFrame(
            NSRect(
                x: point.x - hotSpot.x,
                y: point.y - (size.height - hotSpot.y),
                width: size.width,
                height: size.height
            ),
            display: false
        )
        if !isVisible { orderFrontRegardless() }
    }

    func hide() {
        if isVisible { orderOut(nil) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
