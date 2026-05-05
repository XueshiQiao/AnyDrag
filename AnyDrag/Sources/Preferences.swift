import Foundation

/// Centralizes UserDefaults keys, defaults, and migration so the menu, the
/// Settings window, and the engine read/write through one place.
enum Preferences {

    enum Key {
        static let enabled         = "AnyDragEnabled"
        static let modifierFlags   = "AnyDragModifierFlags"
        static let dragEnabled     = "AnyDragDragEnabled"
        static let maximizeEnabled = "AnyDragMaximizeEnabled"
        static let tilingEnabled   = "AnyDragTilingEnabled"
        static let middleAction    = "AnyDragMiddleAction"

        // Legacy keys (read once on launch and rewritten into the new keys)
        static let legacyModifier         = "AnyDragModifier"           // string-based ModifierKey
        static let legacyMiddleClickDrag  = "AnyDragMiddleClickDrag"    // pre-MiddleAction bool
    }

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
    }

    /// Apply current UserDefaults to a freshly-created DragEngine. Reading
    /// each key falls through to the documented default when absent, matching
    /// the pre-Settings-window behavior (everything on, modifier = Option,
    /// middle action = off).
    static func apply(to engine: DragEngine) {
        let d = UserDefaults.standard

        engine.isEnabled        = d.object(forKey: Key.enabled) as? Bool ?? true
        engine.dragEnabled      = d.object(forKey: Key.dragEnabled) as? Bool ?? true
        engine.maximizeEnabled  = d.object(forKey: Key.maximizeEnabled) as? Bool ?? true
        engine.tilingEnabled    = d.object(forKey: Key.tilingEnabled) as? Bool ?? true

        if let raw = d.object(forKey: Key.modifierFlags) as? UInt {
            let combo = ModifierCombination(rawValue: raw)
            engine.modifiers = combo.isEmpty ? .option : combo
        } else {
            engine.modifiers = .option
        }

        if let raw = d.string(forKey: Key.middleAction),
           let action = MiddleAction(rawValue: raw) {
            engine.middleAction = action
        } else {
            engine.middleAction = .off
        }
    }
}
