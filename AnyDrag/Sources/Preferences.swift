import Foundation

/// One app the user has excluded from AnyDrag. `bundleID` is the match key the
/// engine compares against (stable across renames / localization); `name` is
/// kept only so the Settings list can show something readable without a
/// per-render lookup.
struct BlacklistedApp: Equatable {
    let bundleID: String
    let name: String
}

/// One app with a custom title-bar Y offset that overrides the global default
/// (`titleBarYOffset`). `bundleID` is the match key (stable across renames);
/// `name` is kept for display; `offset` is in points, clamped to
/// `titleBarYOffsetRange`.
struct AppTitleBarOffset: Equatable {
    let bundleID: String
    let name: String
    var offset: CGFloat
}

/// Centralizes UserDefaults keys, defaults, and migration so the menu, the
/// Settings window, and the engine read/write through one place.
enum Preferences {

    enum Key {
        static let modifierFlags   = "AnyDragModifierFlags"
        static let dragEnabled     = "AnyDragDragEnabled"
        static let maximizeEnabled = "AnyDragMaximizeEnabled"
        static let tilingEnabled   = "AnyDragTilingEnabled"
        // How resize is triggered: "off" / "right" / "left" (ResizeTrigger).
        // Absent → derived from the legacy `resizeEnabled` + `leftResizeEnabled`
        // booleans (see `apply`). `leftResizeModifier` stores the secondary
        // modifier for the "left" trigger as a ModifierCombination rawValue.
        static let resizeTrigger      = "AnyDragResizeTrigger"
        static let leftResizeModifier = "AnyDragLeftResizeModifier"
        // Legacy resize toggles, now folded into `resizeTrigger`. Read only for
        // one-time migration; preserved (not deleted) so a downgrade still works.
        static let resizeEnabled      = "AnyDragResizeEnabled"
        static let leftResizeEnabled  = "AnyDragLeftResizeEnabled"
        static let cornerBracketEnabled = "AnyDragCornerBracketEnabled"
        static let multiDisplayBentoEnabled = "AnyDragMultiDisplayBentoEnabled"
        static let middleAction    = "AnyDragMiddleAction"
        // "Drag-only trigger mode" for the tile-by-direction middle gesture.
        // Absent = false (panel shows immediately on middle-press, the original
        // behavior).
        static let tileDragOnly    = "AnyDragTileDragOnly"
        // Linked resize: drag the shared seam between two AnyDrag-tiled
        // complementary windows to resize both. Absent = default (on).
        static let linkedResizeEnabled = "AnyDragLinkedResizeEnabled"
        // Tiling-overlay edge-safe placement + cursor warp. When on (default),
        // the bento overlay is kept fully on-screen near an edge and the cursor
        // glides to its center; when off, the overlay centers on the cursor
        // with no edge clamping and no cursor warp. Absent = default (on).
        static let overlayEdgeSafeEnabled = "AnyDragOverlayEdgeSafeEnabled"
        // Note: the "Hyper" (CapsLock-via-HyperCapslock) modifier needs no key of
        // its own — it's a bit in `modifierFlags`, so it persists with the rest of
        // the modifier combination and drives the CapsLock source via didSet.

        // Diagnostics — persisted across launches now that the section is
        // always visible in Settings.
        static let titleBarYOffset    = "AnyDragTitleBarYOffset"
        static let showDebugDot       = "AnyDragShowDebugDot"
        static let resizeCornerInset  = "AnyDragResizeCornerInset"
        // Whether the (collapsed-by-default) Diagnostics section is expanded.
        // Absent = collapsed.
        static let diagnosticsExpanded = "AnyDragDiagnosticsExpanded"

        // Excluded apps (the blacklist). Stored as an array of
        // ["bundleID": ..., "name": ...] dictionaries; absent = empty list.
        static let blacklistedApps    = "AnyDragBlacklistedApps"

        // Per-app title-bar Y offset overrides. Stored as an array of
        // ["bundleID": ..., "name": ..., "offset": <Double>] dictionaries;
        // absent = empty list (every app uses the global `titleBarYOffset`).
        static let perAppTitleBarYOffsets = "AnyDragPerAppTitleBarYOffsets"

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
    /// Diagnostics section snaps the value back to this default.
    static let defaultTitleBarYOffset: CGFloat = 3

    /// Range mirrored from the Diagnostics control (0…40). Persisted values are
    /// clamped on launch so a manually edited UserDefaults entry can't push the
    /// engine outside what the UI can represent.
    static let titleBarYOffsetRange: ClosedRange<CGFloat> = 0...40

    /// Range for a per-app title-bar Y offset override (points). Narrower than
    /// the global 0…40 by design: a per-app override only ever nudges a few
    /// points around the global default. Stored values are still clamped to the
    /// wider `titleBarYOffsetRange`.
    static let perAppTitleBarYOffsetRange: ClosedRange<CGFloat> = 0...15

    /// Default resize-corner inset. The synthesized resize click lands this
    /// many points INSIDE the window's corner so it falls inside the rounded
    /// outer shape rather than in the transparent halo at the geometric
    /// frame corner. 5 works for Safari / Finder / Notes-class apps as well
    /// as Chromium — verified by hand against both families.
    static let defaultResizeCornerInset: CGFloat = 5

    /// Range for the resize-corner inset (0…30 pt). Persisted values
    /// are clamped to this range on launch.
    static let resizeCornerInsetRange: ClosedRange<CGFloat> = 0...30

    // ─── Feature defaults (flip a single value here to change the default) ───

    /// Default for the linked-resize feature (drag the shared seam between two
    /// AnyDrag-tiled windows to resize both at once). TRUE preserves the
    /// always-on behavior shipped before the toggle existed.
    static let defaultLinkedResizeEnabled = true

    /// Default for edge-safe tiling-overlay placement + cursor warp. TRUE keeps
    /// the overlay on-screen near an edge and glides the cursor to its center;
    /// FALSE centers it on the cursor with no clamping and no cursor warp.
    static let defaultOverlayEdgeSafeEnabled = true

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

    /// The user's excluded-app list, in display order. Unparseable or
    /// empty-bundleID entries are dropped; a missing `name` falls back to the
    /// bundle id so the row still renders.
    static func blacklistedApps() -> [BlacklistedApp] {
        guard let raw = UserDefaults.standard.array(forKey: Key.blacklistedApps) else {
            return []
        }
        // Parse each entry independently — a single malformed element (or a
        // non-String value snuck in by hand) must not discard the whole list.
        return raw.compactMap { element in
            guard let entry = element as? [String: Any],
                  let bundleID = entry["bundleID"] as? String, !bundleID.isEmpty else { return nil }
            let name = (entry["name"] as? String) ?? bundleID
            return BlacklistedApp(bundleID: bundleID, name: name)
        }
    }

    /// Persist the excluded-app list. The engine is updated separately via
    /// `DragEngine.setBlacklistedBundleIDs` so the running tap sees the change
    /// immediately, not just on next launch.
    static func setBlacklistedApps(_ apps: [BlacklistedApp]) {
        let serialized = apps.map { ["bundleID": $0.bundleID, "name": $0.name] }
        UserDefaults.standard.set(serialized, forKey: Key.blacklistedApps)
    }

    /// The user's per-app title-bar Y offset overrides, in display order. Parsed
    /// defensively (like the blacklist): a malformed or empty-bundleID entry is
    /// dropped without discarding the rest, a missing `name` falls back to the
    /// bundle id, and each offset is clamped to `titleBarYOffsetRange` so a
    /// hand-edited value can't push a drag outside what the UI can represent.
    static func perAppTitleBarOffsets() -> [AppTitleBarOffset] {
        guard let raw = UserDefaults.standard.array(forKey: Key.perAppTitleBarYOffsets) else {
            return []
        }
        return raw.compactMap { element in
            guard let entry = element as? [String: Any],
                  let bundleID = entry["bundleID"] as? String, !bundleID.isEmpty else { return nil }
            let name = (entry["name"] as? String) ?? bundleID
            let rawOffset = (entry["offset"] as? Double) ?? Double(defaultTitleBarYOffset)
            let clamped = min(max(CGFloat(rawOffset), titleBarYOffsetRange.lowerBound), titleBarYOffsetRange.upperBound)
            return AppTitleBarOffset(bundleID: bundleID, name: name, offset: clamped)
        }
    }

    /// Persist the per-app offset list. The engine is updated separately via
    /// `DragEngine.setPerAppTitleBarYOffsets` so the running tap sees the change
    /// immediately, not just on next launch.
    static func setPerAppTitleBarOffsets(_ items: [AppTitleBarOffset]) {
        let serialized = items.map {
            ["bundleID": $0.bundleID, "name": $0.name, "offset": Double($0.offset)] as [String: Any]
        }
        UserDefaults.standard.set(serialized, forKey: Key.perAppTitleBarYOffsets)
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
        engine.cornerBracketEnabled = d.object(forKey: Key.cornerBracketEnabled) as? Bool ?? true
        engine.multiDisplayBentoEnabled = d.object(forKey: Key.multiDisplayBentoEnabled) as? Bool ?? true
        engine.tileByDirectionDragOnly = d.object(forKey: Key.tileDragOnly) as? Bool ?? false
        engine.linkedResizeEnabled = d.object(forKey: Key.linkedResizeEnabled) as? Bool ?? defaultLinkedResizeEnabled
        engine.overlayEdgeSafeEnabled = d.object(forKey: Key.overlayEdgeSafeEnabled) as? Bool ?? defaultOverlayEdgeSafeEnabled

        // Empty is a valid persisted state (means "AnyDrag off"), so only the
        // first-launch path falls back to .option.
        if let raw = d.object(forKey: Key.modifierFlags) as? UInt {
            // Normalize so a stale "Hyper + flags" value (possible before the
            // exclusivity rule) loads as a clean Hyper-only selection.
            engine.modifiers = ModifierCombination(rawValue: raw).hyperNormalized
        } else {
            engine.modifiers = .option
        }

        // Resize trigger. Prefer the new key; otherwise migrate from the legacy
        // booleans — favour an explicitly-enabled left-click path, else the
        // right-click path (on by default), else off. Self-contained so it does
        // not depend on migration running first.
        if let raw = d.string(forKey: Key.resizeTrigger), let trigger = ResizeTrigger(rawValue: raw) {
            engine.resizeTrigger = trigger
        } else {
            let leftOn = d.object(forKey: Key.leftResizeEnabled) as? Bool ?? false
            let rightOn = d.object(forKey: Key.resizeEnabled) as? Bool ?? true
            engine.resizeTrigger = leftOn ? .leftClick : (rightOn ? .rightClick : .off)
        }

        // Secondary modifier for the "left" trigger. Read after `modifiers` so
        // the augment can be sanitized against the (now-known) base — it must
        // stay a single valid key disjoint from the base, else the resize
        // trigger wouldn't differ from the move trigger.
        if let raw = d.object(forKey: Key.leftResizeModifier) as? UInt {
            engine.leftResizeModifier = ModifierCombination(rawValue: raw).sanitizedAugment(base: engine.modifiers)
        } else {
            engine.leftResizeModifier = ModifierCombination.defaultAugment(excluding: engine.modifiers)
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

        engine.setBlacklistedBundleIDs(Set(blacklistedApps().map { $0.bundleID }))

        let offsetMap = Dictionary(
            perAppTitleBarOffsets().map { ($0.bundleID, $0.offset) },
            uniquingKeysWith: { _, last in last }
        )
        engine.setPerAppTitleBarYOffsets(offsetMap)
    }
}
