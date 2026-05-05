import Cocoa

/// Five toggleable chips (fn / ⌃ / ⌥ / ⇧ / ⌘) for picking the AnyDrag modifier
/// combination. Replaces the row of NSButton checkboxes with a more compact,
/// glyph-forward control. Multi-select; the parent enforces "at least one".
final class ModifierChipRow: NSView {

    /// Currently-on modifiers. Setting this updates each chip's visual state.
    var selection: ModifierCombination {
        didSet { syncChips() }
    }

    /// Fired when the user toggles a chip. Return `true` to accept the new
    /// combination, `false` to reject it (e.g. last-on guard) — the chip's
    /// visual state will revert because we never optimistically flip it.
    var onChange: ((ModifierCombination) -> Bool)?

    private struct Spec {
        let element: ModifierCombination
        let glyph: String
        let title: String
    }

    private let specs: [Spec] = [
        Spec(element: .fn,      glyph: "fn", title: NSLocalizedString("fn", comment: "")),
        Spec(element: .control, glyph: "⌃",  title: NSLocalizedString("Control", comment: "")),
        Spec(element: .option,  glyph: "⌥",  title: NSLocalizedString("Option", comment: "")),
        Spec(element: .shift,   glyph: "⇧",  title: NSLocalizedString("Shift", comment: "")),
        Spec(element: .command, glyph: "⌘",  title: NSLocalizedString("Command", comment: "")),
    ]
    private var chips: [ModifierChip] = []

    init(initial: ModifierCombination) {
        self.selection = initial
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        setAccessibilityRole(.group)
        setAccessibilityLabel(NSLocalizedString("Modifier Key", comment: ""))

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        for spec in specs {
            let chip = ModifierChip(element: spec.element, glyph: spec.glyph, title: spec.title)
            chip.isOn = initial.contains(spec.element)
            chip.onClick = { [weak self] in self?.userToggled(spec.element) }
            chips.append(chip)
            row.addArrangedSubview(chip)
        }

        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func userToggled(_ element: ModifierCombination) {
        var proposed = selection
        if proposed.contains(element) {
            proposed.remove(element)
        } else {
            proposed.insert(element)
        }
        let accepted = onChange?(proposed) ?? false
        if accepted {
            selection = proposed
        }
        // Rejected: chips never optimistically flipped, so nothing to undo.
    }

    private func syncChips() {
        for chip in chips {
            chip.isOn = selection.contains(chip.element)
        }
    }
}

// MARK: - Single chip

private final class ModifierChip: NSView {

    let element: ModifierCombination
    var onClick: (() -> Void)?

    var isOn: Bool = false {
        didSet {
            guard oldValue != isOn else { return }
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

    private let glyphLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    init(element: ModifierCombination, glyph: String, title: String) {
        self.element = element
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false

        glyphLabel.stringValue = glyph
        glyphLabel.font = .systemFont(ofSize: 14, weight: .medium)
        glyphLabel.alignment = .center
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false
        // The chip itself is the accessibility element (.checkBox); hide the
        // internal label so VoiceOver doesn't announce duplicate static text.
        glyphLabel.setAccessibilityElement(false)
        addSubview(glyphLabel)

        NSLayoutConstraint.activate([
            glyphLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyphLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 56),
            heightAnchor.constraint(equalToConstant: 36),
        ])

        setAccessibilityRole(.checkBox)
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
        isHovering = true
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        var inside = true
        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .leftMouseDragged]
        while true {
            guard let e = window?.nextEvent(matching: mask) else {
                // Window vanished mid-press — treat as cancelled.
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

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let space = (event.charactersIgnoringModifiers == " ")
        let returnKey = (event.keyCode == 36)
        let keypadEnter = (event.keyCode == 76)
        if space || returnKey || keypadEnter {
            onClick?()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Accessibility

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func accessibilityValue() -> Any? {
        return NSNumber(value: isOn)
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor

            if isOn {
                let fill = isHovering ? accent.blended(withFraction: 0.08, of: .black) ?? accent : accent
                layer?.backgroundColor = fill.cgColor
                layer?.borderColor = accent.cgColor
                // Adapts to accent luminance (e.g. black text on yellow accent).
                glyphLabel.textColor = .alternateSelectedControlTextColor
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
                glyphLabel.textColor = .labelColor
            }
        }
    }
}
