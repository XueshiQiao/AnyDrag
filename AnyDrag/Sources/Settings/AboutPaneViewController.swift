import Cocoa

/// About pane: icon, name, version, copyright, update + repo + website links.
final class AboutPaneViewController: NSViewController {

    private let updateController: UpdateController
    private let checkUpdatesButton = NSButton(title: "", target: nil, action: nil)

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

        // Icon
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
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])
        self.view = view
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        checkUpdatesButton.isEnabled = updateController.canCheckForUpdates
    }

    // MARK: - Actions

    @objc private func checkForUpdates(_ sender: Any?) {
        updateController.checkForUpdates(sender)
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
