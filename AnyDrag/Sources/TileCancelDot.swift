import AppKit

// MARK: - Overlay appearance options
//
// The frameless look blends into neighbouring windows on purpose, which is
// great over a wallpaper and can be too subtle over another app's window.
// These three knobs (Settings → Middle-click action) let the user push the
// overlay forward again without giving up the frosted glass.

/// Which frosted-glass material the overlay's cards + chip are made of. Named
/// by how it LOOKS rather than by the AppKit constant, because that's what the
/// user is picking.
enum BentoMaterial: String, CaseIterable {
    /// `.popover` — what a system popover is made of. Adapts light/dark, and
    /// therefore looks the most like every other window.
    case popover
    /// `.menu` — a shade more solid than a popover.
    case menu
    /// `.toolTip` — brighter/more solid again in light mode.
    case toolTip
    /// `.hudWindow` — the volume-OSD look: dark in BOTH appearances, so it
    /// stands out hardest over light windows.
    case hud
    /// `.fullScreenUI` — dark like the HUD but more see-through.
    case fullScreenUI
    /// `.underWindowBackground` — very heavy blur, tends dark.
    case heavyBlur
    /// `.sidebar` — the most see-through; picks up the desktop's colour.
    case sidebar

    var nsMaterial: NSVisualEffectView.Material {
        switch self {
        case .popover:      return .popover
        case .menu:         return .menu
        case .toolTip:      return .toolTip
        case .hud:          return .hudWindow
        case .fullScreenUI: return .fullScreenUI
        case .heavyBlur:    return .underWindowBackground
        case .sidebar:      return .sidebar
        }
    }

    var displayName: String {
        switch self {
        case .popover:      return NSLocalizedString("bentoMaterial.popover", comment: "")
        case .menu:         return NSLocalizedString("bentoMaterial.menu", comment: "")
        case .toolTip:      return NSLocalizedString("bentoMaterial.toolTip", comment: "")
        case .hud:          return NSLocalizedString("bentoMaterial.hud", comment: "")
        case .fullScreenUI: return NSLocalizedString("bentoMaterial.fullScreenUI", comment: "")
        case .heavyBlur:    return NSLocalizedString("bentoMaterial.heavyBlur", comment: "")
        case .sidebar:      return NSLocalizedString("bentoMaterial.sidebar", comment: "")
        }
    }
}

/// A thin wash painted over the glass. Low alpha on purpose: enough to lift
/// the overlay off the window behind it, not enough to stop being glass.
enum BentoTint: String, CaseIterable {
    case none
    /// Just darker (light mode) / lighter (dark mode) than the surroundings.
    case neutral
    /// The system accent colour.
    case accent
    /// AnyDrag's own orange — separates from the accent-blue active tile.
    case brand

    /// nil → paint nothing.
    var color: NSColor? {
        switch self {
        case .none:    return nil
        case .neutral: return bentoDynamicColor(
            dark:  NSColor.white.withAlphaComponent(0.06),
            light: NSColor.black.withAlphaComponent(0.07)
        )
        case .accent:  return NSColor.controlAccentColor.withAlphaComponent(0.08)
        case .brand:   return NSColor.systemOrange.withAlphaComponent(0.08)
        }
    }

    var displayName: String {
        switch self {
        case .none:    return NSLocalizedString("bentoTint.none", comment: "")
        case .neutral: return NSLocalizedString("bentoTint.neutral", comment: "")
        case .accent:  return NSLocalizedString("bentoTint.accent", comment: "")
        case .brand:   return NSLocalizedString("bentoTint.brand", comment: "")
        }
    }
}

/// Resolves `dark`/`light` against whatever appearance is drawing.
func bentoDynamicColor(dark: NSColor, light: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]) {
        case .darkAqua, .vibrantDark: return dark
        default: return light
        }
    }
}

// MARK: - TileCancelDot
//
// Bento-style overlay shown at the middle-button gesture origin while a
// tile-by-direction gesture is in flight. Two modes:
//
//   1. Single-display (the original): one 290×185 glass card with one 3×3
//      grid. Cells extend to infinity outside the card, so the user can
//      fling the cursor and still resolve to a zone.
//
//   2. Multi-display (`multiDisplayEnabled = true` AND ≥2 connected
//      displays): one card per connected display, laid out at the displays'
//      real relative positions. Each card has its own 3×3 grid plus the
//      display's name in its top-left corner. Cells are bounded by the
//      card's rect — cursor outside any card resolves to no zone (release
//      cancels).
//
// Look: "Frameless Islands" (docs/bento-panel-chrome-mockups.html, plan E2).
// There is NO outer container and NO hairline border anywhere — not on the
// panel, not on the cards, not on the tiles. Each display card is its own
// piece of `.popover` glass with its own rounded mask, and the panel window
// is transparent between them, so the window server's shadow follows each
// island's shape. The current display is marked WITHOUT a border: an accent
// dot + accent name in its title row, while the other cards are dimmed to
// `Self.dimmedCardAlpha` so the current one reads as the front-most one.
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

    /// Card size in points. ~16:10 ratio so the tile previews read as
    /// little screens; large enough that each tile is comfortable to hit,
    /// small enough not to swallow the underlying window. In multi-display
    /// this is the size of each card's GRID BOX (the title row sits on top
    /// of it, see `cardTitleAreaHeight`).
    static let panelWidth: CGFloat = 290
    static let panelHeight: CGFloat = 185

    /// Room for the shadow and, when displaced, the popover pointer.
    private static let screenInset: CGFloat = 12

    /// Padding between a card's edge and its grid of tiles.
    static let chromePadding: CGFloat = 12

    /// Gap between adjacent tiles.
    static let tileGap: CGFloat = 5

    /// Tile dimensions. Same values for both paths, so a tile is rendered
    /// at exactly the same scale whether there's one card or N.
    static var tileWidth: CGFloat {
        (panelWidth - chromePadding * 2 - tileGap * 2) / 3
    }
    static var tileHeight: CGFloat {
        (panelHeight - chromePadding * 2 - tileGap * 2) / 3
    }

    /// Half-width of the center deadzone (single-display path), measured
    /// from the card center. Equals half the center cell plus half a gap
    /// so the boundary sits on the visible gap line — "cursor crossing the
    /// gap" matches "cursor commits to the adjacent tile".
    static var halfDeadzoneWidth: CGFloat {
        tileWidth / 2 + tileGap / 2
    }
    static var halfDeadzoneHeight: CGFloat {
        tileHeight / 2 + tileGap / 2
    }

    /// Corner radius of a glass island. Single-display keeps the original
    /// 14; multi-display cards are a touch rounder because they're smaller
    /// relative to the whole overlay.
    fileprivate static let singleCardCornerRadius: CGFloat = 14
    fileprivate static let multiCardCornerRadius: CGFloat = 15

    /// Transparent margin kept around the cards INSIDE the window, so our own
    /// soft shadow has room to fall off instead of being clipped at the
    /// window edge.
    ///
    /// Why we draw the shadow ourselves instead of using `hasShadow`: the
    /// window-server shadow is derived from the window's alpha and is at its
    /// darkest right at the shape boundary. The rounded mask's edge pixels are
    /// partially transparent, so that darkest band shows through them as a
    /// hard ~1pt dark line — a border in everything but name, and worse than
    /// the drawn hairline this redesign removed. A wide, low-opacity shadow of
    /// our own reads as depth without ever forming a line.
    fileprivate static let shadowMargin: CGFloat = 26

    // MARK: - Layout constants (multi-display)

    /// Visual gap between display cards. Wider than the old 8 because the
    /// cards are now separate glass islands with no shared container — the
    /// extra air is what makes them read as "two screens" instead of one
    /// cracked panel.
    static let multiCardGap: CGFloat = 12

    /// The title row lives INSIDE the card, above the grid: a dot plus the
    /// display's name, left-aligned. Single source of truth — the layout
    /// math and `BentoCardContentView` both derive from these.
    fileprivate static let cardTitleTopPad: CGFloat = 10
    fileprivate static let cardTitleHeight: CGFloat = 13
    fileprivate static let cardTitleBottomGap: CGFloat = 2
    fileprivate static let cardTitleAreaHeight: CGFloat =
        cardTitleTopPad + cardTitleHeight + cardTitleBottomGap
    fileprivate static let cardTitleLeftPad: CGFloat = 14
    fileprivate static let cardTitleDotSize: CGFloat = 6
    fileprivate static let cardTitleDotGap: CGFloat = 7

    /// Non-current display cards have their CONTENTS (tiles + title, not the
    /// glass itself) dimmed to this alpha. With no borders left, this plus
    /// the accent dot/name is what marks the current card.
    ///
    /// It has to be the contents and not the whole card view: dimming an
    /// `NSVisualEffectView` with `alphaValue` makes its behind-window
    /// backdrop translucent too, so whatever is on the desktop bleeds
    /// through the glass and the card reads as dirty rather than receded.
    fileprivate static let dimmedContentAlpha: CGFloat = 0.82

    // MARK: - Mode

    /// Set by DragEngine from Preferences before each show. When false
    /// (or when only one display is connected) we use the single-display
    /// path.
    var multiDisplayEnabled: Bool = false

    /// Set by DragEngine from Preferences before each show. When true (default),
    /// the overlay is kept fully on-screen near a screen edge and the real
    /// cursor glides to its center; when false, it centers on the cursor with
    /// no edge clamping and no cursor warp — the original pre-edge-safe
    /// behavior. Single-display direction is then measured from the actual
    /// (un-warped) cursor/panel center, which keeps it geometrically correct.
    var edgeSafeEnabled: Bool = true

    // MARK: - Appearance (set by DragEngine from Preferences before each show)

    /// Stroke a system-coloured hairline around every card and the app chip.
    /// Off by default — the frameless look is the point — but available for
    /// when the overlay sits over another window and blends in too well.
    var borderEnabled: Bool = false

    /// Which frosted-glass material the cards + chip are made of.
    var material: BentoMaterial = .popover

    /// Thin colour wash over the glass, for the same "don't blend in" reason
    /// as `borderEnabled`, without adding a line. Ships as `.accent`.
    var tint: BentoTint = .accent

    /// Origin used by the current layout's hit testing. It differs from the
    /// window origin only when an oversized multi-display layout is clipped.
    private var layoutOriginNS: NSPoint?

    /// The immutable middle-button press point. Single-display direction
    /// selection stays relative to this point even when the panel moves.
    private var gestureOriginNS: NSPoint?

    // MARK: - Layout / highlight state

    /// nil → single-display path (one card filling the window, no title).
    /// Non-nil → one card per entry.
    private var displayLayout: [DisplayCard]?
    /// Multi-display only: how much of the IDEAL layout was clipped off the
    /// bottom-left when the window frame was intersected with the current
    /// display's visibleFrame. Card rects are stored in ideal layout-local
    /// coords; card views are positioned at `cardRect - displayOffset`, so
    /// cards that fall outside the window are naturally clipped instead of
    /// pushing the whole overlay onto another display.
    private var displayOffset: NSPoint = .zero
    /// Size of the content area inside the window (the window is bigger by
    /// `shadowMargin` on every side). Cards are laid out inside it.
    private var contentSizeInWindow: CGSize = .zero
    private var activeScreen: NSScreen?
    private var activeZone: TileZone?

    // MARK: - Subviews

    private let contentContainer = NSView()
    /// One glass island per card. Reused across shows; the pool grows and
    /// shrinks with the number of connected displays.
    private var cardViews: [BentoCardView] = []
    /// The soft shadow behind each card, index-matched to `cardViews`.
    private var shadowViews: [BentoCardShadowView] = []
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
        // Each card draws its own soft shadow (see `shadowMargin`); the
        // system one would put a hard dark line along every card edge.
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        animationBehavior = .none
        hidesOnDeactivate = false
        isMovable = false

        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = NSColor.clear.cgColor
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
        // The chip is a separate panel, so it has to be told the same
        // appearance options — a bordered grid with a border-less pill (or two
        // different materials) would read as a bug.
        targetChip.applyAppearance(material: material, tint: tint, border: borderEnabled)
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
        // Placement works on the CONTENT rect (the card itself); the window is
        // then grown by `shadowMargin` on every side for the shadow.
        let contentFrame: NSRect
        let layoutOrigin: NSPoint
        if edgeSafeEnabled {
            let placement = Self.placePanel(idealFrame: idealFrame, visibleFrame: currentScreen.visibleFrame)
            contentFrame = placement.windowFrame
            layoutOrigin = placement.layoutOrigin
        } else {
            contentFrame = idealFrame
            layoutOrigin = idealFrame.origin
        }
        // Direction is measured from the card's actual center. Un-clamped, that
        // equals the click point (where the un-warped cursor sits), so the OFF
        // path stays geometrically correct.
        let cancelCenter = NSPoint(x: contentFrame.midX, y: contentFrame.midY)
        gestureOriginNS = cancelCenter
        layoutOriginNS = layoutOrigin
        displayLayout = nil
        displayOffset = .zero
        contentSizeInWindow = contentFrame.size
        activeScreen = nil
        activeZone = nil

        setFrame(contentFrame.insetBy(dx: -Self.shadowMargin, dy: -Self.shadowMargin), display: true)
        layOutCardViews()
        if !isVisible {
            orderFrontRegardless()
        }
        if edgeSafeEnabled {
            cursorTransition.move(from: clickNS, to: cancelCenter)
        }
        positionTargetChip(panelFrame: contentFrame)
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

        // Anchor: the current card's GRID center aligned to the click point,
        // so the cursor starts in the center (cancel) cell — the title row
        // sits above the grid and must not shift that.
        let anchorCenter: NSPoint = result.cards.first(where: { $0.isCurrent })
            .map { NSPoint(x: $0.gridRect.midX, y: $0.gridRect.midY) }
            ?? NSPoint(x: result.panelSize.width / 2, y: result.panelSize.height / 2)

        // The IDEAL layout rect: what we'd show if there were no screen
        // boundaries. The current card's grid center lands exactly on the
        // click point in this rect.
        let idealFrame = NSRect(
            x: cgScreenPoint.x - anchorCenter.x,
            y: nsY - anchorCenter.y,
            width: result.panelSize.width,
            height: result.panelSize.height
        )

        // Edge-safe (default): clamp the whole layout on-screen + warp the
        // cursor to the current card's grid center. Off: the original path —
        // clip the window to the current display so it never straddles two
        // displays (cards keep their ideal positions; the window bounds clip
        // the off-display ones), with no clamping and no cursor warp.
        // As in the single-display path, placement works on the CONTENT rect
        // and the window is grown by `shadowMargin` afterwards.
        let contentFrame: NSRect
        let layoutOrigin: NSPoint
        let offset: NSPoint
        if edgeSafeEnabled {
            let placement = Self.placePanel(idealFrame: idealFrame, visibleFrame: currentScreen.visibleFrame)
            contentFrame = placement.windowFrame
            layoutOrigin = placement.layoutOrigin
            offset = placement.displayOffset
        } else {
            let clipped = idealFrame.intersection(currentScreen.visibleFrame)
            contentFrame = clipped.isEmpty ? idealFrame : clipped
            layoutOrigin = idealFrame.origin
            offset = NSPoint(
                x: contentFrame.minX - idealFrame.minX,
                y: contentFrame.minY - idealFrame.minY
            )
        }
        let cancelCenter = NSPoint(
            x: layoutOrigin.x + anchorCenter.x,
            y: layoutOrigin.y + anchorCenter.y
        )
        gestureOriginNS = cancelCenter
        layoutOriginNS = layoutOrigin
        displayLayout = result.cards
        displayOffset = offset
        contentSizeInWindow = contentFrame.size
        activeScreen = nil
        activeZone = nil

        setFrame(contentFrame.insetBy(dx: -Self.shadowMargin, dy: -Self.shadowMargin), display: true)
        layOutCardViews()
        if !isVisible {
            orderFrontRegardless()
        }
        if edgeSafeEnabled {
            cursorTransition.move(from: clickNS, to: cancelCenter)
        }
        positionTargetChip(panelFrame: contentFrame)
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

    // MARK: - Card views

    /// Size the card-view pool to `count`, creating/removing as needed. Each
    /// card is a pair: a shadow view underneath and the glass card on top.
    private func syncCardViewCount(_ count: Int) {
        while cardViews.count < count {
            let shadow = BentoCardShadowView()
            let view = BentoCardView()
            contentContainer.addSubview(shadow)
            contentContainer.addSubview(view, positioned: .above, relativeTo: shadow)
            shadowViews.append(shadow)
            cardViews.append(view)
        }
        while cardViews.count > count {
            cardViews.removeLast().removeFromSuperview()
            shadowViews.removeLast().removeFromSuperview()
        }
    }

    /// Position + configure one glass island per card for the current
    /// layout. Called right after `setFrame` so the views land on the
    /// window's final bounds.
    private func layOutCardViews() {
        let margin = Self.shadowMargin
        let nsMaterial = material.nsMaterial
        let tintOption = tint
        if let layout = displayLayout {
            syncCardViewCount(layout.count)
            for (index, card) in layout.enumerated() {
                let view = cardViews[index]
                // Ideal layout-local → window-local: undo any clipping offset,
                // then shift past the transparent shadow margin.
                view.frame = card.cardRect.offsetBy(
                    dx: -displayOffset.x + margin,
                    dy: -displayOffset.y + margin
                )
                shadowViews[index].frame = view.frame
                shadowViews[index].cornerRadius = Self.multiCardCornerRadius
                view.cornerRadius = Self.multiCardCornerRadius
                view.material = nsMaterial
                view.content.cornerRadius = Self.multiCardCornerRadius
                view.content.tint = tintOption
                view.content.showBorder = borderEnabled
                view.content.alphaValue = card.isCurrent ? 1.0 : Self.dimmedContentAlpha
                view.content.titleAreaHeight = Self.cardTitleAreaHeight
                view.content.label = card.label
                view.content.isCurrent = card.isCurrent
                view.content.activeZone = nil
                view.content.cancelActive = false
                view.content.needsDisplay = true
            }
        } else {
            syncCardViewCount(1)
            let view = cardViews[0]
            view.frame = NSRect(origin: NSPoint(x: margin, y: margin), size: contentSizeInWindow)
            shadowViews[0].frame = view.frame
            shadowViews[0].cornerRadius = Self.singleCardCornerRadius
            view.cornerRadius = Self.singleCardCornerRadius
            view.material = nsMaterial
            view.content.cornerRadius = Self.singleCardCornerRadius
            view.content.tint = tintOption
            view.content.showBorder = borderEnabled
            view.content.alphaValue = 1.0
            view.content.titleAreaHeight = 0
            view.content.label = nil
            view.content.isCurrent = false
            view.content.activeZone = nil
            // Fresh show: the cursor is at the card's center, i.e. the
            // cancel cell is the current selection.
            view.content.cancelActive = true
            view.content.needsDisplay = true
        }
    }

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
        // Each card's grid box matches the single-display card exactly, so
        // the user sees identical cell / preview / cancel-ring rendering
        // inside each one. Multi-display becomes "lay N of those cards out
        // in a grid that mirrors the macOS arrangement", each with its own
        // title row on top.
        let cardW = panelWidth
        let gridH = panelHeight
        let cardH = cardTitleAreaHeight + gridH
        let gap = multiCardGap

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
        // visually higher in the layout, since views are non-flipped).
        for c in columns.indices {
            columns[c].sort { $0.frame.midY > $1.frame.midY }
        }

        // For simplicity in this v1, use a uniform N×M grid where N =
        // column count and M = max rows-in-any-column. Each cell holds one
        // screen; empty cells are blank gaps.
        let nCols = columns.count
        let nRows = columns.map(\.count).max() ?? 0

        // No outer container any more: the layout is exactly the cards plus
        // the gaps between them.
        let panelW = CGFloat(nCols) * cardW + CGFloat(max(0, nCols - 1)) * gap
        let panelH = CGFloat(nRows) * cardH + CGFloat(max(0, nRows - 1)) * gap

        var cards: [DisplayCard] = []
        for (col, columnScreens) in columns.enumerated() {
            for (rowFromTop, screen) in columnScreens.enumerated() {
                let x = CGFloat(col) * (cardW + gap)
                // Card top y (non-flipped: y=0 at bottom, row 0 is the
                // visual TOP). The title row occupies the top of the card,
                // the grid box the rest.
                let cardTopY = panelH - CGFloat(rowFromTop) * (cardH + gap)
                let cardY = cardTopY - cardH
                cards.append(DisplayCard(
                    screen: screen,
                    cardRect: NSRect(x: x, y: cardY, width: cardW, height: cardH),
                    gridRect: NSRect(x: x, y: cardY, width: cardW, height: gridH),
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

        if let layout = displayLayout {
            // Multi-display: hit-test in the IDEAL layout coord space so
            // a cursor over a card cell that's been clipped off-window
            // (e.g. dragged past the visible bento edge into where the
            // ideal layout would still have a cell) still resolves
            // correctly. The window's frame is a clipped subset of the
            // ideal — card rects are stored in ideal layout-local coords,
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
            // Cells are the thirds of the GRID box, not of the whole card:
            // the title row is part of the card's visual rect but not part
            // of the grid. Clamping (rather than rejecting) means the title
            // row belongs to the top row of cells, so there's no dead band
            // inside a card.
            let grid = card.gridRect
            let clampedX = min(max(cursorLocal.x, grid.minX), grid.maxX - 0.001)
            let clampedY = min(max(cursorLocal.y, grid.minY), grid.maxY - 0.001)
            let col = max(0, min(2, Int((clampedX - grid.minX) / (grid.width / 3))))
            // Row 0 = visual top = HIGH local y (views are non-flipped).
            let rowFromBottom = max(0, min(2, Int((clampedY - grid.minY) / (grid.height / 3))))
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
        // the card-relative offset and look up which screen the cursor
        // is currently on (since the tile target follows the cursor's
        // display, not a specific card-local one).
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
        guard newScreen != activeScreen || newZone != activeZone else { return }
        activeScreen = newScreen
        activeZone = newZone

        if let layout = displayLayout {
            // Only the card whose screen matches the hit shows a highlight.
            for (view, card) in zip(cardViews, layout) {
                let zone = card.screen == newScreen ? newZone : nil
                guard view.content.activeZone != zone else { continue }
                view.content.activeZone = zone
                view.content.needsDisplay = true
            }
        } else if let view = cardViews.first {
            view.content.activeZone = newZone
            // No zone → the cursor is back in the deadzone: light the ring.
            view.content.cancelActive = newZone == nil
            view.content.needsDisplay = true
        }
    }
}

// MARK: - DisplayCard

/// One display's rendered position inside the multi-display layout.
/// Both rects are in ideal layout-local coords (non-flipped, bottom-left
/// origin). `cardRect` is the glass island (title row + grid box) and is
/// what decides "is the cursor over this display at all"; `gridRect` is
/// just the 3×3 grid box and is what the cells are derived from.
struct DisplayCard {
    let screen: NSScreen
    let cardRect: NSRect
    let gridRect: NSRect
    let isCurrent: Bool
    let label: String
}

// MARK: - BentoCardShadowView

/// The soft shadow behind one glass island. It has no content of its own —
/// with `shadowPath` set, the layer casts the shadow from that path, so
/// nothing is drawn where the card will sit. Wide radius + low opacity on
/// purpose: the point is a gradual falloff that never forms a line along the
/// card's edge (see `TileCancelDot.shadowMargin`).
private final class BentoCardShadowView: NSView {

    var cornerRadius: CGFloat = 15 {
        didSet {
            guard cornerRadius != oldValue else { return }
            needsLayout = true
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 16
        // Centered: a cursor-anchored overlay has no lighting direction, and
        // an offset shadow would pool on one edge and read as a line again.
        layer?.shadowOffset = .zero
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
    }
}

// MARK: - BentoCardView

/// One glass island: `.popover` vibrancy with a rounded alpha mask, hosting
/// the content view that draws the title row and the 3×3 grid.
///
/// `NSVisualEffectView` does not reliably clip its WindowServer backdrop to
/// a layer corner radius, so the rounding is done with an explicit
/// `maskImage` — that keeps all four corners genuinely transparent, which is
/// also what lets the window's system shadow follow the island's shape.
private final class BentoCardView: NSVisualEffectView {

    let content = BentoCardContentView()

    var cornerRadius: CGFloat = 15 {
        didSet {
            guard cornerRadius != oldValue else { return }
            needsLayout = true
        }
    }

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        content.frame = bounds
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        // Capture the radius in a local so the drawing handler doesn't
        // retain `self` (the image is owned by this view).
        let radius = cornerRadius
        maskImage = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
    }
}

// MARK: - BentoCardContentView

/// Draws one card's contents: the optional title row (dot + display name)
/// and the 3×3 grid of tiles. No borders anywhere — the card's shape comes
/// from the glass mask behind this view, and the only line-ish element is
/// the specular top-edge highlight that makes the glass read as glass.
private final class BentoCardContentView: NSView {

    var activeZone: TileZone?
    /// The center cell has no zone — "no zone" IS the cancel selection — so
    /// it can't be derived from `activeZone` and is passed in explicitly.
    /// Single-display: true whenever no zone is selected (the cursor sits in
    /// the deadzone), which is how the overlay looks the moment it appears.
    /// Multi-display: always false, because a nil hit doesn't say WHICH
    /// card's center the cursor is over.
    var cancelActive: Bool = false
    /// nil → no title row (single-display path).
    var label: String?
    var isCurrent: Bool = false
    /// Height reserved at the TOP of the card for the title row. 0 when
    /// there's no title, in which case the grid fills the whole card.
    var titleAreaHeight: CGFloat = 0
    /// Optional wash over the glass. Stored as the option, not a resolved
    /// colour: every other colour in here is resolved inside `draw`, where
    /// `NSAppearance.current` is this view's, so a light/dark swap needs no
    /// extra plumbing.
    var tint: BentoTint = .none
    /// Optional system hairline around the card (`borderEnabled`).
    var showBorder: Bool = false
    /// The card's corner radius. The tint and the border have to follow the
    /// glass mask's rounding — this view is NOT clipped by that mask, so a
    /// plain `bounds` fill would poke square corners out of the card.
    var cornerRadius: CGFloat = 15

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        if let tintColor = tint.color {
            tintColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }

        let gridRect = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: max(0, bounds.height - titleAreaHeight)
        )
        drawGrid(in: gridRect, accent: NSColor.controlAccentColor)

        if let label, !label.isEmpty {
            drawTitle(label)
        }

        if showBorder {
            // `separatorColor` is the system's own hairline colour, so it
            // tracks light/dark and is a good deal lighter than the
            // hard-coded black hairline this redesign removed.
            let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let radius = max(0, cornerRadius - 0.5)
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    // No specular top-edge highlight. It came from the era of one big panel,
    // where a 590pt-wide white sliver read as glass catching light. Per card
    // it's only 290pt wide with 16pt cut off each end, so it stops before the
    // rounded corners and reads as a stray white line instead. This overlay
    // is meant to have no lines at all; `.popover` already carries its own
    // subtle top brightness.

    // MARK: - Title row

    private func drawTitle(_ text: String) {
        let titleH = TileCancelDot.cardTitleHeight
        let rowY = bounds.maxY - TileCancelDot.cardTitleTopPad - titleH

        let dotSize = TileCancelDot.cardTitleDotSize
        let dotRect = NSRect(
            x: bounds.minX + TileCancelDot.cardTitleLeftPad,
            y: rowY + (titleH - dotSize) / 2,
            width: dotSize,
            height: dotSize
        )
        (isCurrent ? NSColor.controlAccentColor : Self.cardDotIdleColor).setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        let textX = dotRect.maxX + TileCancelDot.cardTitleDotGap
        let textRect = NSRect(
            x: textX,
            y: rowY - 1,
            width: max(0, bounds.maxX - TileCancelDot.chromePadding - textX),
            height: titleH + 2
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: isCurrent ? NSColor.controlAccentColor : Self.cardLabelColor,
            .kern: 0.8,
            .paragraphStyle: paragraph,
        ]
        NSAttributedString(string: text.uppercased(), attributes: attrs).draw(in: textRect)
    }

    // MARK: - Grid
    //
    // Same chromePadding, tileGap, tile dimensions, tile colors, cancel-ring
    // sizes, and mini-preview math for single- and multi-display. To tweak
    // the look, tweak it here once.

    private func drawGrid(in rect: NSRect, accent: NSColor) {
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
                let isActive = zone == nil ? cancelActive : (zone == activeZone)
                drawTile(in: cellRect, zone: zone, isActive: isActive, accent: accent)
            }
        }
    }

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
            // No border: the tile is a plain filled block. (The active
            // tile keeps its accent stroke — that's a highlight, not
            // chrome.)
            Self.tileBgColor.setFill()
            tilePath.fill()
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

    private static let tileBgColor = dynamic(
        dark:  NSColor.white.withAlphaComponent(0.10),
        light: NSColor.black.withAlphaComponent(0.06)
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
    private static let cardDotIdleColor = dynamic(
        dark:  NSColor.white.withAlphaComponent(0.28),
        light: NSColor.black.withAlphaComponent(0.28)
    )
}
