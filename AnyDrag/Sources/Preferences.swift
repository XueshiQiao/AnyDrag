import Foundation

/// Centralizes UserDefaults keys, defaults, and migration so the menu, the
/// Settings window, and the engine read/write through one place.
enum Preferences {

    enum Key {
        static let modifierFlags   = "AnyDragModifierFlags"
        static let dragEnabled     = "AnyDragDragEnabled"
        static let maximizeEnabled = "AnyDragMaximizeEnabled"
        static let tilingEnabled   = "AnyDragTilingEnabled"
        static let middleAction    = "AnyDragMiddleAction"

        // Diagnostics — persisted across launches now that the section is
        // always visible in Settings.
        static let titleBarYOffset = "AnyDragTitleBarYOffset"
        static let showDebugDot    = "AnyDragShowDebugDot"

        // Legacy keys (read once on launch and rewritten into the new keys)
        static let legacyModifier         = "AnyDragModifier"           // string-based ModifierKey
        static let legacyMiddleClickDrag  = "AnyDragMiddleClickDrag"    // pre-MiddleAction bool
        static let legacyEnabled          = "AnyDragEnabled"            // pre-1.3 master toggle
    }

    /// The default title-bar Y offset, in points. The reset button in the
    /// Diagnostics section snaps the slider back to this value.
    static let defaultTitleBarYOffset: CGFloat = 3

    /// Range mirrored from the Diagnostics slider (0…40). Persisted values are
    /// clamped on launch so a manually edited UserDefaults entry can't push the
    /// engine outside what the UI can represent.
    static let titleBarYOffsetRange: ClosedRange<CGFloat> = 0...40

    /// One-shot migration of pre-1.3 preferences. Idempotent — safe to call every launch.
    static func migrateLegacyKeysIfNeeded() {
        let d = UserDefaults.standard

        // ModifierKey (string) → ModifierCombination (UInt bitmask)
        if d.object(forKey: Key.modifierFlags) == nil,
           let legacy = d.string(forKey: Key.legacyModifier),
           let migrated = ModifierCombination(legacyString: legacy) {
            d.set(migrated.rawValue, forKey: Key.modifierFlags)
        }
        d.removeObject(forKey: Key.legacyModifier)

        // MiddleClickDrag bool → MiddleAction string
        if d.object(forKey: Key.middleAction) == nil,
           d.object(forKey: Key.legacyMiddleClickDrag) != nil {
            let migrated: MiddleAction = d.bool(forKey: Key.legacyMiddleClickDrag) ? .dragWindow : .off
            d.set(migrated.rawValue, forKey: Key.middleAction)
        }
        d.removeObject(forKey: Key.legacyMiddleClickDrag)

        // Master enable toggle removed — drop the stored value so it doesn't
        // linger as orphaned state for users upgrading from <= 1.3.
        d.removeObject(forKey: Key.legacyEnabled)
    }

    /// Apply current UserDefaults to a freshly-created DragEngine. Reading
    /// each key falls through to the documented default when absent, matching
    /// the pre-Settings-window behavior (everything on, modifier = Option,
    /// middle action = off).
    static func apply(to engine: DragEngine) {
        let d = UserDefaults.standard

        engine.dragEnabled      = d.object(forKey: Key.dragEnabled) as? Bool ?? true
        engine.maximizeEnabled  = d.object(forKey: Key.maximizeEnabled) as? Bool ?? true
        engine.tilingEnabled    = d.object(forKey: Key.tilingEnabled) as? Bool ?? true

        // Empty is a valid persisted state (means "AnyDrag off"), so only the
        // first-launch path falls back to .option.
        if let raw = d.object(forKey: Key.modifierFlags) as? UInt {
            engine.modifiers = ModifierCombination(rawValue: raw)
        } else {
            engine.modifiers = .option
        }

        if let raw = d.string(forKey: Key.middleAction),
           let action = MiddleAction(rawValue: raw) {
            engine.middleAction = action
        } else {
            engine.middleAction = .off
        }

        if let raw = d.object(forKey: Key.titleBarYOffset) as? Double {
            let clamped = min(max(CGFloat(raw), titleBarYOffsetRange.lowerBound), titleBarYOffsetRange.upperBound)
            engine.titleBarYOffset = clamped
        } else {
            engine.titleBarYOffset = defaultTitleBarYOffset
        }

        engine.showDebugDot = d.object(forKey: Key.showDebugDot) as? Bool ?? false
    }
}
