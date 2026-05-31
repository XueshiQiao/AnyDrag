import Foundation
import os

/// AnyDrag's half of the optional HyperCapslock link, and the ONLY AnyDrag file
/// that knows the HyperCapslock wire protocol. It owns:
///
///   • the cross-process listener for the CapsLock-hold lifecycle, and
///   • a liveness watchdog: while held it pings HyperCapslock; if no pong comes
///     back within `deadThreshold`, it treats HyperCapslock as gone and ends the
///     hold (so a `kill -9` can't leave AnyDrag armed forever).
///
/// `DragEngine` only consults `isHeld` (on the tap thread) and toggles
/// `setEnabled` from the `.hyper` modifier chip; it knows nothing else.
final class HyperCapslockCapsHoldSource {
    private enum Wire {  // contract — must match HyperCapslock byte-for-byte
        static let began = Notification.Name("me.xueshi.hypercapslock.capsHoldBegan")
        static let ended = Notification.Name("me.xueshi.hypercapslock.capsHoldEnded")
        static let ping  = Notification.Name("me.xueshi.hypercapslock.capsHoldPing")
        static let pong  = Notification.Name("me.xueshi.hypercapslock.capsHoldPong")
    }

    /// While held, ping this often; if no pong within `deadThreshold`, presume
    /// HyperCapslock gone and unhold. 100 ms / 1 s ⇒ disarm within ~1 s of a kill.
    private static let pingInterval: TimeInterval = 0.1
    private static let deadThreshold: TimeInterval = 1.0

    private static let log = FileLog("HyperCapslockLink")

    /// Read on the tap thread; written on main. The only cross-thread state.
    private let heldLock = OSAllocatedUnfairLock(initialState: false)
    var isHeld: Bool { heldLock.withLock { $0 } }

    // Everything below is main-thread only.
    private var enabled = false
    private var observers: [NSObjectProtocol] = []
    private var heartbeat: DispatchSourceTimer?
    private var lastPongAt: TimeInterval = 0

    init() { installObservers() }
    deinit { removeObservers(); heartbeat?.cancel() }

    /// Driven by the `.hyper` modifier chip. When disabled, the source ignores
    /// everything and reports not-held.
    func setEnabled(_ on: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard on != enabled else { return }
        enabled = on
        if !on { endHold() }   // disarm + stop the heartbeat
        Self.log.info("Hyper source \(on ? "enabled" : "disabled").")
    }

    // MARK: - Cross-process observers (fire on main)

    private func installObservers() {
        let c = DistributedNotificationCenter.default()
        observers = [
            c.addObserver(forName: Wire.began, object: nil, queue: .main) { [weak self] _ in self?.onBegan() },
            c.addObserver(forName: Wire.ended, object: nil, queue: .main) { [weak self] _ in self?.endHold() },
            c.addObserver(forName: Wire.pong,  object: nil, queue: .main) { [weak self] _ in self?.lastPongAt = Self.now() },
        ]
    }

    private func removeObservers() {
        let c = DistributedNotificationCenter.default()
        observers.forEach { c.removeObserver($0) }
        observers.removeAll()
    }

    private func onBegan() {
        guard enabled else { return }
        heldLock.withLock { $0 = true }
        startHeartbeat()
    }

    private func endHold() {
        heldLock.withLock { $0 = false }
        stopHeartbeat()
    }

    // MARK: - Liveness watchdog (main queue)

    private func startHeartbeat() {
        stopHeartbeat()
        lastPongAt = Self.now()          // grace: assume alive at the start
        post(Wire.ping)                  // probe immediately
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        heartbeat = t
        t.resume()
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    private func tick() {
        if Self.now() - lastPongAt > Self.deadThreshold {
            Self.log.info("No pong within \(Self.deadThreshold)s — HyperCapslock presumed gone; unholding.")
            endHold()
            return
        }
        post(Wire.ping)
    }

    private func post(_ name: Notification.Name) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Monotonic clock — unaffected by wall-clock jumps.
    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}
