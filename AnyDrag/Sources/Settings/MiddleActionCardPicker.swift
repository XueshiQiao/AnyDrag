import Cocoa

/// Three-card segmented picker for `MiddleAction`. Replaces the previous
/// NSPopUpButton with a more discoverable, modern radio-style control.
final class MiddleActionCardPicker: NSView {

    var selection: MiddleAction {
        didSet {
            guard oldValue != selection else { return }
            for card in cards { card.isSelected = (card.action == selection) }
            subtitleLabel.stringValue = Self.subtitle(for: selection)
        }
    }

    /// Fired only when the selection changes via user interaction.
    var onChange: ((MiddleAction) -> Void)?

    private var cards: [MiddleActionCard] = []
    private let subtitleLabel = NSTextField(labelWithString: "")

    init(initial: MiddleAction) {
        self.selection = initial
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(NSLocalizedString("Middle-click action", comment: ""))

        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        for action in MiddleAction.allCases {
            let card = MiddleActionCard(action: action, symbol: Self.symbol(for: action))
            card.isSelected = (action == initial)
            card.onClick = { [weak self] in self?.userPicked(action) }
            cards.append(card)
            row.addArrangedSubview(card)
        }

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.stringValue = Self.subtitle(for: initial)
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [row, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            subtitleLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func userPicked(_ action: MiddleAction) {
        guard selection != action else { return }
        selection = action
        onChange?(action)
    }

    // MARK: - Mappings

    private static func symbol(for action: MiddleAction) -> String {
        switch action {
        case .off:              return "nosign"
        case .dragWindow:       return "hand.draw"
        case .tileByDirection:  return "square.split.2x2"
        }
    }

    private static func subtitle(for action: MiddleAction) -> String {
        switch action {
        case .off:              return NSLocalizedString("middleAction.off.subtitle", comment: "")
        case .dragWindow:       return NSLocalizedString("middleAction.drag.subtitle", comment: "")
        case .tileByDirection:  return NSLocalizedString("middleAction.tile.subtitle", comment: "")
        }
    }
}

// MARK: - Single card

private final class MiddleActionCard: NSView {

    let action: MiddleAction
    var onClick: (() -> Void)?
    var isSelected: Bool = false {
        didSet {
            guard oldValue != isSelected else { return }
            applyAppearance()
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    private var isHovering: Bool = false {
        didSet { if oldValue != isHovering { applyAppearance() } }
    }

    private var isPressed: Bool = false {
        didSet { if oldValue != isPressed { applyAppearance() } }
    }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    init(action: MiddleAction, symbol: String) {
        self.action = action
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        focusRingType = .none

        let cfg = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = action.displayName
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // The card itself is the accessibility element (.radioButton); hide
        // internal pieces so VoiceOver doesn't announce duplicate children.
        iconView.setAccessibilityElement(false)
        titleLabel.setAccessibilityElement(false)
        addSubview(iconView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),

            heightAnchor.constraint(equalToConstant: 78),
        ])

        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(action.displayName)

        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Hover & click

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        // Track press locally so dragging out cancels the click, matching
        // standard NSButton behavior. Loop until mouseUp using nested events.
        isPressed = true
        var inside = true
        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .leftMouseDragged]
        while true {
            guard let e = window?.nextEvent(matching: mask) else {
                inside = false
                break
            }
            let p = convert(e.locationInWindow, from: nil)
            inside = bounds.contains(p)
            isPressed = inside
            if e.type == .leftMouseUp { break }
        }
        isPressed = false
        if inside { onClick?() }
    }

    // VoiceOver / accessibility activation.
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Space, Return, or numeric-keypad Enter activates.
        let space = (event.charactersIgnoringModifiers == " ")
        let returnKey = (event.keyCode == 36)
        let keypadEnter = (event.keyCode == 76)
        if space || returnKey || keypadEnter {
            onClick?()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        super.setAccessibilityValue(accessibilityValue)
    }

    override func accessibilityValue() -> Any? {
        // Radio-button value: 1 selected, 0 not.
        return NSNumber(value: isSelected)
    }

    private func applyAppearance() {
        // Resolve dynamic system colors against the current effective appearance
        // so dark/light mode swaps update the layer correctly.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor

            if isSelected {
                layer?.backgroundColor = accent.withAlphaComponent(0.10).cgColor
                layer?.borderColor = accent.cgColor
                layer?.borderWidth = 1.5
                iconView.contentTintColor = accent
                titleLabel.textColor = accent
                titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            } else {
                let bg: NSColor
                if isPressed {
                    bg = accent.withAlphaComponent(0.06)
                } else if isHovering {
                    bg = NSColor.controlColor
                } else {
                    bg = NSColor.controlBackgroundColor
                }
                layer?.backgroundColor = bg.cgColor
                layer?.borderColor = NSColor.separatorColor.cgColor
                layer?.borderWidth = 1
                iconView.contentTintColor = .secondaryLabelColor
                titleLabel.textColor = .labelColor
                titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
            }
        }
    }
}
