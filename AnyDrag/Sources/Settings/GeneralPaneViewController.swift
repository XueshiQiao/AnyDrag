import Cocoa
import ApplicationServices
import ServiceManagement

private let log = FileLog("Settings.General")

/// General settings pane: language, launch-at-login, and the diagnostics
/// section. Customization of how AnyDrag itself behaves (modifier keys,
/// per-feature toggles, middle-click action) lives in the Advanced pane.
final class GeneralPaneViewController: NSViewController {

    private let dragEngine: DragEngine

    private let launchSwitch = NSSwitch()

    // Accessibility permission row
    private let permissionDot = NSImageView()
    private let permissionStatusLabel = NSTextField(labelWithString: "")
    private let permissionGrantButton = NSButton()

    // Diagnostics
    private let diagnosticsContainer = NSStackView()
    private let showDotSwitch = NSSwitch()
    private let yOffsetSlider = NSSlider()
    private let yOffsetValueLabel = NSTextField(labelWithString: "")
    private let yOffsetResetButton = NSButton()
    private let resizeInsetSlider = NSSlider()
    private let resizeInsetValueLabel = NSTextField(labelWithString: "")
    private let resizeInsetResetButton = NSButton()

    private var trustObserver: NSObjectProtocol?
    private var trustRefreshTasks: [DispatchWorkItem] = []

    init(dragEngine: DragEngine) {
        self.dragEngine = dragEngine
        super.init(nibName: nil, bundle: nil)
        // Listen to the same distributed AX-trust-changed notification the
        // engine uses. Fires only on actual AX state change (not on every
        // app activation).
        trustObserver = DistributedNotificationCenter.default().addObserver(
            forName: .anyDragAXTrustChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleTrustRefresh()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observer = trustObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        trustRefreshTasks.forEach { $0.cancel() }
    }

    /// Staircase of refreshes after the AX-trust notification fires.
    /// `AXIsProcessTrusted()` (our single trust oracle — see
    /// `PermissionManager`) lags the System Settings toggle by a variable
    /// amount, so we re-check at multiple delays instead of a single
    /// 250ms shot. The DragEngine's always-on 5s backstop catches anything
    /// past 2500ms.
    private func scheduleTrustRefresh() {
        trustRefreshTasks.forEach { $0.cancel() }
        trustRefreshTasks.removeAll()
        let delaysMs: [Int] = [250, 1000, 2500]
        for delay in delaysMs {
            let task = DispatchWorkItem { [weak self] in
                self?.updateAccessibilityRow()
            }
            trustRefreshTasks.append(task)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: task)
        }
    }

    override func loadView() {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 14
        container.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        container.translatesAutoresizingMaskIntoConstraints = false

        // Language
        container.addArrangedSubview(sectionHeader(NSLocalizedString("Language", comment: "")))
        let langPopup = buildLanguagePopup()
        container.addArrangedSubview(langPopup)
        container.setCustomSpacing(18, after: langPopup)
        container.addArrangedSubview(separator())

        // Accessibility permission status
        container.addArrangedSubview(buildAccessibilityRow())

        // Launch at Login
        let launchRow = featureRow(
            title: NSLocalizedString("Launch at Login", comment: ""),
            subtitle: nil,
            toggle: launchSwitch,
            action: #selector(launchAtLoginToggled(_:))
        )
        container.addArrangedSubview(launchRow.view)

        // Diagnostics
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

    private func refreshFromState() {
        launchSwitch.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        updateAccessibilityRow()
        syncDiagnosticsControlsFromEngine()
    }

    // MARK: - Accessibility permission

    private func buildAccessibilityRow() -> NSView {
        let titleLabel = NSTextField(labelWithString: NSLocalizedString("accessibility.row.title", comment: ""))
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)

        let dotConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        permissionDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(dotConfig)
        permissionDot.imageScaling = .scaleProportionallyUpOrDown
        permissionDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            permissionDot.widthAnchor.constraint(equalToConstant: 10),
            permissionDot.heightAnchor.constraint(equalToConstant: 10),
        ])

        permissionStatusLabel.font = .systemFont(ofSize: NSFont.systemFontSize)

        permissionGrantButton.title = NSLocalizedString("accessibility.grantButton", comment: "")
        permissionGrantButton.bezelStyle = .rounded
        permissionGrantButton.controlSize = .small
        permissionGrantButton.target = self
        permissionGrantButton.action = #selector(grantTapped(_:))
        permissionGrantButton.focusRingType = .none
        permissionGrantButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let statusStack = NSStackView(views: [permissionDot, permissionStatusLabel, permissionGrantButton])
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 6

        let row = NSStackView(views: [titleLabel, NSView(), statusStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8
        row.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func updateAccessibilityRow() {
        let granted = AXIsProcessTrusted()
        permissionDot.contentTintColor = granted ? .systemGreen : .tertiaryLabelColor
        permissionStatusLabel.stringValue = granted
            ? NSLocalizedString("accessibility.granted", comment: "")
            : NSLocalizedString("accessibility.notGranted", comment: "")
        permissionStatusLabel.textColor = .secondaryLabelColor
        permissionGrantButton.isHidden = granted
    }

    @objc private func grantTapped(_ sender: NSButton) {
        PermissionManager.openAccessibilitySettings()
    }

    // MARK: - Language

    private func buildLanguagePopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.target = self
        popup.action = #selector(languageChanged(_:))
        popup.focusRingType = .none

        let followItem = NSMenuItem(
            title: NSLocalizedString("language.followSystem", comment: ""),
            action: nil,
            keyEquivalent: ""
        )
        followItem.representedObject = NSNull()
        popup.menu?.addItem(followItem)

        if !LocalizationOverride.supportedCodes.isEmpty {
            popup.menu?.addItem(.separator())
            for code in LocalizationOverride.supportedCodes {
                let item = NSMenuItem(
                    title: LocalizationOverride.nativeName(for: code),
                    action: nil,
                    keyEquivalent: ""
                )
                item.representedObject = code
                popup.menu?.addItem(item)
            }
        }

        let saved = UserDefaults.standard.string(forKey: Preferences.Key.languageOverride) ?? ""
        if saved.isEmpty {
            popup.select(followItem)
        } else if let item = popup.menu?.items.first(where: { ($0.representedObject as? String) == saved }) {
            popup.select(item)
        } else {
            popup.select(followItem)
        }
        return popup
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let code = sender.selectedItem?.representedObject as? String  // nil for "Follow System"
        Preferences.setLanguageOverride(code)
    }

    // MARK: - Diagnostics

    private func buildDiagnosticsSection() {
        diagnosticsContainer.orientation = .vertical
        diagnosticsContainer.alignment = .leading
        diagnosticsContainer.spacing = 10
        diagnosticsContainer.translatesAutoresizingMaskIntoConstraints = false

        diagnosticsContainer.addArrangedSubview(separator())
        diagnosticsContainer.addArrangedSubview(sectionHeader(NSLocalizedString("Diagnostics", comment: "")))

        let advancedNote = subLabel(NSLocalizedString("diagnostics.advanced.note", comment: ""))
        advancedNote.lineBreakMode = .byWordWrapping
        advancedNote.maximumNumberOfLines = 0
        advancedNote.preferredMaxLayoutWidth = 432
        diagnosticsContainer.addArrangedSubview(advancedNote)

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

        let title = NSTextField(labelWithString: NSLocalizedString("diagnostics.titleBarYOffset", comment: ""))
        title.font = .systemFont(ofSize: NSFont.systemFontSize)

        yOffsetValueLabel.font = .systemFont(ofSize: 11, weight: .medium)
        yOffsetValueLabel.textColor = .secondaryLabelColor
        yOffsetValueLabel.alignment = .right
        yOffsetValueLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        yOffsetResetButton.title = NSLocalizedString("diagnostics.reset", comment: "")
        yOffsetResetButton.target = self
        yOffsetResetButton.action = #selector(yOffsetResetTapped(_:))
        yOffsetResetButton.bezelStyle = .rounded
        yOffsetResetButton.controlSize = .small
        yOffsetResetButton.focusRingType = .none
        yOffsetResetButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let titleRow = NSStackView(views: [title, NSView(), yOffsetValueLabel, yOffsetResetButton])
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
        yOffsetSlider.numberOfTickMarks = 9
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
        // Without a width hint, wordWrap-mode NSTextField intrinsic-sizes to
        // a single long line and pushes the container wider than the pane.
        hint.preferredMaxLayoutWidth = 420
        diagnosticsContainer.addArrangedSubview(hint)

        // ─── Resize corner inset slider ────────────────────────────────
        let riTitle = NSTextField(labelWithString: NSLocalizedString("diagnostics.resizeCornerInset", comment: ""))
        riTitle.font = .systemFont(ofSize: NSFont.systemFontSize)

        resizeInsetValueLabel.font = .systemFont(ofSize: 11, weight: .medium)
        resizeInsetValueLabel.textColor = .secondaryLabelColor
        resizeInsetValueLabel.alignment = .right
        resizeInsetValueLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        resizeInsetResetButton.title = NSLocalizedString("diagnostics.reset", comment: "")
        resizeInsetResetButton.target = self
        resizeInsetResetButton.action = #selector(resizeInsetResetTapped(_:))
        resizeInsetResetButton.bezelStyle = .rounded
        resizeInsetResetButton.controlSize = .small
        resizeInsetResetButton.focusRingType = .none
        resizeInsetResetButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let riTitleRow = NSStackView(views: [riTitle, NSView(), resizeInsetValueLabel, resizeInsetResetButton])
        riTitleRow.orientation = .horizontal
        riTitleRow.alignment = .centerY
        riTitleRow.distribution = .fill
        riTitleRow.spacing = 8
        riTitleRow.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)
        diagnosticsContainer.addArrangedSubview(riTitleRow)
        riTitleRow.translatesAutoresizingMaskIntoConstraints = false
        riTitleRow.leadingAnchor.constraint(equalTo: diagnosticsContainer.leadingAnchor).isActive = true
        riTitleRow.trailingAnchor.constraint(equalTo: diagnosticsContainer.trailingAnchor).isActive = true

        resizeInsetSlider.minValue = Double(Preferences.resizeCornerInsetRange.lowerBound)
        resizeInsetSlider.maxValue = Double(Preferences.resizeCornerInsetRange.upperBound)
        resizeInsetSlider.numberOfTickMarks = 7
        resizeInsetSlider.allowsTickMarkValuesOnly = false
        resizeInsetSlider.isContinuous = true
        resizeInsetSlider.target = self
        resizeInsetSlider.action = #selector(resizeInsetSliderChanged(_:))
        resizeInsetSlider.focusRingType = .none
        resizeInsetSlider.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsContainer.addArrangedSubview(resizeInsetSlider)
        resizeInsetSlider.leadingAnchor.constraint(equalTo: diagnosticsContainer.leadingAnchor).isActive = true
        resizeInsetSlider.trailingAnchor.constraint(equalTo: diagnosticsContainer.trailingAnchor).isActive = true

        let riHint = subLabel(NSLocalizedString("diagnostics.resizeCornerInset.hint", comment: ""))
        riHint.lineBreakMode = .byWordWrapping
        riHint.maximumNumberOfLines = 0
        riHint.preferredMaxLayoutWidth = 420
        diagnosticsContainer.addArrangedSubview(riHint)
    }

    private func syncDiagnosticsControlsFromEngine() {
        showDotSwitch.state = dragEngine.showDebugDot ? .on : .off
        yOffsetSlider.doubleValue = Double(dragEngine.titleBarYOffset)
        updateYOffsetValueLabel()
        resizeInsetSlider.doubleValue = Double(dragEngine.resizeCornerInset)
        updateResizeInsetValueLabel()
    }

    private func updateYOffsetValueLabel() {
        let value = Int(yOffsetSlider.doubleValue.rounded())
        yOffsetValueLabel.stringValue = "\(value) px"
        let isAtDefault = CGFloat(value) == Preferences.defaultTitleBarYOffset
        yOffsetResetButton.isEnabled = !isAtDefault
    }

    private func updateResizeInsetValueLabel() {
        let value = Int(resizeInsetSlider.doubleValue.rounded())
        resizeInsetValueLabel.stringValue = "\(value) px"
        let isAtDefault = CGFloat(value) == Preferences.defaultResizeCornerInset
        resizeInsetResetButton.isEnabled = !isAtDefault
    }

    @objc private func showDotToggled(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        dragEngine.showDebugDot = on
        UserDefaults.standard.set(on, forKey: Preferences.Key.showDebugDot)
    }

    @objc private func yOffsetSliderChanged(_ sender: NSSlider) {
        let snapped = sender.doubleValue.rounded()
        sender.doubleValue = snapped
        dragEngine.titleBarYOffset = CGFloat(snapped)
        UserDefaults.standard.set(snapped, forKey: Preferences.Key.titleBarYOffset)
        updateYOffsetValueLabel()
    }

    @objc private func yOffsetResetTapped(_ sender: NSButton) {
        let defaultValue = Preferences.defaultTitleBarYOffset
        yOffsetSlider.doubleValue = Double(defaultValue)
        dragEngine.titleBarYOffset = defaultValue
        UserDefaults.standard.set(Double(defaultValue), forKey: Preferences.Key.titleBarYOffset)
        updateYOffsetValueLabel()
    }

    @objc private func resizeInsetSliderChanged(_ sender: NSSlider) {
        let snapped = sender.doubleValue.rounded()
        sender.doubleValue = snapped
        dragEngine.resizeCornerInset = CGFloat(snapped)
        UserDefaults.standard.set(snapped, forKey: Preferences.Key.resizeCornerInset)
        updateResizeInsetValueLabel()
    }

    @objc private func resizeInsetResetTapped(_ sender: NSButton) {
        let defaultValue = Preferences.defaultResizeCornerInset
        resizeInsetSlider.doubleValue = Double(defaultValue)
        dragEngine.resizeCornerInset = defaultValue
        UserDefaults.standard.set(Double(defaultValue), forKey: Preferences.Key.resizeCornerInset)
        updateResizeInsetValueLabel()
    }

    // MARK: - Launch at Login

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
            // Allow up to 2 lines so long descriptions don't push the toggle
            // out of the row.
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
