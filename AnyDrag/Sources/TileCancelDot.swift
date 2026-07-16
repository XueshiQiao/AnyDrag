import AppKit

// MARK: - TileCancelDot
//
// Bento-style overlay shown at the middle-button gesture origin while a
// tile-by-direction gesture is in flight. Two modes:
//
//   1. Single-display (the original): a fixed 290×185 panel with one 3×3
//      grid. Cells extend to infinity outside the panel, so the user can
//      fling the cursor and still resolve to a zone.
//
//   2. Multi-display (`multiDisplayEnabled = true` AND ≥2 connected
//      displays): the panel contains one "card" per connected display,
//      laid out at the displays' real relative positions and sizes. Each
//      card has its own 3×3 grid. The current display gets an accent
//      border. Cells are bounded by the card's rect — cursor outside any
//      card resolves to no zone (release cancels).
//
// (Type is still named `TileCancelDot` for historical/source-stability
// reasons; the very first version of this overlay was a single accent
// ring with no grid.)

final class TileCancelDot: NSPanel {

    private struct PanelPlacement {
        let windowFrame: NSRect
        let layoutOrigin: NSPoint
        let displayOffset: NSPoint
    }

    // MARK: - Layout constants (single-display)

    /// Panel size in points. ~16:10 ratio so the tile previews read as
    /// little screens; large enough that each tile is comfortable to hit,
    /// small enough not to swallow the underlying window.
    static let panelWidth: CGFloat = 290
    static let panelHeight: CGFloat = 185

    /// Room for the shadow and, when displaced, the popover pointer.
    private static let screenInset: CGFloat = 12

    /// Padding between the panel chrome and the grid of tiles.
    static let chromePadding: CGFloat = 12

    /// Gap between adjacent tiles.
    static let tileGap: CGFloat = 5

    /// Tile dimensions for the single-display path.
    static var tileWidth: CGFloat {
        (panelWidth - chromePadding * 2 - tileGap * 2) / 3
    }
    static var tileHeight: CGFloat {
        (panelHeight - chromePadding * 2 - tileGap * 2) / 3
    }

    /// Half-width of the center deadzone (single-display path), measured
    /// from the panel center. Equals half the center cell plus half a gap
    /// so the boundary sits on the visible gap line — "cursor crossing the
    /// gap" matches "cursor commits to the adjacent tile".
    static var halfDeadzoneWidth: CGFloat {
        tileWidth / 2 + tileGap / 2
    }
    static var halfDeadzoneHeight: CGFloat {
        tileHeight / 2 + tileGap / 2
    }

    // MARK: - Layout constants (multi-display)

    /// Visual gap between display cards inside the panel. Cards themselves
    /// keep the same dimensions as the original single-display bento
    /// (`panelWidth × panelHeight`) so the per-card chrome, cells, colors,
    /// and preview rects render at the exact same scale — multi-display
    /// is just "tile N old bento cards spatially."
    static let multiCardGap: CGFloat = 8

    /// Total height reserved BELOW each card for its label (gap above
    /// label + label line height + gap below label). Single source of
    /// truth — `drawCardLabel` uses the same margins to position itself.
    fileprivate static let cardLabelTopMargin: CGFloat = 12
    fileprivate static let cardLabelHeight: CGFloat    = 13
    fileprivate static let cardLabelBottomMargin: CGFloat = 7
    fileprivate static let cardLabelAreaHeight: CGFloat = cardLabelTopMargin + cardLabelHeight + cardLabelBottomMargin

    // MARK: - Mode

    /// Set by DragEngine from Preferences before each show. When false
    /// (or when only one display is connected) we use the single-display
    /// path — pixel-identical to the pre-multi-display behaviour.
    var multiDisplayEnabled: Bool = false

    /// Set by DragEngine from Preferences before each show. When true (default),
    /// the overlay is kept fully on-screen near a screen edge and the real
    /// cursor glides to its center; when false, it centers on the cursor with
    /// no edge clamping and no cursor warp — the original pre-edge-safe
    /// behavior. Single-display direction is then measured from the actual
    /// (un-warped) cursor/panel center, which keeps it geometrically correct.
    var edgeSafeEnabled: Bool = true

    /// Origin used by the current layout's hit testing. It differs from the
    /// window origin only when an oversized multi-display layout is clipped.
    fileprivate var layoutOriginNS: NSPoint?

    /// The immutable middle-button press point. Single-display direction
    /// selection stays relative to this point even when the panel moves.
    private var gestureOriginNS: NSPoint?

    // MARK: - Subviews

    private let contentContainer = NSView()
    private let vibrancyView = BentoPopoverEffectView()
    private let fillView = TileCancelDotView()
    private let cursorTransition = BentoCursorTransition()

    /// Plan B "floating chip": the target app's icon + name, hovering just
    /// above the bento. A separate panel (not part of this one) so the grid
    /// stays pixel-for-pixel and the anchor is identical for 1 or N cards.
    private let targetChip = BentoTargetChip()
    private var targetAppName: String?
    private var targetAppIcon: NSImage?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        level = .statusBar
        animationBehavior = .none
        hidesOnDeactivate = false
        isMovable = false

        // `.popover` adapts to system appearance — dark in dark mode,
        // light in light mode — so the panel never feels washed out the
        // way `.hudWindow` (intentionally dark always) did in light mode.
        vibrancyView.material = .popover
        vibrancyView.blendingMode = .behindWindow
        vibrancyView.state = .active
        vibrancyView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = NSColor.clear.cgColor
        contentContainer.addSubview(vibrancyView)

        fillView.translatesAutoresizingMaskIntoConstraints = false
        vibrancyView.addSubview(fillView)
        NSLayoutConstraint.activate([
            vibrancyView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            vibrancyView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            vibrancyView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            vibrancyView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            fillView.leadingAnchor.constraint(equalTo: vibrancyView.leadingAnchor),
            fillView.trailingAnchor.constraint(equalTo: vibrancyView.trailingAnchor),
            fillView.topAnchor.constraint(equalTo: vibrancyView.topAnchor),
            fillView.bottomAnchor.constraint(equalTo: vibrancyView.bottomAnchor),
        ])

        contentView = contentContainer
    }

    // MARK: - Target chip (Plan B)

    /// Set the window the next `show(...)` will be tiling, so the floating
    /// chip can name it. Prefer the running app's localized name + real
    /// icon; fall back to the CG owner name passed by the caller (the
    /// `pid → NSRunningApplication` lookup can briefly return nil right
    /// after launch). Call on the main thread before `show(...)`.
    func setTarget(pid: pid_t, appName: String) {
        let running = NSRunningApplication(processIdentifier: pid)
        let resolved = running?.localizedName ?? appName
        targetAppName = resolved.isEmpty ? appName : resolved
        targetAppIcon = running?.icon
    }

    /// Anchor the chip to the visible bento panel's top-center and show it.
    /// No target name → hide it (defensive; the tile path always sets one).
    private func positionTargetChip(panelFrame: NSRect) {
        guard let name = targetAppName, !name.isEmpty else {
            targetChip.hide()
            return
        }
        let center = NSPoint(x: panelFrame.midX, y: panelFrame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.screens.first
        guard let screen else {
            targetChip.hide()
            return
        }
        targetChip.show(icon: targetAppIcon, name: name, anchoredAbove: panelFrame, on: screen)
    }

    // MARK: - Lifecycle

    /// Show centered at the given CGEvent screen point (top-left origin,
    /// y-down). Picks single- or multi-display layout based on the toggle
    /// and the number of connected displays.
    func show(atCGPoint cgScreenPoint: CGPoint) {
        let useMulti = multiDisplayEnabled && NSScreen.screens.count >= 2
        if useMulti {
            showMultiDisplay(atCGPoint: cgScreenPoint)
        } else {
            showSingleDisplay(atCGPoint: cgScreenPoint)
        }
    }

    private func showSingleDisplay(atCGPoint cgScreenPoint: CGPoint) {
        guard let primary = NSScreen.screens.first else { return }
        let nsY = primary.frame.height - cgScreenPoint.y
        let clickNS = NSPoint(x: cgScreenPoint.x, y: nsY)
        let currentScreen = NSScreen.screens.first(where: { $0.frame.contains(clickNS) }) ?? primary

        let idealFrame = NSRect(
            x: cgScreenPoint.x - Self.panelWidth / 2,
            y: nsY - Self.panelHeight / 2,
            width: Self.panelWidth,
            height: Self.panelHeight
        )

        // Edge-safe (default): clamp on-screen + warp the cursor to the center.
        // Off: center on the cursor, no clamping, no warp (the original path).
        let windowFrame: NSRect
        let layoutOrigin: NSPoint
        let displayOffset: NSPoint
        if edgeSafeEnabled {
            let placement = Self.placePanel(idealFrame: idealFrame, visibleFrame: currentScreen.visibleFrame)
            windowFrame = placement.windowFrame
            layoutOrigin = placement.layoutOrigin
            displayOffset = placement.displayOffset
        } else {
            windowFrame = idealFrame
            layoutOrigin = idealFrame.origin
            displayOffset = .zero
        }
        // Direction is measured from the panel's actual center. Un-clamped, that
        // equals the click point (where the un-warped cursor sits), so the OFF
        // path stays geometrically correct.
        let cancelCenter = NSPoint(x: windowFrame.midX, y: windowFrame.midY)
        gestureOriginNS = cancelCenter
        layoutOriginNS = layoutOrigin
        setFrame(windowFrame, display: true)
        fillView.displayLayout = nil
        fillView.currentScreen = nil
        fillView.activeScreen = nil
        fillView.activeZone = nil
        fillView.displayOffset = displayOffset
        fillView.needsDisplay = true
        if !isVisible {
            orderFrontRegardless()
        }
        if edgeSafeEnabled {
            cursorTransition.move(from: clickNS, to: cancelCenter)
        }
        positionTargetChip(panelFrame: windowFrame)
    }

    private func showMultiDisplay(atCGPoint cgScreenPoint: CGPoint) {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return }
        let nsY = primary.frame.height - cgScreenPoint.y
        let clickNS = NSPoint(x: cgScreenPoint.x, y: nsY)
        let currentScreen = screens.first(where: { $0.frame.contains(clickNS) }) ?? primary

        let result = Self.computeMultiDisplayLayout(
            screens: screens,
            currentScreen: currentScreen
        )

        // Anchor: current card's center aligned to the click point.
        let anchorCenter: NSPoint = result.cards.first(where: { $0.isCurrent })
            .map { NSPoint(x: $0.cardRect.midX, y: $0.cardRect.midY) }
            ?? NSPoint(x: result.panelSize.width / 2, y: result.panelSize.height / 2)

        // The IDEAL panel rect: what we'd show if there were no screen
        // boundaries. The current card's center lands exactly on the
        // click point in this rect.
        let idealFrame = NSRect(
            x: cgScreenPoint.x - anchorCenter.x,
            y: nsY - anchorCenter.y,
            width: result.panelSize.width,
            height: result.panelSize.height
        )

        // Edge-safe (default): clamp the whole panel on-screen + warp the
        // cursor to the current card's center. Off: the original path — clip
        // the window to the current display so it never straddles two displays
        // (cards keep their ideal positions; the view bounds clip the
        // off-display ones), with no clamping and no cursor warp.
        let windowFrame: NSRect
        let layoutOrigin: NSPoint
        let displayOffset: NSPoint
        if edgeSafeEnabled {
            let placement = Self.placePanel(idealFrame: idealFrame, visibleFrame: currentScreen.visibleFrame)
            windowFrame = placement.windowFrame
            layoutOrigin = placement.layoutOrigin
            displayOffset = placement.displayOffset
        } else {
            let clipped = idealFrame.intersection(currentScreen.visibleFrame)
            windowFrame = clipped.isEmpty ? idealFrame : clipped
            layoutOrigin = idealFrame.origin
            displayOffset = NSPoint(
                x: windowFrame.minX - idealFrame.minX,
                y: windowFrame.minY - idealFrame.minY
            )
        }
        let cancelCenter = NSPoint(
            x: layoutOrigin.x + anchorCenter.x,
            y: layoutOrigin.y + anchorCenter.y
        )
        gestureOriginNS = cancelCenter
        layoutOriginNS = layoutOrigin
        setFrame(windowFrame, display: true)
        fillView.displayLayout = result.cards
        fillView.currentScreen = currentScreen
        fillView.activeScreen = nil
        fillView.activeZone = nil
        fillView.displayOffset = displayOffset
        fillView.needsDisplay = true
        if !isVisible {
            orderFrontRegardless()
        }
        if edgeSafeEnabled {
            cursorTransition.move(from: clickNS, to: cancelCenter)
        }
        positionTargetChip(panelFrame: windowFrame)
    }

    func hide() {
        if isVisible {
            orderOut(nil)
        }
        targetChip.hide()
        cursorTransition.finishImmediately()
        gestureOriginNS = nil
        layoutOriginNS = nil
        // Drop the target so a stray show() without a fresh setTarget(...)
        // can't surface the previous gesture's app name/icon.
        targetAppName = nil
        targetAppIcon = nil
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Edge-safe placement

    private static func placePanel(idealFrame: NSRect, visibleFrame: NSRect) -> PanelPlacement {
        let insetVisible = visibleFrame.insetBy(dx: screenInset, dy: screenInset)
        let available = insetVisible.width > 0 && insetVisible.height > 0
            ? insetVisible
            : visibleFrame

        let x = placeAxis(idealMin: idealFrame.minX, size: idealFrame.width,
                          availableMin: available.minX, availableMax: available.maxX)
        let y = placeAxis(idealMin: idealFrame.minY, size: idealFrame.height,
                          availableMin: available.minY, availableMax: available.maxY)

        return PanelPlacement(
            windowFrame: NSRect(x: x.windowMin, y: y.windowMin,
                                width: x.windowSize, height: y.windowSize),
            layoutOrigin: NSPoint(x: x.layoutMin, y: y.layoutMin),
            displayOffset: NSPoint(x: x.windowMin - x.layoutMin,
                                   y: y.windowMin - y.layoutMin)
        )
    }

    private static func placeAxis(
        idealMin: CGFloat,
        size: CGFloat,
        availableMin: CGFloat,
        availableMax: CGFloat
    ) -> (windowMin: CGFloat, windowSize: CGFloat, layoutMin: CGFloat) {
        let availableSize = availableMax - availableMin
        if size <= availableSize {
            let placedMin = max(availableMin, min(idealMin, availableMax - size))
            return (placedMin, size, placedMin)
        }

        let idealMax = idealMin + size
        let clippedMin = max(idealMin, availableMin)
        let clippedMax = min(idealMax, availableMax)
        guard clippedMax > clippedMin else {
            return (availableMin, availableSize, idealMin)
        }
        return (clippedMin, clippedMax - clippedMin, idealMin)
    }

    // MARK: - Layout computation (multi-display)

    private static func computeMultiDisplayLayout(
        screens: [NSScreen],
        currentScreen: NSScreen
    ) -> (panelSize: CGSize, cards: [DisplayCard]) {
        // Each card matches the original single-display bento size exactly,
        // so the user sees identical chrome / cell / preview / cancel-ring
        // rendering inside each card. Multi-display becomes "lay N of those
        // cards out in a grid that mirrors the macOS arrangement."
        let cardW = panelWidth
        let cardH = panelHeight
        let gap = multiCardGap
        let pad = chromePadding

        // Group screens into columns by the x-center of their NS frames.
        // Screens whose centers are within `tolX` of a previous column join
        // it; otherwise they start a new one. Same for rows within each
        // column. Tolerance is generous (half the average display width/
        // height) so a slight vertical offset between two physical
        // monitors still reads as "same row" — matching how users mentally
        // arrange them.
        let avgW = screens.map(\.frame.width).reduce(0, +) / CGFloat(screens.count)
        let avgH = screens.map(\.frame.height).reduce(0, +) / CGFloat(screens.count)
        let tolX = avgW * 0.5
        let tolY = avgH * 0.5

        // Sort by x-center, group into columns.
        let byX = screens.sorted { $0.frame.midX < $1.frame.midX }
        var columns: [[NSScreen]] = []
        for screen in byX {
            if var lastCol = columns.last,
               let pivot = lastCol.first,
               abs(screen.frame.midX - pivot.frame.midX) <= tolX {
                lastCol.append(screen)
                columns[columns.count - 1] = lastCol
            } else {
                columns.append([screen])
            }
        }
        // Within each column, sort by y-center descending (high NS y is
        // visually higher in the panel, since the view is non-flipped).
        // Group rows by tolY so vertically close screens align.
        for c in columns.indices {
            columns[c].sort { $0.frame.midY > $1.frame.midY }
        }

        // For simplicity in this v1, use a uniform N×M grid where N =
        // column count and M = max rows-in-any-column. Each cell holds one
        // screen; empty cells are blank gaps in the panel.
        let nCols = columns.count
        let nRows = columns.map(\.count).max() ?? 0

        // Each "slot" is one card plus the label area BELOW the card.
        // Slot height grows the panel so the label has room without
        // crowding the card or the next row.
        let labelAreaH = cardLabelAreaHeight
        let slotH = cardH + labelAreaH

        let panelW = pad * 2 + CGFloat(nCols) * cardW + CGFloat(max(0, nCols - 1)) * gap
        let panelH = pad * 2 + CGFloat(nRows) * slotH + CGFloat(max(0, nRows - 1)) * gap

        var cards: [DisplayCard] = []
        for (col, columnScreens) in columns.enumerated() {
            for (rowFromTop, screen) in columnScreens.enumerated() {
                let x = pad + CGFloat(col) * (cardW + gap)
                // Slot top y (non-flipped: y=0 at bottom, row 0 is the
                // visual TOP). Card sits at the top of its slot; label
                // occupies the area below.
                let slotTopY = panelH - pad - CGFloat(rowFromTop) * (slotH + gap)
                let cardY = slotTopY - cardH
                cards.append(DisplayCard(
                    screen: screen,
                    cardRect: NSRect(x: x, y: cardY, width: cardW, height: cardH),
                    isCurrent: screen == currentScreen,
                    label: screen.localizedName
                ))
            }
        }
        // Suppress "unused" warnings (kept for future row-clustering work).
        _ = tolY
        return (CGSize(width: panelW, height: panelH), cards)
    }

    // MARK: - Resolution / highlighting

    /// Resolve the cursor position (CG screen coords, y-down) to a
    /// (display, zone) hit. Returns nil for cancel (center cell of any
    /// display) and for "outside any display" (multi-display) or "off all
    /// screens" (single-display).
    func resolve(cursorAtCGPoint cgPoint: CGPoint) -> (screen: NSScreen, zone: TileZone)? {
        guard let primary = NSScreen.screens.first else { return nil }
        let nsY = primary.frame.height - cgPoint.y
        let cursorNS = NSPoint(x: cgPoint.x, y: nsY)
        if cursorTransition.shouldSuppressMotion(at: cursorNS) {
            return nil
        }

        if let layout = fillView.displayLayout {
            // Multi-display: hit-test in the IDEAL panel coord space so
            // a cursor over a card cell that's been clipped off-window
            // (e.g. dragged past the visible bento edge into where the
            // ideal layout would still have a cell) still resolves
            // correctly. The window's frame is a clipped subset of the
            // ideal — cardRects are stored in ideal panel-local coords,
            // and so is `cursorLocal` here.
            let originNS = layoutOriginNS ?? self.frame.origin
            let local = NSPoint(
                x: cursorNS.x - originNS.x,
                y: cursorNS.y - originNS.y
            )
            return Self.resolveMultiDisplay(cursorLocal: local, layout: layout)
        } else {
            return resolveSingleDisplay(cursorNS: cursorNS)
        }
    }

    private static func resolveMultiDisplay(
        cursorLocal: NSPoint,
        layout: [DisplayCard]
    ) -> (screen: NSScreen, zone: TileZone)? {
        for card in layout where card.cardRect.contains(cursorLocal) {
            let localInCard = NSPoint(
                x: cursorLocal.x - card.cardRect.minX,
                y: cursorLocal.y - card.cardRect.minY
            )
            let col = max(0, min(2, Int(localInCard.x / (card.cardRect.width / 3))))
            // Row 0 = visual top = HIGH local y (view is non-flipped).
            let rowFromBottom = max(0, min(2, Int(localInCard.y / (card.cardRect.height / 3))))
            let row = 2 - rowFromBottom
            let zoneMatrix: [[TileZone?]] = [
                [.topLeft,    .full,      .topRight],
                [.left,       nil,        .right],
                [.bottomLeft, .centered,  .bottomRight],
            ]
            if let zone = zoneMatrix[row][col] {
                return (card.screen, zone)
            } else {
                return nil  // center cell -> cancel
            }
        }
        return nil  // outside every card
    }

    private func resolveSingleDisplay(
        cursorNS: NSPoint
    ) -> (screen: NSScreen, zone: TileZone)? {
        // Single-display: the cells extend to infinity, so resolve from
        // the panel-relative offset and look up which screen the cursor
        // is currently on (since the tile target follows the cursor's
        // display, not a specific panel-local one).
        let origin = gestureOriginNS ?? NSPoint(x: frame.midX, y: frame.midY)
        let dx = cursorNS.x - origin.x
        let dy = origin.y - cursorNS.y  // flip to y-down for the existing math
        let zone = TileZone.bentoZone(
            forDx: dx, dy: dy,
            halfDeadzoneWidth: Self.halfDeadzoneWidth,
            halfDeadzoneHeight: Self.halfDeadzoneHeight
        )
        guard let zone = zone else { return nil }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(cursorNS) })
            ?? NSScreen.screens.first
        guard let screen else { return nil }
        return (screen, zone)
    }

    /// Highlight the resolved hit. Pass nil to clear (cursor in cancel
    /// cell or outside any zone). Cheap to call every drag event — only
    /// triggers a redraw when the visible state changes.
    func setActive(_ hit: (screen: NSScreen, zone: TileZone)?) {
        let newScreen = hit?.screen
        let newZone = hit?.zone
        guard newScreen != fillView.activeScreen || newZone != fillView.activeZone else { return }
        fillView.activeScreen = newScreen
        fillView.activeZone = newZone
        fillView.needsDisplay = true
    }
}

/// `NSVisualEffectView` does not reliably clip its WindowServer backdrop when
/// it is the window's root content view. Hosted inside a transparent root, an
/// explicit alpha mask keeps all four corners genuinely transparent.
private final class BentoPopoverEffectView: NSVisualEffectView {
    override func layout() {
        super.layout()
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        maskImage = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            return true
        }
    }
}

// MARK: - DisplayCard

/// One display's rendered position inside the multi-display panel.
/// `cardRect` is in the view's local coords (non-flipped, bottom-left
/// origin), matching what the view's draw routines expect.
struct DisplayCard {
    let screen: NSScreen
    let cardRect: NSRect
    let isCurrent: Bool
    let label: String
}

// MARK: - Fill View

private final class TileCancelDotView: NSView {

    var activeZone: TileZone? = nil
    var activeScreen: NSScreen? = nil
    /// nil → single-display path: render one card filling the whole
    /// panel, with no per-card chrome (no border, no label).
    /// Non-nil → multi-display: render one card per layout entry, each
    /// at the original single-display size (`panelWidth × panelHeight`)
    /// with the home display marked by an accent border.
    var displayLayout: [DisplayCard]? = nil
    var currentScreen: NSScreen? = nil
    /// Multi-display only: how much of the IDEAL panel was clipped off
    /// the bottom-left when the window's frame was intersected with the
    /// current display's visibleFrame. Card positions in `displayLayout`
    /// are stored in ideal panel-local coords; drawing translates by
    /// `-displayOffset` so view-local (0,0) corresponds to ideal
    /// panel-local `displayOffset`. Cards whose translated rect falls
    /// outside the view's bounds are naturally clipped — that's how the
    /// off-current-display cards "disappear" instead of pushing the
    /// whole panel onto another screen.
    var displayOffset: NSPoint = .zero

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor

        // Panel border. Drawn here (not on the host layer) so it resolves
        // the dynamic color against the current effective appearance each
        // redraw — switching system theme mid-life works without extra
        // KVO/observer plumbing.
        let borderRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let borderPath = NSBezierPath(roundedRect: borderRect, xRadius: 13.5, yRadius: 13.5)
        Self.panelBorderColor.setStroke()
        borderPath.lineWidth = 1
        borderPath.stroke()

        drawSpecularHighlight()

        if let layout = displayLayout {
            for card in layout {
                // Translate from ideal panel-local to view-local.
                let viewRect = card.cardRect.offsetBy(dx: -displayOffset.x, dy: -displayOffset.y)
                drawBentoCard(in: viewRect,
                              screen: card.screen,
                              isCurrent: card.isCurrent,
                              label: card.label,
                              accent: accent)
            }
        } else {
            // Single-display: one card fills the whole panel. No accent
            // border (the panel chrome is the only chrome), no label.
            drawBentoCard(in: bounds,
                          screen: nil,
                          isCurrent: false,
                          label: nil,
                          accent: accent)
        }
    }

    // MARK: - The unit "draw one bento card" routine
    //
    // Single-display and multi-display both go through this. Same
    // chromePadding, tileGap, tile dimensions, tile colors, cancel-ring
    // sizes, and mini-preview math. To tweak the look, tweak it here
    // once.

    private func drawBentoCard(in rect: NSRect,
                               screen cardScreen: NSScreen?,
                               isCurrent: Bool,
                               label: String?,
                               accent: NSColor) {
        let pad = TileCancelDot.chromePadding
        let gap = TileCancelDot.tileGap
        let inner = rect.insetBy(dx: pad, dy: pad)
        let tileW = TileCancelDot.tileWidth
        let tileH = TileCancelDot.tileHeight

        let zoneAt: [[TileZone?]] = [
            [.topLeft,    .full,      .topRight],
            [.left,       nil,        .right],
            [.bottomLeft, .centered,  .bottomRight],
        ]

        for row in 0..<3 {
            for col in 0..<3 {
                let zone = zoneAt[row][col]
                let x = inner.minX + CGFloat(col) * (tileW + gap)
                let y = inner.maxY - CGFloat(row + 1) * tileH - CGFloat(row) * gap
                let cellRect = NSRect(x: x, y: y, width: tileW, height: tileH)
                let isActive: Bool = {
                    guard zone == activeZone else { return false }
                    // Single-display (cardScreen == nil) doesn't check
                    // screen — there's only one notional card. Multi-
                    // display restricts highlighting to the card whose
                    // screen matches the resolved hit.
                    guard let cardScreen else { return true }
                    return cardScreen == activeScreen
                }()
                drawTile(in: cellRect, zone: zone, isActive: isActive, accent: accent)
            }
        }

        // Home-display accent border. Drawn AFTER the cells so it sits
        // on top of any tile that brushes the card edge.
        if isCurrent {
            let borderPath = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                          xRadius: 10, yRadius: 10)
            accent.withAlphaComponent(0.85).setStroke()
            borderPath.lineWidth = 1.5
            borderPath.stroke()
        }

        if let label {
            drawCardLabel(rect: rect, text: label, isCurrent: isCurrent)
        }
    }

    private func drawCardLabel(rect: NSRect, text: String, isCurrent: Bool) {
        let maxChars = max(6, Int(rect.width / 7))
        let displayName: String = {
            if text.count <= maxChars { return text }
            let i = text.index(text.startIndex, offsetBy: maxChars - 1)
            return text[..<i] + "…"
        }()

        let labelColor: NSColor = isCurrent
            ? NSColor.controlAccentColor
            : Self.cardLabelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: labelColor,
            .kern: 0.8,
        ]
        let s = NSAttributedString(string: displayName.uppercased(), attributes: attrs)
        let size = s.size()
        // Sits BELOW the card, horizontally centered, with the same top
        // margin used by the layout's slot calculation.
        let origin = NSPoint(
            x: rect.midX - size.width / 2,
            y: rect.minY - TileCancelDot.cardLabelTopMargin - size.height
        )
        s.draw(at: origin)
    }

    // MARK: - Specular highlight

    private func drawSpecularHighlight() {
        // Subtle "glass top edge" — kept as a constant white-alpha so it
        // reads as a brightness flash regardless of mode (in light mode
        // it's near-invisible against the lighter panel surface, which is
        // intentional — the .popover material already has its own subtle
        // top brightness).
        let panel = bounds
        let highlight = NSBezierPath()
        highlight.move(to: NSPoint(x: panel.minX + 16, y: panel.maxY - 0.5))
        highlight.line(to: NSPoint(x: panel.maxX - 16, y: panel.maxY - 0.5))
        NSColor.white.withAlphaComponent(0.12).setStroke()
        highlight.lineWidth = 1
        highlight.stroke()
    }

    // MARK: - Tile drawing (shared)

    private func drawTile(in rect: NSRect,
                          zone: TileZone?,
                          isActive: Bool,
                          accent: NSColor) {
        if zone == nil {
            drawCancelCell(in: rect, isActive: isActive)
            return
        }

        let tilePath = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        if isActive {
            accent.withAlphaComponent(0.42).setFill()
            tilePath.fill()
            accent.withAlphaComponent(0.95).setStroke()
            tilePath.lineWidth = 1.2
            tilePath.stroke()
        } else {
            Self.tileBgColor.setFill()
            tilePath.fill()
            Self.tileBorderColor.setStroke()
            tilePath.lineWidth = 1
            tilePath.stroke()
        }

        if let zone = zone {
            drawMiniPreview(in: rect, zone: zone, isActive: isActive)
        }
    }

    private func drawCancelCell(in rect: NSRect, isActive: Bool) {
        let ringDiameter: CGFloat = isActive ? 22 : 18
        let ringRect = NSRect(
            x: rect.midX - ringDiameter / 2,
            y: rect.midY - ringDiameter / 2,
            width: ringDiameter,
            height: ringDiameter
        )
        let ringPath = NSBezierPath(ovalIn: ringRect)
        if isActive {
            Self.cancelRingActiveFill.setFill()
            ringPath.fill()
            Self.cancelRingActiveStroke.setStroke()
            ringPath.lineWidth = 1.8
            ringPath.stroke()
            let dotR: CGFloat = 3.5
            let dotRect = NSRect(
                x: rect.midX - dotR,
                y: rect.midY - dotR,
                width: dotR * 2, height: dotR * 2
            )
            Self.cancelRingActiveDot.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        } else {
            Self.cancelRingIdleStroke.setStroke()
            ringPath.lineWidth = 1.4
            ringPath.stroke()
        }
    }

    private func drawMiniPreview(in tile: NSRect, zone: TileZone, isActive: Bool) {
        let innerPad: CGFloat = 5
        let mini = tile.insetBy(dx: innerPad, dy: innerPad)
        let g: CGFloat = 1.5

        let preview: NSRect
        switch zone {
        case .full:
            preview = mini
        case .centered:
            let insetX = mini.width  * 0.075
            let insetY = mini.height * 0.075
            preview = mini.insetBy(dx: insetX, dy: insetY)
        case .left:
            preview = NSRect(x: mini.minX, y: mini.minY,
                             width: mini.width / 2 - g, height: mini.height)
        case .right:
            preview = NSRect(x: mini.midX + g, y: mini.minY,
                             width: mini.width / 2 - g, height: mini.height)
        case .topLeft:
            preview = NSRect(x: mini.minX, y: mini.midY + g,
                             width: mini.width / 2 - g, height: mini.height / 2 - g)
        case .topRight:
            preview = NSRect(x: mini.midX + g, y: mini.midY + g,
                             width: mini.width / 2 - g, height: mini.height / 2 - g)
        case .bottomLeft:
            preview = NSRect(x: mini.minX, y: mini.minY,
                             width: mini.width / 2 - g, height: mini.height / 2 - g)
        case .bottomRight:
            preview = NSRect(x: mini.midX + g, y: mini.minY,
                             width: mini.width / 2 - g, height: mini.height / 2 - g)
        }

        let fg: NSColor = isActive
            ? .white
            : Self.miniPreviewIdleFill
        fg.setFill()
        NSBezierPath(roundedRect: preview, xRadius: 1.5, yRadius: 1.5).fill()
    }

    // MARK: - Dynamic colors (adapt to light / dark mode)

    private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        return NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
            switch match {
            case .darkAqua, .vibrantDark: return dark
            default: return light
            }
        }
    }

    private static let panelBorderColor = dynamic(
        dark:  NSColor.white.withAlphaComponent(0.18),
        light: NSColor.black.withAlphaComponent(0.18)
    )
    private static let tileBgColor = dynamic(
        dark:  NSColor.white.withAlphaComponent(0.10),
        light: NSColor.black.withAlphaComponent(0.06)
    )
    private static let tileBorderColor = dynamic(
        dark:  NSColor.white.withAlphaComponent(0.14),
        light: NSColor.black.withAlphaComponent(0.10)
    )
    private static let cancelRingIdleStroke = dynamic(
        dark:  NSColor.white.withAlphaComponent(0.42),
        light: NSColor.black.withAlphaComponent(0.42)
    )
    private static let cancelRingActiveFill = dynamic(
        dark:  NSColor.white.withAlphaComponent(0.20),
        light: NSColor.black.withAlphaComponent(0.14)
    )
    private static let cancelRingActiveStroke = dynamic(
        dark:  NSColor.white.withAlphaComponent(0.95),
        light: NSColor.black.withAlphaComponent(0.85)
    )
    private static let cancelRingActiveDot = dynamic(
        dark:  NSColor.white,
        light: NSColor.black.withAlphaComponent(0.95)
    )
    private static let miniPreviewIdleFill = dynamic(
        dark:  NSColor.white.withAlphaComponent(0.70),
        light: NSColor.black.withAlphaComponent(0.62)
    )
    private static let cardLabelColor = dynamic(
        dark:  NSColor.white.withAlphaComponent(0.55),
        light: NSColor.black.withAlphaComponent(0.55)
    )
}
