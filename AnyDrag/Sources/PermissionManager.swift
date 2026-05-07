import Cocoa
import ApplicationServices

final class PermissionManager {

    var allGranted: Bool {
        AXIsProcessTrusted()
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
}
