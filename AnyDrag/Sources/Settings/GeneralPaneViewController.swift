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

    // Feature rows whose enabled state follows the modifier selection.
    private var modifierGatedRows: [FeatureRowViews] = []

    private struct FeatureRowViews {
        let title: NSTextField
        let subtitle: NSTextField
        let toggle: NSSwitch
    }

    // Diagnostics (visible only when dragEngine.diagnoseEnabled).
    private let diagnosticsContainer = NSStackView()
    private let showDotSwitch = NSSwitch()
    private let yOffsetSlider = NSSlider()
    private let yOffsetValueLabel = NSTextField(labelWithString: "")

    init(dragEngine: DragEngine) {
        self.dragEngine = dragEngine
        super.init(nibName: nil, bundle: nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(diagnoseModeChanged(_:)),
            name: .anyDragDiagnoseModeChanged,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 14
        container.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        container.translatesAutoresizingMaskIntoConstraints = false

        // Features section (modifier picker + per-feature toggles)
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

        // Vertical breathing room before the feature toggles.
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
        // Stretch to the container's content width so the three cards span the pane.
        middleActionPicker.trailingAnchor.constraint(
            equalTo: container.trailingAnchor, constant: -24
        ).isActive = true

        container.addArrangedSubview(separator())

        // Launch at Login
        let launchRow = featureRow(
            title: NSLocalizedString("Launch at Login", comment: ""),
            subtitle: nil,
            toggle: launchSwitch,
            action: #selector(launchAtLoginToggled(_:))
        )
        container.addArrangedSubview(launchRow.view)

        // Diagnostics (only attached to the visible hierarchy when the
        // diagnose flag is on, so the pane keeps its compact size in normal use).
        buildDiagnosticsSection()
        container.addArrangedSubview(diagnosticsContainer)
        diagnosticsContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24).isActive = true
        diagnosticsContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24).isActive = true

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

        updateFeatureRowsEnabled()

        // Middle action
        middleActionPicker.selection = dragEngine.middleAction

        // Launch at login
        launchSwitch.state = (SMAppService.mainApp.status == .enabled) ? .on : .off

        // Diagnostics
        updateDiagnosticsVisibility(animated: false)
        syncDiagnosticsControlsFromEngine()
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
    /// per-feature toggles are dimmed and disabled. Stored on/off values are
    /// untouched — they snap back as soon as a modifier is re-added.
    private func updateFeatureRowsEnabled() {
        let enabled = !dragEngine.modifiers.isEmpty
        for row in modifierGatedRows {
            row.toggle.isEnabled = enabled
            row.title.textColor = enabled ? .labelColor : .tertiaryLabelColor
            row.subtitle.textColor = enabled ? .secondaryLabelColor : .tertiaryLabelColor
        }
    }

    // MARK: - Diagnostics

    private func buildDiagnosticsSection() {
        diagnosticsContainer.orientation = .vertical
        diagnosticsContainer.alignment = .leading
        diagnosticsContainer.spacing = 10
        diagnosticsContainer.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsContainer.isHidden = true

        // Top separator + section header
        diagnosticsContainer.addArrangedSubview(separator())
        diagnosticsContainer.addArrangedSubview(sectionHeader(NSLocalizedString("Diagnostics", comment: "")))

        // Show-dot toggle
        showDotSwitch.target = self
        showDotSwitch.action = #selector(showDotToggled(_:))
        showDotSwitch.focusRingType = .none
        let dotRow = featureRow(
            title: NSLocalizedString("diagnostics.showDot", comment: ""),
            subtitle: NSLocalizedString("diagnostics.showDot.subtitle", comment: ""),
            toggle: showDotSwitch,
            action: #selector(showDotToggled(_:))
        )
        diagnosticsContainer.addArrangedSubview(dotRow.view)

        // Y offset slider row
        let title = NSTextField(labelWithString: NSLocalizedString("diagnostics.titleBarYOffset", comment: ""))
        title.font = .systemFont(ofSize: NSFont.systemFontSize)

        yOffsetValueLabel.font = .systemFont(ofSize: 11, weight: .medium)
        yOffsetValueLabel.textColor = .secondaryLabelColor
        yOffsetValueLabel.alignment = .right
        yOffsetValueLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let titleRow = NSStackView(views: [title, NSView(), yOffsetValueLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.distribution = .fill
        titleRow.spacing = 8
        titleRow.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)
        diagnosticsContainer.addArrangedSubview(titleRow)
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.leadingAnchor.constraint(equalTo: diagnosticsContainer.leadingAnchor).isActive = true
        titleRow.trailingAnchor.constraint(equalTo: diagnosticsContainer.trailingAnchor).isActive = true

        yOffsetSlider.minValue = 0
        yOffsetSlider.maxValue = 40
        yOffsetSlider.numberOfTickMarks = 9        // 0, 5, 10, …, 40
        yOffsetSlider.allowsTickMarkValuesOnly = false
        yOffsetSlider.isContinuous = true
        yOffsetSlider.target = self
        yOffsetSlider.action = #selector(yOffsetSliderChanged(_:))
        yOffsetSlider.focusRingType = .none
        yOffsetSlider.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsContainer.addArrangedSubview(yOffsetSlider)
        yOffsetSlider.leadingAnchor.constraint(equalTo: diagnosticsContainer.leadingAnchor).isActive = true
        yOffsetSlider.trailingAnchor.constraint(equalTo: diagnosticsContainer.trailingAnchor).isActive = true

        let hint = subLabel(NSLocalizedString("diagnostics.titleBarYOffset.hint", comment: ""))
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 0
        diagnosticsContainer.addArrangedSubview(hint)
    }

    private func updateDiagnosticsVisibility(animated: Bool) {
        let shouldShow = dragEngine.diagnoseEnabled
        guard diagnosticsContainer.isHidden == shouldShow else {
            // Already in the right state.
            return
        }
        diagnosticsContainer.isHidden = !shouldShow

        // Resize the window to fit the new layout. The Settings window
        // controller sizes panes by their fittingSize on tab switch; we have
        // to nudge it ourselves when the General pane grows/shrinks.
        guard let window = view.window else { return }
        let size = view.fittingSize
        let newContentRect = NSRect(origin: .zero, size: size)
        let newFrame = window.frameRect(forContentRect: newContentRect)
        let current = window.frame
        let target = NSRect(
            x: current.origin.x,
            y: current.origin.y + current.height - newFrame.height,
            width: newFrame.width,
            height: newFrame.height
        )
        window.setFrame(target, display: true, animate: animated)
    }

    private func syncDiagnosticsControlsFromEngine() {
        showDotSwitch.state = dragEngine.showDebugDot ? .on : .off
        yOffsetSlider.doubleValue = Double(dragEngine.titleBarYOffset)
        updateYOffsetValueLabel()
    }

    private func updateYOffsetValueLabel() {
        let value = Int(yOffsetSlider.doubleValue.rounded())
        yOffsetValueLabel.stringValue = "\(value) px"
    }

    @objc private func diagnoseModeChanged(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.syncDiagnosticsControlsFromEngine()
            self?.updateDiagnosticsVisibility(animated: true)
        }
    }

    @objc private func showDotToggled(_ sender: NSSwitch) {
        dragEngine.showDebugDot = (sender.state == .on)
    }

    @objc private func yOffsetSliderChanged(_ sender: NSSlider) {
        let snapped = sender.doubleValue.rounded()
        sender.doubleValue = snapped
        dragEngine.titleBarYOffset = CGFloat(snapped)
        updateYOffsetValueLabel()
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
        // Make the spacer view stretch.
        if row.arrangedSubviews.count >= 2 {
            row.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        return BuiltRow(view: row, title: titleLabel, subtitle: subtitleLabel)
    }
}
