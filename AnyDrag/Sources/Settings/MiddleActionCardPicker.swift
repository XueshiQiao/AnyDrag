import Cocoa

// Reusable card-style segmented picker plus thin typed wrappers.
//
// `CardOptionPicker` is the generic, string-id-based control (a horizontal row
// of radio cards + a subtitle for the selected one). `MiddleActionCardPicker`
// and `ResizeTriggerCardPicker` are thin enum-typed wrappers over it, so each
// call site keeps a clean typed API while the card visuals live in one place.

/// One selectable card.
struct CardOption {
    let id: String
    let title: String
    let symbol: String   // SF Symbol name
    var subtitle: String
}

/// Generic radio-style card picker. Setting `selectedID` updates the visuals
/// only; `onChange` fires solely on user interaction.
final class CardOptionPicker: NSView {

    var selectedID: String {
        didSet {
            guard oldValue != selectedID else { return }
            for card in cards { card.isSelected = (card.id == selectedID) }
            subtitleLabel.stringValue = options.first { $0.id == selectedID }?.subtitle ?? ""
        }
    }

    /// Fired only when the selection changes via user interaction.
    var onChange: ((String) -> Void)?

    /// Dim and make non-interactive (e.g. when no primary modifier is set, so
    /// the gesture can't fire). Mirrors the greyed-out feature toggles.
    var isEnabled: Bool = true {
        didSet {
            guard oldValue != isEnabled else { return }
            alphaValue = isEnabled ? 1.0 : 0.45
            cards.forEach { $0.clickable = isEnabled }
        }
    }

    private var options: [CardOption]
    private var cards: [OptionCard] = []
    private let subtitleLabel = NSTextField(labelWithString: "")

    init(options: [CardOption], selectedID: String, accessibilityLabel: String) {
        self.options = options
        self.selectedID = selectedID
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(accessibilityLabel)

        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        for opt in options {
            let card = OptionCard(id: opt.id, title: opt.title, symbol: opt.symbol)
            card.isSelected = (opt.id == selectedID)
            card.onClick = { [weak self] in self?.userPicked(opt.id) }
            cards.append(card)
            row.addArrangedSubview(card)
        }

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.stringValue = options.first { $0.id == selectedID }?.subtitle ?? ""
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

    private func userPicked(_ id: String) {
        guard selectedID != id else { return }
        selectedID = id
        onChange?(id)
    }

    /// Replace one option's subtitle (e.g. to splice in the live primary
    /// modifier symbol), refreshing the visible label if it's the selected one.
    func setSubtitle(_ text: String, forID id: String) {
        guard let idx = options.firstIndex(where: { $0.id == id }) else { return }
        options[idx].subtitle = text
        if selectedID == id { subtitleLabel.stringValue = text }
    }
}

// MARK: - Middle-click action wrapper

/// Three-card picker for `MiddleAction`.
final class MiddleActionCardPicker: NSView {

    var selection: MiddleAction {
        get { MiddleAction(rawValue: picker.selectedID) ?? .off }
        set { picker.selectedID = newValue.rawValue }
    }

    /// Fired only when the selection changes via user interaction.
    var onChange: ((MiddleAction) -> Void)?

    private let picker: CardOptionPicker

    init(initial: MiddleAction) {
        let options = MiddleAction.allCases.map {
            CardOption(id: $0.rawValue, title: $0.displayName,
                       symbol: Self.symbol(for: $0), subtitle: Self.subtitle(for: $0))
        }
        picker = CardOptionPicker(options: options, selectedID: initial.rawValue,
                                  accessibilityLabel: NSLocalizedString("Middle-click action", comment: ""))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        picker.onChange = { [weak self] id in
            guard let action = MiddleAction(rawValue: id) else { return }
            self?.onChange?(action)
        }
        embedFilling(picker)
    }

    required init?(coder: NSCoder) { fatalError() }

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

// MARK: - Resize trigger wrapper

/// Three-card picker for `ResizeTrigger` (Off / Right-drag / Left-drag).
final class ResizeTriggerCardPicker: NSView {

    var selection: ResizeTrigger {
        get { ResizeTrigger(rawValue: picker.selectedID) ?? .off }
        set { picker.selectedID = newValue.rawValue }
    }

    /// Fired only when the selection changes via user interaction.
    var onChange: ((ResizeTrigger) -> Void)?

    private let picker: CardOptionPicker

    init(initial: ResizeTrigger) {
        let options = ResizeTrigger.allCases.map {
            CardOption(id: $0.rawValue, title: $0.displayName,
                       symbol: Self.symbol(for: $0), subtitle: Self.subtitle(for: $0))
        }
        picker = CardOptionPicker(options: options, selectedID: initial.rawValue,
                                  accessibilityLabel: NSLocalizedString("section.windowResize", comment: ""))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        picker.onChange = { [weak self] id in
            guard let trigger = ResizeTrigger(rawValue: id) else { return }
            self?.onChange?(trigger)
        }
        embedFilling(picker)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Dim and make non-interactive when no primary modifier is set.
    var isEnabled: Bool {
        get { picker.isEnabled }
        set { picker.isEnabled = newValue }
    }

    /// Splice the live primary-modifier symbol into the "left-drag" subtitle.
    func setPrimaryModifierSymbol(_ symbol: String) {
        let format = NSLocalizedString("resizeTrigger.left.subtitle", comment: "")
        picker.setSubtitle(String(format: format, symbol), forID: ResizeTrigger.leftClick.rawValue)
    }

    private static func symbol(for trigger: ResizeTrigger) -> String {
        switch trigger {
        case .off:        return "nosign"
        case .rightClick: return "arrow.up.left.and.arrow.down.right"
        case .leftClick:  return "arrow.up.right.and.arrow.down.left"
        }
    }

    private static func subtitle(for trigger: ResizeTrigger) -> String {
        switch trigger {
        case .off:        return NSLocalizedString("resizeTrigger.off.subtitle", comment: "")
        case .rightClick: return NSLocalizedString("resizeTrigger.right.subtitle", comment: "")
        // Placeholder symbol; AdvancedPane refreshes it via setPrimaryModifierSymbol.
        case .leftClick:  return String(format: NSLocalizedString("resizeTrigger.left.subtitle", comment: ""), "—")
        }
    }
}

// MARK: - Helpers

private extension NSView {
    /// Pin `child` to fill the receiver.
    func embedFilling(_ child: NSView) {
        addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: topAnchor),
            child.leadingAnchor.constraint(equalTo: leadingAnchor),
            child.trailingAnchor.constraint(equalTo: trailingAnchor),
            child.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

// MARK: - Single card

private final class OptionCard: NSView {

    let id: String
    var onClick: (() -> Void)?
    /// When false the card is inert (the whole picker is disabled).
    var clickable: Bool = true
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

    init(id: String, title: String, symbol: String) {
        self.id = id
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

        titleLabel.stringValue = title
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
        setAccessibilityLabel(title)

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
        guard clickable else { return }
        isHovering = true
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard clickable else { return }
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
        guard clickable else { return false }
        onClick?()
        return true
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { clickable }

    override func keyDown(with event: NSEvent) {
        // Space, Return, or numeric-keypad Enter activates.
        let space = (event.charactersIgnoringModifiers == " ")
        let returnKey = (event.keyCode == 36)
        let keypadEnter = (event.keyCode == 76)
        if space || returnKey || keypadEnter {
            if clickable { onClick?() }
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
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
