import Cocoa
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers

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

    // Excluded apps (blacklist)
    private var blacklistedApps: [BlacklistedApp] = []
    private let appsTableView = NSTableView()
    private let appsScrollView = NSScrollView()
    private let appsControl = NSSegmentedControl()

    // Diagnostics
    private let showDotSwitch = NSSwitch()
    private let yOffsetSlider = NSSlider()
    private let yOffsetValueLabel = NSTextField(labelWithString: "")
    private let yOffsetResetButton = NSButton()
    private let resizeInsetSlider = NSSlider()
    private let resizeInsetValueLabel = NSTextField(labelWithString: "")
    private let resizeInsetResetButton = NSButton()
    // Diagnostics is collapsed by default; these track the disclosure state.
    private var diagnosticsExpanded = false
    private weak var diagnosticsTriangle: NSButton?
    private weak var diagnosticsCard: NSView?

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
        blacklistedApps = Preferences.blacklistedApps()

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

        // ─── Excluded apps card ──────────────────────────────────────
        SettingsCardLayout.addSection(
            to: container,
            header: NSLocalizedString("blacklist.title", comment: ""),
            rows: [buildBlacklistContent()]
        )

        // ─── Diagnostics card (collapsed by default) ─────────────────
        addCollapsibleDiagnostics(to: container)

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

    // MARK: - Excluded apps (blacklist)

    /// The card body: an explanatory note, a fixed-height scrolling list of
    /// excluded apps, and a +/- control. Returned as a single composite row so
    /// the card draws no hairline separators between the three pieces.
    private func buildBlacklistContent() -> NSView {
        let note = SettingsRowBuilder.subLabel(NSLocalizedString("blacklist.note", comment: ""))
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        note.preferredMaxLayoutWidth = 400

        appsTableView.headerView = nil
        appsTableView.rowHeight = 34
        appsTableView.intercellSpacing = NSSize(width: 0, height: 2)
        appsTableView.allowsMultipleSelection = true
        appsTableView.allowsColumnResizing = false
        appsTableView.backgroundColor = .clear
        appsTableView.style = .inset
        appsTableView.dataSource = self
        appsTableView.delegate = self
        appsTableView.doubleAction = nil
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.resizingMask = .autoresizingMask
        appsTableView.addTableColumn(column)
        appsTableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        appsScrollView.documentView = appsTableView
        appsScrollView.hasVerticalScroller = true
        appsScrollView.autohidesScrollers = true
        appsScrollView.borderType = .bezelBorder
        appsScrollView.translatesAutoresizingMaskIntoConstraints = false
        appsScrollView.heightAnchor.constraint(equalToConstant: 120).isActive = true

        let plus = NSImage(systemSymbolName: "plus", accessibilityDescription: NSLocalizedString("blacklist.add", comment: ""))
        let minus = NSImage(systemSymbolName: "minus", accessibilityDescription: NSLocalizedString("blacklist.remove", comment: ""))
        appsControl.segmentCount = 2
        appsControl.setImage(plus, forSegment: 0)
        appsControl.setImage(minus, forSegment: 1)
        appsControl.setWidth(28, forSegment: 0)
        appsControl.setWidth(28, forSegment: 1)
        appsControl.segmentStyle = .smallSquare
        appsControl.trackingMode = .momentary
        appsControl.target = self
        appsControl.action = #selector(blacklistControlClicked(_:))
        appsControl.focusRingType = .none
        appsControl.setContentHuggingPriority(.required, for: .horizontal)

        let controlRow = NSStackView(views: [appsControl, NSView()])
        controlRow.orientation = .horizontal
        controlRow.spacing = 8
        controlRow.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)

        let block = NSStackView(views: [note, appsScrollView, controlRow])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 8
        block.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            note.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            appsScrollView.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            appsScrollView.trailingAnchor.constraint(equalTo: block.trailingAnchor),
            controlRow.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            controlRow.trailingAnchor.constraint(equalTo: block.trailingAnchor),
        ])

        updateRemoveEnabled()
        return block
    }

    @objc private func blacklistControlClicked(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: showAddMenu(from: sender)
        case 1: removeSelectedApps()
        default: break
        }
    }

    /// Pop the "add app" menu just below the + segment. Lists running, regular
    /// (Dock-visible) apps for one-click add, plus a Browse… item that opens an
    /// NSOpenPanel into /Applications for apps that aren't currently running.
    private func showAddMenu(from control: NSSegmentedControl) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let existing = Set(blacklistedApps.map { $0.bundleID })
        var seen = Set<String>()
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> BlacklistedApp? in
                guard let bundleID = app.bundleIdentifier,
                      bundleID != Bundle.main.bundleIdentifier,
                      !existing.contains(bundleID),
                      seen.insert(bundleID).inserted else { return nil }
                return BlacklistedApp(bundleID: bundleID, name: app.localizedName ?? bundleID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if running.isEmpty {
            let item = NSMenuItem(title: NSLocalizedString("blacklist.noRunningApps", comment: ""), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let header = NSMenuItem(title: NSLocalizedString("blacklist.runningApps", comment: ""), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for app in running {
                let item = NSMenuItem(title: app.name, action: #selector(addRunningApp(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = app
                if let icon = iconForApp(bundleID: app.bundleID)?.copy() as? NSImage {
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let browse = NSMenuItem(title: NSLocalizedString("blacklist.browse", comment: ""), action: #selector(browseForApp(_:)), keyEquivalent: "")
        browse.target = self
        menu.addItem(browse)

        let location = NSPoint(x: 0, y: control.bounds.height + 4)
        menu.popUp(positioning: nil, at: location, in: control)
    }

    @objc private func addRunningApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? BlacklistedApp else { return }
        addApp(app)
    }

    @objc private func browseForApp(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = NSLocalizedString("blacklist.choose", comment: "")
        guard panel.runModal() == .OK else { return }
        var changed = false
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { continue }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            if appendIfNew(BlacklistedApp(bundleID: bundleID, name: name)) { changed = true }
        }
        if changed { commitBlacklist() }
    }

    private func addApp(_ app: BlacklistedApp) {
        if appendIfNew(app) { commitBlacklist() }
    }

    /// Append the app unless its bundle id is already listed. Returns whether it
    /// was added, so multi-select adds can commit once instead of per item.
    @discardableResult
    private func appendIfNew(_ app: BlacklistedApp) -> Bool {
        guard !blacklistedApps.contains(where: { $0.bundleID == app.bundleID }) else { return false }
        blacklistedApps.append(app)
        return true
    }

    private func removeSelectedApps() {
        let indexes = appsTableView.selectedRowIndexes
        guard !indexes.isEmpty else { return }
        for index in indexes.sorted(by: >) where index < blacklistedApps.count {
            blacklistedApps.remove(at: index)
        }
        commitBlacklist()
    }

    /// Persist the list, push the bundle-id set to the live engine so the tap
    /// sees it immediately, then refresh the table and the remove button.
    private func commitBlacklist() {
        Preferences.setBlacklistedApps(blacklistedApps)
        dragEngine.setBlacklistedBundleIDs(Set(blacklistedApps.map { $0.bundleID }))
        appsTableView.reloadData()
        updateRemoveEnabled()
    }

    private func updateRemoveEnabled() {
        appsControl.setEnabled(appsTableView.selectedRow >= 0, forSegment: 1)
    }

    /// Best-effort icon for a bundle id: prefer a running instance's icon, then
    /// the on-disk app bundle, then a generic placeholder.
    private func iconForApp(bundleID: String) -> NSImage? {
        if let icon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon {
            return icon
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
    }

    // MARK: - Collapsible Diagnostics

    /// Add the Diagnostics section under a clickable disclosure header. Default
    /// state is collapsed; the expanded flag persists in UserDefaults. Because
    /// the Settings panes are not scroll views (the window is sized to each
    /// pane's fitting height), toggling re-fits the window.
    private func addCollapsibleDiagnostics(to container: NSStackView) {
        diagnosticsExpanded = UserDefaults.standard.bool(forKey: Preferences.Key.diagnosticsExpanded)

        let triangle = NSButton()
        triangle.bezelStyle = .disclosure
        triangle.setButtonType(.pushOnPushOff)
        triangle.title = ""
        triangle.state = diagnosticsExpanded ? .on : .off
        triangle.target = self
        triangle.action = #selector(toggleDiagnostics(_:))
        triangle.focusRingType = .none
        triangle.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = NSTextField(labelWithString: NSLocalizedString("Diagnostics", comment: ""))
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleLabel.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(toggleDiagnosticsFromLabel(_:)))
        )

        let headerRow = NSStackView(views: [triangle, titleLabel, NSView()])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 4
        headerRow.arrangedSubviews[2].setContentHuggingPriority(.defaultLow, for: .horizontal)
        container.addArrangedSubview(headerRow)
        headerRow.trailingAnchor.constraint(
            equalTo: container.trailingAnchor, constant: -container.edgeInsets.right
        ).isActive = true
        container.setCustomSpacing(6, after: headerRow)

        let card = SettingsSectionCard(rows: buildDiagnosticsRows())
        card.isHidden = !diagnosticsExpanded
        container.addArrangedSubview(card)
        card.trailingAnchor.constraint(
            equalTo: container.trailingAnchor, constant: -container.edgeInsets.right
        ).isActive = true
        container.setCustomSpacing(0, after: card)

        diagnosticsTriangle = triangle
        diagnosticsCard = card
    }

    @objc private func toggleDiagnostics(_ sender: NSButton) {
        // The disclosure button has already flipped its own state.
        setDiagnosticsExpanded(sender.state == .on)
    }

    @objc private func toggleDiagnosticsFromLabel(_ recognizer: NSGestureRecognizer) {
        setDiagnosticsExpanded(!diagnosticsExpanded)
    }

    private func setDiagnosticsExpanded(_ expanded: Bool) {
        diagnosticsExpanded = expanded
        diagnosticsTriangle?.state = expanded ? .on : .off
        diagnosticsCard?.isHidden = !expanded
        UserDefaults.standard.set(expanded, forKey: Preferences.Key.diagnosticsExpanded)
        resizeWindowToFitPane()
    }

    /// Resize the Settings window so it again fits this pane's content after the
    /// disclosure toggles. Width is left at whatever the window controller
    /// locked it to; only the height follows the new fitting size, top-aligned
    /// so the window grows/shrinks from the bottom edge.
    private func resizeWindowToFitPane() {
        guard let window = view.window else { return }
        view.layoutSubtreeIfNeeded()
        let targetHeight = view.fittingSize.height
        let currentContent = window.contentRect(forFrameRect: window.frame)
        let contentSize = NSSize(width: currentContent.width, height: targetHeight)
        let targetFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        let current = window.frame
        let topAligned = NSRect(
            x: current.origin.x,
            y: current.origin.y + current.height - targetFrame.height,
            width: targetFrame.width,
            height: targetFrame.height
        )
        window.setFrame(topAligned, display: true, animate: true)
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

// MARK: - Excluded apps table

extension GeneralPaneViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        blacklistedApps.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < blacklistedApps.count else { return nil }
        let app = blacklistedApps[row]
        let identifier = NSUserInterfaceItemIdentifier("BlacklistCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? BlacklistCellView)
            ?? BlacklistCellView(reuseIdentifier: identifier)
        cell.configure(name: app.name, bundleID: app.bundleID, icon: iconForApp(bundleID: app.bundleID))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveEnabled()
    }
}

/// One row in the excluded-apps list: icon + app name over its bundle id.
private final class BlacklistCellView: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let bundleLabel = NSTextField(labelWithString: "")

    init(reuseIdentifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = reuseIdentifier

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        bundleLabel.font = .systemFont(ofSize: 10)
        bundleLabel.textColor = .secondaryLabelColor
        bundleLabel.lineBreakMode = .byTruncatingMiddle
        bundleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [nameLabel, bundleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 0
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(textStack)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, bundleID: String, icon: NSImage?) {
        nameLabel.stringValue = name
        bundleLabel.stringValue = bundleID
        iconView.image = icon
    }
}
