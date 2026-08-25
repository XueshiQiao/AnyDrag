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

// MARK: - Bento hit

/// What the cursor is currently over inside the bento overlay.
///
/// `workspaceIndex` is nil whenever virtual workspaces are off — then a card
/// still means "a display", exactly as it has always meant.
struct BentoHit: Equatable {
    let screen: NSScreen
    let workspaceIndex: Int?
    let zone: TileZone

    /// Two hits address the same CARD when both the display and the workspace
    /// match. Used to decide which card lights up.
    func sameCard(as other: BentoHit) -> Bool {
        screen == other.screen && workspaceIndex == other.workspaceIndex
    }
}

/// One window drawn in a card's overview layer — the "what is already in this
/// workspace" picture.
struct WSOverviewWindow {
    /// Position and size as a fraction of the card's tile area, NS-style
    /// (origin bottom-left).
    let unitRect: NSRect
    let icon: NSImage?
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

    // MARK: - Virtual workspaces
    //
    // All four are supplied by DragEngine before each show. When
    // `workspacesPerDisplay <= 1` the overlay behaves exactly as it shipped —
    // this whole dimension collapses away and the code below takes the same
    // branches it always did.

    /// How many workspaces each display carries. 0 or 1 = feature off.
    var workspacesPerDisplay: Int = 0

    /// Which workspace a display is currently showing.
    var currentWorkspaceIndex: ((NSScreen) -> Int)?

    /// The user's name for a workspace (defaults to its number).
    var workspaceName: ((NSScreen, Int) -> String)?

    /// The windows already in a workspace, for the overview layer.
    ///
    /// **This closure must be a pure memory read.** It is called while the
    /// panel is being built, which happens on middle-button-down — the most
    /// latency-sensitive moment in the app. Enumerating windows here would
    /// make the gesture feel sticky.
    var overviewProvider: ((NSScreen, Int) -> [WSOverviewWindow])?

    /// True when the gesture has no window to move (middle-press on empty
    /// desktop): no tiles are drawn and every card is purely a jump target.
    var switcherOnly: Bool = false

    /// Whether the workspace dimension is live for this show.
    private var workspacesActive: Bool { workspacesPerDisplay > 1 }

    /// How far the jump frame's HIT area reaches beyond the card's drawn
    /// edge. Kept under half the inter-card gap (12) so two cards can never
    /// both claim the same point.
    static let jumpOuterSlop: CGFloat = 5
    /// How far the jump frame's hit area eats INTO the tile area. The drawn
    /// padding ring is only 12pt; at drag speed that is not aimable, so the
    /// judged region is roughly twice the drawn one.
    static let jumpInnerBite: CGFloat = 6

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
    private var activeHit: BentoHit?

    /// Which card the cursor is physically over, independent of whether a
    /// zone resolved. The cancel cell resolves to no zone, but the card is
    /// still the one being pointed at and must keep showing its grid.
    private var hoveredCardIndex: Int?

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
    /// Where the target window currently sits. Feeds the `.moveToDisplay`
    /// cell: without it there is nothing to preview, so that cell falls back
    /// to being the plain cancel ring.
    private var targetSource: TileZone.Source?

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
    /// chip can name it and the other displays' cards can preview where it
    /// would land. Prefer the running app's localized name + real icon; fall
    /// back to the CG owner name passed by the caller (the
    /// `pid → NSRunningApplication` lookup can briefly return nil right
    /// after launch). Call on the main thread before `show(...)`.
    func setTarget(pid: pid_t, appName: String, source: TileZone.Source) {
        let running = NSRunningApplication(processIdentifier: pid)
        let resolved = running?.localizedName ?? appName
        targetAppName = resolved.isEmpty ? appName : resolved
        targetAppIcon = running?.icon
        targetSource = source
    }

    /// Switcher mode: there is no window, so the name chip must not appear.
    func clearTarget() {
        targetAppName = nil
        targetAppIcon = nil
        targetSource = nil
    }

    /// Anchor the chip above `anchorFrame` (NS coords) and show it. No target
    /// name → hide it (defensive; the tile path always sets one).
    private func positionTargetChip(anchorFrame: NSRect, on screen: NSScreen) {
        guard let name = targetAppName, !name.isEmpty else {
            targetChip.hide()
            return
        }
        // The chip is a separate panel, so it has to be told the same
        // appearance options — a bordered grid with a border-less pill (or two
        // different materials) would read as a bug.
        targetChip.applyAppearance(material: material, tint: tint, border: borderEnabled)
        targetChip.show(icon: targetAppIcon, name: name, anchoredAbove: anchorFrame, on: screen)
    }

    /// Where the chip hangs in the multi-display layout: over the CURRENT
    /// display's card, not over the whole layout. Anchoring to the panel put
    /// the pill in the seam between two side-by-side cards, where it reads as
    /// belonging to neither — it names the window being tiled, and that window
    /// lives on the current display.
    ///
    /// Horizontal position comes from the current card alone. Vertical spans
    /// the whole COLUMN that card sits in (every card whose x-range overlaps
    /// it), so with displays stacked one above the other the pill floats above
    /// the top card of the column instead of landing on the card above.
    ///
    /// Returns the rect in screen coords; nil when there's no current card
    /// (can't happen in practice — the caller falls back to the panel).
    private static func chipAnchorRect(cards: [DisplayCard], layoutOrigin: NSPoint) -> NSRect? {
        guard let current = cards.first(where: { $0.isCurrent }) else { return nil }
        let card = current.cardRect
        let column = cards.filter {
            $0.cardRect.minX < card.maxX && $0.cardRect.maxX > card.minX
        }
        let top = column.map(\.cardRect.maxY).max() ?? card.maxY
        let bottom = column.map(\.cardRect.minY).min() ?? card.minY
        return NSRect(
            x: card.minX + layoutOrigin.x,
            y: bottom + layoutOrigin.y,
            width: card.width,
            height: top - bottom
        )
    }

    // MARK: - Lifecycle

    /// Show centered at the given CGEvent screen point (top-left origin,
    /// y-down). Picks single- or multi-display layout based on the toggle
    /// and the number of connected displays.
    func show(atCGPoint cgScreenPoint: CGPoint) {
        // Workspaces force the card layout regardless of display count: the
        // workspace cards and the jump frame only exist there. On one display
        // it degrades to a single column of workspace cards — which is exactly
        // the case where virtual workspaces are worth the most.
        let useMulti = (multiDisplayEnabled && NSScreen.screens.count >= 2) || workspacesActive
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
        activeHit = nil
        hoveredCardIndex = nil

        setFrame(contentFrame.insetBy(dx: -Self.shadowMargin, dy: -Self.shadowMargin), display: true)
        layOutCardViews()
        if !isVisible {
            orderFrontRegardless()
        }
        if edgeSafeEnabled {
            cursorTransition.move(from: clickNS, to: cancelCenter)
        }
        // One card, so the card IS the anchor.
        positionTargetChip(anchorFrame: contentFrame, on: currentScreen)
    }

    private func showMultiDisplay(atCGPoint cgScreenPoint: CGPoint) {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return }
        let nsY = primary.frame.height - cgScreenPoint.y
        let clickNS = NSPoint(x: cgScreenPoint.x, y: nsY)
        let currentScreen = screens.first(where: { $0.frame.contains(clickNS) }) ?? primary

        let result = Self.computeMultiDisplayLayout(
            screens: screens,
            currentScreen: currentScreen,
            source: switcherOnly ? nil : targetSource,
            workspacesPerDisplay: workspacesPerDisplay,
            currentWorkspaceIndex: currentWorkspaceIndex,
            workspaceName: workspaceName,
            overviewProvider: overviewProvider
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
        activeHit = nil
        hoveredCardIndex = nil

        setFrame(contentFrame.insetBy(dx: -Self.shadowMargin, dy: -Self.shadowMargin), display: true)
        layOutCardViews()
        if !isVisible {
            orderFrontRegardless()
        }
        if edgeSafeEnabled {
            cursorTransition.move(from: clickNS, to: cancelCenter)
        }
        positionTargetChip(
            anchorFrame: Self.chipAnchorRect(cards: result.cards, layoutOrigin: layoutOrigin)
                ?? contentFrame,
            on: currentScreen
        )
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
        // can't surface the previous gesture's app name/icon/geometry.
        targetAppName = nil
        targetAppIcon = nil
        targetSource = nil
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
                view.content.centerZone = card.centerZone
                view.content.moveHerePreview = card.moveHerePreview
                view.content.workspaceMode = card.workspaceIndex != nil
                view.content.overview = card.overview
                // The panel opens with the cursor parked on the current card's
                // centre, so that card starts hot — its grid is visible from
                // the first frame.
                view.content.isHot = card.workspaceIndex != nil && card.isCurrent && !switcherOnly
                view.content.isJumping = false
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
            // Single card: its center is the cancel ring, nowhere to move to.
            view.content.centerZone = nil
            view.content.moveHerePreview = nil
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

    /// `source` is the window being tiled. Cards other than the current one
    /// turn their center cell into `.moveToDisplay` and carry a preview of
    /// where the window would land; without a source there is nothing to
    /// preview, so every center cell stays the cancel ring.
    private static func computeMultiDisplayLayout(
        screens: [NSScreen],
        currentScreen: NSScreen,
        source: TileZone.Source?,
        workspacesPerDisplay: Int,
        currentWorkspaceIndex: ((NSScreen) -> Int)?,
        workspaceName: ((NSScreen, Int) -> String)?,
        overviewProvider: ((NSScreen, Int) -> [WSOverviewWindow])?
    ) -> (panelSize: CGSize, cards: [DisplayCard]) {
        // > 1 workspaces per display turns each display's single card into a
        // vertical stack of workspace cards. At 0 or 1 the loops below run
        // exactly once per display and every workspace field stays nil, so
        // the shipped display-only behaviour is bit-for-bit unchanged.
        let wsCount = max(1, workspacesPerDisplay)
        let wsActive = workspacesPerDisplay > 1
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
        let nRows = (columns.map(\.count).max() ?? 0) * wsCount

        // No outer container any more: the layout is exactly the cards plus
        // the gaps between them.
        let panelW = CGFloat(nCols) * cardW + CGFloat(max(0, nCols - 1)) * gap
        let panelH = CGFloat(nRows) * cardH + CGFloat(max(0, nRows - 1)) * gap

        var cards: [DisplayCard] = []
        for (col, columnScreens) in columns.enumerated() {
            var rowFromTop = 0
            for screen in columnScreens {
                let visibleWS = currentWorkspaceIndex?(screen) ?? 0
                for ws in 0..<wsCount {
                    let x = CGFloat(col) * (cardW + gap)
                    // Card top y (non-flipped: y=0 at bottom, row 0 is the
                    // visual TOP). The title row occupies the top of the card,
                    // the grid box the rest.
                    let cardTopY = panelH - CGFloat(rowFromTop) * (cardH + gap)
                    let cardY = cardTopY - cardH
                    // "Current" is a pair once workspaces exist: the cursor's
                    // display AND the workspace that display is showing.
                    let isCurrent = wsActive
                        ? (screen == currentScreen && ws == visibleWS)
                        : (screen == currentScreen)
                    let canMoveHere = !isCurrent && source != nil
                    let label = wsActive
                        ? (workspaceName?(screen, ws) ?? Workspace.displayName(index: ws))
                        : screen.localizedName
                    cards.append(DisplayCard(
                        screen: screen,
                        cardRect: NSRect(x: x, y: cardY, width: cardW, height: cardH),
                        gridRect: NSRect(x: x, y: cardY, width: cardW, height: gridH),
                        isCurrent: isCurrent,
                        label: label,
                        workspaceIndex: wsActive ? ws : nil,
                        overview: wsActive ? (overviewProvider?(screen, ws) ?? []) : [],
                        centerZone: canMoveHere ? .moveToDisplay : nil,
                        moveHerePreview: canMoveHere
                            ? moveHereUnitRect(source: source!, on: screen)
                            : nil
                    ))
                    rowFromTop += 1
                }
            }
        }
        // Suppress "unused" warnings (kept for future row-clustering work).
        _ = tolY
        return (CGSize(width: panelW, height: panelH), cards)
    }

    /// The window's landing rect on `screen`, expressed as a fraction of that
    /// screen's visible frame, so a card can draw it at card scale. Goes
    /// through `TileZone.sameSpotRect` — the same call the commit makes — so
    /// the little block in the cell can't promise a spot the move won't honour.
    private static func moveHereUnitRect(source: TileZone.Source, on screen: NSScreen) -> NSRect? {
        let visible = screen.visibleFrame
        guard visible.width > 0, visible.height > 0 else { return nil }
        let landing = TileZone.sameSpotRect(source, in: visible)
        return NSRect(
            x: (landing.minX - visible.minX) / visible.width,
            y: (landing.minY - visible.minY) / visible.height,
            width: landing.width / visible.width,
            height: landing.height / visible.height
        )
    }

    // MARK: - Resolution / highlighting

    /// Resolve the cursor position (CG screen coords, y-down) to a
    /// (display, zone) hit. Returns nil for cancel (center cell of any
    /// display) and for "outside any display" (multi-display) or "off all
    /// screens" (single-display).
    func resolve(cursorAtCGPoint cgPoint: CGPoint) -> BentoHit? {
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
            hoveredCardIndex = Self.cardIndex(at: local, layout: layout)
            return Self.resolveMultiDisplay(cursorLocal: local, layout: layout,
                                            switcherOnly: switcherOnly)
        } else {
            return resolveSingleDisplay(cursorNS: cursorNS)
        }
    }

    /// Index of the card containing `cursorLocal`, or nil.
    private static func cardIndex(at cursorLocal: NSPoint, layout: [DisplayCard]) -> Int? {
        layout.firstIndex {
            $0.cardRect.insetBy(dx: -jumpOuterSlop, dy: -jumpOuterSlop).contains(cursorLocal)
        }
    }

    private static func resolveMultiDisplay(
        cursorLocal: NSPoint,
        layout: [DisplayCard],
        switcherOnly: Bool
    ) -> BentoHit? {
        // The jump frame reaches slightly outside the card, so test the
        // grown rect. The slop is under half the inter-card gap, so no two
        // grown rects can overlap and claim the same point.
        for card in layout
        where card.cardRect.insetBy(dx: -jumpOuterSlop, dy: -jumpOuterSlop).contains(cursorLocal) {

            if let ws = card.workspaceIndex {
                // With no window in hand there is nothing to place: the whole
                // card is one big jump target.
                if switcherOnly {
                    return BentoHit(screen: card.screen, workspaceIndex: ws, zone: .jump)
                }
                // The tile area minus a bite off every edge. Anything outside
                // that — the title row, the padding ring, and a little beyond
                // the card — means "take me there".
                let tilesCore = card.gridRect.insetBy(
                    dx: chromePadding + jumpInnerBite,
                    dy: chromePadding + jumpInnerBite)
                if !tilesCore.contains(cursorLocal) {
                    return BentoHit(screen: card.screen, workspaceIndex: ws, zone: .jump)
                }
            } else if !card.cardRect.contains(cursorLocal) {
                // Workspaces off: keep the shipped behaviour exactly — the
                // grown rect must not extend the card's reach.
                continue
            }
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
                return BentoHit(screen: card.screen, workspaceIndex: card.workspaceIndex, zone: zone)
            } else if let center = card.centerZone {
                // Center cell of another card: send the window there untouched.
                return BentoHit(screen: card.screen, workspaceIndex: card.workspaceIndex, zone: center)
            } else {
                return nil  // center cell of the current card -> cancel
            }
        }
        return nil  // outside every card
    }

    private func resolveSingleDisplay(cursorNS: NSPoint) -> BentoHit? {
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
        return BentoHit(screen: screen,
                        workspaceIndex: workspacesActive ? currentWorkspaceIndex?(screen) : nil,
                        zone: zone)
    }

    /// Highlight the resolved hit. Pass nil to clear (cursor in cancel
    /// cell or outside any zone). Cheap to call every drag event — only
    /// triggers a redraw when the visible state changes.
    func setActive(_ hit: BentoHit?) {
        guard hit != activeHit else { return }
        activeHit = hit

        if let layout = displayLayout {
            for (index, pair) in zip(cardViews, layout).enumerated() {
                let (view, card) = pair
                // "Hot" = the cursor is over this card, whether or not a zone
                // resolved. Deriving it from the hit alone would blank the grid
                // the moment the cursor sat in the cancel cell — including the
                // instant the panel opens, which is exactly when the user needs
                // to see where the cells are.
                let onThisCard = hoveredCardIndex == index
                let jumping = onThisCard && hit?.zone == .jump
                let hot = onThisCard && !jumping && !switcherOnly
                _ = card
                let zone = hot ? hit?.zone : nil
                guard view.content.activeZone != zone
                        || view.content.isHot != hot
                        || view.content.isJumping != jumping else { continue }
                view.content.activeZone = zone
                view.content.isHot = hot
                view.content.isJumping = jumping
                view.content.needsDisplay = true
            }
        } else if let view = cardViews.first {
            view.content.activeZone = hit?.zone
            // No zone -> the cursor is back in the deadzone: light the ring.
            view.content.cancelActive = hit == nil
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
    /// What this card's CENTER cell means. nil on the card the gesture
    /// started on — there it stays the cancel ring. `.moveToDisplay` on every
    /// other card: "send the window to this display exactly as it is".
    /// Computed once here so the hit test and the drawing can never disagree
    /// about which cell does what.
    /// Which workspace this card is. nil when virtual workspaces are off, in
    /// which case the card is a plain display card and everything below
    /// behaves exactly as it shipped.
    let workspaceIndex: Int?
    /// The windows already living in this workspace, for the overview layer.
    /// Empty when workspaces are off.
    let overview: [WSOverviewWindow]
    let centerZone: TileZone?
    /// Only set alongside `centerZone == .moveToDisplay`: where the window
    /// would land on THIS display, as a fraction of the display's visible
    /// frame (x/y from the bottom-left, like the rest of this file's coords).
    /// The center cell draws it, so the user sees the window's real size and
    /// position on the destination before committing.
    let moveHerePreview: NSRect?
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
    /// What the CENTER cell is. nil → the cancel ring (single-display, and
    /// the card the gesture started on). `.moveToDisplay` → this card belongs
    /// to another display, and the cell previews the window landing there.
    var centerZone: TileZone?
    /// The `.moveToDisplay` landing rect as a fraction of this display's
    /// visible frame. Drawn inside the center cell's mini-screen.
    var moveHerePreview: NSRect?
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

    // MARK: - Virtual workspace state
    //
    // All inert when `workspaceMode` is false, which is how the overlay
    // behaves when the feature is off.

    /// True when this card represents a workspace rather than a display.
    var workspaceMode: Bool = false
    /// The cursor is inside this card's tile area: show the 3x3 grid and let
    /// the overview recede behind it.
    var isHot: Bool = false
    /// The cursor is on this card's jump frame: no grid, full-strength
    /// overview, accent ring, and the title says where you're going.
    var isJumping: Bool = false
    /// What already lives in this workspace.
    var overview: [WSOverviewWindow] = []

    /// How far the overview fades when the grid takes over. Not zero — a
    /// ghost of the real layout behind the cells is useful context, and it
    /// keeps the card from flashing empty as the cursor crosses in.
    private static let overviewRecededAlpha: CGFloat = 0.25

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
        let accent = NSColor.controlAccentColor

        if workspaceMode {
            // Two layers, and only ever one of them in focus. Which one wins
            // is decided purely by where the cursor is, so the card never
            // asks the eye to read both at once.
            let tiles = gridRect.insetBy(dx: TileCancelDot.chromePadding,
                                         dy: TileCancelDot.chromePadding)
            drawOverview(in: tiles,
                         alpha: isHot ? Self.overviewRecededAlpha : 1.0)
            if isHot {
                drawGrid(in: gridRect, accent: accent)
            }
            if isJumping {
                let inset = bounds.insetBy(dx: 1, dy: 1)
                let path = NSBezierPath(roundedRect: inset,
                                        xRadius: cornerRadius - 1, yRadius: cornerRadius - 1)
                accent.setStroke()
                path.lineWidth = 2
                path.stroke()
            }
        } else {
            drawGrid(in: gridRect, accent: accent)
        }

        if isJumping, let label, !label.isEmpty {
            // Replaces the normal title rather than floating a pill outside
            // the card: a pill above a card in the second row would sit on
            // top of the card above it.
            drawTitle("\u{21B3} " + label, accentOverride: accent)
        } else if let label, !label.isEmpty {
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

    private func drawTitle(_ text: String, accentOverride: NSColor? = nil) {
        let titleH = TileCancelDot.cardTitleHeight
        let rowY = bounds.maxY - TileCancelDot.cardTitleTopPad - titleH

        let dotSize = TileCancelDot.cardTitleDotSize
        let dotRect = NSRect(
            x: bounds.minX + TileCancelDot.cardTitleLeftPad,
            y: rowY + (titleH - dotSize) / 2,
            width: dotSize,
            height: dotSize
        )
        if let accentOverride {
            // Jump state: the arrow in the text carries the meaning, so the
            // dot would just be noise. Draw it hollow to keep the text's
            // left edge where it always is.
            accentOverride.setStroke()
            let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.6, dy: 0.6))
            ring.lineWidth = 1.2
            ring.stroke()
        } else {
            (isCurrent ? NSColor.controlAccentColor : Self.cardDotIdleColor).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }

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
            .foregroundColor: accentOverride
                ?? (isCurrent ? NSColor.controlAccentColor : Self.cardLabelColor),
            .kern: 0.8,
            .paragraphStyle: paragraph,
        ]
        NSAttributedString(string: text.uppercased(), attributes: attrs).draw(in: textRect)
    }

    // MARK: - Workspace overview

    /// Draw what already lives in this workspace: one little window per real
    /// window, each with a title strip and its app icon in the corner.
    ///
    /// The strip and the icon are what make these read as *windows*. Without
    /// them the card is a handful of grey rectangles that look like empty
    /// boxes, which is worse than drawing nothing.
    private func drawOverview(in area: NSRect, alpha: CGFloat) {
        guard !overview.isEmpty else {
            if !isHot { drawEmptyNote(in: area) }
            return
        }
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        // Clip to the card. Without this a window whose computed rect falls
        // outside the tile area is drawn straight across the neighbouring
        // cards — which is exactly what the first build did.
        NSBezierPath(rect: area.insetBy(dx: -1, dy: -1)).setClip()
        ctx.cgContext.setAlpha(alpha)

        let fill = Self.overviewFill
        let line = Self.overviewStroke
        let bar = Self.overviewTitleBar

        for w in overview {
            // Skip anything that isn't really on this display. A unit rect far
            // outside 0...1 means the window's recorded frame belongs
            // somewhere else (or is stale) — drawing it would be a lie, and a
            // messy one.
            guard w.unitRect.maxX > -0.2, w.unitRect.minX < 1.2,
                  w.unitRect.maxY > -0.2, w.unitRect.minY < 1.2 else { continue }
            let r = NSRect(
                x: area.minX + w.unitRect.minX * area.width,
                y: area.minY + w.unitRect.minY * area.height,
                width: max(10, w.unitRect.width * area.width),
                height: max(8, w.unitRect.height * area.height)
            ).insetBy(dx: 0.5, dy: 0.5)
            guard r.width > 2, r.height > 2 else { continue }

            let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            fill.setFill()
            path.fill()

            // Title strip along the top (NS coords: top = maxY).
            let barH = min(9.0, r.height * 0.32)
            let barRect = NSRect(x: r.minX, y: r.maxY - barH, width: r.width, height: barH)
            NSGraphicsContext.current?.saveGraphicsState()
            path.setClip()
            bar.setFill()
            barRect.fill()
            NSGraphicsContext.current?.restoreGraphicsState()

            line.setStroke()
            path.lineWidth = 1
            path.stroke()

            if let icon = w.icon, barH >= 6 {
                let side = min(barH - 2.5, 7)
                let iconRect = NSRect(x: r.minX + 3,
                                      y: barRect.midY - side / 2,
                                      width: side, height: side)
                icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        ctx.restoreGraphicsState()
    }

    private func drawEmptyNote(in area: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: Self.cardLabelColor.withAlphaComponent(0.55),
        ]
        let text = NSAttributedString(
            string: NSLocalizedString("Empty", comment: "empty workspace card"),
            attributes: attrs)
        let size = text.size()
        text.draw(at: NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
    }

    private static let overviewFill = dynamic(
        dark: NSColor(white: 1, alpha: 0.13), light: NSColor(white: 0, alpha: 0.10))
    private static let overviewStroke = dynamic(
        dark: NSColor(white: 1, alpha: 0.30), light: NSColor(white: 0, alpha: 0.24))
    private static let overviewTitleBar = dynamic(
        dark: NSColor(white: 1, alpha: 0.22), light: NSColor(white: 0, alpha: 0.17))

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

        // The middle cell is the only one that changes meaning per card: the
        // cancel ring at home, "move the window here" on any other display.
        let zoneAt: [[TileZone?]] = [
            [.topLeft,    .full,      .topRight],
            [.left,       centerZone, .right],
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
        case .moveToDisplay:
            // The window at its real relative position and size on this
            // display. Floored to a visible size so a small window still
            // reads as a block rather than a speck.
            let u = moveHerePreview ?? NSRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
            let w = max(4, u.width * mini.width)
            let h = max(3, u.height * mini.height)
            preview = NSRect(
                x: min(mini.minX + u.minX * mini.width, mini.maxX - w),
                y: min(mini.minY + u.minY * mini.height, mini.maxY - h),
                width: w,
                height: h
            )
        case .jump:
            // Never rendered inside a cell — the jump frame is the ring
            // around the grid, not one of the nine tiles.
            return
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
