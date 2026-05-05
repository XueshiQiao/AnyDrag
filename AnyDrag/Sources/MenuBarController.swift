import Cocoa

final class MenuBarController: NSObject {

    private var statusItem: NSStatusItem!
    private let dragEngine: DragEngine
    private let updateController: UpdateController
    private lazy var preferencesWindowController = PreferencesWindowController(
        dragEngine: dragEngine,
        updateController: updateController
    )

    init(dragEngine: DragEngine, updateController: UpdateController) {
        self.dragEngine = dragEngine
        self.updateController = updateController
        super.init()
        setupStatusItem()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: "AnyDrag")
        }

        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // App name and version
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let aboutItem = NSMenuItem(title: "AnyDrag v\(version)", action: nil, keyEquivalent: "")
        aboutItem.isEnabled = false
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        // Usage tips (placeholder — updated dynamically in menuWillOpen)
        for (i, _) in tipKeys.enumerated() {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.tag = 500 + i
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Enabled (master toggle)
        let enabledItem = NSMenuItem(title: NSLocalizedString("Enabled", comment: ""), action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.tag = 100
        menu.addItem(enabledItem)

        menu.addItem(.separator())

        // Settings…
        let settingsItem = NSMenuItem(title: NSLocalizedString("Settings…", comment: ""), action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Feedback
        let feedbackItem = NSMenuItem(title: NSLocalizedString("Feedback…", comment: ""), action: #selector(openFeedback(_:)), keyEquivalent: "")
        feedbackItem.target = self
        menu.addItem(feedbackItem)

        // Check for Updates
        let updateItem = NSMenuItem(title: NSLocalizedString("Check for Updates…", comment: ""), action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = self
        updateItem.tag = 600
        menu.addItem(updateItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: NSLocalizedString("Quit AnyDrag", comment: ""), action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        return menu
    }

    // Tip key, the feature toggle that gates it (nil = always show).
    private let tipKeys: [(key: String, gate: (DragEngine) -> Bool)] = [
        ("tip.drag",     { $0.dragEnabled }),
        ("tip.maximize", { $0.maximizeEnabled }),
        ("tip.tiling",   { $0.tilingEnabled }),
    ]

    // MARK: - Actions

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        let newValue = !dragEngine.isEnabled
        dragEngine.isEnabled = newValue
        UserDefaults.standard.set(newValue, forKey: Preferences.Key.enabled)
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        preferencesWindowController.show()
    }

    @objc private func openFeedback(_ sender: NSMenuItem) {
        guard let url = URL(string: "https://xueshasoho.feishu.cn/share/base/form/shrcnZK4KXsAg0w80ERWkf1WoXc") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        updateController.checkForUpdates(sender)
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {

    func menuWillOpen(_ menu: NSMenu) {
        // Update usage tips with current modifier symbol; hide tips whose
        // feature is currently disabled.
        let sym = dragEngine.modifiers.symbol
        for (i, entry) in tipKeys.enumerated() {
            guard let item = menu.item(withTag: 500 + i) else { continue }
            let visible = entry.gate(dragEngine)
            item.isHidden = !visible
            if visible {
                item.title = String(format: NSLocalizedString(entry.key, comment: ""), sym)
            }
        }

        // Update master Enabled checkmark
        if let enabledItem = menu.item(withTag: 100) {
            enabledItem.state = dragEngine.isEnabled ? .on : .off
        }

        // Update check-for-updates availability
        if let updateItem = menu.item(withTag: 600) {
            updateItem.isEnabled = updateController.canCheckForUpdates
        }
    }
}
