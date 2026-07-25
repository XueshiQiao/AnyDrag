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
// Same material language as the bento cards ("Frameless Islands", see
// docs/bento-panel-chrome-mockups.html): `.popover` vibrancy, NO hairline
// border, and a system shadow. The border is deliberately absent — the whole
// overlay is border-free, and a dark 1px outline on a light background was
// the ugliest part of the old look.

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
    /// Transparent margin around the pill inside the window, giving our own
    /// soft shadow room to fall off. Same reasoning as the bento cards: the
    /// window-server shadow is darkest exactly at the pill's edge and shows
    /// through the rounded corner's antialiased pixels as a hard dark line.
    private static let shadowMargin: CGFloat = 20

    private static let nameFont = NSFont.systemFont(ofSize: 14, weight: .semibold)

    // MARK: - Subviews

    private let container = NSView()
    private let shadowView = NSView()
    private let vibrancyView = NSVisualEffectView()
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
        // We draw the shadow ourselves (see `shadowMargin`).
        hasShadow = false
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
        }

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

        // No content of its own: with `shadowPath` set the layer casts the
        // shadow from that path alone, so nothing is painted under the pill.
        shadowView.wantsLayer = true
        if let layer = shadowView.layer {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.16
            layer.shadowRadius = 12
            layer.shadowOffset = .zero
        }

        vibrancyView.addSubview(iconView)
        vibrancyView.addSubview(nameField)
        container.addSubview(shadowView)
        container.addSubview(vibrancyView, positioned: .above, relativeTo: shadowView)
        contentView = container
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

        // `x`/`y` are the PILL's position; the window is bigger by
        // `shadowMargin` on every side, and the pill sits inset by it.
        let margin = Self.shadowMargin
        setFrame(
            NSRect(x: x - margin, y: y - margin,
                   width: panelW + margin * 2, height: panelH + margin * 2),
            display: true
        )
        let pillFrame = NSRect(x: margin, y: margin, width: panelW, height: panelH)
        vibrancyView.frame = pillFrame
        shadowView.frame = pillFrame
        shadowView.layer?.shadowPath = CGPath(
            roundedRect: NSRect(origin: .zero, size: pillFrame.size),
            cornerWidth: Self.cornerRadius,
            cornerHeight: Self.cornerRadius,
            transform: nil
        )
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
