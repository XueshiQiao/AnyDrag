import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let log = FileLog("AppDelegate")

    private let permissionManager = PermissionManager()
    private let updateController = UpdateController()
    private var dragEngine: DragEngine?
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        Self.log.info("launch — AXIsProcessTrusted=\(AXIsProcessTrusted())")
        permissionManager.ensurePermissions { [weak self] in
            Self.log.info("permissions OK, starting")
            self?.startApp()
        }
    }

    private func startApp() {
        Preferences.migrateLegacyKeysIfNeeded()

        let engine = DragEngine()
        Preferences.apply(to: engine)
        engine.start()
        dragEngine = engine

        menuBarController = MenuBarController(dragEngine: engine, updateController: updateController)
    }
}
