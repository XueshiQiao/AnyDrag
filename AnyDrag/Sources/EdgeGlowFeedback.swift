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
// Renders the bracket as a stack of stroked `CAShapeLayer`s sharing one path
// (the outer rounded corner is part of the path itself, not a lineJoin trick):
// two wide accent-tinted shadow passes for the soft bloom, plus a bright "lit
// filament" core on top. Stacking discrete layer shadows is how we fake the
// multi-pass glow a single CALayer shadow can't produce. No `draw(_:)` — keeps
// the backing store negligible regardless of window size.

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

    /// Halo padding around the bracket so the soft glow has room to render
    /// outside the panel's edge without being clipped. Must be ≥ the widest
    /// bloom layer's `shadowRadius` (22, see `BracketView`), plus a margin.
    static let haloPadding: CGFloat = 30

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

    // Glow stack, back-to-front, all sharing one bracket path. The two halo
    // layers contribute the wide soft bloom; the core is a bright lit filament
    // with a tight glow on top.
    private let glowWide = CAShapeLayer()   // widest, faintest halo
    private let glowMid  = CAShapeLayer()   // mid halo
    private let core     = CAShapeLayer()   // bright filament + tight glow
    private var allLayers: [CAShapeLayer] { [glowWide, glowMid, core] }

    var corner: ResizeCorner = .topLeft {
        didSet { needsLayout = true }
    }

    override var isFlipped: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for l in allLayers {
            layer?.addSublayer(l)
            l.fillColor = nil
            l.lineWidth = EdgeGlowPanel.edgeThickness
            l.lineCap = .round
            l.lineJoin = .round
            l.shadowOffset = .zero
            l.masksToBounds = false
        }
        // Radii kept inside `haloPadding` (30pt) so no halo is clipped.
        glowWide.shadowRadius = 22; glowWide.shadowOpacity = 0.42
        glowMid.shadowRadius  = 12; glowMid.shadowOpacity  = 0.65
        core.shadowRadius     = 3;  core.shadowOpacity     = 1.0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let halo = EdgeGlowPanel.haloPadding
        let L    = EdgeGlowPanel.armLength
        let r    = EdgeGlowPanel.cornerRadius
        let win  = bounds.insetBy(dx: halo, dy: halo)
        let path = Self.bracketPath(corner: corner, in: win, armLength: L, cornerRadius: r)
        // The glow is cast by the stroked line itself; handing CA the stroked
        // outline as `shadowPath` skips the per-frame offscreen rasterize+blur
        // it would otherwise do for each of the three layers during a live
        // resize gesture.
        let shadowPath = path.copy(
            strokingWithWidth: EdgeGlowPanel.edgeThickness,
            lineCap: .round, lineJoin: .round, miterLimit: 10
        )
        // Disable implicit animations: manually-added sublayers (unlike a
        // view's backing layer) animate `frame`/`path` changes by default, so
        // without this the bracket eases toward each new size and trails the
        // window during a resize.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in allLayers {
            l.frame = bounds
            l.path = path
            l.shadowPath = shadowPath
        }
        CATransaction.commit()
    }

    /// Re-resolve the current dynamic accent color and push it to the layer.
    /// Called at `begin` so a system accent change between gestures is
    /// reflected immediately (CALayer caches CGColor; doesn't auto-follow
    /// the dynamic NSColor catalog entry).
    func refreshAccent() {
        // Resolve the dynamic accent AND every CGColor derived from it inside
        // the appearance block: a catalog color only commits to concrete
        // components when `.cgColor` / `.usingColorSpace` / `.blended` are
        // evaluated, so those must run against the view's effectiveAppearance
        // here — not after the closure returns.
        let (accentCG, coreCG): (CGColor, CGColor) =
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let accent = NSColor.controlAccentColor
                let base = accent.usingColorSpace(.sRGB) ?? accent
                // Bright filament: accent pushed toward white so the line itself
                // reads as "lit" while keeping the accent hue.
                let coreNS = base.blended(withFraction: 0.55, of: .white) ?? base
                return (accent.cgColor, coreNS.cgColor)
            }
        // Halo layers: accent stroke + accent-tinted bloom.
        glowWide.strokeColor = accentCG; glowWide.shadowColor = accentCG
        glowMid.strokeColor  = accentCG; glowMid.shadowColor  = accentCG
        // Core: lit stroke, accent glow.
        core.strokeColor = coreCG;       core.shadowColor = accentCG
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
