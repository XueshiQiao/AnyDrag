import Cocoa
import ApplicationServices

// MARK: - How Resize Drag Simulation Works
//
// Same trick as TitleBarDragStrategy, but the synthesized click lands on a
// resize corner instead of the title bar. The macOS window server treats
// clicks ~1px inside a window's border as a native resize gesture; we rewrite
// the modifier+right-click's location to that anchor, suppress the original
// down event, and replay it as a leftMouseDown on the first rightMouseDragged
// — the same defer-and-replay pattern the title-bar move uses. Every
// subsequent drag/up event gets rewritten by the same (anchor − cursor) offset
// so the cursor delta drives the edge 1:1, with zero per-frame AX calls.
//
// Corner selection (v1): 4-quadrant by window center. Cursor in the top-left
// quadrant → resize from the top-left corner, etc. Edges (8-zone) can come
// later once the corner-only version proves out in real use.

enum ResizeCorner {
    case topLeft, topRight, bottomLeft, bottomRight

    /// Pick the corner closest to the cursor within a window frame. Uses a
    /// 4-quadrant partition by window center; the cursor's quadrant maps
    /// directly to the corner of the same name.
    static func nearest(cursorCG: CGPoint, windowFrame: CGRect) -> ResizeCorner {
        let left = cursorCG.x < windowFrame.midX
        // CG y-down: smaller y is visually higher (the top edge).
        let top  = cursorCG.y < windowFrame.midY
        switch (top, left) {
        case (true,  true ): return .topLeft
        case (true,  false): return .topRight
        case (false, true ): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }

    /// Anchor point in CG screen coords, `inset` px inside the chosen corner
    /// so it lands in the window-server's resize hit zone. Larger insets are
    /// needed for windows with rounded outer corners — at 1px the geometric
    /// frame corner is in the transparent halo *outside* the rounded shape,
    /// and the synthesized click misses the resize zone entirely. Stock
    /// AppKit windows (TextEdit) work at 1; system apps like Safari / Finder
    /// with larger rounded corners need ~12.
    func anchor(in windowFrame: CGRect, inset: CGFloat) -> CGPoint {
        switch self {
        case .topLeft:     return CGPoint(x: windowFrame.minX + inset, y: windowFrame.minY + inset)
        case .topRight:    return CGPoint(x: windowFrame.maxX - inset, y: windowFrame.minY + inset)
        case .bottomLeft:  return CGPoint(x: windowFrame.minX + inset, y: windowFrame.maxY - inset)
        case .bottomRight: return CGPoint(x: windowFrame.maxX - inset, y: windowFrame.maxY - inset)
        }
    }

    /// Given the original window frame and a cursor delta (CG coords) from
    /// the down point, return the frame the window server should now be
    /// showing. The two sides that meet at this corner move by the delta;
    /// the opposite two stay anchored. Result is clamped to a 40pt minimum
    /// per axis so visual feedback can't degenerate to a negative-size rect
    /// when the user drags past the opposite edge. (The actual window may
    /// have a different minimum and clip differently — accepted divergence
    /// for v1.)
    func predictedFrame(startFrame: CGRect, cursorDelta: CGPoint) -> CGRect {
        var minX = startFrame.minX, minY = startFrame.minY
        var maxX = startFrame.maxX, maxY = startFrame.maxY
        switch self {
        case .topLeft:     minX += cursorDelta.x; minY += cursorDelta.y
        case .topRight:    maxX += cursorDelta.x; minY += cursorDelta.y
        case .bottomLeft:  minX += cursorDelta.x; maxY += cursorDelta.y
        case .bottomRight: maxX += cursorDelta.x; maxY += cursorDelta.y
        }
        let minSize: CGFloat = 40
        if maxX - minX < minSize {
            if self == .topLeft || self == .bottomLeft { minX = maxX - minSize }
            else                                       { maxX = minX + minSize }
        }
        if maxY - minY < minSize {
            if self == .topLeft || self == .topRight   { minY = maxY - minSize }
            else                                       { maxY = minY + minSize }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Rewrites right-button mouse event coordinates to a resize corner so the
/// window server handles the resize natively — same speed and pixel accuracy
/// as grabbing a corner by hand, with no AX setSize call per frame.
final class ResizeStrategy {

    private(set) var isActive = false
    private(set) var didDrag = false
    private var xOffset: CGFloat = 0
    private var yOffset: CGFloat = 0
    private var dragPoint: CGPoint = .zero
    private var needsInitialMouseDown = false

    // Captured at mouseDown so handleMouseDragged can predict the live frame
    // for the feedback overlay without an AX round-trip per event.
    private var startCursor: CGPoint = .zero
    private var startFrame: CGRect = .zero
    private var activeCorner: ResizeCorner = .topLeft

    /// AX handle for the target window, cached at gesture start. Used to
    /// poll the window's actual frame at a throttled rate during the drag
    /// so the corner bracket tracks reality (and stops where the window
    /// actually stops — at the dock, at a screen edge, at an app-enforced
    /// min/max, or not at all for non-resizable windows like System
    /// Settings' horizontal axis). Predicting from cursor delta alone gets
    /// every one of those cases wrong.
    private var axWindow: AXUIElement?

    /// Most recent observed CG frame from AX. Initialized to the gesture's
    /// starting frame, then refreshed every `axPollInterval` while the
    /// drag is in flight.
    private var observedFrame: CGRect?

    /// Throttle anchor for AX polls. Reset at gesture start.
    private var lastAXPoll: Date = .distantPast

    /// ~30 Hz — fast enough that the bracket reads as "live" without
    /// hammering AX during a multi-second drag.
    private static let axPollInterval: TimeInterval = 0.033

    /// How far inside the window's corner the synthesized click lands.
    /// Configurable from Settings → Diagnostics — different apps have
    /// different outer-corner radii, and the click has to land *inside* the
    /// rounded shape (not in the transparent halo) for the window server to
    /// register it as a resize hit. 5 verified to work across native and
    /// Chromium apps.
    var cornerInset: CGFloat = 5

    /// User-facing toggle: show the Corner Bracket overlay during resize?
    /// When false the resize still works (CGEvent rewrite is independent
    /// of the feedback), but we also skip the AX size/position polling
    /// done to keep the bracket tracking the window — the polling exists
    /// only to drive the overlay, so turning the overlay off frees the
    /// CPU budget it spent.
    var cornerBracketEnabled: Bool = true

    /// User-facing toggle, shared with the title-bar move debug dot in
    /// `TitleBarDragStrategy`: show a red marker at the synthesized click
    /// position. Defaults off; the Settings switch flips both strategies.
    var showDebugDot: Bool = false

    /// Pluggable visual indicator. Swap with `NoResizeFeedback` to disable,
    /// or future implementations (anchor dot, geometry HUD) to vary.
    private let feedback: ResizeFeedback
    private var feedbackOpen = false  // begin() called, end() not yet

    /// Diagnostic dot at the location the window server actually sees for our
    /// rewritten mouse events. mouseDown shows it at `dragPoint` (the corner
    /// anchor); each drag moves it to (cursor + offset). Lets us visually
    /// check whether the synthesized click point lands in the system resize
    /// hit zone for any given app.
    private let dragPointDot = DragPointDot()

    init(feedback: ResizeFeedback = EdgeGlowFeedback()) {
        self.feedback = feedback
    }

    /// Only Control is stripped — same reasoning as TitleBarDragStrategy: AppKit
    /// converts Control+leftMouseDown to a secondary-click at the NSResponder
    /// layer, which would defeat the resize.
    private static let modifierFlagsToStrip: CGEventFlags = [.maskControl]

    /// Extra modifier flags to scrub from the synthesized events on top of
    /// `modifierFlagsToStrip`. Set by the engine to the left-click resize
    /// augment key (Shift / Command / …) so it can't perturb the window
    /// server's native resize; left empty for the right-click path. Reset to
    /// empty in `reset()`.
    var extraFlagsToStrip: CGEventFlags = []

    /// All flags scrubbed from synthesized events this gesture. Also read by the
    /// engine so `TrailingFlagScrubber` can repeat the same scrub at the tail of
    /// the tap chain, after any downstream tool has re-asserted them.
    var flagsToStrip: CGEventFlags { Self.modifierFlagsToStrip.union(extraFlagsToStrip) }

    func handleMouseDown(pid: pid_t,
                        windowID: CGWindowID,
                        windowFrame: CGRect,
                        event: CGEvent) -> Unmanaged<CGEvent>? {
        let cursorPos = event.location
        let corner = ResizeCorner.nearest(cursorCG: cursorPos, windowFrame: windowFrame)

        dragPoint = corner.anchor(in: windowFrame, inset: cornerInset)
        xOffset = dragPoint.x - cursorPos.x
        yOffset = dragPoint.y - cursorPos.y
        startCursor = cursorPos
        startFrame = windowFrame
        activeCorner = corner

        // Open the feedback overlay immediately so the user sees confirmation
        // before any drag (mirrors the cursor change the window server will
        // produce on the synthesized first-drag mouseDown). NSPanel touches
        // must happen on main. Both halves (bracket overlay, debug dot) are
        // independently gated by their user settings; when both are off the
        // dispatch is a cheap no-op.
        let bracketOn = cornerBracketEnabled
        let dotOn = showDebugDot
        if bracketOn { feedbackOpen = true }
        let feedback = self.feedback
        let dot = self.dragPointDot
        let anchor = dragPoint
        DispatchQueue.main.async {
            if bracketOn { feedback.begin(windowFrame: windowFrame, corner: corner) }
            if dotOn { dot.show(atCGPoint: anchor) }
        }

        // Activate the target app and raise its window. Same defer-the-click
        // pattern as TitleBarDragStrategy: suppress this down, send the
        // synthesized leftMouseDown on the first drag so the window server has
        // finished reordering by the time the click arrives.
        if pid == getpid() {
            let targetNumber = Int(windowID)
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.windowNumber == targetNumber }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            // Our OWN window still needs an AX handle for the poll loop —
            // AX reads work on the current process too. Without this the
            // corner bracket would freeze at the start frame when resizing
            // AnyDrag's own windows (only the cross-app branch below set it).
            if cornerBracketEnabled {
                axWindow = ResizeStrategy.findAXWindow(pid: pid, windowFrame: windowFrame)
            }
        } else {
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

            if let foundAXWindow = ResizeStrategy.findAXWindow(pid: pid, windowFrame: windowFrame) {
                let raiseResult = AXUIElementPerformAction(foundAXWindow, kAXRaiseAction as CFString)
                if raiseResult != .success {
                    AXUIElementSetAttributeValue(foundAXWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
                }
                // Only cache the window for polling if the bracket is
                // actually going to use it — keeps the AX poll loop
                // dormant when the user has the overlay turned off.
                if cornerBracketEnabled { axWindow = foundAXWindow }
            }
        }
        // Seed the observed frame with the input frame so the very first
        // drag event has something to render before the AX poll kicks in.
        // `Date()` instead of `.distantPast` so the first poll fires
        // `axPollInterval` into the gesture (gives the resize a moment to
        // engage natively before we start reading back).
        //
        // Only seed when we actually got an AX handle to poll. If `findAXWindow`
        // failed (`axWindow == nil`), leaving `observedFrame` nil lets
        // `handleMouseDragged` fall back to cursor-delta prediction — otherwise
        // the seeded start frame would make the bracket freeze (the very bug
        // this gesture's self-window path hit).
        if cornerBracketEnabled, axWindow != nil {
            observedFrame = windowFrame
            lastAXPoll = Date()
        }

        isActive = true
        didDrag = false
        needsInitialMouseDown = true
        return nil  // suppress — first drag becomes the synthesized leftDown
    }

    func handleMouseDragged(event: CGEvent) -> Unmanaged<CGEvent>? {
        didDrag = true
        event.flags = event.flags.subtracting(flagsToStrip)

        // Snapshot the ORIGINAL cursor position before any rewrite — both
        // branches below use it (the early-return branch synthesizes a
        // leftMouseDown at the corner, but we still want the feedback to
        // track the cursor on the very first drag so the glow doesn't
        // stutter for one frame).
        let pos = event.location
        let cursorDelta = CGPoint(x: pos.x - startCursor.x, y: pos.y - startCursor.y)
        // Geometry-only prediction first; then clamp to the screen's
        // visible area so the overlay doesn't drift above the menu bar
        // (the window server stops the actual window there, but our raw
        // prediction would keep going as the cursor moves up).
        // Throttled AX read of the window's actual frame. Bracket tracks
        // reality, not the cursor — so it stops automatically wherever the
        // window stops (dock, screen edge, app min/max, non-resizable).
        let now = Date()
        if let win = axWindow, now.timeIntervalSince(lastAXPoll) >= Self.axPollInterval {
            lastAXPoll = now
            if let actual = Self.readAXFrame(win) {
                observedFrame = actual
            }
        }

        let bracketFrame: CGRect
        if let observed = observedFrame {
            bracketFrame = observed
        } else {
            // No AX window (rare — findAXWindow failed). Fall back to
            // geometry prediction + screen clamp.
            let raw = activeCorner.predictedFrame(startFrame: startFrame, cursorDelta: cursorDelta)
            bracketFrame = Self.clampToVisibleScreen(frame: raw, corner: activeCorner)
        }
        let feedback = self.feedback
        let dot = self.dragPointDot
        // The point the window server will see for this event after we
        // rewrite event.location below. Pre-compute here so the closure
        // captures a snapshot.
        let serverPoint = CGPoint(x: pos.x + xOffset, y: pos.y + yOffset)
        let bracketOn = cornerBracketEnabled
        let dotOn = showDebugDot
        if bracketOn || dotOn {
            DispatchQueue.main.async {
                if bracketOn { feedback.update(windowFrame: bracketFrame) }
                if dotOn { dot.show(atCGPoint: serverPoint) }
            }
        }

        if needsInitialMouseDown {
            needsInitialMouseDown = false
            // Convert this rightMouseDragged into a leftMouseDown at the corner.
            event.type = .leftMouseDown
            event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
            event.location = dragPoint
            return Unmanaged.passUnretained(event)
        }
        event.type = .leftMouseDragged
        event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        event.location = CGPoint(x: pos.x + xOffset, y: pos.y + yOffset)
        return Unmanaged.passUnretained(event)
    }

    func handleMouseUp(event: CGEvent) -> Unmanaged<CGEvent>? {
        // Close out feedback regardless of which path we take below — every
        // begin() call needs an end() to pair with.
        closeFeedback()

        if needsInitialMouseDown {
            // Released before any drag — was a right-click, not a right-drag.
            // Suppress the up so the engine can fall through to the original
            // TilingPanel-on-right-click behavior.
            needsInitialMouseDown = false
            isActive = false
            return nil
        }
        event.type = .leftMouseUp
        event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        event.flags = event.flags.subtracting(flagsToStrip)
        let pos = event.location
        event.location = CGPoint(x: pos.x + xOffset, y: pos.y + yOffset)
        isActive = false
        return Unmanaged.passUnretained(event)
    }

    func reset() {
        // Defensive: if the engine aborts us mid-gesture (tap disabled,
        // stop(), stale-state cleanup at left-down), tear the feedback down
        // here too — otherwise the overlay sticks around with no gesture
        // backing it.
        closeFeedback()
        isActive = false
        didDrag = false
        xOffset = 0
        yOffset = 0
        dragPoint = .zero
        needsInitialMouseDown = false
        startCursor = .zero
        startFrame = .zero
        axWindow = nil
        observedFrame = nil
        lastAXPoll = .distantPast
        extraFlagsToStrip = []
    }

    private func closeFeedback() {
        // The debug dot is shown independently of the bracket (gated by
        // `showDebugDot`), so hide it unconditionally — `dot.hide` is a
        // cheap no-op when it isn't visible.
        let dot = self.dragPointDot
        let hadFeedback = feedbackOpen
        feedbackOpen = false
        let feedback = self.feedback
        DispatchQueue.main.async {
            if hadFeedback { feedback.end() }
            dot.hide()
        }
    }

    // MARK: - AX Window Lookup
    //
    // (Duplicated from TitleBarDragStrategy for now — used only for the
    // one-shot raise on mouseDown, never during drag. Refactor to a shared
    // helper if a third strategy ever needs it.)

    /// Fallback clamp used only when we couldn't acquire an AX handle on
    /// the target window (rare). Clamps each moving edge to the host
    /// screen's *visible* frame — i.e. excludes the menu bar at the top
    /// and the dock at the bottom. The common-case path doesn't go through
    /// here; observed-frame AX polling provides accurate per-app stops.
    private static func clampToVisibleScreen(frame: CGRect, corner: ResizeCorner) -> CGRect {
        guard let primary = NSScreen.screens.first else { return frame }
        let centerNS = NSPoint(
            x: frame.midX,
            y: primary.frame.height - frame.midY
        )
        let screen = NSScreen.screens.first(where: { $0.frame.contains(centerNS) }) ?? primary

        // screen.visibleFrame (NS) → CG (top-left origin, Y-down).
        let vfNS = screen.visibleFrame
        let visibleCG = CGRect(
            x: vfNS.minX,
            y: primary.frame.height - vfNS.maxY,
            width: vfNS.width,
            height: vfNS.height
        )

        let leftMoves   = (corner == .topLeft  || corner == .bottomLeft)
        let rightMoves  = (corner == .topRight || corner == .bottomRight)
        let topMoves    = (corner == .topLeft  || corner == .topRight)
        let bottomMoves = (corner == .bottomLeft || corner == .bottomRight)

        var minX = frame.minX, minY = frame.minY
        var maxX = frame.maxX, maxY = frame.maxY
        if leftMoves   { minX = max(minX, visibleCG.minX) }
        if rightMoves  { maxX = min(maxX, visibleCG.maxX) }
        if topMoves    { minY = max(minY, visibleCG.minY) }
        if bottomMoves { maxY = min(maxY, visibleCG.maxY) }

        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    /// Read the target window's current position + size via AX, returning
    /// a CG-coord frame. nil if either attribute is missing or malformed.
    /// Synchronous; called on the tap thread at the throttled poll rate.
    /// AX read calls are documented thread-safe.
    private static func readAXFrame(_ axWindow: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        let r1 = AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
        let r2 = AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
        guard r1 == .success, r2 == .success,
              let posVal = posRef, let sizeVal = sizeRef,
              CFGetTypeID(posVal) == AXValueGetTypeID(),
              CFGetTypeID(sizeVal) == AXValueGetTypeID()
        else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    private static func findAXWindow(pid: pid_t, windowFrame: CGRect) -> AXUIElement? {
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

// MARK: - Persistent debug dot
//
// Like `DebugDotOverlay` but stays visible for the whole gesture (no fade)
// and supports cheap repositioning on every drag event. Used to visualize
// the point the window server actually receives — invaluable for figuring
// out why a synthesized resize gesture works for some apps but not others.

private final class DragPointDot {

    static let size: CGFloat = 12

    private let panel: NSPanel

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.isMovable = false

        let dot = NSView(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.size / 2
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.borderColor = NSColor.white.cgColor
        dot.layer?.borderWidth = 2
        panel.contentView = dot
    }

    /// Show or move the dot to the given CGEvent screen point (top-left
    /// origin, Y-down). Same flip convention as TileCancelDot.
    func show(atCGPoint cg: CGPoint) {
        guard let primary = NSScreen.screens.first else { return }
        let nsY = primary.frame.height - cg.y
        let frame = NSRect(
            x: cg.x - Self.size / 2,
            y: nsY - Self.size / 2,
            width: Self.size,
            height: Self.size
        )
        panel.setFrame(frame, display: false)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        if panel.isVisible {
            panel.orderOut(nil)
        }
    }
}
