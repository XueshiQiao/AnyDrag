import Foundation
import ObjectiveC

extension Notification.Name {
    /// Posted after the user picks a different language in Settings. Visible
    /// surfaces (Settings panes, status item menu) observe this and rebuild
    /// themselves so labels switch without a relaunch.
    static let anyDragLanguageChanged = Notification.Name("AnyDragLanguageChanged")
}

/// Per-app override of the language used by `NSLocalizedString`.
///
/// macOS resolves localized strings through `Bundle.main`. To switch the
/// rendered language inside a running process we swap `Bundle.main`'s class
/// to a subclass that consults a sub-bundle (e.g. `zh-Hans.lproj`) when an
/// override is active, falling through to the system resolution otherwise.
/// `apply(code:)` is idempotent and safe to call before any UI is built.
enum LocalizationOverride {

    /// Codes shipped in the app bundle (filtered to actual `.lproj` folders).
    static let supportedCodes: [String] = {
        Bundle.main.localizations.filter { $0 != "Base" }.sorted()
    }()

    /// The sub-bundle the swizzled lookup defers to. Nil means "follow system".
    fileprivate static var activeBundle: Bundle?

    /// Apply the user's language preference. Pass nil for "follow system".
    /// Call this before any localized string is read so the very first lookups
    /// already see the override.
    static func apply(code: String?) {
        let cls: AnyClass = LanguageOverrideBundle.self
        if object_getClass(Bundle.main) != cls {
            object_setClass(Bundle.main, cls)
        }

        if let code,
           let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            activeBundle = bundle
        } else {
            activeBundle = nil
        }
    }

    /// The user-facing native name for a code (e.g. "English", "简体中文").
    static func nativeName(for code: String) -> String {
        let locale = Locale(identifier: code)
        return locale.localizedString(forIdentifier: code) ?? code
    }
}

private final class LanguageOverrideBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let lprojBundle = LocalizationOverride.activeBundle {
            return lprojBundle.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}
