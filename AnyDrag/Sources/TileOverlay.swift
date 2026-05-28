import AppKit

// MARK: - TileOverlay
//
// Translucent rectangle that previews where a window will land during a
// middle-button tile-by-direction gesture. Uses a borderless, non-activating,
// mouse-transparent panel so it never steals focus or eats events from the
// CGEvent tap.
//
// The preview is rendered with a layer-backed view (backgroundColor + rounded
// border) rather than an NSView `draw(_:)` override. A `draw(_:)`-based
// buffered window allocates a CPU-side bitmap backing store the size of the
// window in *device pixels* — for a full-screen preview on a 5K display that's
// ~59 MB, reallocated every time the previewed zone changes (the source of a
// reported multi-tens-of-MB spike during the slide). A solid-color rounded
// layer is composited without any per-pixel bitmap, so the overlay now costs a
// few KB regardless of the previewed zone's size.

final class TileOverlay: NSPanel {

    private static let cornerRadius: CGFloat = 14
    private static let borderWidth: CGFloat = 2
    /// Margin between the previewed zone edge and the drawn shape. Applied to
    /// the window frame (was the drawing inset in the old `draw(_:)` version),
    /// so the visible result is unchanged.
    private static let edgeInset: CGFloat = 4

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

        let fill = NSView()
        fill.wantsLayer = true
        if let layer = fill.layer {
            layer.cornerRadius = Self.cornerRadius
            layer.borderWidth = Self.borderWidth
            layer.masksToBounds = true
        }
        contentView = fill
    }

    /// Show or move the overlay so it covers the given rect (NSScreen coords).
    func show(rect: NSRect) {
        // Guard degenerate zones: a rect narrower/shorter than the inset would
        // produce a zero/negative-size frame (undefined for NSPanel).
        let frame = rect.insetBy(dx: Self.edgeInset, dy: Self.edgeInset)
        guard frame.width > 0, frame.height > 0 else {
            hide()
            return
        }
        // Resolve the dynamic accent color in the overlay's own appearance so it
        // stays correct across light/dark and live accent changes, then push it
        // to the layer. Cheap, and accent rarely changes mid-gesture.
        if let view = contentView, let layer = view.layer {
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                // Translucent fill — accent tinted, matching the old draw values.
                layer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
                // Slightly stronger edge for visibility on light backgrounds.
                layer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            }
        }
        // `display: false` — the layer composites itself; forcing a synchronous
        // draw pass would only matter for a `draw(_:)`-based view.
        setFrame(frame, display: false)
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
