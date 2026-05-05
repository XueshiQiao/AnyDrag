import Cocoa

/// Two-tab Settings window (General + About) using NSToolbar to switch panes,
/// matching the macOS standard Settings UX (Safari, Finder, Mail).
final class PreferencesWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {

    private enum Tab: String {
        case general
        case about

        var label: String {
            switch self {
            case .general: return NSLocalizedString("General", comment: "")
            case .about:   return NSLocalizedString("About", comment: "")
            }
        }

        var image: NSImage? {
            switch self {
            case .general: return NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
            case .about:   return NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
            }
        }
    }

    private let dragEngine: DragEngine
    private let updateController: UpdateController

    private lazy var generalVC = GeneralPaneViewController(dragEngine: dragEngine)
    private lazy var aboutVC   = AboutPaneViewController(dragEngine: dragEngine, updateController: updateController)

    private var currentTab: Tab = .general

    init(dragEngine: DragEngine, updateController: UpdateController) {
        self.dragEngine = dragEngine
        self.updateController = updateController

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("AnyDrag Settings", comment: "")
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("AnyDragPreferences")

        super.init(window: window)

        window.delegate = self

        let toolbar = NSToolbar(identifier: "AnyDragPreferencesToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(Tab.general.rawValue)
        window.toolbar = toolbar
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .preference
        }

        select(.general, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Bring the window to front, creating it if necessary.
    func show() {
        guard let window = window else { return }
        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    /// Switch to the named pane. The window is resized to the pane's natural size.
    private func select(_ tab: Tab, animated: Bool = true) {
        currentTab = tab
        window?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(tab.rawValue)

        let newVC: NSViewController = (tab == .general) ? generalVC : aboutVC
        guard let window = window else { return }

        let targetSize = newVC.view.fittingSize
        let currentFrame = window.frame
        let targetFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: targetSize))
        let newOrigin = NSPoint(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y + currentFrame.height - targetFrame.height
        )
        let resized = NSRect(origin: newOrigin, size: targetFrame.size)

        window.contentViewController = newVC
        window.setFrame(resized, display: true, animate: animated)
        window.title = (tab == .general)
            ? NSLocalizedString("AnyDrag Settings", comment: "")
            : NSLocalizedString("About AnyDrag", comment: "")
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        guard let tab = Tab(rawValue: sender.itemIdentifier.rawValue) else { return }
        select(tab)
    }

    // MARK: - NSToolbarDelegate

    private static let allTabs: [Tab] = [.general, .about]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.allTabs.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = Tab(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.label
        item.paletteLabel = tab.label
        item.image = tab.image
        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        return item
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Closing should not terminate the app — main.swift uses an accessory app.
    }
}
