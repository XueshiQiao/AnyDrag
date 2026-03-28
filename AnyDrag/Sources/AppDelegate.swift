import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let permissionManager = PermissionManager()
    private var dragEngine: DragEngine?
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Do not activate the app (no window, no dock icon)
        NSApp.setActivationPolicy(.accessory)

        NSLog("AnyDrag: AXIsProcessTrusted=\(AXIsProcessTrusted())")
        permissionManager.ensurePermissions { [weak self] in
            NSLog("AnyDrag: permissions OK, starting")
            self?.startApp()
        }
    }

    private func startApp() {
        let engine = DragEngine()
        engine.start()
        dragEngine = engine

        menuBarController = MenuBarController(dragEngine: engine)
    }
}
