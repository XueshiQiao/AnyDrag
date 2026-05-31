import Cocoa

/// macOS Sonoma-style settings card: rounded surface with a subtle background
/// (`controlBackgroundColor`), padded rows, and hairline separators between
/// rows. Used by the General and Advanced preference panes — each visual
/// section is a card, with its title placed above (outside) the card.
final class SettingsSectionCard: NSView {

    /// Horizontal padding from the card's edge to row content.
    static let horizontalInset: CGFloat = 14
    /// Vertical padding above the first row and below the last row.
    static let verticalInset: CGFloat = 12
    /// Distance between a row and the adjacent hairline separator (applied
    /// both above and below the separator).
    static let rowSpacing: CGFloat = 10
    /// Corner radius for the card.
    static let cornerRadius: CGFloat = 10

    init(rows: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        // Hairline border so each section reads as a distinct grouped "form"
        // card, matching macOS System Settings. Color is re-resolved in
        // `updateLayer()` so it tracks light/dark + Increase Contrast.
        layer?.borderWidth = 1

        var lastAnchor: NSLayoutYAxisAnchor = topAnchor
        var lastSpacing: CGFloat = Self.verticalInset

        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                addSubview(separator)
                NSLayoutConstraint.activate([
                    separator.topAnchor.constraint(equalTo: lastAnchor, constant: lastSpacing),
                    separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
                    separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
                ])
                lastAnchor = separator.bottomAnchor
                lastSpacing = Self.rowSpacing
            }

            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: lastAnchor, constant: lastSpacing),
                row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
                row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            ])
            lastAnchor = row.bottomAnchor
            lastSpacing = Self.rowSpacing
        }

        bottomAnchor.constraint(equalTo: lastAnchor, constant: Self.verticalInset).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // CGColor is not appearance-reactive on its own — re-resolve the dynamic
    // color whenever AppKit asks us to redraw the layer (covers light/dark
    // toggles and Increase Contrast).
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    // `wantsUpdateLayer` alone doesn't reliably trigger on appearance flips —
    // peer settings views (MiddleActionCardPicker, ModifierChipRow) all add
    // this override for the same reason.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Shared row primitives

/// Bundle of references to a built row, returned so the caller can later
/// re-style the labels (e.g. dimming subtitle when the gating modifier is
/// empty).
struct SettingsRow {
    let view: NSView
    let title: NSTextField
    let subtitle: NSTextField?
}

enum SettingsRowBuilder {

    /// Small secondary-color label, used for sub-headings and hint text
    /// inside cards.
    static func subLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Standard "title + optional subtitle + trailing toggle" row used in
    /// almost every feature card.
    static func feature(
        title: String,
        subtitle: String?,
        toggle: NSSwitch,
        target: AnyObject?,
        action: Selector
    ) -> SettingsRow {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)

        let labelStack = NSStackView()
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 1
        labelStack.addArrangedSubview(titleLabel)

        var subtitleLabel: NSTextField?
        if let subtitle = subtitle {
            let sub = NSTextField(labelWithString: subtitle)
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor
            // Allow up to 2 lines — long descriptions (e.g. the corner
            // bracket's perf hint) overflow a single line and would
            // otherwise push the toggle off the row.
            sub.lineBreakMode = .byWordWrapping
            sub.maximumNumberOfLines = 2
            sub.preferredMaxLayoutWidth = 360
            sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            labelStack.addArrangedSubview(sub)
            subtitleLabel = sub
        }

        toggle.target = target
        toggle.action = action
        toggle.focusRingType = .none
        // Toggle never compresses or moves; the label stack absorbs all the
        // width variation.
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [labelStack, NSView(), toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8
        row.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)
        return SettingsRow(view: row, title: titleLabel, subtitle: subtitleLabel)
    }
}

enum SettingsCardLayout {
    /// Adds a small section label followed by a SettingsSectionCard to the
    /// pane's outer vertical stack. The card stretches to fill the inner
    /// width (respecting the stack's right edge inset).
    @discardableResult
    static func addSection(
        to container: NSStackView,
        header: String?,
        rows: [NSView],
        bottomSpacing: CGFloat = 18
    ) -> SettingsSectionCard {
        if let header = header {
            let label = NSTextField(labelWithString: header)
            label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            container.addArrangedSubview(label)
            container.setCustomSpacing(6, after: label)
        }

        let card = SettingsSectionCard(rows: rows)
        container.addArrangedSubview(card)
        // The leading edge is already set by the stack's edgeInsets. We force
        // the trailing edge so the card spans the full width — without this,
        // the card would shrink to zero (it has no intrinsic width).
        card.trailingAnchor.constraint(
            equalTo: container.trailingAnchor,
            constant: -container.edgeInsets.right
        ).isActive = true

        container.setCustomSpacing(bottomSpacing, after: card)
        return card
    }
}
