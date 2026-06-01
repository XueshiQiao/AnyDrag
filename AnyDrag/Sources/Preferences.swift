import Foundation

/// Centralizes UserDefaults keys, defaults, and migration so the menu, the
/// Settings window, and the engine read/write through one place.
enum Preferences {

    enum Key {
        static let modifierFlags   = "AnyDragModifierFlags"
        static let dragEnabled     = "AnyDragDragEnabled"
        static let maximizeEnabled = "AnyDragMaximizeEnabled"
        static let tilingEnabled   = "AnyDragTilingEnabled"
        static let resizeEnabled   = "AnyDragResizeEnabled"
        static let cornerBracketEnabled = "AnyDragCornerBracketEnabled"
        static let multiDisplayBentoEnabled = "AnyDragMultiDisplayBentoEnabled"
        static let middleAction    = "AnyDragMiddleAction"
        // Experimental (issue #13 prototype): dedicated modifier for the
        // "modifier + mouse-move, no button → move window" trigger. Absent /
        // empty = feature off. Kept separate from `modifierFlags` so it never
        // competes with the main button-drag gesture.
        static let noButtonMoveModifierFlags = "AnyDragNoButtonMoveModifierFlags"
        // Note: the "Hyper" (CapsLock-via-HyperCapslock) modifier needs no key of
        // its own — it's a bit in `modifierFlags`, so it persists with the rest of
        // the modifier combination and drives the CapsLock source via didSet.

        // Diagnostics — persisted across launches now that the section is
        // always visible in Settings.
        static let titleBarYOffset    = "AnyDragTitleBarYOffset"
        static let showDebugDot       = "AnyDragShowDebugDot"
        static let resizeCornerInset  = "AnyDragResizeCornerInset"

        // In-app language override. Empty/absent means "follow system".
        static let languageOverride = "AnyDragLanguageOverride"

        // Analytics opt-out. Absent or `true` = enabled; `false` = user disabled.
        static let analyticsEnabled = "AnyDragAnalyticsEnabled"

        // Tracks the previously-installed CFBundleShortVersionString so we can
        // fire `update_installed` exactly once on the first launch after an
        // upgrade. Absent on first install.
        static let lastSeenVersion = "AnyDragLastSeenVersion"

        // Snapshot of `AXIsProcessTrusted()` from the previous launch. Used to
        // fire `permission_granted` exactly when the trust transitions
        // launch-to-launch from false → true (the "first grant" funnel point).
        static let lastPermissionGranted = "AnyDragLastPermissionGranted"

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

    /// Default resize-corner inset. The synthesized resize click lands this
    /// many points INSIDE the window's corner so it falls inside the rounded
    /// outer shape rather than in the transparent halo at the geometric
    /// frame corner. 5 works for Safari / Finder / Notes-class apps as well
    /// as Chromium — verified by hand against both families.
    static let defaultResizeCornerInset: CGFloat = 5

    /// Slider range for the resize-corner inset (0…30 px). Persisted values
    /// are clamped to this range on launch.
    static let resizeCornerInsetRange: ClosedRange<CGFloat> = 0...30

    /// Read the persisted language override and install it. Call before any
    /// localized string is read in the launch path so the very first reads see
    /// the user's choice.
    static func applyLanguageOverride() {
        let raw = UserDefaults.standard.string(forKey: Key.languageOverride) ?? ""
        LocalizationOverride.apply(code: raw.isEmpty ? nil : raw)
    }

    /// Persist the user's language pick (nil/empty == "Follow System"), apply
    /// it to the live process, and broadcast `.anyDragLanguageChanged` so
    /// visible surfaces re-render their labels.
    static func setLanguageOverride(_ code: String?) {
        let normalized: String? = (code?.isEmpty == false) ? code : nil
        let previous = UserDefaults.standard.string(forKey: Key.languageOverride)
        if let normalized {
            UserDefaults.standard.set(normalized, forKey: Key.languageOverride)
        } else {
            UserDefaults.standard.removeObject(forKey: Key.languageOverride)
        }
        LocalizationOverride.apply(code: normalized)
        NotificationCenter.default.post(name: .anyDragLanguageChanged, object: nil)
        if previous != normalized {
            Analytics.trackPreferenceChanged(key: "language", value: normalized ?? "system")
        }
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
        engine.resizeEnabled    = d.object(forKey: Key.resizeEnabled) as? Bool ?? true
        engine.cornerBracketEnabled = d.object(forKey: Key.cornerBracketEnabled) as? Bool ?? true
        engine.multiDisplayBentoEnabled = d.object(forKey: Key.multiDisplayBentoEnabled) as? Bool ?? true

        // Empty is a valid persisted state (means "AnyDrag off"), so only the
        // first-launch path falls back to .option.
        if let raw = d.object(forKey: Key.modifierFlags) as? UInt {
            // Normalize so a stale "Hyper + flags" value (possible before the
            // exclusivity rule) loads as a clean Hyper-only selection.
            engine.modifiers = ModifierCombination(rawValue: raw).hyperNormalized
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

        if let raw = d.object(forKey: Key.resizeCornerInset) as? Double {
            let clamped = min(max(CGFloat(raw), resizeCornerInsetRange.lowerBound), resizeCornerInsetRange.upperBound)
            engine.resizeCornerInset = clamped
        } else {
            engine.resizeCornerInset = defaultResizeCornerInset
        }

        engine.showDebugDot = d.object(forKey: Key.showDebugDot) as? Bool ?? false

        // Experimental no-button move modifier (flags-only; no Hyper). Absent
        // or empty means the feature is off.
        if let raw = d.object(forKey: Key.noButtonMoveModifierFlags) as? UInt {
            // Flags-only feature — strip any stray Hyper bit (the UI can't set
            // it, but a hand-edited default could) so it can't masquerade as a
            // non-empty combination with no event flags.
            engine.noButtonMoveModifiers = ModifierCombination(rawValue: raw).subtracting(.hyper)
        } else {
            engine.noButtonMoveModifiers = []
        }
    }
}
