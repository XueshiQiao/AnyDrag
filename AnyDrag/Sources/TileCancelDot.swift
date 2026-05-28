import AppKit

// MARK: - TileCancelDot
//
// Bento-style overlay shown at the middle-button gesture origin while a
// tile-by-direction gesture is in flight. Renders a screen-shaped panel
// with a 3×3 grid: the eight outer tiles preview the available tile zones
// (each with a mini layout glyph), and the center tile is the cancel
// deadzone — release while it's highlighted to abort.
//
// Lifecycle: shown on otherMouseDown when middleAction == .tileByDirection,
// hidden on otherMouseUp. `setActiveZone(_:)` is called from the drag
// handler every drag event; `nil` means "cursor is in the deadzone" and
// lights up the center tile. Cell hit-testing uses the half-deadzone
// constants below — keep them in sync with the drawn cell geometry.
//
// (Type kept as `TileCancelDot` to localize the redesign to one file; the
// name is a historical artifact from the earlier ring-only overlay.)

final class TileCancelDot: NSPanel {

    /// Panel size in points. ~16:10 ratio so the tile previews read as
    /// little screens; large enough that each tile is comfortable to hit,
    /// small enough not to swallow the underlying window.
    static let panelWidth: CGFloat = 290
    static let panelHeight: CGFloat = 185

    /// Padding between the panel chrome and the grid of tiles.
    static let chromePadding: CGFloat = 12

    /// Gap between adjacent tiles.
    static let tileGap: CGFloat = 5

    /// Tile dimensions, derived from panel size + padding + gap. Public so
    /// the zone resolver can size its deadzone to the visible center cell.
    static var tileWidth: CGFloat {
        (panelWidth - chromePadding * 2 - tileGap * 2) / 3
    }
    static var tileHeight: CGFloat {
        (panelHeight - chromePadding * 2 - tileGap * 2) / 3
    }

    /// Half-width of the deadzone (in points, measured from the panel
    /// center). Equals half the center cell plus half a gap so the boundary
    /// sits exactly on the gap line — "cursor crossing the visible gap"
    /// matches "cursor commits to the adjacent tile".
    static var halfDeadzoneWidth: CGFloat {
        tileWidth / 2 + tileGap / 2
    }
    static var halfDeadzoneHeight: CGFloat {
        tileHeight / 2 + tileGap / 2
    }

    private let vibrancyView = NSVisualEffectView()
    private let fillView = TileCancelDotView()

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

        // Frosted-glass material — NSVisualEffectView lets the underlying
        // desktop/window blur through the panel, like Control Center. The
        // `.hudWindow` material is HIG-recommended for floating HUD panels
        // (volume/brightness indicators use it). `.behindWindow` blends with
        // everything under the panel; `.active` keeps the effect on even
        // though we're a non-activating panel.
        vibrancyView.material = .hudWindow
        vibrancyView.blendingMode = .behindWindow
        vibrancyView.state = .active
        vibrancyView.wantsLayer = true
        if let layer = vibrancyView.layer {
            layer.cornerRadius = 14
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            layer.borderWidth = 1
            // Slightly brighter hairline than the solid version — defines
            // the glass edge against busy wallpapers.
            layer.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        }

        fillView.translatesAutoresizingMaskIntoConstraints = false
        vibrancyView.addSubview(fillView)
        NSLayoutConstraint.activate([
            fillView.leadingAnchor.constraint(equalTo: vibrancyView.leadingAnchor),
            fillView.trailingAnchor.constraint(equalTo: vibrancyView.trailingAnchor),
            fillView.topAnchor.constraint(equalTo: vibrancyView.topAnchor),
            fillView.bottomAnchor.constraint(equalTo: vibrancyView.bottomAnchor),
        ])

        contentView = vibrancyView
    }

    /// Show centered at the given CGEvent screen point (top-left origin, y down).
    /// Initial state: center cell is highlighted (cursor sits at the click point,
    /// which is inside the deadzone).
    func show(atCGPoint cgScreenPoint: CGPoint) {
        // Mirror DragEngine.screen(containingCGPoint:): NSScreen uses a unified
        // coord space whose origin is the bottom-left of the primary screen,
        // and `NSScreen.screens.first` is the primary by Apple convention.
        guard let primary = NSScreen.screens.first else { return }
        let nsY = primary.frame.height - cgScreenPoint.y

        let frame = NSRect(
            x: cgScreenPoint.x - Self.panelWidth / 2,
            y: nsY - Self.panelHeight / 2,
            width: Self.panelWidth,
            height: Self.panelHeight
        )
        setFrame(frame, display: true)
        fillView.activeZone = nil
        fillView.needsDisplay = true
        if !isVisible {
            orderFrontRegardless()
        }
    }

    /// Update which tile is highlighted. Pass `nil` to highlight the center
    /// (cancel) cell. Cheap to call every drag event — only triggers a
    /// redraw when the value actually changes.
    func setActiveZone(_ zone: TileZone?) {
        guard fillView.activeZone != zone else { return }
        fillView.activeZone = zone
        fillView.needsDisplay = true
    }

    func hide() {
        if isVisible {
            orderOut(nil)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Fill View

private final class TileCancelDotView: NSView {

    var activeZone: TileZone? = nil

    /// `nil` means the center (cancel) cell is highlighted — that's the
    /// initial state when the gesture starts and whenever the cursor is
    /// inside the deadzone.

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor

        // Panel chrome is provided by the host NSVisualEffectView (background
        // material) + its layer border. We only draw the tile grid here.
        let panel = bounds

        // Subtle top-edge highlight — the "specular" line you see along the
        // top of glass panels in macOS. Sits just inside the rounded border.
        let highlight = NSBezierPath()
        highlight.move(to: NSPoint(x: panel.minX + 16, y: panel.maxY - 0.5))
        highlight.line(to: NSPoint(x: panel.maxX - 16, y: panel.maxY - 0.5))
        NSColor.white.withAlphaComponent(0.12).setStroke()
        highlight.lineWidth = 1
        highlight.stroke()

        // 3×3 tile grid. Iteration row 0 is the visual TOP row; since the
        // view isn't flipped, top = highest y, so we compute y from maxY
        // downward.
        let pad = TileCancelDot.chromePadding
        let gap = TileCancelDot.tileGap
        let inner = panel.insetBy(dx: pad, dy: pad)
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
                let rect = NSRect(x: x, y: y, width: tileW, height: tileH)
                let isActive: Bool = (zone == activeZone)
                drawTile(in: rect, zone: zone, isActive: isActive, accent: accent)
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

        // Tile background — tuned for legibility on top of vibrancy material.
        let tilePath = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        if isActive {
            accent.withAlphaComponent(0.42).setFill()
            tilePath.fill()
            accent.withAlphaComponent(0.95).setStroke()
            tilePath.lineWidth = 1.2
            tilePath.stroke()
        } else {
            NSColor.white.withAlphaComponent(0.10).setFill()
            tilePath.fill()
            NSColor.white.withAlphaComponent(0.14).setStroke()
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
            NSColor.white.withAlphaComponent(0.20).setFill()
            ringPath.fill()
            NSColor.white.withAlphaComponent(0.95).setStroke()
            ringPath.lineWidth = 1.8
            ringPath.stroke()
            // Small filled dot at center for emphasis.
            let dotR: CGFloat = 3.5
            let dotRect = NSRect(
                x: rect.midX - dotR,
                y: rect.midY - dotR,
                width: dotR * 2, height: dotR * 2
            )
            NSColor.white.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        } else {
            NSColor.white.withAlphaComponent(0.42).setStroke()
            ringPath.lineWidth = 1.4
            ringPath.stroke()
        }
    }

    /// Draw a tiny rect inside the tile representing where the window will
    /// land. The tile itself is the mini-screen; the preview rect is the
    /// window-within-screen at that tile's target zone.
    private func drawMiniPreview(in tile: NSRect,
                                 zone: TileZone,
                                 isActive: Bool) {
        let innerPad: CGFloat = 5
        let mini = tile.insetBy(dx: innerPad, dy: innerPad)

        // Sub-gap to keep half/quarter previews visually separated.
        let g: CGFloat = 1.5

        let preview: NSRect
        switch zone {
        case .full:
            preview = mini
        case .centered:
            // 85%×85% — matches the centeredFraction in TileZone.rect(in:).
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
            // Non-flipped view: top = high y.
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
            : NSColor.white.withAlphaComponent(0.70)
        fg.setFill()
        NSBezierPath(roundedRect: preview, xRadius: 1.5, yRadius: 1.5).fill()
    }
}
