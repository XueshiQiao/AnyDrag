import Sparkle

final class UpdateController {

    let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Triggers a user-initiated update check (shows UI).
    @objc func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }

    /// Whether the updater is idle and ready to check.
    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }
}
