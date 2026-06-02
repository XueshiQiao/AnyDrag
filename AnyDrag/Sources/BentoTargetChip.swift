import AppKit

// MARK: - BentoTargetChip
//
// Plan B from docs/bento-target-app-mockups.html — a self-contained glass
// "nameplate" pill that hovers just above the bento overlay (TileCancelDot)
// and says WHICH window the tile gesture is about to move: the target app's
// icon + name.
//
// It's a separate borderless panel (not part of the bento panel) on purpose:
// the bento grid stays pixel-for-pixel as it ships today, and the chip
// anchors to the bento panel's top edge identically whether there's one
// display card or N. It floats above the panel, flipping below when there's
// no headroom near the screen's top edge.
//
// Same material + accent + border language as TileCancelDot: `.popover`
// vibrancy, a 1px appearance-resolved hairline, and a system shadow.

final class BentoTargetChip: NSPanel {

    // MARK: - Layout constants (mirror the mockup's chip)

    /// Icon edge length in points.
    private static let iconSize: CGFloat = 18
    /// Inner padding: left is tighter than right so the icon doesn't crowd
    /// the rounded corner, matching the mockup's `padding:8 14 8 9`.
    private static let padLeft: CGFloat = 9
    private static let padRight: CGFloat = 14
    private static let padV: CGFloat = 8
    /// Gap between the icon and the name.
    private static let iconTextGap: CGFloat = 9
    /// Corner radius of the pill.
    private static let cornerRadius: CGFloat = 13
    /// Hard cap on the name width before tail-truncation, so a long app
    /// name (e.g. "Visual Studio Code") can't stretch the pill across the
    /// whole bento.
    private static let maxNameWidth: CGFloat = 240
    /// Vertical gap between the bento panel edge and the chip.
    private static let panelGap: CGFloat = 12

    private static let nameFont = NSFont.systemFont(ofSize: 14, weight: .semibold)

    // MARK: - Subviews

    private let vibrancyView = ChipEffectView()
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")

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
        // We hold a strong reference and only ever `orderOut`, never
        // `close()`. Defensively opt out of close-time release so an
        // external/system close can't deallocate us out from under ARC.
        isReleasedWhenClosed = false

        vibrancyView.material = .popover
        vibrancyView.blendingMode = .behindWindow
        vibrancyView.state = .active
        vibrancyView.wantsLayer = true
        if let layer = vibrancyView.layer {
            layer.cornerRadius = Self.cornerRadius
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            // The border is drawn by the LAYER (not a separate stroked
            // subview) so it follows the exact same rounded mask + continuous
            // curve — one shape, so the top edge can't render as two hairlines.
            layer.borderWidth = 1
        }
        vibrancyView.updateBorderColor()

        iconView.imageScaling = .scaleProportionallyUpOrDown

        nameField.font = Self.nameFont
        nameField.textColor = .labelColor
        nameField.lineBreakMode = .byTruncatingTail
        nameField.usesSingleLineMode = true
        nameField.maximumNumberOfLines = 1
        nameField.drawsBackground = false
        nameField.isBezeled = false
        nameField.isEditable = false
        nameField.isSelectable = false

        vibrancyView.addSubview(iconView)
        vibrancyView.addSubview(nameField)
        contentView = vibrancyView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Show / hide

    /// Show the chip for `name` (+ optional `icon`) anchored to the top edge
    /// of `panelFrame` (the bento panel, NS coords) on `screen`. Centered
    /// horizontally over the panel, `panelGap` above it — flipped to below
    /// when there isn't room above within the screen's visible frame.
    func show(icon: NSImage?, name: String, anchoredAbove panelFrame: NSRect, on screen: NSScreen) {
        let hasIcon = icon != nil
        iconView.image = icon
        iconView.isHidden = !hasIcon
        nameField.stringValue = name

        // Measure the name via the field's own fitting size (accounts for
        // the cell's internal padding). Single-line mode never wraps, so
        // fittingSize is the full natural width; clamp to maxNameWidth so a
        // long name tail-truncates inside the pill instead of stretching it.
        let fit = nameField.fittingSize
        let nameW = min(ceil(fit.width), Self.maxNameWidth)
        let nameH = ceil(fit.height)

        let contentH = max(hasIcon ? Self.iconSize : 0, nameH)
        let panelH = Self.padV * 2 + contentH
        let iconBlockW = hasIcon ? (Self.iconSize + Self.iconTextGap) : 0
        let panelW = Self.padLeft + iconBlockW + nameW + Self.padRight

        // Lay out subviews (non-flipped: y grows up, so vertical-center).
        if hasIcon {
            iconView.frame = NSRect(
                x: Self.padLeft,
                y: (panelH - Self.iconSize) / 2,
                width: Self.iconSize,
                height: Self.iconSize
            )
        }
        nameField.frame = NSRect(
            x: Self.padLeft + iconBlockW,
            y: (panelH - nameH) / 2,
            width: nameW,
            height: nameH
        )

        // Anchor over the panel's top-center, panelGap above it.
        let visible = screen.visibleFrame
        var x = panelFrame.midX - panelW / 2
        var y = panelFrame.maxY + Self.panelGap
        // Flip below the panel if the chip would spill past the visible top.
        if y + panelH > visible.maxY {
            y = panelFrame.minY - Self.panelGap - panelH
        }
        // Keep the pill on-screen on both axes (the vertical clamp is a
        // safety net for the flip-below case when the bento panel is tall
        // enough — e.g. multi-display — to leave no room below either).
        x = max(visible.minX + 4, min(x, visible.maxX - panelW - 4))
        y = max(visible.minY + 4, min(y, visible.maxY - panelH - 4))

        setFrame(NSRect(x: x, y: y, width: panelW, height: panelH), display: true)
        if !isVisible {
            orderFrontRegardless()
        }
    }

    func hide() {
        if isVisible {
            orderOut(nil)
        }
    }
}

// MARK: - ChipEffectView

/// `.popover`-material glass for the chip. The hairline border is drawn by
/// this view's own layer (`borderWidth`/`borderColor`), so it follows the
/// layer's exact rounded mask and `.continuous` corner curve — a single
/// shape, which is why the top edge can't split into two hairlines the way a
/// separate `NSBezierPath` stroke (circular) over a `.continuous` mask could.
/// `borderColor` is a static CGColor, so we re-resolve it whenever the
/// effective appearance flips between light and dark.
private final class ChipEffectView: NSVisualEffectView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    func updateBorderColor() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let color = isDark
            ? NSColor.white.withAlphaComponent(0.18)
            : NSColor.black.withAlphaComponent(0.16)
        layer?.borderColor = color.cgColor
    }
}
