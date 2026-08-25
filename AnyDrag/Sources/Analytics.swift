import Foundation
import Aptabase

/// Thin facade over the Aptabase SDK. All call sites in AnyDrag go through
/// this enum so the rest of the codebase never imports `Aptabase` directly,
/// and so the opt-out gate lives in exactly one place.
///
/// Privacy contract:
/// - No bundle IDs, window titles, or app names ever leave the device.
/// - All events are gated on `Preferences.Key.analyticsEnabled` (default `true`)
///   EXCEPT the meta-event recording the toggle itself (see
///   `trackPreferenceChanged`), so the OFF→ON re-enable is still observable.
enum Analytics {

    private static let log = FileLog("Analytics")

    private static let appKey = "A-US-7901961627"

    /// Set once after the first successful `initialize` so re-entry is a no-op.
    private static var started = false

    // MARK: - Lifecycle

    /// Initialize the SDK and fire the launch/update events. Safe to call
    /// multiple times — subsequent calls are no-ops.
    static func start() {
        guard !started else { return }
        started = true

        Aptabase.shared.initialize(appKey: appKey)

        track("app_launched")
        trackUpdateInstalledIfNeeded()
    }

    /// Force-flush any queued events. Call from `applicationWillTerminate`.
    static func flush() {
        guard started else { return }
        Aptabase.shared.flush()
    }

    // MARK: - Events

    static func trackPermissionGranted() {
        track("permission_granted")
    }

    static func trackDrag(trigger: DragTrigger, modifier: ModifierCombination) {
        track("drag_performed", with: [
            "trigger": trigger.rawValue,
            "modifier": modifier.analyticsKey,
        ])
    }

    static func trackMaximize() {
        track("maximize_performed")
    }

    static func trackTile(tile: String, trigger: TileTrigger) {
        track("tile_performed", with: [
            "tile": tile,
            "trigger": trigger.rawValue,
        ])
    }

    /// Tracks a preference change. The `analytics_enabled` toggle is the one
    /// intentional exception to the opt-out gate — see top-of-file comment.
    static func trackPreferenceChanged(key: String, value: String) {
        let props: [String: Value] = ["key": .string(key), "value": .string(value)]
        if key == "analytics_enabled" {
            // Bypass the gate so BOTH directions of the toggle are observable.
            // Without this, an OFF→ON re-enable would never reach Aptabase.
            sendDirect("preference_changed", props: props)
            return
        }
        track("preference_changed", with: ["key": key, "value": value])
    }

    // MARK: - Update detection

    private static func trackUpdateInstalledIfNeeded() {
        let d = UserDefaults.standard
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let last = d.string(forKey: Preferences.Key.lastSeenVersion)
        if let last, !last.isEmpty, last != current {
            track("update_installed", with: [
                "from_version": last,
                "to_version": current,
            ])
        }
        if !current.isEmpty {
            d.set(current, forKey: Preferences.Key.lastSeenVersion)
        }
    }

    // MARK: - Internals

    /// Strongly-typed property value so we can pass numbers/bools without
    /// stringifying them. Aptabase accepts String / Int / Double / Float / Bool.
    enum Value {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)

        fileprivate var any: Any {
            switch self {
            case .string(let s): return s
            case .int(let i):    return i
            case .double(let d): return d
            case .bool(let b):   return b
            }
        }
    }

    private static func track(_ name: String) {
        guard analyticsEnabled else { return }
        Aptabase.shared.trackEvent(name)
    }

    private static func track(_ name: String, with props: [String: String]) {
        guard analyticsEnabled else { return }
        Aptabase.shared.trackEvent(name, with: props)
    }

    /// Gate-bypassing send (used only for the analytics_enabled toggle event).
    private static func sendDirect(_ name: String, props: [String: Value]) {
        guard started else { return }
        let anyProps = props.mapValues { $0.any }
        Aptabase.shared.trackEvent(name, with: anyProps)
    }

    private static var analyticsEnabled: Bool {
        // Default true when the key is absent (fresh installs opt in).
        guard started else { return false }
        let d = UserDefaults.standard
        if d.object(forKey: Preferences.Key.analyticsEnabled) == nil { return true }
        return d.bool(forKey: Preferences.Key.analyticsEnabled)
    }

    // MARK: - Helper enums

    enum DragTrigger: String {
        case modifier
        case middle
    }

    enum TileTrigger: String {
        case panel
        case middleDirection = "middle_direction"
    }
}

// MARK: - Domain types → analytics keys
//
// All telemetry-string mappings live here so the canonical lowercase forms
// are visible in one place and a renamed enum case can't silently change
// what the dashboard reports.

extension ModifierCombination {
    /// Canonical lowercase, `+`-joined representation for analytics.
    /// Order matches Apple HIG (fn, control, option, shift, command).
    var analyticsKey: String {
        var parts: [String] = []
        if contains(.hyper)   { parts.append("hyper") }
        if contains(.fn)      { parts.append("fn") }
        if contains(.control) { parts.append("control") }
        if contains(.option)  { parts.append("option") }
        if contains(.shift)   { parts.append("shift") }
        if contains(.command) { parts.append("command") }
        return parts.joined(separator: "+")
    }
}

extension TileAction {
    var analyticsKey: String {
        switch self {
        case .leftHalf:     return "left_half"
        case .rightHalf:    return "right_half"
        case .topHalf:      return "top_half"
        case .bottomHalf:   return "bottom_half"
        case .topLeft:      return "top_left"
        case .topRight:     return "top_right"
        case .bottomLeft:   return "bottom_left"
        case .bottomRight:  return "bottom_right"
        case .centered:     return "centered"
        case .restoreOriginal: return "restore_original"
        case .minimize:     return "minimize"
        case .fill:         return "fill"
        case .fillRight:    return "fill_right"
        case .leftAndRight: return "left_and_right"
        case .quarters:     return "quarters"
        }
    }
}

extension TileZone {
    var analyticsKey: String {
        switch self {
        case .full:        return "fill"
        case .centered:    return "centered"
        case .left:        return "left_half"
        case .right:       return "right_half"
        case .topLeft:     return "top_left"
        case .topRight:    return "top_right"
        case .bottomLeft:  return "bottom_left"
        case .bottomRight: return "bottom_right"
        case .moveToDisplay: return "move_to_display"
        case .jump: return "jump_to_workspace"
        }
    }
}
