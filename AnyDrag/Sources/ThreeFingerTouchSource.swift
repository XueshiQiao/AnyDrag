import AppKit
import IOKit
import os

/// Reports whether three (or more) fingers are resting on a trackpad, so a
/// three-finger drag can move a window with no modifier key held.
///
/// The gesture rides on the macOS Accessibility option *Pointer Control →
/// Trackpad Options → Use trackpad for dragging → Three Finger Drag*. With it
/// on, the system turns three moving fingers into an ordinary left-button
/// press/drag/release, which is what the engine already knows how to turn
/// into a native title-bar drag. That synthesized press is identical to a
/// physical click in every `CGEvent` field, so the only way to tell them apart
/// is the trackpad's own contact count, read here from the private
/// MultitouchSupport framework (the same source BetterTouchTool / MiddleClick
/// use). Measured on a built-in trackpad: the contact frame reporting three
/// touches lands 2–4 ms *before* the mouse-down, and a plain click reads 1–2.
///
/// Mirrors `HyperCapslockCapsHoldSource`: `DragEngine` only consults `isHeld`
/// on the tap thread and toggles `setEnabled` from the preference on main. If
/// the private framework is missing or fails to start, `isHeld` is simply
/// always false and the ordinary modifier path is unaffected.
final class ThreeFingerTouchSource {
    private static let log = FileLog("ThreeFingerTouch")

    /// After the last frame with three contacts, how long a mouse-down still
    /// counts as three-finger. The 3-contact frame precedes the synthesized
    /// mouse-down by single-digit milliseconds, and the nearest plain click
    /// observed after a three-finger release was 400+ ms later, so this can't
    /// catch a click while still covering any callback-ordering jitter.
    private static let grace: TimeInterval = 0.05

    /// Restart delay after a trackpad (re)appears; gives the device a moment
    /// to finish enumerating before the list is rebuilt.
    private static let hotplugSettle: TimeInterval = 0.5

    private struct Contacts {
        var touching = 0
        var lastThreeAt: TimeInterval = -.infinity
    }
    /// Written on the framework's callback thread, read on the tap thread. A
    /// static because the C callback below cannot capture `self`; the app
    /// only ever creates one source.
    private static let contacts = OSAllocatedUnfairLock(initialState: Contacts())

    /// True while three fingers rest on a trackpad (or did within `grace`).
    /// Read on the tap thread at every left mouse-down.
    var isHeld: Bool {
        let now = Self.now()
        return Self.contacts.withLock { $0.touching >= 3 || now - $0.lastThreeAt <= Self.grace }
    }

    // MARK: - System preference

    private static let systemPreferenceDomains = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad",
    ]

    /// True when the macOS three-finger-drag option is on for the built-in or
    /// a Bluetooth trackpad. Without it the gesture never produces mouse
    /// events, so the feature can't work; Settings uses this to show a hint.
    static var systemThreeFingerDragEnabled: Bool {
        systemPreferenceDomains.contains { domain in
            // Re-read from disk: the user may have just flipped it in
            // System Settings while AnyDrag was running.
            CFPreferencesAppSynchronize(domain as CFString)
            let value = CFPreferencesCopyAppValue("TrackpadThreeFingerDrag" as CFString, domain as CFString)
            return (value as? Bool) ?? ((value as? Int).map { $0 != 0 } ?? false)
        }
    }

    /// System Settings → Accessibility → Pointer Control, where the
    /// "Trackpad Options…" button lives.
    static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?PointerControl")!

    // MARK: - MultitouchSupport binding

    private enum MT {
        static let frameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        typealias DeviceRef = UnsafeMutableRawPointer
        typealias Callback = @convention(c) (DeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
        typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
        typealias Register = @convention(c) (DeviceRef?, Callback?) -> Void
        typealias Start = @convention(c) (DeviceRef?, Int32) -> Int32
        typealias Stop = @convention(c) (DeviceRef?, Int32) -> Int32

        struct Point { var x: Float; var y: Float }
        struct Readout { var pos: Point; var vel: Point }
        /// One contact in a frame. 96 bytes, the layout every open-source
        /// user of this framework agrees on; only `state` is read here.
        struct Touch {
            var frame: Int32
            var timestamp: Double
            var identifier: Int32, state: Int32, foo3: Int32, foo4: Int32
            var normalized: Readout
            var size: Float
            var zero1: Int32
            var angle: Float, majorAxis: Float, minorAxis: Float
            var mm: Readout
            var zero2: (Int32, Int32)
            var unk2: Float
        }
        /// `state` of a finger that is fully down (not hovering, not lifting).
        static let touchingState: Int32 = 4

        struct Functions {
            let createList: CreateList
            let register: Register
            let unregister: Register
            let start: Start
            let stop: Stop
        }
    }

    /// Resolved once. `nil` when the framework or a symbol is missing — then
    /// the source stays inert.
    private static let functions: MT.Functions? = {
        guard MemoryLayout<MT.Touch>.stride == 96 else {
            log.warn("MT.Touch layout is \(MemoryLayout<MT.Touch>.stride) bytes, expected 96 — refusing to read contact frames")
            return nil
        }
        guard let handle = dlopen(MT.frameworkPath, RTLD_NOW) else {
            log.warn("MultitouchSupport unavailable: \(String(cString: dlerror()))")
            return nil
        }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else {
                log.warn("MultitouchSupport is missing \(name)")
                return nil
            }
            return unsafeBitCast(p, to: type)
        }
        guard let createList = symbol("MTDeviceCreateList", as: MT.CreateList.self),
              let register = symbol("MTRegisterContactFrameCallback", as: MT.Register.self),
              let unregister = symbol("MTUnregisterContactFrameCallback", as: MT.Register.self),
              let start = symbol("MTDeviceStart", as: MT.Start.self),
              let stop = symbol("MTDeviceStop", as: MT.Stop.self) else { return nil }
        return MT.Functions(createList: createList, register: register, unregister: unregister, start: start, stop: stop)
    }()

    /// Runs on the framework's own thread for every contact frame (~100 Hz
    /// while fingers are on the pad). Counts fully-down fingers only.
    private static let frameCallback: MT.Callback = { _, touches, count, _, _ in
        var touching = 0
        if let touches, count > 0 {
            let n = Int(count)
            let t = touches.bindMemory(to: MT.Touch.self, capacity: n)
            for i in 0..<n where t[i].state == MT.touchingState { touching += 1 }
        }
        let now = ThreeFingerTouchSource.now()
        contacts.withLock { c in
            c.touching = touching
            if touching >= 3 { c.lastThreeAt = now }
        }
        return 0
    }

    // MARK: - Lifecycle (main thread)

    private var enabled = false
    /// Retains the `MTDeviceRef`s the framework handed us.
    private var devices: CFArray?
    private var hotplugPort: IONotificationPortRef?
    private var hotplugIterator: io_iterator_t = 0
    private var wakeObserver: NSObjectProtocol?
    private var pendingRestart: DispatchWorkItem?

    deinit {
        if enabled {
            removeHotplugObservers()
            stopDevices()
        }
    }

    /// Driven by the "Three-finger drag" preference. When disabled, no
    /// contact frames are read and `isHeld` reports false.
    func setEnabled(_ on: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard on != enabled else { return }
        enabled = on
        if on {
            startDevices()
            installHotplugObservers()
        } else {
            removeHotplugObservers()
            stopDevices()
        }
        Self.log.info("Three-finger source \(on ? "enabled" : "disabled").")
    }

    private func startDevices() {
        guard let f = Self.functions else { return }
        stopDevices()
        guard let list = f.createList()?.takeRetainedValue() else {
            Self.log.warn("MTDeviceCreateList returned nothing — no multitouch devices")
            return
        }
        var started = 0
        for device in Self.deviceRefs(in: list) {
            f.register(device, Self.frameCallback)
            let rc = f.start(device, 0)
            if rc == 0 { started += 1 } else { Self.log.warn("MTDeviceStart failed rc=\(rc)") }
        }
        devices = list
        Self.log.info("Listening to \(started)/\(CFArrayGetCount(list)) multitouch device(s).")
    }

    private func stopDevices() {
        guard let f = Self.functions, let list = devices else { return }
        for device in Self.deviceRefs(in: list) {
            _ = f.stop(device, 0)
            f.unregister(device, Self.frameCallback)
        }
        devices = nil
        Self.contacts.withLock { $0 = Contacts() }
    }

    private static func deviceRefs(in list: CFArray) -> [MT.DeviceRef] {
        (0..<CFArrayGetCount(list)).compactMap { i in
            CFArrayGetValueAtIndex(list, i).map { UnsafeMutableRawPointer(mutating: $0) }
        }
    }

    // MARK: - Hot-plug & wake

    /// A Magic Trackpad pairing after launch, or the built-in pad coming back
    /// from sleep, needs the device list rebuilt — the old refs go quiet.
    private func installHotplugObservers() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleRestart(reason: "wake") }

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, .main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let rc = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, IOServiceMatching("AppleMultitouchDevice"),
            { refcon, iterator in
                // Drain, or the notification never re-arms.
                while IOIteratorNext(iterator) != 0 {}
                guard let refcon else { return }
                Unmanaged<ThreeFingerTouchSource>.fromOpaque(refcon).takeUnretainedValue()
                    .scheduleRestart(reason: "device added")
            }, refcon, &hotplugIterator)
        guard rc == KERN_SUCCESS else {
            Self.log.warn("IOServiceAddMatchingNotification failed rc=\(rc)")
            IONotificationPortDestroy(port)
            return
        }
        hotplugPort = port
        // The first drain delivers the devices already present and arms the
        // notification for future ones; those are already started above.
        while IOIteratorNext(hotplugIterator) != 0 {}
    }

    private func removeHotplugObservers() {
        pendingRestart?.cancel()
        pendingRestart = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if hotplugIterator != 0 {
            IOObjectRelease(hotplugIterator)
            hotplugIterator = 0
        }
        if let hotplugPort {
            IONotificationPortDestroy(hotplugPort)
            self.hotplugPort = nil
        }
    }

    private func scheduleRestart(reason: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard enabled else { return }
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.enabled else { return }
            Self.log.info("Restarting multitouch listeners (\(reason)).")
            self.startDevices()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hotplugSettle, execute: work)
    }

    /// Monotonic clock — unaffected by wall-clock jumps.
    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}
