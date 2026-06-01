import AppKit
import Sparkle

/// Owns Sparkle's updater and bridges the menu-bar / About-pane
/// "Check for Updates…" actions to it.
///
/// AnyDrag is an accessory (`LSUIElement`) app, so it is never the frontmost
/// app on its own. Sparkle already activates background apps when showing
/// update UI (`SPUStandardUserDriver._activateApplication`), but on macOS 14+
/// `[NSApp activate]` is *cooperative* — the system routinely defers it when
/// another app is frontmost, so the update window opens behind it (issue #12).
/// Activation calls alone therefore don't fix it. As the user-driver delegate
/// we additionally force the window above other apps with
/// `orderFrontRegardless()`, which ignores app-active state — but only for
/// user-initiated checks, so scheduled background reminders stay gentle.
final class UpdateController: NSObject, SPUStandardUserDriverDelegate {

    private var updaterController: SPUStandardUpdaterController!

    /// True while a *user-initiated* update session is in flight. Gates the
    /// front-ordering: `standardUserDriverWillShowModalAlert()` carries no
    /// state, and a scheduled background check that errors mid-download also
    /// routes through it — we don't want that to jump in front.
    private var userInitiatedSession = false

    /// Briefly re-orders the update window to the front after Sparkle presents
    /// it. Lives in `.common` runloop modes so it also fires inside a modal
    /// alert's `runModal` loop. Invalidated when the session ends.
    private var raiseTimer: Timer?

    override init() {
        super.init()
        // `self` is the user-driver delegate, so the controller must be built
        // after `super.init()`. Sparkle holds the delegate weakly; this
        // instance is retained by AppDelegate for the app's lifetime.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
    }

    /// Triggers a user-initiated update check (shows UI).
    @objc func checkForUpdates(_ sender: Any?) {
        // Both call sites (menu bar, About pane) are explicit user actions, but
        // only mark a user-initiated session if a check will actually start.
        // `checkForUpdates` no-ops when the updater is busy/disabled without
        // ending a session, so an unconditional `true` could linger and later
        // wrongly front a scheduled background alert. Assigning (not |=) also
        // clears any stale `true`.
        userInitiatedSession = canCheckForUpdates
        updaterController.checkForUpdates(sender)

        // When an update window is ALREADY on screen, Sparkle re-focuses the
        // existing window (`showUpdateInFocus`) without calling any user-driver
        // delegate hook, so we raise it here. Harmless for a fresh check — no
        // Sparkle window exists yet; the delegate hooks raise that one.
        if userInitiatedSession {
            bringUpdateWindowToFront()
        }
    }

    /// Whether the updater is idle and ready to check.
    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    // MARK: - SPUStandardUserDriverDelegate

    /// Fired right before the "update available" window is shown. Front-order
    /// for user-initiated checks; scheduled background checks keep Sparkle's
    /// default (gentle, non-focus-stealing) behavior. Also re-syncs
    /// `userInitiatedSession` to Sparkle's own notion so a scheduled session
    /// can't inherit a stale `true` from a prior user check.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        userInitiatedSession = state.userInitiated
        if state.userInitiated {
            bringUpdateWindowToFront()
        }
    }

    /// Fired before modal alerts ("You're up to date", errors). The
    /// up-to-date alert does NOT go through `…WillHandleShowingUpdate` (there's
    /// no update to show), so we rely on the session flag set in
    /// `checkForUpdates(_:)` to front-order it for user-initiated checks while
    /// staying quiet for a scheduled session that errored mid-download.
    func standardUserDriverWillShowModalAlert() {
        if userInitiatedSession {
            bringUpdateWindowToFront()
        }
    }

    /// End of an update session — stop re-ordering and reset the flag so the
    /// next (possibly scheduled) session starts from a quiet baseline.
    func standardUserDriverWillFinishUpdateSession() {
        userInitiatedSession = false
        raiseTimer?.invalidate()
        raiseTimer = nil
    }

    // MARK: - Front-ordering

    /// Activate (aggressively — the pre-macOS-14 API still steals focus more
    /// reliably than the cooperative one) and then raise the update window
    /// above other apps. The window isn't on screen yet when this delegate
    /// fires (Sparkle shows it right after), and modal alerts block the main
    /// queue, so we poll briefly via a `.common`-mode timer rather than a
    /// single `DispatchQueue.main.async`.
    private func bringUpdateWindowToFront() {
        NSApp.activate(ignoringOtherApps: true)

        raiseTimer?.invalidate()
        var fires = 0
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            fires += 1
            self?.raiseUpdateWindows()
            if fires >= 4 {   // ~0.2s — long enough for the window to appear,
                timer.invalidate()  // short enough not to fight the user.
                self?.raiseTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        raiseTimer = timer
    }

    /// Brings Sparkle's visible update/alert window(s) above other apps' windows
    /// regardless of whether AnyDrag is the active app. We raise every visible
    /// window EXCEPT AnyDrag's own (Preferences, the tiling panel, gesture
    /// overlays) — what's left on screen during a check is Sparkle's. Excluding
    /// by owner (rather than by "newly appeared") also covers the focus-restore
    /// path, where Sparkle re-raises a window that was already on screen.
    private func raiseUpdateWindows() {
        for window in NSApp.windows where window.isVisible && !isOwnedByAnyDrag(window) {
            window.orderFrontRegardless()
        }
    }

    /// A window "belongs to AnyDrag" if it's one of our own NSWindow/NSPanel
    /// subclasses (tiling panel, overlays) or a plain window we drive via our
    /// own controller (Preferences). Sparkle's windows live in its framework
    /// bundle, and AppKit's NSAlert panel in AppKit's — neither matches.
    private func isOwnedByAnyDrag(_ window: NSWindow) -> Bool {
        if Bundle(for: type(of: window)) == .main { return true }
        if let controller = window.windowController,
           Bundle(for: type(of: controller)) == .main { return true }
        return false
    }
}
