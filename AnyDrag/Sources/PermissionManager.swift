import Cocoa
import ApplicationServices

final class PermissionManager {

    var allGranted: Bool { AXIsProcessTrusted() }

    /// Blocks on a background timer until Accessibility is granted, then
    /// calls `completion` on the main thread.
    func ensurePermissions(completion: @escaping () -> Void) {
        if allGranted {
            completion()
            return
        }

        showPermissionAlert()

        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.allGranted {
                timer.invalidate()
                completion()
            }
        }
    }

    // MARK: - Private

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("permission.title", comment: "")
        alert.informativeText = NSLocalizedString("permission.message", comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("permission.openSettings", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("permission.quit", comment: ""))

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        } else {
            NSApp.terminate(nil)
        }
    }

    private func openAccessibilitySettings() {
        Self.openAccessibilitySettings()
    }

    /// Open System Settings → Privacy & Security → Accessibility. Shared by
    /// the launch-time permission alert and the in-app permission row.
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Trust oracle
    //
    // We used to maintain a separate `probeAccessibilityTrust()` that
    // attempted a throwaway `CGEvent.tapCreate(.listenOnly, leftMouseDown,
    // .cgSessionEventTap)` and treated success as "AX granted". The idea
    // (commit d381c14) was that tap creation gives a synchronous answer
    // without the TCC cache lag that `AXIsProcessTrusted()` has on grant.
    //
    // On macOS 14/15 that probe is unreliable in *both* directions:
    //   - It returns true even when AX has never been granted (likely
    //     because listen-only mouse taps no longer require AX — the tap
    //     creates fine, it just receives no events).
    //   - It returns true after a mid-run revoke for the lifetime of the
    //     process (the WindowServer's per-process AX trust is pinned at
    //     launch, so `CGEvent.tapCreate` keeps succeeding until relaunch).
    //
    // The original symptom that motivated the probe — `AXIsProcessTrusted`
    // lagging the System Settings toggle by hundreds of ms and showing an
    // inverted UI — is now absorbed by the 250/1000/2500 ms notification
    // staircase in `DragEngine.handleTrustNotification` /
    // `SettingsStore.scheduleTrustRefresh` plus the always-on
    // 5 s backstop. So `AXIsProcessTrusted()` is the single source of
    // truth everywhere; the probe and its helpers are gone.
}
