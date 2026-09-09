import Cocoa
import SwiftUI
import ServiceManagement
import ApplicationServices

// MARK: - SettingsStore
//
// The single SwiftUI source of truth for the Settings window. It mirrors the
// live `DragEngine` state and the persisted `Preferences` into `@Published`
// properties so SwiftUI can bind to them, and writes every change back through
// the SAME three channels the old AppKit panes used:
//   1. the live `DragEngine` (so the running event tap sees it immediately),
//   2. `UserDefaults` (via `Preferences.Key`, so it survives relaunch),
//   3. `Analytics.trackPreferenceChanged` (only on an actual value change).
//
// All the subtle invariants the panes enforced are preserved here: Hyper is
// exclusive with the flag modifiers, the left-resize shortcut stays distinct
// from the primary shortcut, and the corner-bracket / tile sub-options gate on
// their parent selection. The views stay dumb — they read these properties and
// call the `set*` methods; the store owns the rules.
//
// Not actor-isolated: it is only ever touched on the main thread — SwiftUI
// bindings run on main, and every notification observer below uses `queue:
// .main`. Keeping it non-isolated avoids cascading `@MainActor` onto the
// AppKit controllers that create it, and stays compatible with macOS 13.
final class SettingsStore: ObservableObject {

    let engine: DragEngine
    let updateController: UpdateController

    private static let log = FileLog("Settings.Store")

    // Which sidebar page is showing. Kept in the store (not @State) so it
    // survives the `.id(languageRevision)` rebuild on a language switch.
    @Published var page: SettingsPage = .windowDrag

    // Bumped whenever the in-app language changes; the root view keys its
    // identity off this so the whole SwiftUI tree re-reads NSLocalizedString.
    @Published private(set) var languageRevision = 0

    // ─── Engine-backed ───────────────────────────────────────────────
    @Published private(set) var modifiers: ModifierCombination
    @Published private(set) var leftResizeModifier: ModifierCombination
    @Published private(set) var dragEnabled: Bool
    @Published private(set) var maximizeEnabled: Bool
    @Published private(set) var tilingEnabled: Bool
    @Published private(set) var resizeTrigger: ResizeTrigger
    @Published private(set) var cornerBracketEnabled: Bool
    @Published private(set) var multiDisplayBentoEnabled: Bool
    @Published private(set) var bentoBorderEnabled: Bool
    @Published private(set) var bentoMaterial: BentoMaterial
    @Published private(set) var bentoTint: BentoTint
    @Published private(set) var tileByDirectionDragOnly: Bool
    @Published private(set) var linkedResizeEnabled: Bool
    @Published private(set) var overlayEdgeSafeEnabled: Bool
    @Published private(set) var middleAction: MiddleAction
    @Published private(set) var centeredSizePercent: Int
    @Published private(set) var titleBarYOffset: CGFloat
    @Published private(set) var resizeCornerInset: CGFloat
    @Published private(set) var showDebugDot: Bool

    // ─── Non-engine ──────────────────────────────────────────────────
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var accessibilityGranted: Bool
    @Published private(set) var languageCode: String?   // nil = follow system
    @Published private(set) var analyticsEnabled: Bool
    @Published private(set) var blacklist: [BlacklistedApp]
    @Published private(set) var perAppOffsets: [AppTitleBarOffset]

    private var trustObserver: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?
    private var trustRefreshTasks: [DispatchWorkItem] = []

    init(engine: DragEngine, updateController: UpdateController) {
        self.engine = engine
        self.updateController = updateController

        modifiers = engine.modifiers
        leftResizeModifier = engine.leftResizeModifier
        dragEnabled = engine.dragEnabled
        maximizeEnabled = engine.maximizeEnabled
        tilingEnabled = engine.tilingEnabled
        resizeTrigger = engine.resizeTrigger
        cornerBracketEnabled = engine.cornerBracketEnabled
        multiDisplayBentoEnabled = engine.multiDisplayBentoEnabled
        bentoBorderEnabled = engine.bentoBorderEnabled
        bentoMaterial = engine.bentoMaterial
        bentoTint = engine.bentoTint
        tileByDirectionDragOnly = engine.tileByDirectionDragOnly
        linkedResizeEnabled = engine.linkedResizeEnabled
        overlayEdgeSafeEnabled = engine.overlayEdgeSafeEnabled
        middleAction = engine.middleAction
        centeredSizePercent = engine.centeredSizePercent
        titleBarYOffset = engine.titleBarYOffset
        resizeCornerInset = engine.resizeCornerInset
        showDebugDot = engine.showDebugDot

        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        accessibilityGranted = AXIsProcessTrusted()
        let savedLang = UserDefaults.standard.string(forKey: Preferences.Key.languageOverride) ?? ""
        languageCode = savedLang.isEmpty ? nil : savedLang
        let d = UserDefaults.standard
        analyticsEnabled = (d.object(forKey: Preferences.Key.analyticsEnabled) == nil)
            ? true : d.bool(forKey: Preferences.Key.analyticsEnabled)
        blacklist = Preferences.blacklistedApps()
        perAppOffsets = Preferences.perAppTitleBarOffsets()

        // Live-refresh the Accessibility row on the same distributed trust
        // notification the engine uses (fires only on real AX state changes).
        trustObserver = DistributedNotificationCenter.default().addObserver(
            forName: .anyDragAXTrustChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleTrustRefresh()
        }

        // A language switch (from our own popup or elsewhere) rebuilds labels.
        languageObserver = NotificationCenter.default.addObserver(
            forName: .anyDragLanguageChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let saved = UserDefaults.standard.string(forKey: Preferences.Key.languageOverride) ?? ""
            self.languageCode = saved.isEmpty ? nil : saved
            self.languageRevision &+= 1
        }
    }

    deinit {
        if let trustObserver { DistributedNotificationCenter.default().removeObserver(trustObserver) }
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
        trustRefreshTasks.forEach { $0.cancel() }
    }

    /// Re-sync the values that can change while the window is open from outside
    /// the SwiftUI bindings (permission grant, login-item state).
    func refreshExternalState() {
        accessibilityGranted = AXIsProcessTrusted()
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    // MARK: Primary modifier

    /// Apply a proposed primary-modifier combination. Always accepted (returns
    /// true to match the picker's accept/reject contract). Mirrors
    /// `AdvancedPaneViewController.modifierChipRow.onChange`: persist, re-validate
    /// the left-resize augment against the new base, and track the change.
    @discardableResult
    func setModifiers(_ proposed: ModifierCombination) -> Bool {
        let previous = engine.modifiers
        engine.modifiers = proposed
        modifiers = proposed
        UserDefaults.standard.set(proposed.rawValue, forKey: Preferences.Key.modifierFlags)

        // Keep the secondary a single eligible key distinct from the new base.
        // It may remain contained in a multi-key base because matching is exact.
        let sanitized = engine.leftResizeModifier.sanitizedAugment(base: proposed)
        if sanitized != engine.leftResizeModifier {
            engine.leftResizeModifier = sanitized
            leftResizeModifier = sanitized
            UserDefaults.standard.set(sanitized.rawValue, forKey: Preferences.Key.leftResizeModifier)
        }

        if previous != proposed {
            Analytics.trackPreferenceChanged(key: "modifier", value: proposed.analyticsKey)
        }
        return true
    }

    // MARK: Left-resize augment (secondary modifier)

    /// The key forbidden in the augment picker when the primary modifier is the
    /// same single key. Keys contained in a multi-key primary remain available.
    var augmentDisabledElements: ModifierCombination {
        modifiers.isValidAugment ? modifiers : []
    }

    /// Apply a proposed augment. Accepted only when it is a single eligible key
    /// whose final shortcut differs from the primary modifier.
    @discardableResult
    func setAugment(_ proposed: ModifierCombination) -> Bool {
        guard proposed.isValidAugment(for: modifiers) else { return false }
        let previous = engine.leftResizeModifier
        engine.leftResizeModifier = proposed
        leftResizeModifier = proposed
        UserDefaults.standard.set(proposed.rawValue, forKey: Preferences.Key.leftResizeModifier)
        if previous != proposed {
            Analytics.trackPreferenceChanged(key: "left_resize_modifier", value: proposed.analyticsKey)
        }
        return true
    }

    // MARK: Resize trigger

    func setResizeTrigger(_ trigger: ResizeTrigger) {
        let previous = engine.resizeTrigger
        engine.resizeTrigger = trigger
        resizeTrigger = trigger
        UserDefaults.standard.set(trigger.rawValue, forKey: Preferences.Key.resizeTrigger)
        if previous != trigger {
            Analytics.trackPreferenceChanged(key: "resize_trigger", value: trigger.rawValue)
        }
    }

    // MARK: Middle-click action

    func setMiddleAction(_ action: MiddleAction) {
        let previous = engine.middleAction
        engine.middleAction = action
        middleAction = action
        UserDefaults.standard.set(action.rawValue, forKey: Preferences.Key.middleAction)
        if previous != action {
            Analytics.trackPreferenceChanged(key: "middle_action", value: action.rawValue)
        }
    }

    // MARK: Centered-window size

    /// Applies to every centered path at once — the tiling panel's Center button
    /// and the middle-drag-down gesture (both its preview and where it lands) —
    /// because they all read `engine.centeredSizePercent`.
    func setCenteredSizePercent(_ percent: Int) {
        let normalized = Preferences.normalizedCenteredPercent(percent)
        let previous = engine.centeredSizePercent
        engine.centeredSizePercent = normalized
        centeredSizePercent = normalized
        UserDefaults.standard.set(normalized, forKey: Preferences.Key.centeredSizePercent)
        if previous != normalized {
            Analytics.trackPreferenceChanged(key: "centered_size_percent", value: String(normalized))
        }
    }

    // MARK: Boolean feature toggles

    func setDragEnabled(_ on: Bool)     { setBool(on, key: Preferences.Key.dragEnabled, analytics: "drag_enabled", current: \.dragEnabled, write: { self.engine.dragEnabled = $0 }, mirror: { self.dragEnabled = $0 }) }
    func setMaximizeEnabled(_ on: Bool) { setBool(on, key: Preferences.Key.maximizeEnabled, analytics: "maximize_enabled", current: \.maximizeEnabled, write: { self.engine.maximizeEnabled = $0 }, mirror: { self.maximizeEnabled = $0 }) }
    func setTilingEnabled(_ on: Bool)   { setBool(on, key: Preferences.Key.tilingEnabled, analytics: "tiling_enabled", current: \.tilingEnabled, write: { self.engine.tilingEnabled = $0 }, mirror: { self.tilingEnabled = $0 }) }
    func setCornerBracketEnabled(_ on: Bool) { setBool(on, key: Preferences.Key.cornerBracketEnabled, analytics: "corner_bracket_enabled", current: \.cornerBracketEnabled, write: { self.engine.cornerBracketEnabled = $0 }, mirror: { self.cornerBracketEnabled = $0 }) }
    func setMultiDisplayBentoEnabled(_ on: Bool) { setBool(on, key: Preferences.Key.multiDisplayBentoEnabled, analytics: "multi_display_bento_enabled", current: \.multiDisplayBentoEnabled, write: { self.engine.multiDisplayBentoEnabled = $0 }, mirror: { self.multiDisplayBentoEnabled = $0 }) }
    func setBentoBorderEnabled(_ on: Bool) { setBool(on, key: Preferences.Key.bentoBorderEnabled, analytics: "bento_border_enabled", current: \.bentoBorderEnabled, write: { self.engine.bentoBorderEnabled = $0 }, mirror: { self.bentoBorderEnabled = $0 }) }

    func setBentoMaterial(_ value: BentoMaterial) {
        let previous = engine.bentoMaterial
        engine.bentoMaterial = value
        bentoMaterial = value
        UserDefaults.standard.set(value.rawValue, forKey: Preferences.Key.bentoMaterial)
        if previous != value {
            Analytics.trackPreferenceChanged(key: "bento_material", value: value.rawValue)
        }
    }

    func setBentoTint(_ value: BentoTint) {
        let previous = engine.bentoTint
        engine.bentoTint = value
        bentoTint = value
        UserDefaults.standard.set(value.rawValue, forKey: Preferences.Key.bentoTint)
        if previous != value {
            Analytics.trackPreferenceChanged(key: "bento_tint", value: value.rawValue)
        }
    }
    func setTileDragOnly(_ on: Bool)    { setBool(on, key: Preferences.Key.tileDragOnly, analytics: "tile_drag_only", current: \.tileByDirectionDragOnly, write: { self.engine.tileByDirectionDragOnly = $0 }, mirror: { self.tileByDirectionDragOnly = $0 }) }
    func setLinkedResizeEnabled(_ on: Bool)   { setBool(on, key: Preferences.Key.linkedResizeEnabled, analytics: "linked_resize_enabled", current: \.linkedResizeEnabled, write: { self.engine.linkedResizeEnabled = $0 }, mirror: { self.linkedResizeEnabled = $0 }) }
    func setOverlayEdgeSafeEnabled(_ on: Bool) { setBool(on, key: Preferences.Key.overlayEdgeSafeEnabled, analytics: "overlay_edge_safe_enabled", current: \.overlayEdgeSafeEnabled, write: { self.engine.overlayEdgeSafeEnabled = $0 }, mirror: { self.overlayEdgeSafeEnabled = $0 }) }

    private func setBool(_ on: Bool, key: String, analytics: String,
                         current: KeyPath<DragEngine, Bool>,
                         write: (Bool) -> Void, mirror: (Bool) -> Void) {
        let previous = engine[keyPath: current]
        write(on)
        mirror(on)
        UserDefaults.standard.set(on, forKey: key)
        if previous != on {
            Analytics.trackPreferenceChanged(key: analytics, value: String(on))
        }
    }

    // MARK: Diagnostics

    func setShowDebugDot(_ on: Bool) {
        engine.showDebugDot = on
        showDebugDot = on
        UserDefaults.standard.set(on, forKey: Preferences.Key.showDebugDot)
    }

    func setTitleBarYOffset(_ value: CGFloat) {
        let clamped = value.rounded().clamped(to: Preferences.titleBarYOffsetRange)
        engine.titleBarYOffset = clamped
        titleBarYOffset = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Preferences.Key.titleBarYOffset)
    }

    func setResizeCornerInset(_ value: CGFloat) {
        let clamped = value.rounded().clamped(to: Preferences.resizeCornerInsetRange)
        engine.resizeCornerInset = clamped
        resizeCornerInset = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Preferences.Key.resizeCornerInset)
    }

    func resetTitleBarYOffset()   { setTitleBarYOffset(Preferences.defaultTitleBarYOffset) }
    func resetResizeCornerInset() { setResizeCornerInset(Preferences.defaultResizeCornerInset) }

    // MARK: Language

    func setLanguage(_ code: String?) {
        // Preferences.setLanguageOverride persists, applies, posts
        // .anyDragLanguageChanged (which our observer turns into a rebuild),
        // and tracks the change. We optimistically mirror so the popup updates
        // even before the notification round-trips.
        languageCode = code
        Preferences.setLanguageOverride(code)
    }

    // MARK: Launch at Login

    func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            Self.log.error("Failed to toggle launch at login: \(error)")
        }
        // Reflect the real post-call state (a failed toggle reverts).
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    // MARK: Analytics opt-out

    func setAnalyticsEnabled(_ on: Bool) {
        let d = UserDefaults.standard
        let previous = (d.object(forKey: Preferences.Key.analyticsEnabled) == nil)
            ? true : d.bool(forKey: Preferences.Key.analyticsEnabled)
        // Fire the meta-event BEFORE persisting — trackPreferenceChanged bypasses
        // the opt-out gate for `analytics_enabled` so BOTH transitions reach the
        // server.
        if previous != on {
            Analytics.trackPreferenceChanged(key: "analytics_enabled", value: String(on))
        }
        d.set(on, forKey: Preferences.Key.analyticsEnabled)
        analyticsEnabled = on
        if !on { Analytics.flush() }   // flush the OFF event before the gate closes
    }

    // MARK: Accessibility

    func openAccessibilitySettings() {
        PermissionManager.openAccessibilitySettings()
    }

    /// Staircase of re-checks after the AX-trust notification fires —
    /// `AXIsProcessTrusted()` lags the System Settings toggle by a variable
    /// amount. Mirrors the old `GeneralPaneViewController.scheduleTrustRefresh`.
    private func scheduleTrustRefresh() {
        trustRefreshTasks.forEach { $0.cancel() }
        trustRefreshTasks.removeAll()
        accessibilityGranted = AXIsProcessTrusted()
        for delay in [250, 1000, 2500] {
            let task = DispatchWorkItem { [weak self] in
                self?.accessibilityGranted = AXIsProcessTrusted()
            }
            trustRefreshTasks.append(task)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: task)
        }
    }

    // MARK: Excluded apps (blacklist)

    /// Apps eligible to add: running, Dock-visible, not already excluded, not us.
    func addableRunningApps() -> [BlacklistedApp] {
        runningRegularApps(excluding: Set(blacklist.map { $0.bundleID }))
    }

    /// Apps eligible to add to the per-app offset list: running, Dock-visible,
    /// not already in the list, not us.
    func addableRunningAppsForOffset() -> [BlacklistedApp] {
        runningRegularApps(excluding: Set(perAppOffsets.map { $0.bundleID }))
    }

    /// Running, regular (Dock-visible) apps minus AnyDrag itself and any bundle
    /// id in `excluded`, de-duplicated and sorted by display name. Shared by the
    /// Excluded Apps and per-app offset "add" pickers.
    private func runningRegularApps(excluding excluded: Set<String>) -> [BlacklistedApp] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> BlacklistedApp? in
                guard let bundleID = app.bundleIdentifier,
                      bundleID != Bundle.main.bundleIdentifier,
                      !excluded.contains(bundleID),
                      seen.insert(bundleID).inserted else { return nil }
                return BlacklistedApp(bundleID: bundleID, name: app.localizedName ?? bundleID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func addBlacklistedApp(_ app: BlacklistedApp) {
        guard !blacklist.contains(where: { $0.bundleID == app.bundleID }) else { return }
        blacklist.append(app)
        commitBlacklist()
    }

    func addBlacklistedApps(_ apps: [BlacklistedApp]) {
        var changed = false
        for app in apps where !blacklist.contains(where: { $0.bundleID == app.bundleID }) {
            blacklist.append(app)
            changed = true
        }
        if changed { commitBlacklist() }
    }

    func removeBlacklistedApps(bundleIDs: Set<String>) {
        guard !bundleIDs.isEmpty else { return }
        blacklist.removeAll { bundleIDs.contains($0.bundleID) }
        commitBlacklist()
    }

    private func commitBlacklist() {
        Preferences.setBlacklistedApps(blacklist)
        engine.setBlacklistedBundleIDs(Set(blacklist.map { $0.bundleID }))
    }

    // MARK: Per-app title-bar Y offset

    /// Offset a freshly-added app starts at: the current global default, but
    /// clamped into the per-app offset range so the seeded value is always one
    /// the stepper can represent (the global range is wider).
    private var seededPerAppOffset: CGFloat {
        titleBarYOffset.clamped(to: Preferences.perAppTitleBarYOffsetRange)
    }

    /// Add an app to the per-app offset list, seeding its offset with the
    /// current global default so the stepper starts at a sensible value.
    func addPerAppOffset(_ app: BlacklistedApp) {
        guard !perAppOffsets.contains(where: { $0.bundleID == app.bundleID }) else { return }
        perAppOffsets.append(AppTitleBarOffset(bundleID: app.bundleID, name: app.name, offset: seededPerAppOffset))
        commitPerAppOffsets()
    }

    func addPerAppOffsets(_ apps: [BlacklistedApp]) {
        var changed = false
        for app in apps where !perAppOffsets.contains(where: { $0.bundleID == app.bundleID }) {
            perAppOffsets.append(AppTitleBarOffset(bundleID: app.bundleID, name: app.name, offset: seededPerAppOffset))
            changed = true
        }
        if changed { commitPerAppOffsets() }
    }

    func setPerAppOffset(bundleID: String, value: CGFloat) {
        guard let idx = perAppOffsets.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        let clamped = value.rounded().clamped(to: Preferences.titleBarYOffsetRange)
        guard perAppOffsets[idx].offset != clamped else { return }
        perAppOffsets[idx].offset = clamped
        commitPerAppOffsets()
    }

    func removePerAppOffset(bundleID: String) {
        guard perAppOffsets.contains(where: { $0.bundleID == bundleID }) else { return }
        perAppOffsets.removeAll { $0.bundleID == bundleID }
        commitPerAppOffsets()
    }

    private func commitPerAppOffsets() {
        Preferences.setPerAppTitleBarOffsets(perAppOffsets)
        let map = Dictionary(
            perAppOffsets.map { ($0.bundleID, $0.offset) },
            uniquingKeysWith: { _, last in last }
        )
        engine.setPerAppTitleBarYOffsets(map)
    }

    /// Best-effort icon for a bundle id: running instance, then on-disk bundle,
    /// then a generic placeholder.
    func icon(forBundleID bundleID: String) -> NSImage {
        if let icon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon {
            return icon
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - PreferencesWindowController
//
// Hosts the SwiftUI Settings UI (`SettingsRootView`) in a single window with a
// native sidebar, matching HyperCapslock's `MainWindowController`. The public
// API (`init(dragEngine:updateController:)` + `show()`) is unchanged so
// `MenuBarController` keeps working without edits. Closing hides the window
// rather than terminating — AnyDrag is a menu-bar accessory app.
final class PreferencesWindowController: NSObject, NSWindowDelegate {

    private let window: NSWindow
    private let store: SettingsStore

    init(dragEngine: DragEngine, updateController: UpdateController) {
        self.store = SettingsStore(engine: dragEngine, updateController: updateController)

        let root = SettingsRootView().environmentObject(store)
        let hosting = NSHostingController(rootView: root)

        window = NSWindow(contentViewController: hosting)
        window.title = NSLocalizedString("AnyDrag Settings", comment: "")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 860, height: 600))
        window.setFrameAutosaveName("AnyDragSettings")
        window.center()
        super.init()
        window.delegate = self
    }

    /// Bring the window to front, re-syncing any state that can change while
    /// it's closed (permission grant, login-item toggle made elsewhere).
    func show() {
        store.refreshExternalState()
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window.orderOut(nil)
        return false
    }
}
