import AppKit

// MARK: - TileCancelDot
//
// Marks the origin of a middle-button tile-by-direction gesture so the user
// can drag back inside the ring to cancel. Drawn as a translucent accent-color
// ring with a small filled dot at center — matches TileOverlay's accent palette
// so the two overlays read as one system.
//
// Lifecycle: shown on otherMouseDown when middleAction == .tileByDirection,
// hidden on otherMouseUp. Highlighted state lights up while the cursor is
// inside the cancel radius (i.e. release-here-to-cancel).

final class TileCancelDot: NSPanel {

    /// Visible ring radius (points). Doubles as the cancel-area radius — the
    /// caller is expected to keep its threshold in sync so the ring matches
    /// the actual cancel zone.
    static let radius: CGFloat = 50

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
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        animationBehavior = .none
        hidesOnDeactivate = false
        isMovable = false

        contentView = fillView
    }

    /// Show centered at the given CGEvent screen point (top-left origin, y down).
    func show(atCGPoint cgScreenPoint: CGPoint) {
        // Mirror DragEngine.screen(containingCGPoint:): NSScreen uses a unified
        // coord space whose origin is the bottom-left of the primary screen,
        // and `NSScreen.screens.first` is the primary by Apple convention.
        guard let primary = NSScreen.screens.first else { return }
        let nsY = primary.frame.height - cgScreenPoint.y

        let side = Self.radius * 2 + TileCancelDotView.padding * 2
        let frame = NSRect(
            x: cgScreenPoint.x - side / 2,
            y: nsY - side / 2,
            width: side,
            height: side
        )
        setFrame(frame, display: true)
        fillView.isHighlighted = false
        fillView.needsDisplay = true
        if !isVisible {
            orderFrontRegardless()
        }
    }

    /// Update the highlighted state (cursor inside cancel area). Cheap to call
    /// every drag event — only triggers a redraw when the value actually changes.
    func setHighlighted(_ highlighted: Bool) {
        guard fillView.isHighlighted != highlighted else { return }
        fillView.isHighlighted = highlighted
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

    /// Extra room around the ring so the stroke isn't clipped at panel edges.
    static let padding: CGFloat = 4

    var isHighlighted: Bool = false

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = TileCancelDot.radius

        let ringFill: NSColor
        let ringStroke: NSColor
        let dotFill: NSColor
        let dotRadius: CGFloat
        let ringLineWidth: CGFloat

        if isHighlighted {
            ringFill = NSColor.controlAccentColor.withAlphaComponent(0.22)
            ringStroke = NSColor.controlAccentColor.withAlphaComponent(0.95)
            dotFill = NSColor.controlAccentColor.withAlphaComponent(1.0)
            dotRadius = 6
            ringLineWidth = 2.5
        } else {
            ringFill = NSColor.controlAccentColor.withAlphaComponent(0.06)
            ringStroke = NSColor.controlAccentColor.withAlphaComponent(0.55)
            dotFill = NSColor.controlAccentColor.withAlphaComponent(0.85)
            dotRadius = 4
            ringLineWidth = 2.0
        }

        // Inset by half the stroke so the outer edge of the stroke sits at
        // exactly `radius` — keeps "inside the visible ring" aligned with
        // "inside the cancel boundary" (cursor distance < radius).
        let strokeInset = ringLineWidth / 2
        let ringRect = CGRect(
            x: center.x - radius + strokeInset,
            y: center.y - radius + strokeInset,
            width: (radius - strokeInset) * 2,
            height: (radius - strokeInset) * 2
        )
        let ringPath = NSBezierPath(ovalIn: ringRect)
        ringFill.setFill()
        ringPath.fill()
        ringPath.lineWidth = ringLineWidth
        ringStroke.setStroke()
        ringPath.stroke()

        let dotRect = CGRect(
            x: center.x - dotRadius,
            y: center.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        )
        let dotPath = NSBezierPath(ovalIn: dotRect)
        dotFill.setFill()
        dotPath.fill()
    }
}
