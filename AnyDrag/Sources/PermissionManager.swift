import Cocoa
import ApplicationServices

final class PermissionManager {

    var allGranted: Bool {
        // Use the live probe (see `probeAccessibilityTrust`) — the polling
        // path that calls this every 2s after the alert needs to detect
        // the user's grant as soon as it actually takes effect, not after
        // the TCC cache catches up.
        Self.probeAccessibilityTrust()
    }

    /// Blocks on a background timer until both permissions are granted, then calls `completion` on the main thread.
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

    /// Probe the *actual* current Accessibility / event-tap authorization
    /// by attempting to create a throwaway listen-only tap. Returns true
    /// iff creation succeeds.
    ///
    /// Per Apple DTS guidance (developer.apple.com/forums/thread/727984),
    /// `AXIsProcessTrusted()` and `CGPreflightListenEventAccess()` both
    /// read a TCC cache that lags the real authorization state — right
    /// after the user toggles AX in System Settings, those APIs return
    /// the **previous** value for some hundreds of ms (longer than our
    /// 250ms debounce on some machines, which is what produced the
    /// "totally inverted" bug). Attempting `CGEventTapCreate` is the only
    /// way to get a synchronous, non-stale answer.
    static func probeAccessibilityTrust() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let probe = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passRetained(event) },
            userInfo: nil
        )
        guard let probe = probe else { return false }
        // We only wanted the perm check; tear the throwaway down.
        CGEvent.tapEnable(tap: probe, enable: false)
        CFMachPortInvalidate(probe)
        return true
    }
}
