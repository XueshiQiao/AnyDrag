import Cocoa
import ServiceManagement

private let log = FileLog("Settings.General")

/// General settings pane: modifier picker, per-feature toggles, middle-click
/// mode, and launch-at-login. All controls are bound to UserDefaults via the
/// `Preferences` helper and applied to the live `DragEngine`.
final class GeneralPaneViewController: NSViewController {

    private let dragEngine: DragEngine

    // Modifier checkboxes, in HIG order: fn ⌃ ⌥ ⇧ ⌘
    private struct ModifierRow {
        let element: ModifierCombination
        let title: String
    }

    private let modifierRows: [ModifierRow] = [
        ModifierRow(element: .fn,      title: "fn"),
        ModifierRow(element: .control, title: "⌃ \(NSLocalizedString("Control", comment: ""))"),
        ModifierRow(element: .option,  title: "⌥ \(NSLocalizedString("Option", comment: ""))"),
        ModifierRow(element: .shift,   title: "⇧ \(NSLocalizedString("Shift", comment: ""))"),
        ModifierRow(element: .command, title: "⌘ \(NSLocalizedString("Command", comment: ""))"),
    ]

    private var modifierCheckboxes: [NSButton] = []
    private let modifierPreview = NSTextField(labelWithString: "")

    private let dragSwitch     = NSSwitch()
    private let maximizeSwitch = NSSwitch()
    private let tilingSwitch   = NSSwitch()
    private let launchSwitch   = NSSwitch()

    private let middleActionPopup = NSPopUpButton(frame: .zero, pullsDown: false)

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

        let modifierRow = NSStackView()
        modifierRow.orientation = .horizontal
        modifierRow.spacing = 12
        for row in modifierRows {
            let cb = NSButton(checkboxWithTitle: row.title, target: self, action: #selector(modifierToggled(_:)))
            cb.tag = Int(row.element.rawValue)
            modifierCheckboxes.append(cb)
            modifierRow.addArrangedSubview(cb)
        }
        container.addArrangedSubview(modifierRow)

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
        for action in MiddleAction.allCases {
            middleActionPopup.addItem(withTitle: action.displayName)
            middleActionPopup.lastItem?.representedObject = action.rawValue
        }
        middleActionPopup.target = self
        middleActionPopup.action = #selector(middleActionChanged(_:))
        container.addArrangedSubview(middleActionPopup)

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
        // Modifier checkboxes
        for cb in modifierCheckboxes {
            let element = ModifierCombination(rawValue: UInt(cb.tag))
            cb.state = dragEngine.modifiers.contains(element) ? .on : .off
        }
        updateModifierPreview()

        // Feature switches
        dragSwitch.state     = dragEngine.dragEnabled ? .on : .off
        maximizeSwitch.state = dragEngine.maximizeEnabled ? .on : .off
        tilingSwitch.state   = dragEngine.tilingEnabled ? .on : .off

        // Middle action
        if let idx = MiddleAction.allCases.firstIndex(of: dragEngine.middleAction) {
            middleActionPopup.selectItem(at: idx)
        }

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

    @objc private func modifierToggled(_ sender: NSButton) {
        var combo = ModifierCombination()
        for cb in modifierCheckboxes where cb.state == .on {
            combo.insert(ModifierCombination(rawValue: UInt(cb.tag)))
        }

        // At least one modifier required — refuse to remove the last one.
        if combo.isEmpty {
            sender.state = .on
            NSSound.beep()
            return
        }

        dragEngine.modifiers = combo
        UserDefaults.standard.set(combo.rawValue, forKey: Preferences.Key.modifierFlags)
        updateModifierPreview()
    }

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

    @objc private func middleActionChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let action = MiddleAction(rawValue: raw) else { return }
        dragEngine.middleAction = action
        UserDefaults.standard.set(action.rawValue, forKey: Preferences.Key.middleAction)
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
