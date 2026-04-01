import Cocoa
import ServiceManagement

final class MenuBarController: NSObject {

    private var statusItem: NSStatusItem!
    private let dragEngine: DragEngine

    private let enabledKey = "AnyDragEnabled"
    private let modifierKey = "AnyDragModifier"
    private let launchAtLoginKey = "AnyDragLaunchAtLogin"

    init(dragEngine: DragEngine) {
        self.dragEngine = dragEngine
        super.init()
        setupStatusItem()
        loadPreferences()
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

        // Enabled toggle
        let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.tag = 100
        menu.addItem(enabledItem)

        menu.addItem(.separator())

        // Modifier key submenu
        let modifierItem = NSMenuItem(title: "Modifier Key", action: nil, keyEquivalent: "")
        let modifierSubmenu = NSMenu()

        for (index, mod) in ModifierKey.allCases.enumerated() {
            let item = NSMenuItem(title: mod.displayName, action: #selector(selectModifier(_:)), keyEquivalent: "")
            item.target = self
            item.tag = 200 + index
            item.representedObject = mod.rawValue
            modifierSubmenu.addItem(item)
        }

        modifierItem.submenu = modifierSubmenu
        menu.addItem(modifierItem)

        menu.addItem(.separator())

        // Launch at Login
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.tag = 300
        menu.addItem(loginItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit AnyDrag", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        return menu
    }

    // MARK: - Preferences

    private func loadPreferences() {
        let defaults = UserDefaults.standard

        // Enabled (default true)
        if defaults.object(forKey: enabledKey) == nil {
            defaults.set(true, forKey: enabledKey)
        }
        dragEngine.isEnabled = defaults.bool(forKey: enabledKey)

        // Modifier (default option)
        if let savedMod = defaults.string(forKey: modifierKey),
           let mod = ModifierKey(rawValue: savedMod) {
            dragEngine.modifierKey = mod
        } else {
            defaults.set(ModifierKey.option.rawValue, forKey: modifierKey)
            dragEngine.modifierKey = .option
        }
    }

    // MARK: - Actions

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        let newValue = !dragEngine.isEnabled
        dragEngine.isEnabled = newValue
        UserDefaults.standard.set(newValue, forKey: enabledKey)
    }

    @objc private func selectModifier(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mod = ModifierKey(rawValue: rawValue) else { return }
        dragEngine.modifierKey = mod
        UserDefaults.standard.set(mod.rawValue, forKey: modifierKey)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("AnyDrag: Failed to toggle launch at login: \(error)")
        }
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {

    func menuWillOpen(_ menu: NSMenu) {
        // Update checkmarks
        if let enabledItem = menu.item(withTag: 100) {
            enabledItem.state = dragEngine.isEnabled ? .on : .off
        }

        // Update modifier selection
        if let modifierItem = menu.item(withTitle: "Modifier Key"),
           let submenu = modifierItem.submenu {
            for item in submenu.items {
                if let rawValue = item.representedObject as? String {
                    item.state = (rawValue == dragEngine.modifierKey.rawValue) ? .on : .off
                }
            }
        }

        // Update launch at login
        if let loginItem = menu.item(withTag: 300) {
            loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }
    }
}
