import Cocoa

/// Five toggleable chips (fn / ⌃ / ⌥ / ⇧ / ⌘) for picking the AnyDrag modifier
/// combination. Replaces the row of NSButton checkboxes with a more compact,
/// glyph-forward control. Multi-select; empty selection is valid (means "off").
final class ModifierChipRow: NSView {

    /// Currently-on modifiers. Setting this updates each chip's visual state.
    var selection: ModifierCombination {
        didSet { syncChips() }
    }

    /// Fired when the user toggles a chip. Return `true` to accept the new
    /// combination, `false` to reject it — the chip's visual state will revert
    /// because we never optimistically flip it.
    var onChange: ((ModifierCombination) -> Bool)?

    /// Elements that are shown but greyed-out and unclickable. Used by the
    /// left-click resize augment picker to forbid keys already in the base
    /// modifier (picking one would make the resize trigger identical to the
    /// move trigger). Setting this restyles the affected chips.
    var disabledElements: ModifierCombination = [] {
        didSet { guard oldValue != disabledElements else { return }; syncChips() }
    }

    /// Radio behavior: at most one chip on at a time, and the on chip can't be
    /// toggled off by re-clicking it. Used by the augment picker.
    private let singleSelect: Bool

    private struct Spec {
        let element: ModifierCombination
        let glyph: String
        let title: String
    }

    private static func allSpecs() -> [Spec] {
        [
            Spec(element: .fn,      glyph: "fn", title: NSLocalizedString("fn", comment: "")),
            Spec(element: .control, glyph: "⌃",  title: NSLocalizedString("Control", comment: "")),
            Spec(element: .option,  glyph: "⌥",  title: NSLocalizedString("Option", comment: "")),
            Spec(element: .shift,   glyph: "⇧",  title: NSLocalizedString("Shift", comment: "")),
            Spec(element: .command, glyph: "⌘",  title: NSLocalizedString("Command", comment: "")),
            // Virtual "Hyper" = hold CapsLock via HyperCapslock. Shown with the
            // macOS CapsLock glyph (⇪, U+21EA) since that's literally what's held;
            // accessibility label stays the word "Hyper".
            Spec(element: .hyper,   glyph: "⇪", title: NSLocalizedString("Hyper", comment: "")),
        ]
    }

    private var chips: [ModifierChip] = []

    /// - Parameters:
    ///   - initial: starting selection.
    ///   - candidates: when non-nil, only these single-key elements get a chip
    ///     (in the canonical fn ⌃ ⌥ ⇧ ⌘ ⇪ order); nil shows all six.
    ///   - singleSelect: radio behavior (see `singleSelect`).
    init(initial: ModifierCombination,
         candidates: [ModifierCombination]? = nil,
         singleSelect: Bool = false) {
        self.selection = initial
        self.singleSelect = singleSelect
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let specs: [Spec]
        if let candidates {
            specs = Self.allSpecs().filter { candidates.contains($0.element) }
        } else {
            specs = Self.allSpecs()
        }

        setAccessibilityRole(.group)
        setAccessibilityLabel(NSLocalizedString("Modifier Keys", comment: ""))

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
        // Disabled chips are inert (their `ModifierChip` already swallows the
        // click, but guard here too in case of keyboard/AX activation).
        guard disabledElements.isDisjoint(with: element) else { return }

        var proposed = selection
        if singleSelect {
            // Radio: clicking the already-on chip keeps it on (no empty state);
            // clicking another moves the selection there.
            guard !proposed.contains(element) else { return }
            proposed = element
        } else if proposed.contains(element) {
            proposed.remove(element)
        } else {
            proposed.insert(element)
            // Hyper is exclusive with the real flag modifiers. The engine arms on
            // EITHER a held CapsLock (Hyper) OR a flag combination, never a mix —
            // so selecting one side clears the other to keep the UI honest.
            if element == .hyper {
                proposed = .hyper
            } else {
                proposed.remove(.hyper)
            }
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
            chip.isDisabled = !disabledElements.isDisjoint(with: chip.element)
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

    /// Greyed-out and unclickable. Used to forbid keys already taken by the
    /// base modifier in the augment picker.
    var isDisabled: Bool = false {
        didSet { guard oldValue != isDisabled else { return }; applyAppearance() }
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
        guard !isDisabled else { return }
        isHovering = true
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard !isDisabled else { return }
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

    override var acceptsFirstResponder: Bool { !isDisabled }

    override func keyDown(with event: NSEvent) {
        let space = (event.charactersIgnoringModifiers == " ")
        let returnKey = (event.keyCode == 36)
        let keypadEnter = (event.keyCode == 76)
        if space || returnKey || keypadEnter {
            if !isDisabled { onClick?() }
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Accessibility

    override func accessibilityPerformPress() -> Bool {
        guard !isDisabled else { return false }
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
        // Dim the whole chip when disabled; the on/off styling below still
        // draws so a forbidden-but-selected key reads as "this is the choice,
        // just not available right now".
        alphaValue = isDisabled ? 0.35 : 1.0

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
