import Cocoa
import os

/// A short-lived event tap appended at the **tail** of the session tap chain,
/// created fresh at the start of every gesture and torn down when it ends.
///
/// ## Why this exists
///
/// `TitleBarDragStrategy` and `ResizeStrategy` strip the trigger modifiers from
/// the events they synthesize, because AppKit turns Control+leftMouseDown into a
/// *secondary* click — the app pops a context menu and the native title-bar drag
/// never starts.
///
/// Some mouse utilities tap left down/up **downstream** of our main tap and
/// re-assert the modifier flags from the physical key state as they pass events
/// along. That puts Control straight back onto the click we just cleaned, and
/// the drag dies. Measured against BetterMouse (2026-07): our synthesized
/// title-bar `leftMouseDown` reached the app carrying Control on every drag, and
/// quitting BetterMouse — changing nothing else — made the same event arrive
/// clean.
///
/// ## Why it is created per gesture rather than once at launch
///
/// Within one tap point, head-inserted taps run before tail-appended ones, and
/// tail-appended taps run in creation order — so **the tap appended last has the
/// final word**. Creating this tap when a gesture begins (instead of at launch)
/// is the whole trick: whenever the other tool started, its taps already exist
/// by the time we append, so we always land behind them. A tap created once at
/// launch loses this race the moment the user restarts the other tool, which is
/// exactly what the measurements showed.
///
/// The tap exists only for the duration of a gesture, and its callback is inert
/// while `flagsToStrip` is empty, so even a leaked tap cannot alter events.
///
/// ## Threading
///
/// `begin` and `finish` must run on `DragEngine`'s event-tap thread — they touch
/// that thread's run loop. `end` is callable from any thread (`stop()` calls it
/// from main): the mutable state lives behind an unfair lock, and the CF
/// invalidations it performs are documented thread-safe.
final class TrailingFlagScrubber {

    private static let log = FileLog("FlagScrubber")

    /// Mouse events a synthesized gesture stream can consist of. Kept in sync
    /// with what `TitleBarDragStrategy` / `ResizeStrategy` emit.
    private static let maskedTypes: [CGEventType] = [
        .leftMouseDown, .leftMouseDragged, .leftMouseUp,
        .rightMouseDown, .rightMouseDragged, .rightMouseUp,
        .otherMouseDown, .otherMouseDragged, .otherMouseUp,
    ]

    /// A stranded gesture (lost mouse-up) must not leave a live tap behind, so
    /// the tap self-destructs if no `finish()` / `end()` arrives within this
    /// long. Generous: it only needs to outlast a real drag.
    private static let watchdogSeconds: CFTimeInterval = 30

    /// Grace period after `finish()`. The terminating mouse-up still has to
    /// travel from the main tap down to us before the tap may go away; if the
    /// engine suppressed that up it never arrives, so this bounds the wait.
    private static let finishGraceSeconds: CFTimeInterval = 2

    private struct State {
        var tap: CFMachPort?
        var source: CFRunLoopSource?
        var watchdog: CFRunLoopTimer?
        /// Flags removed from every mouse event reaching the tail of the chain.
        /// Empty makes the callback a pure pass-through.
        var flagsToStrip: CGEventFlags = []
        /// Set by `finish(terminator:)`. Once non-nil the gesture is over and
        /// only an event of exactly this type still gets scrubbed — everything
        /// else belongs to some other interaction and must pass untouched.
        var pendingTerminator: CGEventType?
        /// Cleared by `shutdown()` so a `begin()` already in flight on the tap
        /// thread cannot publish a live tap onto a run loop main is stopping.
        var acceptingNewTaps = true
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    /// Retained `self` handed to the C callback. Never released while the
    /// scrubber is alive — same reasoning as `DragEngine.tapUserInfo`: releasing
    /// while a callback might be on the stack would be a use-after-free.
    private var selfRef: UnsafeMutableRawPointer?

    var isActive: Bool { state.withLock { $0.tap != nil } }

    deinit {
        end()
        if let selfRef {
            Unmanaged<TrailingFlagScrubber>.fromOpaque(selfRef).release()
        }
    }

    // MARK: - Lifecycle

    /// Append a fresh scrubbing tap at the tail of the session chain.
    ///
    /// Call from the event-tap thread at gesture start. An empty set is a no-op:
    /// with no conflicting modifier held there is nothing for anyone downstream
    /// to re-assert, so we skip the tap entirely and users without a
    /// flag-rewriting mouse utility pay nothing.
    func begin(stripping flags: CGEventFlags) {
        guard !flags.isEmpty else {
            // A gesture needing no scrub supersedes whatever came before.
            end()
            return
        }
        guard state.withLock({ $0.acceptingNewTaps }) else { return }

        // Always recreate. An existing tap was appended earlier and may now sit
        // ahead of one the other tool created since; re-appending re-takes the
        // last position, which is the entire point of this class.
        end()

        if selfRef == nil {
            selfRef = Unmanaged.passRetained(self).toOpaque()
        }
        guard let selfRef else { return }

        let mask: CGEventMask = Self.maskedTypes.reduce(into: CGEventMask(0)) { mask, type in
            mask |= CGEventMask(1) << type.rawValue
        }

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: trailingFlagScrubberCallback,
            userInfo: selfRef
        ) else {
            // Not fatal — without a downstream tool rewriting flags (the common
            // case) the gesture works exactly as before.
            Self.log.warn("begin: tapCreate failed — gesture runs unscrubbed")
            return
        }

        guard let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            CFMachPortInvalidate(newTap)
            Self.log.warn("begin: run loop source creation failed")
            return
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)

        let timer = makeWatchdog(after: Self.watchdogSeconds)

        // Publish and re-check acceptance in one atomic step. `stop()` runs on
        // main and is about to stop the run loop we just registered with; if it
        // landed while we were building, publishing anyway would strand an
        // enabled tap that nobody services — which stalls input until the system
        // times it out.
        let published = state.withLock { s -> Bool in
            guard s.acceptingNewTaps else { return false }
            s.tap = newTap
            s.source = newSource
            s.watchdog = timer
            s.flagsToStrip = flags
            s.pendingTerminator = nil
            return true
        }
        guard published else {
            Self.log.info("begin: engine shut down mid-setup — discarding the tap we just built")
            if let timer { CFRunLoopTimerInvalidate(timer) }
            CGEvent.tapEnable(tap: newTap, enable: false)
            CFMachPortInvalidate(newTap)
            CFRunLoopSourceInvalidate(newSource)
            return
        }
    }

    /// End the gesture, but let its own terminating event through the scrub
    /// first. We sit at the tail of the chain, so that release reaches us
    /// *after* the main tap handled it — tearing down right away would hand the
    /// app an event still carrying the modifier we spent the gesture removing.
    ///
    /// `terminator` is the type that release will have **as it arrives here**,
    /// i.e. after any rewrite the strategy applied (a middle-button drag ends as
    /// a `leftMouseUp`). Only that type is still scrubbed; anything else belongs
    /// to a different interaction and passes through untouched, so a release the
    /// engine suppressed can't cost an unrelated click its modifiers.
    ///
    /// Call from the event-tap thread.
    func finish(terminator: CGEventType) {
        let timer = makeWatchdog(after: Self.finishGraceSeconds)
        let (stale, accepted) = state.withLock { s -> (CFRunLoopTimer?, Bool) in
            guard s.tap != nil else { return (nil, false) }
            let previous = s.watchdog
            s.watchdog = timer
            s.pendingTerminator = terminator
            return (previous, true)
        }
        if let stale { CFRunLoopTimerInvalidate(stale) }
        if !accepted, let timer { CFRunLoopTimerInvalidate(timer) }
    }

    /// Block further taps and drop the current one. Called from `DragEngine.stop()`
    /// on main, right before it stops the tap thread's run loop.
    func shutdown() {
        state.withLock { $0.acceptingNewTaps = false }
        end()
    }

    /// Re-allow taps after a `shutdown()`. Called from `DragEngine.start()`.
    func resume() {
        state.withLock { $0.acceptingNewTaps = true }
    }

    /// Remove the tap immediately. Safe from any thread, and safe when inactive.
    func end() {
        let (tap, source, watchdog) = state.withLock { s -> (CFMachPort?, CFRunLoopSource?, CFRunLoopTimer?) in
            let pulled = (s.tap, s.source, s.watchdog)
            s.tap = nil
            s.source = nil
            s.watchdog = nil
            s.flagsToStrip = []
            s.pendingTerminator = nil
            return pulled
        }
        if let watchdog { CFRunLoopTimerInvalidate(watchdog) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopSourceInvalidate(source) }
    }

    /// Builds and schedules a teardown timer on the calling thread's run loop.
    /// Caller stores it into `state` and invalidates whatever it replaced.
    private func makeWatchdog(after seconds: CFTimeInterval) -> CFRunLoopTimer? {
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + seconds,
            0, 0, 0
        ) { [weak self] _ in
            guard let self, self.isActive else { return }
            Self.log.debug("watchdog fired after \(seconds)s — dropping scrubber")
            self.end()
        }
        if let timer {
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        }
        return timer
    }

    // MARK: - Event handling

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // A disabled tap never recovers on its own and would silently stop
        // scrubbing, so drop it; the next gesture appends a fresh one.
        if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
            Self.log.warn("tap disabled (type \(type.rawValue)) — dropping scrubber")
            end()
            return Unmanaged.passUnretained(event)
        }

        let (flags, terminator) = state.withLock { ($0.flagsToStrip, $0.pendingTerminator) }
        guard !flags.isEmpty else {
            return Unmanaged.passUnretained(event)
        }

        if let terminator {
            // The gesture is over and we're only waiting for its own release.
            // Anything else in the meantime belongs to a different interaction —
            // stripping its modifiers would break, say, a Control-click the user
            // makes right after letting go.
            guard type == terminator else {
                return Unmanaged.passUnretained(event)
            }
            event.flags = event.flags.subtracting(flags)
            end()
            return Unmanaged.passUnretained(event)
        }

        event.flags = event.flags.subtracting(flags)
        return Unmanaged.passUnretained(event)
    }
}

private func trailingFlagScrubberCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let scrubber = Unmanaged<TrailingFlagScrubber>.fromOpaque(userInfo).takeUnretainedValue()
    return scrubber.handle(type: type, event: event)
}
