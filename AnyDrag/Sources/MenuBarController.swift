import Cocoa
import ServiceManagement

final class MenuBarController: NSObject {

    private var statusItem: NSStatusItem!
    private let dragEngine: DragEngine
    private let updateController: UpdateController

    private let enabledKey = "AnyDragEnabled"
    private let modifierKey = "AnyDragModifier"
    private let launchAtLoginKey = "AnyDragLaunchAtLogin"
    private let middleActionKey = "AnyDragMiddleAction"
    private let legacyMiddleClickDragKey = "AnyDragMiddleClickDrag"  // pre-MiddleAction bool

    init(dragEngine: DragEngine, updateController: UpdateController) {
        self.dragEngine = dragEngine
        self.updateController = updateController
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

        // Usage tips (placeholder — updated dynamically in menuWillOpen)
        for key in ["tip.drag", "tip.maximize", "tip.tiling"] {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.tag = 500 + ["tip.drag", "tip.maximize", "tip.tiling"].firstIndex(of: key)!
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Enabled toggle
        let enabledItem = NSMenuItem(title: NSLocalizedString("Enabled", comment: ""), action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.tag = 100
        menu.addItem(enabledItem)

        menu.addItem(.separator())

        // Modifier key submenu
        let modifierItem = NSMenuItem(title: NSLocalizedString("Modifier Key", comment: ""), action: nil, keyEquivalent: "")
        let modifierSubmenu = NSMenu()

        for (index, mod) in ModifierKey.allCases.enumerated() {
            let item = NSMenuItem(title: mod.displayName, action: #selector(selectModifier(_:)), keyEquivalent: "")
            item.target = self
            item.tag = 200 + index
            item.representedObject = mod.rawValue
            modifierSubmenu.addItem(item)
        }

        modifierItem.submenu = modifierSubmenu
        modifierItem.tag = 400
        menu.addItem(modifierItem)

        // Middle-click action submenu (Off / Drag window / Tile by direction)
        let middleActionItem = NSMenuItem(title: NSLocalizedString("Middle-click action", comment: ""), action: nil, keyEquivalent: "")
        let middleActionSubmenu = NSMenu()
        for (index, action) in MiddleAction.allCases.enumerated() {
            let item = NSMenuItem(title: action.displayName, action: #selector(selectMiddleAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = 700 + index
            item.representedObject = action.rawValue
            middleActionSubmenu.addItem(item)
        }
        middleActionItem.submenu = middleActionSubmenu
        middleActionItem.tag = 700
        menu.addItem(middleActionItem)

        menu.addItem(.separator())

        // Launch at Login
        let loginItem = NSMenuItem(title: NSLocalizedString("Launch at Login", comment: ""), action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.tag = 300
        menu.addItem(loginItem)

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

        // Middle-click action (default off). Migrate the old bool preference if present.
        if let saved = defaults.string(forKey: middleActionKey),
           let action = MiddleAction(rawValue: saved) {
            dragEngine.middleAction = action
        } else if defaults.object(forKey: legacyMiddleClickDragKey) != nil {
            let migrated: MiddleAction = defaults.bool(forKey: legacyMiddleClickDragKey) ? .dragWindow : .off
            dragEngine.middleAction = migrated
            defaults.set(migrated.rawValue, forKey: middleActionKey)
            defaults.removeObject(forKey: legacyMiddleClickDragKey)
        } else {
            dragEngine.middleAction = .off
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

    @objc private func selectMiddleAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = MiddleAction(rawValue: raw) else { return }
        dragEngine.middleAction = action
        UserDefaults.standard.set(action.rawValue, forKey: middleActionKey)
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
        // Update usage tips with current modifier key
        let sym = dragEngine.modifierKey.symbol
        let tipKeys = ["tip.drag", "tip.maximize", "tip.tiling"]
        for (i, key) in tipKeys.enumerated() {
            if let item = menu.item(withTag: 500 + i) {
                item.title = String(format: NSLocalizedString(key, comment: ""), sym)
            }
        }

        // Update checkmarks
        if let enabledItem = menu.item(withTag: 100) {
            enabledItem.state = dragEngine.isEnabled ? .on : .off
        }

        // Update modifier selection
        if let modifierItem = menu.item(withTag: 400),
           let submenu = modifierItem.submenu {
            for item in submenu.items {
                if let rawValue = item.representedObject as? String {
                    item.state = (rawValue == dragEngine.modifierKey.rawValue) ? .on : .off
                }
            }
        }

        // Update middle-click action selection
        if let middleActionItem = menu.item(withTag: 700),
           let submenu = middleActionItem.submenu {
            for item in submenu.items {
                if let raw = item.representedObject as? String {
                    item.state = (raw == dragEngine.middleAction.rawValue) ? .on : .off
                }
            }
        }

        // Update launch at login
        if let loginItem = menu.item(withTag: 300) {
            loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }

        // Update check-for-updates availability
        if let updateItem = menu.item(withTag: 600) {
            updateItem.isEnabled = updateController.canCheckForUpdates
        }
    }
}
