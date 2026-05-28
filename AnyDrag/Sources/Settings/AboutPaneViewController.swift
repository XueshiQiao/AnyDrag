import Cocoa

/// About pane: icon, name, version, copyright, update + repo + website links.
final class AboutPaneViewController: NSViewController {

    private static let log = FileLog("Settings.About")

    private let updateController: UpdateController
    private let checkUpdatesButton = NSButton(title: "", target: nil, action: nil)
    private let analyticsCheckbox = NSButton()

    private static let githubURL  = URL(string: "https://github.com/XueshiQiao/AnyDrag")!
    private static let websiteURL = URL(string: "https://xueshi.dev")!

    init(updateController: UpdateController) {
        self.updateController = updateController
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 96),
            iconView.heightAnchor.constraint(equalToConstant: 96),
        ])
        stack.addArrangedSubview(iconView)

        // App name
        let bundle = Bundle.main
        let appName = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "AnyDrag"
        let nameLabel = NSTextField(labelWithString: appName)
        nameLabel.font = .systemFont(ofSize: 20, weight: .bold)
        stack.addArrangedSubview(nameLabel)

        // Version "1.2.4 (3)"
        let short = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
        let versionFormat = NSLocalizedString("about.version.format", comment: "")
        let versionLabel = NSTextField(labelWithString: String(format: versionFormat, short, build))
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(versionLabel)

        // Spacer
        stack.setCustomSpacing(16, after: versionLabel)

        // Check for Updates button
        checkUpdatesButton.title = NSLocalizedString("Check for Updates…", comment: "")
        checkUpdatesButton.bezelStyle = .rounded
        checkUpdatesButton.target = self
        checkUpdatesButton.action = #selector(checkForUpdates(_:))
        checkUpdatesButton.focusRingType = .none
        stack.addArrangedSubview(checkUpdatesButton)

        stack.setCustomSpacing(20, after: checkUpdatesButton)

        // Links
        let github = linkButton(
            title: NSLocalizedString("GitHub Repository", comment: ""),
            url: Self.githubURL
        )
        stack.addArrangedSubview(github)
        stack.setCustomSpacing(16, after: github)

        let websiteDesc = NSTextField(labelWithString: NSLocalizedString("about.website.description", comment: ""))
        websiteDesc.font = .systemFont(ofSize: 11)
        websiteDesc.textColor = .secondaryLabelColor
        stack.addArrangedSubview(websiteDesc)
        stack.setCustomSpacing(2, after: websiteDesc)

        stack.addArrangedSubview(linkButton(
            title: "xueshi.dev",
            url: Self.websiteURL
        ))

        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // Analytics opt-out — a small checkbox with the explanation as a
        // tertiary subtitle below. Deliberately understated: most users glance
        // at About once and move on, so we don't want the toggle to read as a
        // call to action.
        analyticsCheckbox.setButtonType(.switch)
        analyticsCheckbox.title = NSLocalizedString("about.analytics.toggle", comment: "")
        analyticsCheckbox.controlSize = .small
        analyticsCheckbox.target = self
        analyticsCheckbox.action = #selector(analyticsToggled(_:))
        analyticsCheckbox.focusRingType = .none
        stack.addArrangedSubview(analyticsCheckbox)
        stack.setCustomSpacing(2, after: analyticsCheckbox)

        let analyticsNote = NSTextField(labelWithString: NSLocalizedString("about.analytics.subtitle", comment: ""))
        analyticsNote.font = .systemFont(ofSize: 9)
        analyticsNote.textColor = .tertiaryLabelColor
        analyticsNote.alignment = .center
        analyticsNote.lineBreakMode = .byWordWrapping
        analyticsNote.maximumNumberOfLines = 0
        analyticsNote.preferredMaxLayoutWidth = 340
        stack.addArrangedSubview(analyticsNote)
        stack.setCustomSpacing(14, after: analyticsNote)

        // Copyright
        let copy = NSTextField(labelWithString: NSLocalizedString("about.copyright", comment: ""))
        copy.font = .systemFont(ofSize: 11)
        copy.textColor = .secondaryLabelColor
        stack.addArrangedSubview(copy)

        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
        ])
        self.view = view
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        checkUpdatesButton.isEnabled = updateController.canCheckForUpdates
        refreshAnalyticsSwitch()
    }

    private func refreshAnalyticsSwitch() {
        // Default `true` when the key is absent — matches the Analytics gate.
        let d = UserDefaults.standard
        let on = (d.object(forKey: Preferences.Key.analyticsEnabled) == nil)
            ? true
            : d.bool(forKey: Preferences.Key.analyticsEnabled)
        analyticsCheckbox.state = on ? .on : .off
    }

    // MARK: - Actions

    @objc private func checkForUpdates(_ sender: Any?) {
        updateController.checkForUpdates(sender)
    }

    @objc private func analyticsToggled(_ sender: NSButton) {
        let on = (sender.state == .on)
        let d = UserDefaults.standard
        let previous = (d.object(forKey: Preferences.Key.analyticsEnabled) == nil)
            ? true
            : d.bool(forKey: Preferences.Key.analyticsEnabled)
        // Fire the meta-event BEFORE persisting. `trackPreferenceChanged`
        // bypasses the opt-out gate for `analytics_enabled` so BOTH ON→OFF
        // and OFF→ON transitions reach the server.
        if previous != on {
            Analytics.trackPreferenceChanged(key: "analytics_enabled", value: String(on))
        }
        d.set(on, forKey: Preferences.Key.analyticsEnabled)
        // Flush so the OFF event reaches the server before the gate closes
        // for any subsequent activity in this session.
        if !on {
            Analytics.flush()
        }
    }

    @objc private func openGitHub(_ sender: Any?) {
        NSWorkspace.shared.open(Self.githubURL)
    }

    @objc private func openWebsite(_ sender: Any?) {
        NSWorkspace.shared.open(Self.websiteURL)
    }

    // MARK: - Helpers

    private func linkButton(title: String, url: URL) -> NSButton {
        let attr = NSMutableAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ])
        let button = NSButton()
        button.attributedTitle = attr
        button.isBordered = false
        button.bezelStyle = .inline
        button.target = self
        button.action = #selector(openLink(_:))
        button.identifier = NSUserInterfaceItemIdentifier(url.absoluteString)
        button.focusRingType = .none
        return button
    }

    @objc private func openLink(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }
}
