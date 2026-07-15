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

        requestAccessibilityAuthorization()

        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.allGranted {
                timer.invalidate()
                completion()
            }
        }
    }

    // MARK: - Private

    /// Ask TCC to register AnyDrag and present the native Accessibility
    /// authorization prompt. A fresh process is required after a live revoke
    /// because the old process may retain a stale positive trust result.
    private func requestAccessibilityAuthorization() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Open System Settings → Privacy & Security → Accessibility. Shared by
    /// the native permission prompt and the in-app permission row.
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Relaunch after a live revoke so TCC evaluates authorization in a fresh
    /// process. The new instance runs `ensurePermissions`, which presents the
    /// single native prompt and re-registers an app removed from the list.
    static func relaunchForAccessibilityAuthorization() {
#if DEBUG
        // A relaunched process is detached from Xcode's debugger. During local
        // development, exit cleanly and let the developer run again instead.
        NSApp.terminate(nil)
#else
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
#endif
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
