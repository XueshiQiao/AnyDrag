import Cocoa
import ApplicationServices
import os

extension Notification.Name {
    /// Undocumented but stable distributed notification posted by macOS when
    /// any app's Accessibility trust changes. Verified usage in many open-source
    /// apps (Loop, MonitorControl, Shifty, GitHub Copilot for Xcode, …).
    static let anyDragAXTrustChanged = Notification.Name("com.apple.accessibility.api")
}

// MARK: - Modifier Combination Model

/// User-selectable combination of modifier keys. Any non-empty subset of
/// command/shift/option/control/fn is allowed.
struct ModifierCombination: OptionSet, Equatable, Hashable {
    let rawValue: UInt
    init(rawValue: UInt) { self.rawValue = rawValue }

    static let command = ModifierCombination(rawValue: 1 << 0)
    static let shift   = ModifierCombination(rawValue: 1 << 1)
    static let option  = ModifierCombination(rawValue: 1 << 2)
    static let control = ModifierCombination(rawValue: 1 << 3)
    static let fn      = ModifierCombination(rawValue: 1 << 4)

    static let fnEventFlag = CGEventFlags.maskSecondaryFn

    var eventFlags: CGEventFlags {
        var f: CGEventFlags = []
        if contains(.command) { f.insert(.maskCommand) }
        if contains(.shift)   { f.insert(.maskShift) }
        if contains(.option)  { f.insert(.maskAlternate) }
        if contains(.control) { f.insert(.maskControl) }
        if contains(.fn)      { f.insert(Self.fnEventFlag) }
        return f
    }

    /// Glyph display, e.g. "⌃⌥⇧⌘" or "fn⌘". Order follows Apple HIG (fn ⌃ ⌥ ⇧ ⌘).
    var symbol: String {
        var s = ""
        if contains(.fn)      { s += "fn" }
        if contains(.control) { s += "⌃" }
        if contains(.option)  { s += "⌥" }
        if contains(.shift)   { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s.isEmpty ? "—" : s
    }

    /// Localized name, e.g. "Control + Option + Command".
    var displayName: String {
        var parts: [String] = []
        if contains(.fn)      { parts.append(NSLocalizedString("fn", comment: "")) }
        if contains(.control) { parts.append(NSLocalizedString("Control", comment: "")) }
        if contains(.option)  { parts.append(NSLocalizedString("Option", comment: "")) }
        if contains(.shift)   { parts.append(NSLocalizedString("Shift", comment: "")) }
        if contains(.command) { parts.append(NSLocalizedString("Command", comment: "")) }
        return parts.isEmpty ? "—" : parts.joined(separator: " + ")
    }

    /// True when adding Option to the gesture is allowed (so users can combine
    /// AnyDrag with the macOS "Hold Option while dragging windows to tile" feature).
    var supportsOptionAugmentation: Bool {
        !contains(.option)
    }

    /// Migrate the pre-1.3 `ModifierKey` string preference.
    init?(legacyString: String) {
        switch legacyString {
        case "option":         self = .option
        case "command":        self = .command
        case "control":        self = .control
        case "fn":             self = .fn
        case "option+command": self = [.option, .command]
        default:               return nil
        }
    }
}

// MARK: - Middle Action Model

/// What the middle mouse button does. Mutually exclusive — the user picks one.
enum MiddleAction: String, CaseIterable {
    case off = "off"
    case dragWindow = "drag"
    case tileByDirection = "tile"

    var displayName: String {
        switch self {
        case .off:              return NSLocalizedString("Off", comment: "")
        case .dragWindow:       return NSLocalizedString("Drag window", comment: "")
        case .tileByDirection:  return NSLocalizedString("Tile by direction", comment: "")
        }
    }
}

// MARK: - Tile Zone Model

/// A target region on the screen, selected by drag direction.
enum TileZone {
    case full          // drag up
    case centered      // drag down (~70% × 70%)
    case left, right
    case topLeft, topRight, bottomLeft, bottomRight

    /// Map a cursor offset (in CG coords, Y-down) relative to the bento
    /// overlay's center to a tile zone via 3×3 cell hit-testing. Returns
    /// nil when the cursor is inside the center deadzone (cancel cell).
    ///
    /// Cell boundaries align with the visible gaps in `TileCancelDot`'s
    /// 3×3 grid — keep the half-deadzone constants in sync with the
    /// drawn cell geometry so "cursor crossing the visible gap" matches
    /// "cursor commits to the adjacent tile".
    static func bentoZone(forDx dx: CGFloat,
                          dy: CGFloat,
                          halfDeadzoneWidth: CGFloat,
                          halfDeadzoneHeight: CGFloat) -> TileZone? {
        let col: Int = dx < -halfDeadzoneWidth ? 0 : (dx > halfDeadzoneWidth ? 2 : 1)
        let row: Int = dy < -halfDeadzoneHeight ? 0 : (dy > halfDeadzoneHeight ? 2 : 1)
        // Center cell — release here to cancel.
        if col == 1 && row == 1 { return nil }
        // Y-down: row 0 = above center = top of screen. The middle entry of
        // the middle row is unreachable (the col==1 && row==1 early return
        // above is the only path to it); `.full` is a harmless placeholder
        // chosen to keep the matrix non-Optional.
        let grid: [[TileZone]] = [
            [.topLeft,    .full,      .topRight],
            [.left,       .full,      .right],
            [.bottomLeft, .centered,  .bottomRight],
        ]
        return grid[row][col]
    }

    /// Compute the target rect within the screen's visible NSScreen-coord frame
    /// (bottom-left origin). For .centered the window covers 85% × 85%.
    func rect(in v: NSRect, centeredFraction: CGFloat = 0.85) -> NSRect {
        switch self {
        case .full:
            return v
        case .centered:
            let w = v.width * centeredFraction
            let h = v.height * centeredFraction
            return NSRect(x: v.minX + (v.width - w) / 2,
                          y: v.minY + (v.height - h) / 2,
                          width: w, height: h)
        case .left:
            return NSRect(x: v.minX, y: v.minY, width: v.width / 2, height: v.height)
        case .right:
            return NSRect(x: v.midX, y: v.minY, width: v.width / 2, height: v.height)
        case .topLeft:
            return NSRect(x: v.minX, y: v.midY, width: v.width / 2, height: v.height / 2)
        case .topRight:
            return NSRect(x: v.midX, y: v.midY, width: v.width / 2, height: v.height / 2)
        case .bottomLeft:
            return NSRect(x: v.minX, y: v.minY, width: v.width / 2, height: v.height / 2)
        case .bottomRight:
            return NSRect(x: v.midX, y: v.minY, width: v.width / 2, height: v.height / 2)
        }
    }
}

// MARK: - DragEngine

/// Intercepts mouse events via a CGEvent tap and delegates to TitleBarDragStrategy
/// when a configured modifier key is held during a click.
final class DragEngine {

    private static let relevantModifierMask = CGEventFlags([
        .maskAlternate, .maskCommand, .maskControl, .maskShift, ModifierCombination.fnEventFlag
    ])

    // Marker carried on synthesized replay events so we ignore them in our own tap.
    private static let synthesizedEventMarker: Int64 = 0x416E794472616701  // "AnyDrag\x01"

    private static let log = FileLog("DragEngine")

    var modifiers: ModifierCombination = .option
    var dragEnabled: Bool = true
    var maximizeEnabled: Bool = true
    var tilingEnabled: Bool = true
    var middleAction: MiddleAction = .off {
        didSet {
            // If the user changes the middle-button action mid-gesture, abort
            // the in-flight tile so a stale gesture can't apply on release.
            guard oldValue != middleAction else { return }
            let hasInFlight = cbState.withLock { $0.tileTarget != nil }
            guard hasInFlight else { return }
            abortTileGesture()
        }
    }

    var titleBarYOffset: CGFloat {
        get { strategy.titleBarYOffset }
        set { strategy.titleBarYOffset = newValue }
    }

    var showDebugDot: Bool {
        get { strategy.showDebugDot }
        set { strategy.showDebugDot = newValue }
    }

    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?

    /// Retained `self` pointer handed to the C event-tap callback. Created
    /// once on first `start()` and never released until `deinit` — releasing
    /// while a callback might still be on the stack would UAF (the callback
    /// uses `takeUnretainedValue`). Cost: a one-time self-cycle while the
    /// engine is alive. Safe because AnyDrag uses one DragEngine for the
    /// process lifetime (held by `AppDelegate.dragEngine`); `deinit` is
    /// effectively unreachable, which we accept rather than introducing
    /// teardown coordination across threads.
    private var tapUserInfo: UnsafeMutableRawPointer?

    /// State shared between the tap-callback thread and main thread,
    /// guarded by one unfair lock to avoid Swift data races. The fast-path
    /// `handleEvent` reads `trusted` + bumps `eventCounter` per event;
    /// `tap` and `tapRunLoop` are written by start/stop on main and the
    /// new tap thread (only at startup), and read on main in `stop()`.
    /// Tile-by-direction gesture fields are written by the tap thread on
    /// every middle-button event AND by main from `abortTileGesture()`
    /// inside `stop()`, so they live here too.
    ///
    /// The callback **never** reads `tap` from this state — that would
    /// open a race where an in-flight callback from an old tap generation
    /// could read a freshly-installed new tap and disable it. Instead,
    /// any tap manipulation the callback wants to do is dispatched to
    /// main, which reads the current `tap` under the lock.
    private struct CallbackState {
        var trusted: Bool = true
        var tap: CFMachPort? = nil
        var tapRunLoop: CFRunLoop? = nil
        var eventCounter: Int = 0
        // Middle-button tile-by-direction gesture state. Mutated by both
        // the tap callback and main (from abortTileGesture / stop).
        var tileTarget: (pid: pid_t, windowID: CGWindowID, frame: CGRect, app: String)? = nil
        var tileZone: TileZone? = nil
        var middleClickOrigin: CGPoint? = nil
        // Sticky: set true the first drag event that resolves to a non-nil
        // zone. Releasing in the deadzone with this true means the user
        // actively chose a direction and then changed their mind — cancel
        // cleanly without replaying the middle-click. False means the
        // gesture never left the center cell (likely just a tap), so the
        // middle-click is replayed so apps see it (browser tab close, etc.).
        var tileSawDirection: Bool = false
        // Right-button gesture pending state: set at modifier+rightMouseDown,
        // consumed at rightMouseUp. If no drag happened, we open TilingPanel
        // with this target (preserving the old right-click-to-tile behavior);
        // if a drag happened, the resize strategy committed the new geometry
        // and we just clear the pending info.
        var rightTarget: (pid: pid_t, windowID: CGWindowID, frame: CGRect, app: String)? = nil
        var rightOrigin: CGPoint? = nil
        // Throttle anchor for diagnostic "miss" logs (modifier mismatch,
        // no-window-under-cursor). Shared bucket; 1s window keeps the log
        // readable when a user clicks rapidly.
        var lastDiagMissAt: CFAbsoluteTime = 0
    }
    private let cbState = OSAllocatedUnfairLock<CallbackState>(initialState: CallbackState())

    private var trustNotificationObserver: NSObjectProtocol?
    /// Staircase of delayed probes scheduled after each
    /// `com.apple.accessibility.api` notification. We probe at multiple
    /// offsets because `AXIsProcessTrusted()` — the only API that detects
    /// a *revoke* for non-sandboxed processes — has variable TCC settle
    /// latency. A single 250ms probe used to miss slow revokes, leaving
    /// our unauthorized `.defaultTap` at the head of the event chain and
    /// freezing system-wide clicks.
    private var trustRestoreDebounceTasks: [DispatchWorkItem] = []
    private var backstopTimer: Timer?

    /// Wall-clock anchor for the backstop's events-per-second log. Only
    /// touched on main, so no lock needed.
    private var eventCounterStart: Date = Date()

    private let strategy = TitleBarDragStrategy()
    private let resizeStrategy = ResizeStrategy()
    private var savedFrames: [CGWindowID: CGRect] = [:]
    private var tilingPanel: TilingPanel?
    private lazy var tileOverlay = TileOverlay()
    private lazy var tileCancelDot = TileCancelDot()

    // Middle-button tile state and click origin live in `cbState` (see
    // `CallbackState` above) so they're race-free under the lock.

    // MARK: - Lifecycle

    init() {
        installTrustObserver()
    }

    deinit {
        removeTrustObserver()
        if let userInfo = tapUserInfo {
            // Balance the `Unmanaged.passRetained(self)` from the first
            // `start()`. Safe at deinit: by the time we get here, no
            // callback can be running (deinit means refcount hit zero,
            // which couldn't have happened while the tap held a retain).
            Unmanaged<DragEngine>.fromOpaque(userInfo).release()
        }
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        Self.log.info("start(): entering")

        let alreadyRunning = cbState.withLock { $0.tap != nil }
        guard !alreadyRunning else {
            Self.log.info("start(): already running, no-op")
            return
        }
        // Don't pre-check via `AXIsProcessTrusted()` — its TCC cache lags
        // System-Settings toggles by ~hundreds of ms (forum thread 727984),
        // which produced an "inverted" trust state in earlier builds.
        // Just attempt `CGEvent.tapCreate` and treat its result as the
        // ground truth; we update the cache from the actual outcome.

        let eventMask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) |
                                     (1 << CGEventType.leftMouseDragged.rawValue) |
                                     (1 << CGEventType.leftMouseUp.rawValue) |
                                     (1 << CGEventType.rightMouseDown.rawValue) |
                                     (1 << CGEventType.rightMouseDragged.rawValue) |
                                     (1 << CGEventType.rightMouseUp.rawValue) |
                                     (1 << CGEventType.otherMouseDown.rawValue) |
                                     (1 << CGEventType.otherMouseDragged.rawValue) |
                                     (1 << CGEventType.otherMouseUp.rawValue)

        // Retain `self` exactly once across the engine's lifetime. Reused on
        // re-start so we never accumulate unbalanced retains.
        if tapUserInfo == nil {
            tapUserInfo = Unmanaged.passRetained(self).toOpaque()
        }
        guard let userInfo = tapUserInfo else { return }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: userInfo
        ) else {
            Self.log.warn("start(): tapCreate failed — AX not authorized")
            // tapCreate is the source of truth; sync the cache to match
            // so the fast path and UI both see the actual state.
            cbState.withLock { $0.trusted = false }
            return
        }

        // Tap created — we ARE authorized. Lock in the truth.
        cbState.withLock { state in
            state.tap = tap
            state.trusted = true
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source

        // Capture the tap thread's run loop so `stop()` can wake it.
        // `source` is captured by value (closure local) so the tap thread
        // never reads `self.runLoopSource` — keeping that field main-only.
        // The semaphore ensures `start()` returns only after the tap
        // thread has recorded its run loop into `cbState.tapRunLoop`.
        let runLoopReady = DispatchSemaphore(value: 0)
        let thread = Thread { [source, weak self] in
            let runLoop = CFRunLoopGetCurrent()
            self?.cbState.withLock { $0.tapRunLoop = runLoop }
            CFRunLoopAddSource(runLoop, source, .commonModes)
            runLoopReady.signal()
            CFRunLoopRun()
            // Returns after CFRunLoopStop is called from stop().
            Self.log.info("tap thread run loop exited")
        }
        thread.qualityOfService = .userInteractive
        thread.name = "com.anydrag.eventtap"
        thread.start()
        tapThread = thread

        // Bounded wait so a wedged Thread.start can't hang main forever.
        // 1 second is generous — the new thread does just CFRunLoopGetCurrent
        // before signaling; if it can't manage that, the system is in a
        // worse state than this lock can fix. On timeout we leak the
        // partially-started thread (it'll be reaped at process exit) but
        // do not block main.
        let waitResult = runLoopReady.wait(timeout: .now() + 1.0)
        guard waitResult == .success else {
            Self.log.error("start(): tap thread did not signal readiness within 1s — aborting")
            // Best-effort rollback so a half-started state can't trip stop().
            cbState.withLock { state in
                if let t = state.tap {
                    CGEvent.tapEnable(tap: t, enable: false)
                    CFMachPortInvalidate(t)
                }
                state.tap = nil
                state.tapRunLoop = nil
            }
            if let source = runLoopSource { CFRunLoopSourceInvalidate(source) }
            runLoopSource = nil
            tapThread = nil
            return
        }

        cbState.withLock { $0.eventCounter = 0 }
        eventCounterStart = Date()
        startBackstopTimer()

        Self.log.info("start(): tap created OK")
        Self.log.info("config: modifier=\(self.modifiers.symbol) drag=\(self.dragEnabled) max=\(self.maximizeEnabled) tile=\(self.tilingEnabled) middle=\(self.middleAction.rawValue) yOffset=\(self.strategy.titleBarYOffset) debugDot=\(self.strategy.showDebugDot)")
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        Self.log.info("stop(): tearing down event tap")

        // Atomically pull the tap and run loop out of the shared state.
        // After this exits the lock, the cbState reflects "no tap running"
        // — a concurrent fast-path reader sees `tap = nil` and skips. The
        // captured locals here are then used to actually invalidate things
        // outside the lock, which is fine because CFMachPort/CFRunLoop
        // operations are thread-safe per Apple docs.
        let (tap, runLoop) = cbState.withLock { state -> (CFMachPort?, CFRunLoop?) in
            let t = state.tap
            let r = state.tapRunLoop
            state.tap = nil
            state.tapRunLoop = nil
            return (t, r)
        }
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopSourceInvalidate(source)
        }
        if let runLoop = runLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
        runLoopSource = nil
        tapThread = nil
        // tapUserInfo intentionally NOT released — kept for next start().
        // Released only in deinit (see init notes).

        strategy.reset()
        resizeStrategy.reset()
        abortTileGesture()
        cbState.withLock { state in
            state.rightTarget = nil
            state.rightOrigin = nil
        }

        // Backstop deliberately kept alive across stop(). `AXIsProcessTrusted`
        // has TCC settle latency that can exceed the 2.5 s notification
        // staircase. Without a running backstop, a false-revoke from
        // `tapDisabledBy*` (or a legitimate re-grant later in the
        // session) would never be observed automatically — the engine
        // would stay stopped until the next distributed AX notification
        // or app restart. Five-second ticks reading `AXIsProcessTrusted`
        // cost essentially nothing and recover the engine without user
        // intervention.
        trustRestoreDebounceTasks.forEach { $0.cancel() }
        trustRestoreDebounceTasks.removeAll()

        Self.log.info("stop(): teardown complete (backstop left running)")
    }

    // MARK: - AX Trust Observation

    private func installTrustObserver() {
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: .anyDragAXTrustChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleTrustNotification()
        }
        trustNotificationObserver = observer
        Self.log.info("AX trust distributed notification observer installed")
    }

    private func removeTrustObserver() {
        if let observer = trustNotificationObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            trustNotificationObserver = nil
        }
    }

    private func handleTrustNotification() {
        dispatchPrecondition(condition: .onQueue(.main))
        Self.log.info("AX trust notification fired; scheduling check staircase")
        // The notification is just a "something changed" hint — for ANY
        // app, not just us. We need to discover whether *our* trust just
        // flipped. `AXIsProcessTrusted` reads TCC state and lags the
        // System Settings toggle by a variable amount (hundreds of ms,
        // sometimes longer on slow machines), so we re-check at a
        // staircase of delays — 250ms catches fast settles, 2500ms covers
        // the slow tail. The always-on 5s backstop catches anything past
        // 2500ms.
        trustRestoreDebounceTasks.forEach { $0.cancel() }
        trustRestoreDebounceTasks.removeAll()
        let delaysMs: [Int] = [250, 1000, 2500]
        for delay in delaysMs {
            let task = DispatchWorkItem { [weak self] in
                self?.recheckTrust(source: "notification+\(delay)ms")
            }
            trustRestoreDebounceTasks.append(task)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: task)
        }
    }

    /// Probe the actual AX state and reconcile cache + engine lifecycle.
    /// Called from the notification handler and the backstop poll.
    private func recheckTrust(source: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        let prior = cbState.withLock { $0.trusted }
        let trusted = AXIsProcessTrusted()
        Self.log.info("Trust check [\(source)]: prior=\(prior) → AXIsProcessTrusted=\(trusted)")
        applyTrustChange(trusted, source: source)
    }

    /// Update the cached trust state and start/stop the engine accordingly.
    /// Safe to call repeatedly — no-op when the cached state already matches.
    private func applyTrustChange(_ trusted: Bool, source: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        let previous = cbState.withLock { state -> Bool in
            let p = state.trusted
            state.trusted = trusted
            return p
        }
        guard previous != trusted else {
            Self.log.debug("Trust unchanged (\(trusted)) from \(source); ignoring")
            return
        }
        Self.log.warn("AX trust transition: \(previous) → \(trusted) [\(source)]")

        if trusted {
            start()
        } else {
            stop()
        }
    }

    // MARK: - Backstop poll

    /// Periodic trust poll, (re)created on every successful `start()` and
    /// **deliberately kept alive across `stop()` calls** for the engine's
    /// lifetime. Two responsibilities:
    ///
    /// 1. While trusted: catch missed `com.apple.accessibility.api`
    ///    distributed notifications (the name is undocumented and not
    ///    guaranteed reliable) and dump event-rate stats for diagnostics.
    /// 2. While untrusted (post-revoke): catch a re-grant — or a false
    ///    positive from the `tapDisabledBy*` recovery path — that the
    ///    notification staircase missed. Without this, the engine would
    ///    stay wedged until the next AX notification or app restart.
    private func startBackstopTimer() {
        backstopTimer?.invalidate()
        backstopTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.backstopTick()
        }
    }

    /// Belt-and-suspenders trust check at each AX-call entry point. Closes
    /// the brief window where the cached `cbState.trusted` may still
    /// report true while an `com.apple.accessibility.api` notification is
    /// in flight. Cheap to call (single TCC query, microseconds) — these
    /// sites are user-gesture-driven, not in any hot loop. If trust is
    /// gone, schedules a full teardown.
    private func axGuardOrAbort(_ site: String) -> Bool {
        if AXIsProcessTrusted() { return true }
        Self.log.warn("AX call site '\(site)' aborted — AXIsProcessTrusted=false")
        DispatchQueue.main.async { [weak self] in
            self?.applyTrustChange(false, source: "axGuard:\(site)")
        }
        return false
    }

    private func backstopTick() {
        dispatchPrecondition(condition: .onQueue(.main))
        let snapshot = cbState.withLock { state -> (Bool, Int) in
            let s = (state.trusted, state.eventCounter)
            state.eventCounter = 0
            return s
        }
        let cached = snapshot.0
        let count = snapshot.1
        let actual = AXIsProcessTrusted()
        let elapsed = Date().timeIntervalSince(eventCounterStart)
        eventCounterStart = Date()
        let perSec = elapsed > 0 ? Double(count) / elapsed : 0
        Self.log.debug(String(
            format: "Backstop: AX cache=%@, actual=%@, events=%d in %.1fs (%.1f/s)",
            cached ? "true" : "false",
            actual ? "true" : "false",
            count, elapsed, perSec
        ))

        if actual != cached {
            Self.log.warn("Backstop detected drift cache=\(cached) vs actual=\(actual) — applying")
            applyTrustChange(actual, source: "backstop")
        }
    }

    /// Discard any in-flight tile-by-direction gesture and tear down its
    /// overlays. Safe to call from any thread — tile fields are guarded
    /// by `cbState`, and the overlay teardown is dispatched to main.
    private func abortTileGesture() {
        cbState.withLock { state in
            state.tileTarget = nil
            state.tileZone = nil
            state.middleClickOrigin = nil
            state.tileSawDirection = false
        }
        DispatchQueue.main.async { [weak self] in
            self?.tileOverlay.hide()
            self?.tileCancelDot.hide()
        }
    }

    // MARK: - Event Handling

    fileprivate func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Snapshot trust + bump the per-event counter under one lock. We
        // do NOT read `state.tap` here — see the CallbackState comment for
        // why (rapid-restart generation race). Any tap manipulation is
        // dispatched to main, which holds the lock when reading tap.
        let trusted = cbState.withLock { state -> Bool in
            state.eventCounter &+= 1
            return state.trusted
        }

        // Fast path: AX trust was revoked. Just pass the event through
        // untouched; main is on the way to `stop()` (or the backstop will
        // catch us). The system can route events around an unauthorized
        // tap as long as we don't suppress or modify them.
        //
        // Note: this branch silently skips `tapDisabledBy*` handling
        // when cache=false. That's intentional — `stop()` itself will
        // call `CFMachPortInvalidate` and `abortTileGesture()`, so no
        // cleanup is lost.
        if !trusted {
            return Unmanaged.passUnretained(event)
        }

        // Tap disabled by the system (callback ran too long, or AX was
        // revoked). Decide on main where we can probe and access the
        // tap reference race-free.
        if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
            Self.log.info("tap-disabled event \(type) — dispatching trust check to main")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // We're here because the OS just killed our tap. The tap
                // can only exist if we were previously trusted, so this
                // is unambiguously a revoke-direction check — consult
                // `AXIsProcessTrusted()` directly. The listen-only mouse
                // probe used here previously *lied on revoke* (succeeded
                // because WindowServer pins per-process trust at launch),
                // which made us re-enable an unauthorized `.defaultTap`
                // at the head of the event chain and freeze all clicks
                // system-wide. TCC has had plenty of time to settle by
                // the time we receive a tap-disabled event, so the bare
                // `AXIsProcessTrusted()` read is the right oracle here.
                let trusted = AXIsProcessTrusted()
                Self.log.info("tap-disabled trust check: AXIsProcessTrusted=\(trusted)")
                if trusted {
                    self.cbState.withLock { state in
                        if let tap = state.tap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                            Self.log.info("Re-enabled tap (still authorized)")
                        }
                    }
                } else {
                    Self.log.warn("tap-disabled and AX revoked — calling applyTrustChange(false)")
                    self.applyTrustChange(false, source: "tap-disabled")
                }
            }
            // The tap missed events while disabled — any in-flight tile
            // gesture is now stranded. Drop it so we don't apply a stale
            // tile on the next mouse-up.
            abortTileGesture()
            // Same reasoning for the right-button resize gesture: a missed
            // rightUp would leave `resizeStrategy.isActive` stuck true,
            // intercepting the next right-click. Drop it so the next gesture
            // starts clean.
            if resizeStrategy.isActive {
                resizeStrategy.reset()
                cbState.withLock { state in
                    state.rightTarget = nil
                    state.rightOrigin = nil
                }
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown:
            return handleMouseDown(event: event)
        case .leftMouseDragged:
            return handleMouseDragged(event: event)
        case .leftMouseUp:
            return handleMouseUp(event: event)
        case .rightMouseDown:
            return handleRightMouseDown(event: event)
        case .rightMouseDragged:
            return handleRightMouseDragged(event: event)
        case .rightMouseUp:
            return handleRightMouseUp(event: event)
        case .otherMouseDown:
            return handleOtherMouseDown(event: event)
        case .otherMouseDragged:
            return handleOtherMouseDragged(event: event)
        case .otherMouseUp:
            return handleOtherMouseUp(event: event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Mouse Down

    private func handleMouseDown(event: CGEvent) -> Unmanaged<CGEvent>? {
        // If tiling panel is visible, don't intercept — let clicks reach the panel
        if tilingPanel?.isVisible == true {
            return Unmanaged.passUnretained(event)
        }

        // Both left-button features off → nothing to do here.
        if !dragEnabled && !maximizeEnabled {
            return Unmanaged.passUnretained(event)
        }

        // Check if the configured modifier key is held.
        // We also allow an extra Option key for non-Option shortcuts so
        // macOS native tiling can still kick in during an AnyDrag drag.
        guard matchesConfiguredModifier(event.flags) else {
            logModifierMiss(flags: event.flags, button: "left")
            return Unmanaged.passUnretained(event)
        }

        let screenPoint = event.location

        // Pass clicks on the primary screen's menu bar through.
        if Self.isOnPrimaryMenuBar(screenPoint) {
            return Unmanaged.passUnretained(event)
        }

        // Find the topmost normal window (layer 0) under the cursor
        guard let windowInfo = windowUnderCursor(at: screenPoint) else {
            logNoWindowMiss(button: "left", at: screenPoint)
            return Unmanaged.passUnretained(event)
        }

        // Double-click with modifier: toggle maximize/restore
        let clickCount = event.getIntegerValueField(.mouseEventClickState)
        if clickCount == 2 {
            guard maximizeEnabled else { return Unmanaged.passUnretained(event) }
            guard axGuardOrAbort("toggleMaximize") else {
                return Unmanaged.passUnretained(event)
            }
            Self.log.info("maximize toggle: app=\"\(windowInfo.app)\" wid=\(windowInfo.windowID)")
            toggleMaximize(windowID: windowInfo.windowID, pid: windowInfo.pid, windowFrame: windowInfo.frame)
            return nil
        }

        guard dragEnabled else {
            return Unmanaged.passUnretained(event)
        }

        guard axGuardOrAbort("strategy.handleMouseDown(left)") else {
            return Unmanaged.passUnretained(event)
        }

        // Clear any orphaned middle-gesture state (e.g. from a tap-disabled
        // gesture where we never received the otherMouseUp).
        let hadStaleTile = cbState.withLock { state -> Bool in
            if state.tileTarget != nil { return true }
            state.middleClickOrigin = nil
            return false
        }
        if hadStaleTile {
            abortTileGesture()
        }
        // If the user starts a fresh left drag while a right-resize is
        // somehow still in flight (lost rightUp, modifier-key remap, etc.),
        // drop the stale resize state so a stranded gesture can't commit on
        // some future event.
        if resizeStrategy.isActive {
            resizeStrategy.reset()
            cbState.withLock { state in
                state.rightTarget = nil
                state.rightOrigin = nil
            }
        }
        strategy.reset()
        Self.log.info("drag start: app=\"\(windowInfo.app)\" wid=\(windowInfo.windowID)")
        return strategy.handleMouseDown(
            pid: windowInfo.pid,
            windowID: windowInfo.windowID,
            windowFrame: windowInfo.frame,
            event: event
        )
    }

    // MARK: - Mouse Dragged

    private func handleMouseDragged(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard strategy.isActive else {
            return Unmanaged.passUnretained(event)
        }
        return strategy.handleMouseDragged(event: event)
    }

    // MARK: - Mouse Up

    private func handleMouseUp(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard strategy.isActive else {
            return Unmanaged.passUnretained(event)
        }
        let didDrag = strategy.didDrag
        let modsForAnalytics = self.modifiers
        let result = strategy.handleMouseUp(event: event)
        if didDrag {
            DispatchQueue.main.async {
                Analytics.trackDrag(trigger: .modifier, modifier: modsForAnalytics)
            }
        }
        return result
    }

    // MARK: - Right Button (resize-from-anywhere or open TilingPanel)
    //
    // A modifier+right-click WITHOUT a drag opens the TilingPanel (the
    // pre-existing behavior). A modifier+right-click WITH a drag starts a
    // resize-from-anywhere gesture: the cursor's quadrant in the window
    // picks the resize corner; the strategy rewrites events so the window
    // server treats it as a native edge drag (no per-frame AX call). We
    // can't decide which it is at down-time, so we suppress the down and
    // defer the choice until rightMouseDragged (resize) or rightMouseUp
    // without an intervening drag (panel).

    private func handleRightMouseDown(event: CGEvent) -> Unmanaged<CGEvent>? {
        // If tiling panel is visible, suppress right-click (avoid system context menu)
        if tilingPanel?.isVisible == true {
            return nil
        }

        guard tilingEnabled else {
            return Unmanaged.passUnretained(event)
        }

        guard matchesConfiguredModifier(event.flags) else {
            logModifierMiss(flags: event.flags, button: "right")
            return Unmanaged.passUnretained(event)
        }

        let screenPoint = event.location

        // Pass clicks on the primary screen's menu bar through.
        if Self.isOnPrimaryMenuBar(screenPoint) {
            return Unmanaged.passUnretained(event)
        }

        guard let windowInfo = windowUnderCursor(at: screenPoint) else {
            logNoWindowMiss(button: "right", at: screenPoint)
            return Unmanaged.passUnretained(event)
        }

        guard axGuardOrAbort("resizeStrategy.handleMouseDown(right)") else {
            return Unmanaged.passUnretained(event)
        }

        // Stash the target so a no-drag release can open the TilingPanel
        // with the same window we considered here.
        cbState.withLock { state in
            state.rightTarget = windowInfo
            state.rightOrigin = screenPoint
        }

        Self.log.info("right gesture start: app=\"\(windowInfo.app)\" wid=\(windowInfo.windowID)")

        // Suppress the down; the strategy will replay it as a leftMouseDown
        // on the first drag (resize) — or `handleRightMouseUp` will open the
        // panel if no drag arrives.
        return resizeStrategy.handleMouseDown(
            pid: windowInfo.pid,
            windowID: windowInfo.windowID,
            windowFrame: windowInfo.frame,
            event: event
        )
    }

    private func handleRightMouseDragged(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard resizeStrategy.isActive else {
            return Unmanaged.passUnretained(event)
        }
        return resizeStrategy.handleMouseDragged(event: event)
    }

    private func handleRightMouseUp(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard resizeStrategy.isActive else {
            return Unmanaged.passUnretained(event)
        }

        let didDrag = resizeStrategy.didDrag
        let result = resizeStrategy.handleMouseUp(event: event)

        if didDrag {
            // Resize committed natively via the rewritten event stream.
            // Clear the pending right-gesture state and we're done.
            cbState.withLock { state in
                state.rightTarget = nil
                state.rightOrigin = nil
            }
            return result
        }

        // No drag — fall through to the original "open TilingPanel" behavior
        // using the target we stashed at mouseDown.
        let pending: (target: (pid: pid_t, windowID: CGWindowID, frame: CGRect, app: String), origin: CGPoint)? = cbState.withLock { state in
            guard let target = state.rightTarget, let origin = state.rightOrigin else { return nil }
            state.rightTarget = nil
            state.rightOrigin = nil
            return (target, origin)
        }
        if let pending {
            // `NSEvent.mouseLocation` gives us NS-coords (bottom-left origin);
            // the original right-down code used that, so mirror it here for
            // consistent panel positioning.
            let mouseLocation = NSEvent.mouseLocation
            let target = pending.target
            DispatchQueue.main.async { [weak self] in
                self?.showTilingPanel(at: mouseLocation, for: target)
            }
        }
        return result  // typically nil — strategy.handleMouseUp returns nil on no-drag
    }

    // MARK: - Middle Button (drag or tile-by-direction)

    private func handleOtherMouseDown(event: CGEvent) -> Unmanaged<CGEvent>? {
        // Only the middle button (button 2) — leave side buttons (3, 4) alone.
        guard event.getIntegerValueField(.mouseEventButtonNumber) == 2 else {
            return Unmanaged.passUnretained(event)
        }

        // Skip our own replay events so they don't recurse.
        if event.getIntegerValueField(.eventSourceUserData) == Self.synthesizedEventMarker {
            return Unmanaged.passUnretained(event)
        }

        guard middleAction != .off else {
            return Unmanaged.passUnretained(event)
        }

        if tilingPanel?.isVisible == true {
            return Unmanaged.passUnretained(event)
        }

        // Don't start a middle gesture while a left drag is in flight.
        if strategy.isActive {
            return Unmanaged.passUnretained(event)
        }

        // Defense in depth: if a previous tile gesture lost its mouse-up (rare —
        // tap-disabled events also clean up), drop the stranded state before
        // starting a new one so the old overlay can't survive.
        let hadStaleTile = cbState.withLock { $0.tileTarget != nil }
        if hadStaleTile {
            abortTileGesture()
        }

        let screenPoint = event.location

        // Pass clicks on the primary screen's menu bar through (mirrors handleMouseDown).
        if Self.isOnPrimaryMenuBar(screenPoint) {
            return Unmanaged.passUnretained(event)
        }

        guard let windowInfo = windowUnderCursor(at: screenPoint) else {
            logNoWindowMiss(button: "middle", at: screenPoint)
            return Unmanaged.passUnretained(event)
        }

        switch middleAction {
        case .off:
            return Unmanaged.passUnretained(event)

        case .dragWindow:
            guard axGuardOrAbort("strategy.handleMouseDown(middle)") else {
                return Unmanaged.passUnretained(event)
            }
            cbState.withLock { $0.middleClickOrigin = screenPoint }
            strategy.reset()
            Self.log.info("middle drag start: app=\"\(windowInfo.app)\" wid=\(windowInfo.windowID)")
            return strategy.handleMouseDown(
                pid: windowInfo.pid,
                windowID: windowInfo.windowID,
                windowFrame: windowInfo.frame,
                event: event,
                rewriteToLeftButton: true
            )

        case .tileByDirection:
            // Window stays put — we use the middle drag to pick a tile target.
            cbState.withLock { state in
                state.middleClickOrigin = screenPoint
                state.tileTarget = windowInfo
                state.tileZone = nil
                state.tileSawDirection = false
            }
            DispatchQueue.main.async { [weak self] in
                self?.tileCancelDot.show(atCGPoint: screenPoint)
            }
            Self.log.info("tile gesture start: app=\"\(windowInfo.app)\" wid=\(windowInfo.windowID)")
            return nil  // suppress the down; will replay middle-click on no-drag release
        }
    }

    private func handleOtherMouseDragged(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard event.getIntegerValueField(.mouseEventButtonNumber) == 2 else {
            return Unmanaged.passUnretained(event)
        }

        // Snapshot tile fields atomically; if a tile gesture is in flight,
        // compute the new zone and write it back under the same lock so an
        // abort-from-main running concurrently can't tear it.
        struct TileSnap {
            let origin: CGPoint
            let zone: TileZone?
        }
        let tileSnap: TileSnap? = cbState.withLock { state -> TileSnap? in
            guard state.tileTarget != nil, let origin = state.middleClickOrigin else { return nil }
            let dx = event.location.x - origin.x
            let dy = event.location.y - origin.y
            let zone = TileZone.bentoZone(
                forDx: dx, dy: dy,
                halfDeadzoneWidth: TileCancelDot.halfDeadzoneWidth,
                halfDeadzoneHeight: TileCancelDot.halfDeadzoneHeight
            )
            state.tileZone = zone
            if zone != nil { state.tileSawDirection = true }
            return TileSnap(origin: origin, zone: zone)
        }

        if let snap = tileSnap {
            let cursorScreenPoint = event.location
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let zone = snap.zone, let screen = self.screen(containingCGPoint: cursorScreenPoint) {
                    let target = zone.rect(in: screen.visibleFrame)
                    self.tileOverlay.show(rect: target)
                    self.tileCancelDot.setActiveZone(zone)
                } else {
                    self.tileOverlay.hide()
                    self.tileCancelDot.setActiveZone(nil)
                }
            }
            return nil
        }

        // Drag-window path (existing).
        let hasOrigin = cbState.withLock { $0.middleClickOrigin != nil }
        guard strategy.isActive, hasOrigin else {
            return Unmanaged.passUnretained(event)
        }
        return strategy.handleMouseDragged(event: event)
    }

    private func handleOtherMouseUp(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard event.getIntegerValueField(.mouseEventButtonNumber) == 2 else {
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.synthesizedEventMarker {
            return Unmanaged.passUnretained(event)
        }

        // Tile-by-direction path. Pull all gesture state out under one
        // lock so the read+clear pair is atomic with a concurrent
        // `abortTileGesture` from main.
        struct TileFinish {
            let target: (pid: pid_t, windowID: CGWindowID, frame: CGRect, app: String)
            let origin: CGPoint
            let zone: TileZone?
            let sawDirection: Bool
        }
        let tileFinish: TileFinish? = cbState.withLock { state -> TileFinish? in
            guard let target = state.tileTarget, let origin = state.middleClickOrigin else { return nil }
            let zone = state.tileZone
            let sawDirection = state.tileSawDirection
            state.tileTarget = nil
            state.middleClickOrigin = nil
            state.tileZone = nil
            state.tileSawDirection = false
            return TileFinish(target: target, origin: origin, zone: zone, sawDirection: sawDirection)
        }
        if let finish = tileFinish {
            let cursorScreenPoint = event.location
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.tileOverlay.hide()
                self.tileCancelDot.hide()
                if let zone = finish.zone, let screen = self.screen(containingCGPoint: cursorScreenPoint) {
                    self.applyTile(zone: zone, target: finish.target, screen: screen)
                } else if finish.sawDirection {
                    // User actively chose a direction and then moved back into
                    // the cancel cell — clean cancel, don't replay the click.
                    Self.log.info("tile gesture cancelled by user (returned to deadzone)")
                } else {
                    // Cursor never left the center cell — treat as a plain
                    // middle-click so apps still see it (browser tab close, etc.).
                    self.replayMiddleClick(at: finish.origin)
                }
            }
            return nil
        }

        // Drag-window path (existing). Pull and clear `middleClickOrigin`
        // atomically so a concurrent abort can't observe a half-cleared state.
        let dragOrigin: CGPoint? = cbState.withLock { state -> CGPoint? in
            let o = state.middleClickOrigin
            state.middleClickOrigin = nil
            return o
        }
        guard strategy.isActive, dragOrigin != nil else {
            return Unmanaged.passUnretained(event)
        }

        let didDrag = strategy.didDrag
        let origin = dragOrigin

        let result = strategy.handleMouseUp(event: event)

        // Click without drag: replay a synthesized middle-click at the original
        // location so apps still see the click (browsers, IDEs, etc). Dispatch
        // off the tap thread — posting from inside the callback can re-enter
        // our own tap synchronously on the same run loop.
        if !didDrag, let origin {
            DispatchQueue.main.async { [weak self] in
                self?.replayMiddleClick(at: origin)
            }
        } else if didDrag {
            DispatchQueue.main.async {
                Analytics.trackDrag(trigger: .middle, modifier: ModifierCombination())
            }
        }

        return result
    }

    // MARK: - Tile Application

    /// Snap the target window to the tile zone's rect on the given screen.
    /// Saves the original frame in savedFrames so the existing double-click-restore works.
    private func applyTile(zone: TileZone,
                           target: (pid: pid_t, windowID: CGWindowID, frame: CGRect, app: String),
                           screen: NSScreen) {
        guard axGuardOrAbort("applyTile") else { return }
        Analytics.trackTile(tile: zone.analyticsKey, trigger: .middleDirection)
        guard let axWindow = findAXWindow(pid: target.pid, windowFrame: target.frame) else {
            Self.log.warn("applyTile: findAXWindow returned nil for pid=\(target.pid) wid=\(target.windowID)")
            return
        }
        Self.log.info("tile commit: app=\"\(target.app)\" wid=\(target.windowID) zone=\(zone)")

        let nsRect = zone.rect(in: screen.visibleFrame)
        let cgRect = cgRectFromNSScreenRect(nsRect)

        // Save current frame for double-click restore (matches performTileAction's behavior).
        let currentFrame = getWindowFrame(axWindow) ?? target.frame
        savedFrames[target.windowID] = currentFrame

        setWindowFrame(axWindow, frame: cgRect)
    }

    /// Convert an NSScreen-coord rect (bottom-left origin) into a Quartz CG rect (top-left origin).
    private func cgRectFromNSScreenRect(_ ns: NSRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return ns }
        let primaryHeight = primary.frame.height
        return CGRect(x: ns.origin.x,
                      y: primaryHeight - ns.origin.y - ns.height,
                      width: ns.width, height: ns.height)
    }

    /// Find the NSScreen containing a given CG point (top-left origin, Y-down).
    private func screen(containingCGPoint cg: CGPoint) -> NSScreen? {
        guard let primary = NSScreen.screens.first else { return nil }
        let primaryHeight = primary.frame.height
        let nsPoint = NSPoint(x: cg.x, y: primaryHeight - cg.y)
        return NSScreen.screens.first { $0.frame.contains(nsPoint) } ?? primary
    }

    /// Returns true if `cgPoint` falls inside the **primary** screen's
    /// menu-bar zone (the top `NSStatusBar.system.thickness` pt strip).
    /// Click handlers use this to pass menu-bar clicks through to the
    /// system instead of treating them as window drags.
    ///
    /// The Y lower bound (`>= 0`) matters: CG coordinates are global with
    /// the primary's top-left as origin, so a secondary display positioned
    /// above the primary has CG y < 0. Without the lower bound, every
    /// click on such a secondary display has y < menuBarHeight and was
    /// silently passed through — breaking AnyDrag entirely on that
    /// screen. (See issue #4.)
    private static func isOnPrimaryMenuBar(_ cgPoint: CGPoint) -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        let primaryFrame = primary.frame
        let menuBarHeight = NSStatusBar.system.thickness
        return cgPoint.y >= 0 &&
               cgPoint.y < menuBarHeight &&
               cgPoint.x >= primaryFrame.origin.x &&
               cgPoint.x <= primaryFrame.origin.x + primaryFrame.width
    }

    private func replayMiddleClick(at point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Self.log.warn("replayMiddleClick: CGEventSource creation failed — middle-click swallowed")
            return
        }
        source.userData = Self.synthesizedEventMarker

        if let down = CGEvent(
            mouseEventSource: source,
            mouseType: .otherMouseDown,
            mouseCursorPosition: point,
            mouseButton: .center
        ) {
            down.post(tap: .cghidEventTap)
        } else {
            Self.log.warn("replayMiddleClick: failed to create mouseDown event")
        }
        if let up = CGEvent(
            mouseEventSource: source,
            mouseType: .otherMouseUp,
            mouseCursorPosition: point,
            mouseButton: .center
        ) {
            up.post(tap: .cghidEventTap)
        } else {
            Self.log.warn("replayMiddleClick: failed to create mouseUp event")
        }
    }

    private func showTilingPanel(at point: NSPoint, for windowInfo: (pid: pid_t, windowID: CGWindowID, frame: CGRect, app: String)) {
        Self.log.info("tile panel: app=\"\(windowInfo.app)\" wid=\(windowInfo.windowID)")
        tilingPanel?.dismiss()

        let panel = TilingPanel()
        panel.onAction = { [weak self] action in
            self?.performTileAction(action, windowInfo: windowInfo)
        }
        panel.show(at: point)
        tilingPanel = panel
    }

    private func matchesConfiguredModifier(_ flags: CGEventFlags) -> Bool {
        let cleanedFlags = flags.subtracting(.maskNonCoalesced)
        let activeModifiers = cleanedFlags.intersection(Self.relevantModifierMask)
        let targetModifiers = modifiers.eventFlags

        // Empty target = no modifier configured; never match (avoids matching
        // every plain click).
        guard !targetModifiers.isEmpty else { return false }

        if activeModifiers == targetModifiers {
            return true
        }

        guard modifiers.supportsOptionAugmentation else {
            return false
        }

        // Allow base shortcut + Option so users can combine AnyDrag with
        // the macOS "Hold Option key while dragging windows to tile" feature.
        return activeModifiers == targetModifiers.union(.maskAlternate)
    }

    private func performTileAction(_ action: TileAction, windowInfo: (pid: pid_t, windowID: CGWindowID, frame: CGRect, app: String)) {
        guard axGuardOrAbort("performTileAction") else { return }
        Analytics.trackTile(tile: action.analyticsKey, trigger: .panel)
        guard let axWindow = findAXWindow(pid: windowInfo.pid, windowFrame: windowInfo.frame) else {
            Self.log.warn("performTileAction: findAXWindow returned nil for pid=\(windowInfo.pid) wid=\(windowInfo.windowID)")
            return
        }
        guard let screen = screenVisibleFrame(for: windowInfo.frame) else {
            Self.log.warn("performTileAction: screenVisibleFrame returned nil for frame=\(windowInfo.frame)")
            return
        }

        // Save original frame for double-click restore
        let currentFrame = getWindowFrame(axWindow) ?? windowInfo.frame
        savedFrames[windowInfo.windowID] = currentFrame

        switch action {
        // MARK: Move & Resize
        case .leftHalf:
            setWindowFrame(axWindow, frame: CGRect(
                x: screen.minX, y: screen.minY,
                width: screen.width / 2, height: screen.height))

        case .rightHalf:
            setWindowFrame(axWindow, frame: CGRect(
                x: screen.midX, y: screen.minY,
                width: screen.width / 2, height: screen.height))

        case .topHalf:
            setWindowFrame(axWindow, frame: CGRect(
                x: screen.minX, y: screen.minY,
                width: screen.width, height: screen.height / 2))

        case .bottomHalf:
            setWindowFrame(axWindow, frame: CGRect(
                x: screen.minX, y: screen.midY,
                width: screen.width, height: screen.height / 2))

        case .topLeft:
            setWindowFrame(axWindow, frame: CGRect(
                x: screen.minX, y: screen.minY,
                width: screen.width / 2, height: screen.height / 2))

        case .topRight:
            setWindowFrame(axWindow, frame: CGRect(
                x: screen.midX, y: screen.minY,
                width: screen.width / 2, height: screen.height / 2))

        case .bottomLeft:
            setWindowFrame(axWindow, frame: CGRect(
                x: screen.minX, y: screen.midY,
                width: screen.width / 2, height: screen.height / 2))

        case .bottomRight:
            setWindowFrame(axWindow, frame: CGRect(
                x: screen.midX, y: screen.midY,
                width: screen.width / 2, height: screen.height / 2))

        // MARK: Fill & Arrange
        case .fill:
            // Maximize to screen's visible area (keeps title bar)
            setWindowFrame(axWindow, frame: screen)

        case .leftAndRight:
            // Current window → left half, next Z-order window → right half
            setWindowFrame(axWindow, frame: CGRect(
                x: screen.minX, y: screen.minY,
                width: screen.width / 2, height: screen.height))
            if let next = nextWindowOnScreen(after: windowInfo.windowID, screen: screen) {
                savedFrames[next.windowID] = getWindowFrame(next.axWindow) ?? next.frame
                setWindowFrame(next.axWindow, frame: CGRect(
                    x: screen.midX, y: screen.minY,
                    width: screen.width / 2, height: screen.height))
            }

        case .fillRight:
            // Current window → right half, next Z-order window → left half
            setWindowFrame(axWindow, frame: CGRect(
                x: screen.midX, y: screen.minY,
                width: screen.width / 2, height: screen.height))
            if let next = nextWindowOnScreen(after: windowInfo.windowID, screen: screen) {
                savedFrames[next.windowID] = getWindowFrame(next.axWindow) ?? next.frame
                setWindowFrame(next.axWindow, frame: CGRect(
                    x: screen.minX, y: screen.minY,
                    width: screen.width / 2, height: screen.height))
            }

        case .quarters:
            // Top 4 windows by Z-order → quadrants
            let quadrants = [
                CGRect(x: screen.minX, y: screen.minY,
                       width: screen.width / 2, height: screen.height / 2),
                CGRect(x: screen.midX, y: screen.minY,
                       width: screen.width / 2, height: screen.height / 2),
                CGRect(x: screen.minX, y: screen.midY,
                       width: screen.width / 2, height: screen.height / 2),
                CGRect(x: screen.midX, y: screen.midY,
                       width: screen.width / 2, height: screen.height / 2),
            ]
            // Current window → top-left
            setWindowFrame(axWindow, frame: quadrants[0])
            // Next windows → remaining quadrants
            let others = windowsOnScreen(after: windowInfo.windowID, screen: screen, limit: 3)
            for (i, other) in others.enumerated() {
                savedFrames[other.windowID] = getWindowFrame(other.axWindow) ?? other.frame
                setWindowFrame(other.axWindow, frame: quadrants[i + 1])
            }
        }
    }

    // MARK: - Maximize / Restore

    private func toggleMaximize(windowID: CGWindowID, pid: pid_t, windowFrame: CGRect) {
        // Always run on main: same-process AX writes call NSWindow (which
        // requires main); routing every maximize through main also keeps
        // savedFrames mutations single-threaded with the tile paths.
        DispatchQueue.main.async { [weak self] in
            self?.toggleMaximizeImpl(windowID: windowID, pid: pid, windowFrame: windowFrame)
        }
    }

    private func toggleMaximizeImpl(windowID: CGWindowID, pid: pid_t, windowFrame: CGRect) {
        guard axGuardOrAbort("toggleMaximizeImpl") else { return }
        Analytics.trackMaximize()
        guard let axWindow = findAXWindow(pid: pid, windowFrame: windowFrame) else {
            Self.log.warn("toggleMaximizeImpl: findAXWindow returned nil for pid=\(pid) wid=\(windowID)")
            return
        }

        // Activate the target app and raise the window
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)

        if let savedFrame = savedFrames[windowID] {
            // Restore to original frame
            setWindowFrame(axWindow, frame: savedFrame)
            savedFrames.removeValue(forKey: windowID)
        } else {
            // Save current frame and maximize to screen's visible area
            let currentFrame = getWindowFrame(axWindow) ?? windowFrame
            savedFrames[windowID] = currentFrame
            if let targetFrame = screenVisibleFrame(for: windowFrame) {
                setWindowFrame(axWindow, frame: targetFrame)
            }
        }
    }

    private func setWindowFrame(_ window: AXUIElement, frame: CGRect) {
        // Disable AXEnhancedUserInterface if enabled (Electron apps set this,
        // which causes AX resizing to silently fail). Rectangle does the same.
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let appElement = AXUIElementCreateApplication(pid)

        var enhancedUIRef: CFTypeRef?
        let hadEnhancedUI = AXUIElementCopyAttributeValue(
            appElement, "AXEnhancedUserInterface" as CFString, &enhancedUIRef
        ) == .success && (enhancedUIRef as? NSNumber)?.boolValue == true

        if hadEnhancedUI {
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }

        // Size → Position → Size (Rectangle's proven approach).
        // macOS constrains window size to the current display, so we must:
        // 1. Shrink first (so the window fits before moving)
        // 2. Move to the target position
        // 3. Set size again (in case the display changed and the constraint was wrong)
        var position = frame.origin
        var size = frame.size
        if let sv = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sv)
        }
        if let pv = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pv)
        }
        if let sv = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sv)
        }

        if hadEnhancedUI {
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    private func getWindowFrame(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, CFGetTypeID(posVal) == AXValueGetTypeID(),
              let sizeVal = sizeRef, CFGetTypeID(sizeVal) == AXValueGetTypeID()
        else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    /// Returns the screen's visible area (excluding menu bar and Dock) in CG coordinates
    /// for the screen that contains the given window frame.
    private func screenVisibleFrame(for windowFrame: CGRect) -> CGRect? {
        guard let mainScreen = NSScreen.screens.first else { return nil }
        let mainHeight = mainScreen.frame.height

        // Find which screen contains the window center (convert CG → NS coordinates)
        let centerNS = NSPoint(x: windowFrame.midX, y: mainHeight - windowFrame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(centerNS) } ?? mainScreen

        // Convert NSScreen visibleFrame (bottom-left origin) → CG coordinates (top-left origin)
        let vf = screen.visibleFrame
        return CGRect(
            x: vf.origin.x,
            y: mainHeight - vf.origin.y - vf.height,
            width: vf.width,
            height: vf.height
        )
    }

    /// Look up an AX window by matching its top-left corner against the given
    /// CG window frame (5-point tolerance). Returns nil when no AX window's
    /// position matches — call sites that warn on nil should expect occasional
    /// benign hits: the window may have closed between CG enumeration and the
    /// AX lookup, or the app may report a different AX position than CG bounds
    /// (some Electron / custom-drawn apps do this). A nil here means the
    /// user-initiated action couldn't proceed — worth logging, not always a bug.
    private func findAXWindow(pid: pid_t, windowFrame: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement]
        else { return nil }

        return windows.first { axWin in
            var posRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &posRef)
            guard let posVal = posRef, CFGetTypeID(posVal) == AXValueGetTypeID() else { return false }
            var pos = CGPoint.zero
            AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
            return abs(pos.x - windowFrame.origin.x) < 5 && abs(pos.y - windowFrame.origin.y) < 5
        }
    }

    // MARK: - Multi-Window Lookup

    /// Returns the next window in Z-order on the same screen, skipping the given windowID.
    private func nextWindowOnScreen(after windowID: CGWindowID, screen: CGRect) -> (windowID: CGWindowID, pid: pid_t, frame: CGRect, axWindow: AXUIElement)? {
        return windowsOnScreen(after: windowID, screen: screen, limit: 1).first
    }

    /// Returns up to `limit` windows in Z-order on the same screen, skipping the given windowID.
    private func windowsOnScreen(after windowID: CGWindowID, screen: CGRect, limit: Int) -> [(windowID: CGWindowID, pid: pid_t, frame: CGRect, axWindow: AXUIElement)] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return [] }

        var results: [(windowID: CGWindowID, pid: pid_t, frame: CGRect, axWindow: AXUIElement)] = []

        for info in windowList {
            guard results.count < limit,
                  let layer = info[kCGWindowLayer] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds] as? [String: CGFloat],
                  let pid = info[kCGWindowOwnerPID] as? pid_t,
                  let wID = info[kCGWindowNumber] as? CGWindowID,
                  wID != windowID
            else { continue }

            let ownerName = info[kCGWindowOwnerName] as? String ?? "unknown"
            if ownerName == "Dock" { continue }

            let frame = CGRect(
                x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
            )

            // Check if window center is on the same screen
            let centerX = frame.midX
            let centerY = frame.midY
            guard centerX >= screen.minX && centerX <= screen.maxX &&
                  centerY >= screen.minY && centerY <= screen.maxY else { continue }

            guard let axWindow = findAXWindow(pid: pid, windowFrame: frame) else { continue }
            results.append((wID, pid, frame, axWindow))
        }

        return results
    }

    // MARK: - Window Detection

    /// Finds the topmost normal window at the given screen point using CGWindowListCopyWindowInfo.
    /// Returns nil if no window is found. Skips the Dock and non-normal windows (layer != 0).
    /// `app` is the CG-reported process owner name (e.g. "Google Chrome", "Finder") — extracted
    /// here so engagement-point logs can include it without a separate NSRunningApplication
    /// lookup on the tap-callback thread.
    private func windowUnderCursor(at point: CGPoint) -> (pid: pid_t, windowID: CGWindowID, frame: CGRect, app: String)? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else {
            return nil
        }

        // CGWindowListCopyWindowInfo returns windows in front-to-back order,
        // so the first hit is the topmost window at that point.
        for info in windowList {
            guard
                let layer = info[kCGWindowLayer] as? Int, layer == 0,
                let boundsDict = info[kCGWindowBounds] as? [String: CGFloat],
                let pid = info[kCGWindowOwnerPID] as? pid_t,
                let windowID = info[kCGWindowNumber] as? CGWindowID
            else { continue }

            let ownerName = info[kCGWindowOwnerName] as? String ?? "unknown"
            if ownerName == "Dock" { continue }

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            if bounds.contains(point) {
                return (pid, windowID, bounds, ownerName)
            }
        }
        return nil
    }

    // MARK: - Diagnostics

    /// Rate-limit anchor for the "miss" diagnostic logs. Returns true at most
    /// once per second across the modifier-miss and no-window-miss paths
    /// combined — they share one bucket so a stream of one can't drown out
    /// the other indefinitely, and the user never gets a wall of debug lines
    /// from rapid clicking.
    private func shouldLogDiagMiss() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        return cbState.withLock { state in
            if now - state.lastDiagMissAt >= 1.0 {
                state.lastDiagMissAt = now
                return true
            }
            return false
        }
    }

    /// Log when a click arrived with some modifier held but it didn't match
    /// the configured combination. Silent for plain (no-modifier) clicks so
    /// every button press doesn't enter this path.
    private func logModifierMiss(flags: CGEventFlags, button: String) {
        let observed = flags.subtracting(.maskNonCoalesced).intersection(Self.relevantModifierMask)
        guard !observed.isEmpty else { return }
        guard shouldLogDiagMiss() else { return }
        Self.log.debug("modifier miss [\(button)Down]: observed=\(Self.describeFlags(observed)) target=\(self.modifiers.symbol)")
    }

    /// Log when the configured gesture matched but `windowUnderCursor` found
    /// nothing — diagnoses "AnyDrag does nothing in app X" reports where
    /// CGWindowListCopyWindowInfo can't see the target window's layer.
    private func logNoWindowMiss(button: String, at point: CGPoint) {
        guard shouldLogDiagMiss() else { return }
        Self.log.debug("no window under cursor [\(button)Down] at (\(Int(point.x)), \(Int(point.y)))")
    }

    /// Render a CGEventFlags modifier set as the same glyph string the UI
    /// shows for `ModifierCombination` (e.g. "⌃⌥"), so log lines line up
    /// with what the user sees in Settings.
    private static func describeFlags(_ flags: CGEventFlags) -> String {
        var combo: ModifierCombination = []
        if flags.contains(.maskCommand)                  { combo.insert(.command) }
        if flags.contains(.maskShift)                    { combo.insert(.shift) }
        if flags.contains(.maskAlternate)                { combo.insert(.option) }
        if flags.contains(.maskControl)                  { combo.insert(.control) }
        if flags.contains(ModifierCombination.fnEventFlag) { combo.insert(.fn) }
        return combo.symbol
    }
}

// MARK: - C-level Event Tap Callback

private let eventTapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<DragEngine>.fromOpaque(userInfo).takeUnretainedValue()
    return engine.handleEvent(proxy: proxy, type: type, event: event)
}
