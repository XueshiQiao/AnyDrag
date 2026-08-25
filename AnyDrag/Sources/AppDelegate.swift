import Cocoa
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let log = FileLog("AppDelegate")

    private let permissionManager = PermissionManager()
    private let updateController = UpdateController()
    private var dragEngine: DragEngine?
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Install the user's language override before anything reads a
        // localized string (e.g. the permission alert).
        Preferences.applyLanguageOverride()

        // Initialize analytics ASAP so the session covers the entire app
        // lifetime, including the (possibly long) wait for Accessibility
        // permission. Fires `app_launched` and any `update_installed`.
        Analytics.start()

        // Detect a launch-to-launch permission grant (false → true) and fire
        // the funnel event. We compare against the previous launch's snapshot
        // and update the stored value here so the engine's runtime trust
        // observer doesn't need to know about analytics.
        emitPermissionGrantedIfNeeded()

        Self.log.info("launch — AXIsProcessTrusted=\(AXIsProcessTrusted())")
        permissionManager.ensurePermissions { [weak self] in
            Self.log.info("permissions OK, starting")
            // The permission may have been granted *during* this launch (the
            // alert path). Re-emit so first-grant-after-install is captured.
            self?.emitPermissionGrantedIfNeeded()
            self?.startApp()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave windows parked off-screen across a quit — the user would
        // have no way left to reach them.
        dragEngine?.workspaces.restoreAllWindows()
        Analytics.flush()
    }

    private func startApp() {
        Preferences.migrateLegacyKeysIfNeeded()

        let engine = DragEngine()
        Preferences.apply(to: engine)
        engine.start()
        dragEngine = engine

        menuBarController = MenuBarController(dragEngine: engine, updateController: updateController)

        // Put back anything a previous run left parked off-screen. Runs after
        // Accessibility is granted (we are inside `ensurePermissions`), and is
        // a no-op when the last run exited cleanly.
        WorkspaceStore.recoverOnLaunch()
        engine.workspaces.refresh()

        // Keep the registry roughly in step with reality. The prototype
        // refreshes on app activation rather than wiring up AXObservers —
        // crude, but it never runs on the drag path, which is the property
        // that actually matters.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak engine] _ in
            engine?.workspaces.refresh()
        }

        // Retry recovery whenever an app finishes launching.
        //
        // The launch sweep above can only rescue windows whose app is already
        // running. At login that is frequently false — AnyDrag starts early and
        // the app owning a parked window may still be coming up — and the
        // record is then correctly kept but nothing would ever act on it again
        // until the next launch. A window would sit off-screen for the rest of
        // the session with no sign anything was wrong.
        //
        // Cheap: it does nothing at all unless records are pending.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak engine] note in
            guard !WorkspaceStore.all.isEmpty else { return }
            let name = (note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.localizedName ?? "?"
            let result = WorkspaceStore.recoverOnLaunch()
            if result.restored > 0 {
                Self.log.info("recovered \(result.restored) parked window(s) after \(name) launched")
                engine?.workspaces.refresh()
            }
        }
    }

    /// Fires `permission_granted` once on the launch where the trust state
    /// flips false → true *with an observable prior state*. Idempotent.
    ///
    /// We deliberately do NOT fire when the key is absent: an already-authorized
    /// user upgrading to this integration would otherwise produce a spurious
    /// first-grant event. On absence we just record the snapshot and wait for
    /// a real transition next time. For the fresh-install flow, the launch
    /// path calls this twice — first before `ensurePermissions` (records
    /// `false` if not granted), then again after the user grants in the
    /// alert flow (sees the stored `false`, fires the event).
    private func emitPermissionGrantedIfNeeded() {
        let d = UserDefaults.standard
        let current = AXIsProcessTrusted()
        let priorObject = d.object(forKey: Preferences.Key.lastPermissionGranted)
        let hadPrior = (priorObject != nil)
        let prior = (priorObject as? Bool) ?? false
        if hadPrior && current && !prior {
            Analytics.trackPermissionGranted()
        }
        if !hadPrior || prior != current {
            d.set(current, forKey: Preferences.Key.lastPermissionGranted)
        }
    }
}
