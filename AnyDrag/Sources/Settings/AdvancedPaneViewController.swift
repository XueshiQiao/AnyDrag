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

        // Features
        container.addArrangedSubview(sectionHeader(NSLocalizedString("Features", comment: "")))
        container.addArrangedSubview(subLabel(NSLocalizedString("Modifier Keys", comment: "")))

        modifierChipRow.onChange = { [weak self] proposed in
            guard let self = self else { return false }
            self.dragEngine.modifiers = proposed
            UserDefaults.standard.set(proposed.rawValue, forKey: Preferences.Key.modifierFlags)
            self.updateModifierPreview()
            self.updateFeatureRowsEnabled()
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

        // Middle-click action
        container.addArrangedSubview(sectionHeader(NSLocalizedString("Middle-click action", comment: "")))
        middleActionPicker.onChange = { [weak self] action in
            guard let self = self else { return }
            self.dragEngine.middleAction = action
            UserDefaults.standard.set(action.rawValue, forKey: Preferences.Key.middleAction)
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

        dragSwitch.state     = dragEngine.dragEnabled ? .on : .off
        maximizeSwitch.state = dragEngine.maximizeEnabled ? .on : .off
        tilingSwitch.state   = dragEngine.tilingEnabled ? .on : .off

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
        dragEngine.dragEnabled = on
        UserDefaults.standard.set(on, forKey: Preferences.Key.dragEnabled)
    }

    @objc private func maximizeToggled(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        dragEngine.maximizeEnabled = on
        UserDefaults.standard.set(on, forKey: Preferences.Key.maximizeEnabled)
    }

    @objc private func tilingToggled(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        dragEngine.tilingEnabled = on
        UserDefaults.standard.set(on, forKey: Preferences.Key.tilingEnabled)
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
            labelStack.addArrangedSubview(sub)
            subtitleLabel = sub
        }

        toggle.target = self
        toggle.action = action
        toggle.focusRingType = .none

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
