import Cocoa

/// Advanced settings pane: the modifier picker, per-feature toggles, and the
/// middle-click action card picker. Splits out from General to keep each pane
/// short — General now holds language / launch / diagnostics only.
final class AdvancedPaneViewController: NSViewController {

    private let dragEngine: DragEngine

    private let modifierChipRow = ModifierChipRow(initial: ModifierCombination())
    private let modifierPreview = NSTextField(labelWithString: "")
    /// Shown only when the virtual "Hyper" chip is selected — explains it needs
    /// HyperCapslock running with its broadcast setting on.
    private let hyperHint = NSTextField(wrappingLabelWithString: "")

    private let dragSwitch     = NSSwitch()
    private let maximizeSwitch = NSSwitch()
    private let tilingSwitch   = NSSwitch()
    private let resizeSwitch   = NSSwitch()
    private let cornerBracketSwitch = NSSwitch()
    private let multiDisplayBentoSwitch = NSSwitch()

    private let middleActionPicker = MiddleActionCardPicker(initial: .off)

    private var modifierGatedRows: [FeatureRowViews] = []

    private struct FeatureRowViews {
        let title: NSTextField
        let subtitle: NSTextField
        let toggle: NSSwitch
    }

    private func buildFeatureRow(title: String, subtitle: String?, toggle: NSSwitch, action: Selector) -> SettingsRow {
        let row = SettingsRowBuilder.feature(title: title, subtitle: subtitle, toggle: toggle, target: self, action: action)
        if let subtitleLabel = row.subtitle {
            modifierGatedRows.append(FeatureRowViews(title: row.title, subtitle: subtitleLabel, toggle: toggle))
        }
        return row
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

        // ─── Window Drag card ─────────────────────────────────────────
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

        modifierPreview.font = .systemFont(ofSize: 11)
        modifierPreview.textColor = .secondaryLabelColor

        hyperHint.font = .systemFont(ofSize: 11)
        hyperHint.textColor = .secondaryLabelColor
        hyperHint.lineBreakMode = .byWordWrapping
        hyperHint.maximumNumberOfLines = 0
        hyperHint.stringValue = NSLocalizedString("modifier.hyper.hint", comment: "")

        let modifierBlock = NSStackView(views: [
            SettingsRowBuilder.subLabel(NSLocalizedString("Modifier Keys", comment: "")),
            modifierChipRow,
            modifierPreview,
            hyperHint,
        ])
        modifierBlock.orientation = .vertical
        modifierBlock.alignment = .leading
        modifierBlock.spacing = 6

        let dragToggleRow = buildFeatureRow(
            title: NSLocalizedString("Drag window", comment: ""),
            subtitle: NSLocalizedString("feature.drag.subtitle", comment: ""),
            toggle: dragSwitch,
            action: #selector(dragToggled(_:))
        )
        let maximizeRow = buildFeatureRow(
            title: NSLocalizedString("Maximize / Restore", comment: ""),
            subtitle: NSLocalizedString("feature.maximize.subtitle", comment: ""),
            toggle: maximizeSwitch,
            action: #selector(maximizeToggled(_:))
        )
        let tilingRow = buildFeatureRow(
            title: NSLocalizedString("Window tiling", comment: ""),
            subtitle: NSLocalizedString("feature.tiling.subtitle", comment: ""),
            toggle: tilingSwitch,
            action: #selector(tilingToggled(_:))
        )

        SettingsCardLayout.addSection(
            to: container,
            header: NSLocalizedString("section.windowDrag", comment: ""),
            rows: [modifierBlock, dragToggleRow.view, maximizeRow.view, tilingRow.view]
        )

        // ─── Window Resize card ───────────────────────────────────────
        let resizeRow = buildFeatureRow(
            title: NSLocalizedString("feature.resize", comment: ""),
            subtitle: NSLocalizedString("feature.resize.subtitle", comment: ""),
            toggle: resizeSwitch,
            action: #selector(resizeToggled(_:))
        )
        let cornerBracketRow = buildFeatureRow(
            title: NSLocalizedString("feature.cornerBracket", comment: ""),
            subtitle: NSLocalizedString("feature.cornerBracket.subtitle", comment: ""),
            toggle: cornerBracketSwitch,
            action: #selector(cornerBracketToggled(_:))
        )

        SettingsCardLayout.addSection(
            to: container,
            header: NSLocalizedString("section.windowResize", comment: ""),
            rows: [resizeRow.view, cornerBracketRow.view]
        )

        // ─── Middle-click action card ─────────────────────────────────
        middleActionPicker.onChange = { [weak self] action in
            guard let self = self else { return }
            let previous = self.dragEngine.middleAction
            self.dragEngine.middleAction = action
            UserDefaults.standard.set(action.rawValue, forKey: Preferences.Key.middleAction)
            if previous != action {
                Analytics.trackPreferenceChanged(key: "middle_action", value: action.rawValue)
            }
        }

        let multiDisplayRow = buildFeatureRow(
            title: NSLocalizedString("feature.multiDisplayBento", comment: ""),
            subtitle: NSLocalizedString("feature.multiDisplayBento.subtitle", comment: ""),
            toggle: multiDisplayBentoSwitch,
            action: #selector(multiDisplayBentoToggled(_:))
        )

        SettingsCardLayout.addSection(
            to: container,
            header: NSLocalizedString("Middle-click action", comment: ""),
            rows: [middleActionPicker, multiDisplayRow.view],
            bottomSpacing: 0
        )

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
        multiDisplayBentoSwitch.state = dragEngine.multiDisplayBentoEnabled ? .on : .off

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
        hyperHint.isHidden = !combo.contains(.hyper)
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

    @objc private func multiDisplayBentoToggled(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        let previous = dragEngine.multiDisplayBentoEnabled
        dragEngine.multiDisplayBentoEnabled = on
        UserDefaults.standard.set(on, forKey: Preferences.Key.multiDisplayBentoEnabled)
        if previous != on {
            Analytics.trackPreferenceChanged(key: "multi_display_bento_enabled", value: String(on))
        }
    }

}
