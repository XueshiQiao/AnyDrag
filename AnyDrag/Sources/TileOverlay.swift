import AppKit

// MARK: - TileOverlay
//
// Translucent rectangle that previews where a window will land during a
// middle-button tile-by-direction gesture. Uses a borderless, non-activating,
// mouse-transparent panel so it never steals focus or eats events from the
// CGEvent tap.

final class TileOverlay: NSPanel {

    private let fillView = TileOverlayFillView()

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

    /// Show or move the overlay so it covers the given rect (NSScreen coords).
    func show(rect: NSRect) {
        setFrame(rect, display: true)
        if !isVisible {
            orderFrontRegardless()
        }
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

private final class TileOverlayFillView: NSView {

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let cornerRadius: CGFloat = 14
        let inset: CGFloat = 4
        let rect = bounds.insetBy(dx: inset, dy: inset)

        // Translucent fill — accent color tinted, semi-transparent like macOS native tile preview.
        let fill = NSColor.controlAccentColor.withAlphaComponent(0.25)
        // Slightly stronger edge for visibility on light backgrounds.
        let stroke = NSColor.controlAccentColor.withAlphaComponent(0.85)

        let path = NSBezierPath(roundedRect: rect,
                                xRadius: cornerRadius,
                                yRadius: cornerRadius)
        fill.setFill()
        path.fill()

        path.lineWidth = 2
        stroke.setStroke()
        path.stroke()
    }
}
