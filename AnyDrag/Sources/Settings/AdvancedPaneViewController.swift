import Cocoa

/// Advanced settings pane: the modifier picker, per-feature toggles, and the
/// middle-click action card picker. Splits out from General to keep each pane
/// short — General now holds language / launch / diagnostics only.
final class AdvancedPaneViewController: NSViewController {

    private let dragEngine: DragEngine

    private let modifierChipRow = ModifierChipRow(initial: ModifierCombination())
    private let modifierPreview = NSTextField(labelWithString: "")

    private let dragSwitch     = NSSwitch()
    private let maximizeSwitch = NSSwitch()
    private let tilingSwitch   = NSSwitch()
    private let resizeSwitch   = NSSwitch()
    private let cornerBracketSwitch = NSSwitch()

    private let middleActionPicker = MiddleActionCardPicker(initial: .off)

    private var modifierGatedRows: [FeatureRowViews] = []

    private struct FeatureRowViews {
        let title: NSTextField
        let subtitle: NSTextField
        let toggle: NSSwitch
    }

    init(dragEngine: DragEngine) {
        self.dragEngine = dragEngine
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 14
        container.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        container.translatesAutoresizingMaskIntoConstraints = false

        // Window Drag
        container.addArrangedSubview(sectionHeader(NSLocalizedString("section.windowDrag", comment: "")))
        container.addArrangedSubview(subLabel(NSLocalizedString("Modifier Keys", comment: "")))

        modifierChipRow.onChange = { [weak self] proposed in
            guard let self = self else { return false }
            let previous = self.dragEngine.modifiers
            self.dragEngine.modifiers = proposed
            UserDefaults.standard.set(proposed.rawValue, forKey: Preferences.Key.modifierFlags)
            self.updateModifierPreview()
            self.updateFeatureRowsEnabled()
            if previous != proposed {
                Analytics.trackPreferenceChanged(key: "modifier", value: proposed.analyticsKey)
            }
            return true
        }
        container.addArrangedSubview(modifierChipRow)

        modifierPreview.font = .systemFont(ofSize: 11)
        modifierPreview.textColor = .secondaryLabelColor
        container.addArrangedSubview(modifierPreview)
        container.setCustomSpacing(18, after: modifierPreview)

        addFeatureRow(
            to: container,
            title: NSLocalizedString("Drag window", comment: ""),
            subtitle: NSLocalizedString("feature.drag.subtitle", comment: ""),
            toggle: dragSwitch,
            action: #selector(dragToggled(_:))
        )
        addFeatureRow(
            to: container,
            title: NSLocalizedString("Maximize / Restore", comment: ""),
            subtitle: NSLocalizedString("feature.maximize.subtitle", comment: ""),
            toggle: maximizeSwitch,
            action: #selector(maximizeToggled(_:))
        )
        addFeatureRow(
            to: container,
            title: NSLocalizedString("Window tiling", comment: ""),
            subtitle: NSLocalizedString("feature.tiling.subtitle", comment: ""),
            toggle: tilingSwitch,
            action: #selector(tilingToggled(_:))
        )

        container.addArrangedSubview(separator())

        // Window Resize
        container.addArrangedSubview(sectionHeader(NSLocalizedString("section.windowResize", comment: "")))
        addFeatureRow(
            to: container,
            title: NSLocalizedString("feature.resize", comment: ""),
            subtitle: NSLocalizedString("feature.resize.subtitle", comment: ""),
            toggle: resizeSwitch,
            action: #selector(resizeToggled(_:))
        )
        addFeatureRow(
            to: container,
            title: NSLocalizedString("feature.cornerBracket", comment: ""),
            subtitle: NSLocalizedString("feature.cornerBracket.subtitle", comment: ""),
            toggle: cornerBracketSwitch,
            action: #selector(cornerBracketToggled(_:))
        )

        container.addArrangedSubview(separator())

        // Middle-click action
        container.addArrangedSubview(sectionHeader(NSLocalizedString("Middle-click action", comment: "")))
        middleActionPicker.onChange = { [weak self] action in
            guard let self = self else { return }
            let previous = self.dragEngine.middleAction
            self.dragEngine.middleAction = action
            UserDefaults.standard.set(action.rawValue, forKey: Preferences.Key.middleAction)
            if previous != action {
                Analytics.trackPreferenceChanged(key: "middle_action", value: action.rawValue)
            }
        }
        container.addArrangedSubview(middleActionPicker)
        middleActionPicker.trailingAnchor.constraint(
            equalTo: container.trailingAnchor, constant: -24
        ).isActive = true

        let view = NSView()
        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
        ])
        self.view = view
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshFromState()
    }

    private func refreshFromState() {
        modifierChipRow.selection = dragEngine.modifiers
        updateModifierPreview()

        dragSwitch.state            = dragEngine.dragEnabled ? .on : .off
        maximizeSwitch.state        = dragEngine.maximizeEnabled ? .on : .off
        tilingSwitch.state          = dragEngine.tilingEnabled ? .on : .off
        resizeSwitch.state          = dragEngine.resizeEnabled ? .on : .off
        cornerBracketSwitch.state   = dragEngine.cornerBracketEnabled ? .on : .off

        updateFeatureRowsEnabled()

        middleActionPicker.selection = dragEngine.middleAction
    }

    private func updateModifierPreview() {
        let combo = dragEngine.modifiers
        if combo.isEmpty {
            modifierPreview.stringValue = NSLocalizedString("modifier.preview.empty", comment: "")
        } else {
            let format = NSLocalizedString("modifier.preview.format", comment: "")
            modifierPreview.stringValue = String(format: format, combo.symbol, combo.displayName)
        }
    }

    /// When no modifier is selected, AnyDrag has nothing to listen for, so the
    /// per-feature toggles dim. Stored on/off values are untouched.
    private func updateFeatureRowsEnabled() {
        let enabled = !dragEngine.modifiers.isEmpty
        for row in modifierGatedRows {
            row.toggle.isEnabled = enabled
            row.title.textColor = enabled ? .labelColor : .tertiaryLabelColor
            row.subtitle.textColor = enabled ? .secondaryLabelColor : .tertiaryLabelColor
        }
    }

    // MARK: - Actions

    @objc private func dragToggled(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        let previous = dragEngine.dragEnabled
        dragEngine.dragEnabled = on
        UserDefaults.standard.set(on, forKey: Preferences.Key.dragEnabled)
        if previous != on {
            Analytics.trackPreferenceChanged(key: "drag_enabled", value: String(on))
        }
    }

    @objc private func maximizeToggled(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        let previous = dragEngine.maximizeEnabled
        dragEngine.maximizeEnabled = on
        UserDefaults.standard.set(on, forKey: Preferences.Key.maximizeEnabled)
        if previous != on {
            Analytics.trackPreferenceChanged(key: "maximize_enabled", value: String(on))
        }
    }

    @objc private func tilingToggled(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        let previous = dragEngine.tilingEnabled
        dragEngine.tilingEnabled = on
        UserDefaults.standard.set(on, forKey: Preferences.Key.tilingEnabled)
        if previous != on {
            Analytics.trackPreferenceChanged(key: "tiling_enabled", value: String(on))
        }
    }

    @objc private func resizeToggled(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        let previous = dragEngine.resizeEnabled
        dragEngine.resizeEnabled = on
        UserDefaults.standard.set(on, forKey: Preferences.Key.resizeEnabled)
        if previous != on {
            Analytics.trackPreferenceChanged(key: "resize_enabled", value: String(on))
        }
    }

    @objc private func cornerBracketToggled(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        let previous = dragEngine.cornerBracketEnabled
        dragEngine.cornerBracketEnabled = on
        UserDefaults.standard.set(on, forKey: Preferences.Key.cornerBracketEnabled)
        if previous != on {
            Analytics.trackPreferenceChanged(key: "corner_bracket_enabled", value: String(on))
        }
    }

    // MARK: - View builders

    private func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func subLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    private func addFeatureRow(to container: NSStackView, title: String, subtitle: String?, toggle: NSSwitch, action: Selector) {
        let row = featureRow(title: title, subtitle: subtitle, toggle: toggle, action: action)
        container.addArrangedSubview(row.view)
        if let subtitleLabel = row.subtitle {
            modifierGatedRows.append(FeatureRowViews(title: row.title, subtitle: subtitleLabel, toggle: toggle))
        }
    }

    private struct BuiltRow {
        let view: NSView
        let title: NSTextField
        let subtitle: NSTextField?
    }

    private func featureRow(title: String, subtitle: String?, toggle: NSSwitch, action: Selector) -> BuiltRow {
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

        toggle.target = self
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
        if row.arrangedSubviews.count >= 2 {
            row.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        return BuiltRow(view: row, title: titleLabel, subtitle: subtitleLabel)
    }
}
