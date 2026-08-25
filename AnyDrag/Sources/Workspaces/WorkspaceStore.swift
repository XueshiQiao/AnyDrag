import AppKit

/// One parked window's recovery record.
///
/// Deliberately does NOT store `CGWindowID`: that number only means anything
/// inside one session, so after a crash it matches nothing. Recognition works
/// off "an app with this bundle id has a window sitting almost exactly where
/// we parked one".
struct HiddenWindowRecord: Codable, Equatable {
    /// Identifies the record itself, so a caller can retire exactly the one it
    /// created without having to re-identify the window.
    let id: UUID
    let bundleID: String
    let appName: String
    let parkedAtCG: CGPoint
    let restoreFrameCG: CGRect
}

/// The durable truth about which windows are parked off-screen.
///
/// **This is not a projection of the live registry.** It used to be, and that
/// was a real hazard: anything that emptied or rebuilt the registry — an app
/// quitting, the feature being switched off, a refresh that failed to see a
/// window — silently erased the only records able to bring those windows back.
/// The store now owns its records. A record is created BEFORE the window is
/// moved and retired only once the window has been observed back on screen.
enum WorkspaceStore {

    private static let log = FileLog("WorkspaceStore")

    /// In-memory mirror so reads never touch the disk. The file is the
    /// authority across launches; this is the authority within one.
    private static var records: [HiddenWindowRecord] = load()

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("AnyDrag", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("hidden-windows.json")
    }

    static var all: [HiddenWindowRecord] { records }

    // MARK: - Write-ahead

    /// Persist a record BEFORE the window is moved.
    ///
    /// Returns false when the write failed — the caller must then NOT park the
    /// window. Parking without a durable record is how a window ends up
    /// off-screen with nothing left that knows where it came from, and a full
    /// disk is not a good enough reason to lose someone's window.
    static func reserve(_ record: HiddenWindowRecord) -> Bool {
        var next = records
        next.append(record)
        guard flush(next) else {
            WSDebug.bail("store", "reserve FAILED for \(record.appName) — refusing to park")
            log.warn("reserve failed — refusing to park \(record.appName)")
            return false
        }
        records = next
        WSDebug.log("store", "reserved \(record.appName) parkedAt=\(WSDebug.point(record.parkedAtCG)) "
            + "restoreTo=\(WSDebug.rect(record.restoreFrameCG)); \(records.count) record(s) on disk")
        return true
    }

    /// Correct a record to where the window ACTUALLY landed.
    ///
    /// The record is written before the move (so a crash mid-park still leaves
    /// a trail), which means it holds the *intended* parking point. macOS then
    /// clamps the Y — it will not let a title bar sink below the screen — so
    /// the window settles 20-120pt above where we asked. Recovery matches on
    /// coordinates, so leaving the intention on disk means the record never
    /// matches the window it was written for.
    static func confirmParked(id: UUID, actualCG: CGPoint) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        guard records[i].parkedAtCG != actualCG else { return }
        var next = records
        next[i] = HiddenWindowRecord(id: records[i].id, bundleID: records[i].bundleID,
                                     appName: records[i].appName, parkedAtCG: actualCG,
                                     restoreFrameCG: records[i].restoreFrameCG)
        if flush(next) {
            records = next
            WSDebug.log("store", "confirmed \(records[i].appName) actually parked at "
                + "\(WSDebug.point(actualCG)) (asked for a Y macOS clamped)")
        }
    }

    /// Retire a record once the window has been verified back on screen.
    static func retire(id: UUID) {
        guard records.contains(where: { $0.id == id }) else { return }
        let gone = records.first { $0.id == id }
        let next = records.filter { $0.id != id }
        if flush(next) {
            records = next
            WSDebug.log("store", "retired \(gone?.appName ?? "?"); \(records.count) record(s) left")
        } else {
            WSDebug.bail("store", "retire FAILED for \(gone?.appName ?? "?") — record kept on disk")
        }
    }

    /// Drop a record that no longer refers to anything — the window was closed
    /// while parked, so there is nothing left to restore.
    static func discard(id: UUID) { retire(id: id) }

    private static func flush(_ next: [HiddenWindowRecord]) -> Bool {
        do {
            try JSONEncoder().encode(next).write(to: fileURL, options: .atomic)
            return true
        } catch {
            log.warn("write failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func load() -> [HiddenWindowRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([HiddenWindowRecord].self, from: data)) ?? []
    }

    // MARK: - Launch recovery

    /// Put back anything a previous run left parked.
    ///
    /// Runs once at launch, after Accessibility has been granted.
    ///
    /// Two rules make this safe:
    ///
    /// * **Unmatched records are kept.** At login the owning app may not have
    ///   started yet, or Accessibility may briefly refuse. Deleting the record
    ///   because the window is not visible *right now* throws away the only
    ///   thing that could rescue it later.
    /// * **Each live window is consumed once.** Two same-sized windows of one
    ///   app parked in the same corner have identical coordinates; without
    ///   one-to-one matching the first record would restore both to its own
    ///   frame and the second would match nothing.
    @discardableResult
    static func recoverOnLaunch() -> (restored: Int, kept: Int) {
        guard !records.isEmpty else { return (0, 0) }

        var consumed: [pid_t: Set<Int>] = [:]
        var survivors: [HiddenWindowRecord] = []
        var restored = 0

        for record in records {
            var didRestore = false
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: record.bundleID) {
                let pid = app.processIdentifier
                let axApp = AXUIElementCreateApplication(pid)
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                        axApp, kAXWindowsAttribute as CFString, &ref) == .success,
                      let windows = ref as? [AXUIElement] else { continue }

                for (i, w) in windows.enumerated() where !(consumed[pid]?.contains(i) ?? false) {
                    // X tight, Y loose. X is the axis that actually does the
                    // hiding and is written through untouched; Y is routinely
                    // clamped upward by macOS, so demanding an exact Y here
                    // would reject the very windows this pass exists to save.
                    guard let p = WindowHider.position(of: w),
                          abs(p.x - record.parkedAtCG.x) <= 6,
                          abs(p.y - record.parkedAtCG.y) <= 200 else { continue }
                    // Same rule as the live path: the recorded home may predate
                    // a display change, so it is validated before being written.
                    let safe = WSCoord.reachableFrame(record.restoreFrameCG)
                    if safe != record.restoreFrameCG {
                        WSDebug.log("store", "\(record.appName): recorded home "
                            + "\(WSDebug.rect(record.restoreFrameCG)) is off every display now — "
                            + "restoring to \(WSDebug.rect(safe)) instead")
                    }
                    if WindowHider.restore(w, pid: pid, toCG: safe) {
                        consumed[pid, default: []].insert(i)
                        restored += 1
                        didRestore = true
                    }
                    break
                }
                if didRestore { break }
            }
            if !didRestore { survivors.append(record) }
        }

        if flush(survivors) { records = survivors }
        WSDebug.log("store", "launch recovery: restored \(restored), kept \(survivors.count) "
            + "for later: \(survivors.map(\.appName).joined(separator: ", "))")
        log.info("launch recovery: restored \(restored), kept \(survivors.count) for later")
        return (restored, survivors.count)
    }
}
