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

        // ─── Language card ───────────────────────────────────────────
        SettingsCardLayout.addSection(
            to: container,
            header: NSLocalizedString("Language", comment: ""),
            rows: [buildLanguageRow()]
        )

        // ─── Accessibility + Launch card (no header) ─────────────────
        let launchRow = SettingsRowBuilder.feature(
            title: NSLocalizedString("Launch at Login", comment: ""),
            subtitle: nil,
            toggle: launchSwitch,
            target: self,
            action: #selector(launchAtLoginToggled(_:))
        )
        SettingsCardLayout.addSection(
            to: container,
            header: nil,
            rows: [buildAccessibilityRow(), launchRow.view]
        )

        // ─── Diagnostics card ────────────────────────────────────────
        SettingsCardLayout.addSection(
            to: container,
            header: NSLocalizedString("Diagnostics", comment: ""),
            rows: buildDiagnosticsRows(),
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

    /// Row with the popup left-aligned. NSPopUpButton has an intrinsic width
    /// based on its longest item, so wrapping it in a horizontal stack with a
    /// trailing spacer keeps it from stretching across the whole card.
    private func buildLanguageRow() -> NSView {
        let popup = buildLanguagePopup()
        let row = NSStackView(views: [popup, NSView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8
        row.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

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

    /// Build the rows that go inside the Diagnostics card. Each "row" here is
    /// either a simple control or a compound vertical stack (for slider
    /// blocks: title row + slider + hint).
    private func buildDiagnosticsRows() -> [NSView] {
        let advancedNote = SettingsRowBuilder.subLabel(NSLocalizedString("diagnostics.advanced.note", comment: ""))
        advancedNote.lineBreakMode = .byWordWrapping
        advancedNote.maximumNumberOfLines = 0
        advancedNote.preferredMaxLayoutWidth = 400

        let dotRow = SettingsRowBuilder.feature(
            title: NSLocalizedString("diagnostics.showDot", comment: ""),
            subtitle: NSLocalizedString("diagnostics.showDot.subtitle", comment: ""),
            toggle: showDotSwitch,
            target: self,
            action: #selector(showDotToggled(_:))
        )

        let yOffsetBlock = buildSliderBlock(
            title: NSLocalizedString("diagnostics.titleBarYOffset", comment: ""),
            slider: yOffsetSlider,
            sliderAction: #selector(yOffsetSliderChanged(_:)),
            valueLabel: yOffsetValueLabel,
            resetButton: yOffsetResetButton,
            resetAction: #selector(yOffsetResetTapped(_:)),
            hint: NSLocalizedString("diagnostics.titleBarYOffset.hint", comment: ""),
            min: 0, max: 40, tickMarks: 9
        )

        let resizeInsetBlock = buildSliderBlock(
            title: NSLocalizedString("diagnostics.resizeCornerInset", comment: ""),
            slider: resizeInsetSlider,
            sliderAction: #selector(resizeInsetSliderChanged(_:)),
            valueLabel: resizeInsetValueLabel,
            resetButton: resizeInsetResetButton,
            resetAction: #selector(resizeInsetResetTapped(_:)),
            hint: NSLocalizedString("diagnostics.resizeCornerInset.hint", comment: ""),
            min: Double(Preferences.resizeCornerInsetRange.lowerBound),
            max: Double(Preferences.resizeCornerInsetRange.upperBound),
            tickMarks: 7
        )

        return [advancedNote, dotRow.view, yOffsetBlock, resizeInsetBlock]
    }

    private func buildSliderBlock(
        title: String,
        slider: NSSlider,
        sliderAction: Selector,
        valueLabel: NSTextField,
        resetButton: NSButton,
        resetAction: Selector,
        hint: String,
        min: Double, max: Double, tickMarks: Int
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)

        valueLabel.font = .systemFont(ofSize: 11, weight: .medium)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        resetButton.title = NSLocalizedString("diagnostics.reset", comment: "")
        resetButton.target = self
        resetButton.action = resetAction
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.focusRingType = .none
        resetButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let titleRow = NSStackView(views: [titleLabel, NSView(), valueLabel, resetButton])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.distribution = .fill
        titleRow.spacing = 8
        titleRow.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)

        slider.minValue = min
        slider.maxValue = max
        slider.numberOfTickMarks = tickMarks
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true
        slider.target = self
        slider.action = sliderAction
        slider.focusRingType = .none

        let hintLabel = SettingsRowBuilder.subLabel(hint)
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.maximumNumberOfLines = 0
        hintLabel.preferredMaxLayoutWidth = 400

        let block = NSStackView(views: [titleRow, slider, hintLabel])
        block.orientation = .vertical
        // .fill so the title row and slider stretch to the block's width
        // (which the card constrains to the card width minus insets).
        block.alignment = .leading
        block.spacing = 6

        // The title row and slider need to stretch horizontally to look
        // right. NSStackView in `.leading` doesn't auto-stretch, so anchor
        // them explicitly to the block.
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        slider.translatesAutoresizingMaskIntoConstraints = false
        block.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleRow.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            titleRow.trailingAnchor.constraint(equalTo: block.trailingAnchor),
            slider.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: block.trailingAnchor),
        ])

        return block
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

}
