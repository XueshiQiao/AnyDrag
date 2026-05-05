import Cocoa
import ServiceManagement

private let log = FileLog("Settings.General")

/// General settings pane: modifier picker, per-feature toggles, middle-click
/// mode, and launch-at-login. All controls are bound to UserDefaults via the
/// `Preferences` helper and applied to the live `DragEngine`.
final class GeneralPaneViewController: NSViewController {

    private let dragEngine: DragEngine

    private let modifierChipRow = ModifierChipRow(initial: ModifierCombination())
    private let modifierPreview = NSTextField(labelWithString: "")

    private let dragSwitch     = NSSwitch()
    private let maximizeSwitch = NSSwitch()
    private let tilingSwitch   = NSSwitch()
    private let launchSwitch   = NSSwitch()

    private let middleActionPicker = MiddleActionCardPicker(initial: .off)

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

        // Modifier section
        container.addArrangedSubview(sectionHeader(NSLocalizedString("Modifier Key", comment: "")))

        modifierChipRow.onChange = { [weak self] proposed in
            guard let self = self else { return false }
            // At least one modifier required — refuse to toggle off the last.
            if proposed.isEmpty {
                NSSound.beep()
                return false
            }
            self.dragEngine.modifiers = proposed
            UserDefaults.standard.set(proposed.rawValue, forKey: Preferences.Key.modifierFlags)
            self.updateModifierPreview()
            return true
        }
        container.addArrangedSubview(modifierChipRow)

        modifierPreview.font = .systemFont(ofSize: 11)
        modifierPreview.textColor = .secondaryLabelColor
        container.addArrangedSubview(modifierPreview)

        container.addArrangedSubview(separator())

        // Features section
        container.addArrangedSubview(sectionHeader(NSLocalizedString("Features", comment: "")))
        container.addArrangedSubview(featureRow(
            title: NSLocalizedString("Drag window", comment: ""),
            subtitle: NSLocalizedString("feature.drag.subtitle", comment: ""),
            toggle: dragSwitch,
            action: #selector(dragToggled(_:))
        ))
        container.addArrangedSubview(featureRow(
            title: NSLocalizedString("Maximize / Restore", comment: ""),
            subtitle: NSLocalizedString("feature.maximize.subtitle", comment: ""),
            toggle: maximizeSwitch,
            action: #selector(maximizeToggled(_:))
        ))
        container.addArrangedSubview(featureRow(
            title: NSLocalizedString("Window tiling", comment: ""),
            subtitle: NSLocalizedString("feature.tiling.subtitle", comment: ""),
            toggle: tilingSwitch,
            action: #selector(tilingToggled(_:))
        ))

        container.addArrangedSubview(separator())

        // Middle-click action
        container.addArrangedSubview(sectionHeader(NSLocalizedString("Middle-click action", comment: "")))
        middleActionPicker.onChange = { [weak self] action in
            guard let self = self else { return }
            self.dragEngine.middleAction = action
            UserDefaults.standard.set(action.rawValue, forKey: Preferences.Key.middleAction)
        }
        container.addArrangedSubview(middleActionPicker)
        // Stretch to the container's content width so the three cards span the pane.
        middleActionPicker.trailingAnchor.constraint(
            equalTo: container.trailingAnchor, constant: -24
        ).isActive = true

        container.addArrangedSubview(separator())

        // Launch at Login
        container.addArrangedSubview(featureRow(
            title: NSLocalizedString("Launch at Login", comment: ""),
            subtitle: nil,
            toggle: launchSwitch,
            action: #selector(launchAtLoginToggled(_:))
        ))

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

    // MARK: - Refresh

    private func refreshFromState() {
        // Modifier chips
        modifierChipRow.selection = dragEngine.modifiers
        updateModifierPreview()

        // Feature switches
        dragSwitch.state     = dragEngine.dragEnabled ? .on : .off
        maximizeSwitch.state = dragEngine.maximizeEnabled ? .on : .off
        tilingSwitch.state   = dragEngine.tilingEnabled ? .on : .off

        // Middle action
        middleActionPicker.selection = dragEngine.middleAction

        // Launch at login
        launchSwitch.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
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

    @objc private func launchAtLoginToggled(_ sender: NSSwitch) {
        let service = SMAppService.mainApp
        do {
            if sender.state == .on {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            log.error("Failed to toggle launch at login: \(error)")
            // Revert the visual state to match reality.
            sender.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }
    }

    // MARK: - View builders

    private func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    private func featureRow(title: String, subtitle: String?, toggle: NSSwitch, action: Selector) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)

        let labelStack = NSStackView()
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 1
        labelStack.addArrangedSubview(titleLabel)
        if let subtitle = subtitle {
            let sub = NSTextField(labelWithString: subtitle)
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor
            labelStack.addArrangedSubview(sub)
        }

        toggle.target = self
        toggle.action = action
        toggle.focusRingType = .none

        let row = NSStackView(views: [labelStack, NSView(), toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8
        // Make the spacer view stretch.
        if row.arrangedSubviews.count >= 2 {
            row.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        return row
    }
}
