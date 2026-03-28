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
        alert.messageText = "AnyDrag Needs Permissions"
        alert.informativeText = permissionMessage()
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        } else {
            NSApp.terminate(nil)
        }
    }

    private func permissionMessage() -> String {
        return "AnyDrag requires Accessibility permission to detect modifier keys and move windows.\n\n" +
            "Please grant the permission in System Settings, then return here. AnyDrag will detect the change automatically."
    }

    private func openAccessibilitySettings() {
        // Opens Privacy & Security > Accessibility
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
