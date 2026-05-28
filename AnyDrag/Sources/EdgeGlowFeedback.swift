import AppKit

// MARK: - EdgeGlowFeedback
//
// Lights up an L-shaped corner bracket at the resize anchor — two short
// glowing arms that meet at the active corner, with a rounded outer curve
// to echo the system window's corner. Drawn on a borderless, mouse-
// transparent, non-activating panel positioned to cover the target window's
// frame plus a halo padding so the soft glow can render outside the visible
// boundary without being clipped.
//
// Renders the bracket as a single stroked `CAShapeLayer` (the outer rounded
// corner is part of the path itself, not a lineJoin trick). The layer-based
// shadow gives the colored halo. No `draw(_:)` — keeps the backing store
// negligible regardless of window size.

final class EdgeGlowFeedback: ResizeFeedback {

    private let panel = EdgeGlowPanel()

    func begin(windowFrame: CGRect, corner: ResizeCorner) {
        panel.show(windowFrameCG: windowFrame, corner: corner)
    }

    func update(windowFrame: CGRect) {
        panel.update(windowFrameCG: windowFrame)
    }

    func end() {
        panel.hide()
    }
}

// MARK: - Panel

private final class EdgeGlowPanel: NSPanel {

    /// Thickness of the glow line itself (the bright colored stroke).
    static let edgeThickness: CGFloat = 3

    /// Length of each L-arm from the anchor corner. Long enough to read as
    /// a corner bracket from a few feet of viewing distance; short enough
    /// that it doesn't underline the whole window edge.
    static let armLength: CGFloat = 120

    /// Outer-corner radius (in points). Apps vary on their outer-corner
    /// radius; this is "close enough", not an exact match per window.
    static let cornerRadius: CGFloat = 22

    /// Halo padding around the bracket so the soft shadow has room to
    /// render outside the panel's edge. Must be at least `shadowRadius`
    /// (set on the shape layer) so the glow isn't clipped.
    static let haloPadding: CGFloat = 16

    private let bracketView: BracketView

    init() {
        bracketView = BracketView()
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
        contentView = bracketView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(windowFrameCG: CGRect, corner: ResizeCorner) {
        bracketView.corner = corner
        bracketView.refreshAccent()
        applyFrame(windowFrameCG: windowFrameCG)
        if !isVisible {
            orderFrontRegardless()
        }
    }

    func update(windowFrameCG: CGRect) {
        applyFrame(windowFrameCG: windowFrameCG)
    }

    func hide() {
        if isVisible {
            orderOut(nil)
        }
    }

    /// Convert the CG window frame to an NS panel frame (bottom-left origin),
    /// outset by `haloPadding` so the glow halo has room outside the window's
    /// visible edge. Mirrors the flip convention used in TileCancelDot.
    private func applyFrame(windowFrameCG: CGRect) {
        guard let primary = NSScreen.screens.first else { return }
        let h = Self.haloPadding
        let nsY = primary.frame.height - windowFrameCG.maxY - h
        let frame = NSRect(
            x: windowFrameCG.minX - h,
            y: nsY,
            width: windowFrameCG.width + h * 2,
            height: windowFrameCG.height + h * 2
        )
        setFrame(frame, display: false)
    }
}

// MARK: - Content view (single layer-backed bracket)

private final class BracketView: NSView {

    private let shape = CAShapeLayer()

    var corner: ResizeCorner = .topLeft {
        didSet { needsLayout = true }
    }

    override var isFlipped: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(shape)
        shape.fillColor = nil
        shape.lineWidth = EdgeGlowPanel.edgeThickness
        shape.lineCap = .round
        shape.lineJoin = .round
        shape.shadowOpacity = 0.85
        // Radius chosen well inside `haloPadding` (16pt) so the soft halo
        // never gets clipped at the panel's edge.
        shape.shadowRadius = 8
        shape.shadowOffset = .zero
        shape.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        shape.frame = bounds
        let halo = EdgeGlowPanel.haloPadding
        let L    = EdgeGlowPanel.armLength
        let r    = EdgeGlowPanel.cornerRadius
        let win  = bounds.insetBy(dx: halo, dy: halo)
        shape.path = Self.bracketPath(corner: corner, in: win, armLength: L, cornerRadius: r)
    }

    /// Re-resolve the current dynamic accent color and push it to the layer.
    /// Called at `begin` so a system accent change between gestures is
    /// reflected immediately (CALayer caches CGColor; doesn't auto-follow
    /// the dynamic NSColor catalog entry).
    func refreshAccent() {
        let accent: NSColor = effectiveAppearance.performAsCurrentDrawingAppearance {
            return NSColor.controlAccentColor
        }
        let cg = accent.cgColor
        shape.strokeColor = cg
        shape.shadowColor = cg
    }

    /// Build the L-bracket path for the given corner: two arms meeting at
    /// the anchor corner with a rounded outer curve. The path's center-line
    /// is `edgeThickness / 2` inward from the visible window boundary so
    /// the stroked line straddles the boundary evenly.
    private static func bracketPath(corner: ResizeCorner,
                                    in win: NSRect,
                                    armLength L: CGFloat,
                                    cornerRadius r: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let cornerPoint: CGPoint   // where the two arms would intersect if extended
        let armX_end: CGPoint      // far end of the horizontal arm
        let armY_end: CGPoint      // far end of the vertical arm
        switch corner {
        case .topLeft:
            cornerPoint = CGPoint(x: win.minX, y: win.maxY)
            armX_end    = CGPoint(x: win.minX + L, y: win.maxY)
            armY_end    = CGPoint(x: win.minX, y: win.maxY - L)
        case .topRight:
            cornerPoint = CGPoint(x: win.maxX, y: win.maxY)
            armX_end    = CGPoint(x: win.maxX - L, y: win.maxY)
            armY_end    = CGPoint(x: win.maxX, y: win.maxY - L)
        case .bottomLeft:
            cornerPoint = CGPoint(x: win.minX, y: win.minY)
            armX_end    = CGPoint(x: win.minX + L, y: win.minY)
            armY_end    = CGPoint(x: win.minX, y: win.minY + L)
        case .bottomRight:
            cornerPoint = CGPoint(x: win.maxX, y: win.minY)
            armX_end    = CGPoint(x: win.maxX - L, y: win.minY)
            armY_end    = CGPoint(x: win.maxX, y: win.minY + L)
        }
        // Trace: horizontal arm → tangent arc at corner → vertical arm.
        path.move(to: armX_end)
        path.addArc(tangent1End: cornerPoint, tangent2End: armY_end, radius: r)
        path.addLine(to: armY_end)
        return path
    }
}

// (NSAppearance helper — NSColor.controlAccentColor needs to be read inside
// `performAsCurrentDrawingAppearance` to return the dynamic value rather
// than the catalog placeholder when called off the main UI tree.)
private extension NSAppearance {
    func performAsCurrentDrawingAppearance<T>(_ block: () -> T) -> T {
        var result: T!
        self.performAsCurrentDrawingAppearance { result = block() }
        return result
    }
}
