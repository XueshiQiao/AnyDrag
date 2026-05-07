import Cocoa

/// Three-tab Settings window (General, Advanced, About) using NSToolbar to
/// switch panes, matching the macOS standard Settings UX.
///
/// The window is sized once to fit the tallest pane and never resizes when
/// switching tabs, so the chrome stays stable as the user clicks around.
final class PreferencesWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {

    private enum Tab: String {
        case general
        case advanced
        case about

        var label: String {
            switch self {
            case .general:  return NSLocalizedString("General", comment: "")
            case .advanced: return NSLocalizedString("Advanced", comment: "")
            case .about:    return NSLocalizedString("About", comment: "")
            }
        }

        var image: NSImage? {
            switch self {
            case .general:  return NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
            case .advanced: return NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
            case .about:    return NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
            }
        }
    }

    private let dragEngine: DragEngine
    private let updateController: UpdateController

    private var generalVC: GeneralPaneViewController
    private var advancedVC: AdvancedPaneViewController
    private var aboutVC: AboutPaneViewController

    private var currentTab: Tab = .general
    private var fixedContentWidth: CGFloat = 480

    init(dragEngine: DragEngine, updateController: UpdateController) {
        self.dragEngine = dragEngine
        self.updateController = updateController
        self.generalVC = GeneralPaneViewController(dragEngine: dragEngine)
        self.advancedVC = AdvancedPaneViewController(dragEngine: dragEngine)
        self.aboutVC = AboutPaneViewController(updateController: updateController)

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

        recomputeFixedWidth()
        select(.general, animated: false)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageChanged(_:)),
            name: .anyDragLanguageChanged,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func languageChanged(_ note: Notification) {
        // Defer one runloop tick — the popup that fired this is mid-action.
        DispatchQueue.main.async { [weak self] in
            self?.rebuildAfterLanguageChange()
        }
    }

    private func rebuildAfterLanguageChange() {
        generalVC = GeneralPaneViewController(dragEngine: dragEngine)
        advancedVC = AdvancedPaneViewController(dragEngine: dragEngine)
        aboutVC = AboutPaneViewController(updateController: updateController)

        if let toolbar = window?.toolbar {
            for item in toolbar.items {
                guard let tab = Tab(rawValue: item.itemIdentifier.rawValue) else { continue }
                item.label = tab.label
                item.paletteLabel = tab.label
            }
        }
        window?.title = NSLocalizedString("AnyDrag Settings", comment: "")
        recomputeFixedWidth()
        select(currentTab, animated: false)
    }

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

    // MARK: - Sizing

    /// Touch every pane's view so its constraints resolve, then pick the
    /// width that fits the widest of them. Called at init and after a language
    /// switch (where new strings can shift natural widths). Height is per-tab
    /// — see `select(_:)`.
    private func recomputeFixedWidth() {
        let panes: [NSView] = [generalVC.view, advancedVC.view, aboutVC.view]
        let widths = panes.map { $0.fittingSize.width }
        fixedContentWidth = widths.max() ?? 480
    }

    /// Switch to the named pane. Width is locked across tabs to keep the
    /// chrome stable; height follows the pane's natural fitting size.
    private func select(_ tab: Tab, animated: Bool = true) {
        currentTab = tab
        window?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(tab.rawValue)

        let newVC: NSViewController
        switch tab {
        case .general:  newVC = generalVC
        case .advanced: newVC = advancedVC
        case .about:    newVC = aboutVC
        }

        guard let window = window else { return }

        let paneHeight = newVC.view.fittingSize.height
        let contentSize = NSSize(width: fixedContentWidth, height: paneHeight)
        let targetFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        let current = window.frame
        let topAlignedFrame = NSRect(
            x: current.origin.x,
            y: current.origin.y + current.height - targetFrame.height,
            width: targetFrame.width,
            height: targetFrame.height
        )

        window.contentViewController = newVC
        if current.size != topAlignedFrame.size {
            window.setFrame(topAlignedFrame, display: true, animate: animated)
        }
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        guard let tab = Tab(rawValue: sender.itemIdentifier.rawValue) else { return }
        select(tab)
    }

    // MARK: - NSToolbarDelegate

    private static let allTabs: [Tab] = [.general, .advanced, .about]

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
