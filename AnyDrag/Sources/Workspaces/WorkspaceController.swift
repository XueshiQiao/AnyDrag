import AppKit

/// Orchestrates virtual workspaces: which one each display is showing, what
/// happens on a switch, and the escape hatch that undoes everything.
///
/// Everything here runs on the main thread.
final class WorkspaceController {

    private static let log = FileLog("Workspaces")

    let registry = WindowRegistry()

    /// Master switch. Turning it OFF immediately un-parks every window —
    /// otherwise the user would be left with windows off-screen and no
    /// remaining UI able to reach them.
    var isEnabled: Bool = false {
        didSet {
            guard oldValue != isEnabled else { return }
            if isEnabled {
                refresh()
                Self.log.info("workspaces enabled (perDisplay=\(workspacesPerDisplay))")
                logParkingPlan()
            } else {
                restoreAllWindows()
                registry.reset()
                visibleIndex.removeAll()
                Self.log.info("workspaces disabled — all windows restored")
            }
            onChange?()
        }
    }

    var workspacesPerDisplay: Int = 2
    /// User override. `nil` (the default) means "work it out per display",
    /// which is almost always what you want — see `HideCorner.best`.
    var hideCornerOverride: HideCorner?

    private func corner(for screen: NSScreen) -> HideCorner {
        hideCornerOverride ?? HideCorner.best(for: screen)
    }

    /// Log which side each display parks towards, and where that actually
    /// lands. Getting this wrong doesn't hide a window, it drops it in the
    /// middle of the neighbouring screen — so it is worth being able to read
    /// the decision straight out of the log.
    /// Dump who lives where and what is parked. Successful parks used to be
    /// silent, which made "this window followed me across a switch" impossible
    /// to diagnose from a log — you couldn't tell a park that worked from a
    /// window that was never in the workspace to begin with.
    func logRegistrySnapshot(reason: String) {
        for screen in NSScreen.screens {
            guard let key = DisplayKey.from(screen) else { continue }
            let visible = visibleWorkspaceIndex(on: key)
            for i in 0..<workspacesPerDisplay {
                let ws = WorkspaceID(display: key, index: i)
                let list = registry.windows(in: ws)
                guard !list.isEmpty else { continue }
                let desc = list.map { "\($0.appName)#\($0.windowID)\($0.isHidden ? "[parked]" : "[visible]")" }
                    .joined(separator: ", ")
                Self.log.info("  [\(reason)] \(screen.localizedName) ws\(i)\(i == visible ? "*" : " ") → \(desc)")
            }
        }
    }

    private func logParkingPlan() {
        for screen in NSScreen.screens {
            let v = WSCoord.visibleFrameCG(of: screen)
            let c = corner(for: screen)
            // Where a 1200pt-wide window would end up, as a concrete example.
            let sample = WindowHider.hidePoint(windowSize: CGSize(width: 1200, height: 800),
                                               visibleFrameCG: v, corner: c)
            let landsOnAnother = NSScreen.screens.contains { other in
                other != screen && WSCoord.visibleFrameCG(of: other).contains(
                    CGPoint(x: sample.x + 600, y: sample.y + 10))
            }
            Self.log.info("parking plan: \(screen.localizedName) visible=\(v) corner=\(c.rawValue) "
                + "sample1200→\(sample) \(landsOnAnother ? "❌ LANDS ON ANOTHER DISPLAY" : "✅ off into empty space")")
        }
    }

    /// Fires when the visible workspace or the enabled flag changes, so the
    /// menu bar can redraw.
    var onChange: (() -> Void)?

    /// display → index of the workspace currently on screen. Missing = 0.
    private var visibleIndex: [DisplayKey: Int] = [:]

    // MARK: - Queries

    func visibleWorkspaceIndex(on display: DisplayKey) -> Int {
        min(visibleIndex[display] ?? 0, workspacesPerDisplay - 1)
    }

    func isVisible(_ ws: WorkspaceID) -> Bool {
        visibleWorkspaceIndex(on: ws.display) == ws.index
    }

    /// The workspace the cursor's display is currently showing.
    func currentWorkspace(forCG point: CGPoint) -> WorkspaceID? {
        guard let screen = WSCoord.screen(containingCG: point),
              let key = DisplayKey.from(screen) else { return nil }
        return WorkspaceID(display: key, index: visibleWorkspaceIndex(on: key))
    }

    /// Windows in a workspace — a memory read, safe to call while the panel
    /// is being built.
    func windows(in ws: WorkspaceID) -> [ManagedWindow] { registry.windows(in: ws) }

    // MARK: - Refresh

    /// Re-sync the registry with the real window list. Called on activation
    /// and after switches — never from the drag path.
    func refresh() {
        guard isEnabled else { return }
        registry.refresh { [weak self] key in
            self?.visibleWorkspaceIndex(on: key) ?? 0
        }
    }

    // MARK: - Switching

    /// Hard cut — no animation, by design. The windows of the outgoing
    /// workspace are parked and the incoming ones are put back in one pass.
    func switchTo(_ ws: WorkspaceID) {
        let run = WSDebug.newRun("switch")
        WSDebug.log(run, "requested → \(WSDebug.ws(ws))")

        guard isEnabled else { return WSDebug.bail(run, "feature disabled") }
        guard ws.index < workspacesPerDisplay else {
            return WSDebug.bail(run, "index \(ws.index) >= perDisplay \(workspacesPerDisplay)")
        }
        let current = visibleWorkspaceIndex(on: ws.display)
        guard current != ws.index else {
            return WSDebug.bail(run, "already showing ws\(current)")
        }
        guard let screen = ws.display.screen else {
            return WSDebug.bail(run, "display \(ws.display.uuid.prefix(8)) is not attached")
        }

        let visibleCG = WSCoord.visibleFrameCG(of: screen)
        let outgoing = WorkspaceID(display: ws.display, index: current)
        let parkCorner = corner(for: screen)
        WSDebug.log(run, "screen=\(screen.localizedName) visible=\(WSDebug.rect(visibleCG)) corner=\(parkCorner.rawValue)")

        let incoming = registry.windows(in: ws)
        let leaving = registry.windows(in: outgoing)
        WSDebug.log(run, "incoming ws\(ws.index) has \(incoming.count): "
            + incoming.map { "\(WSDebug.win($0))\($0.isHidden ? "[parked]" : "[visible]")" }.joined(separator: ", "))
        WSDebug.log(run, "outgoing ws\(current) has \(leaving.count): "
            + leaving.map { "\(WSDebug.win($0))\($0.isHidden ? "[parked]" : "[visible]")" }.joined(separator: ", "))

        // Un-park the incoming set BEFORE parking the outgoing one. The other
        // order leaves a frame with an empty screen, which reads as a flicker.
        for w in incoming {
            guard w.isHidden else {
                WSDebug.log(run, "skip unpark \(WSDebug.win(w)) — already visible")
                continue
            }
            unpark(w, run: run)
        }
        for w in leaving {
            guard !w.isHidden else {
                WSDebug.log(run, "skip park \(WSDebug.win(w)) — already parked")
                continue
            }
            park(w, visibleFrameCG: visibleCG, parkCorner: parkCorner, run: run)
        }

        visibleIndex[ws.display] = ws.index
        WSDebug.log(run, "visible index \(current) → \(ws.index)")
        Self.log.info("switch: display=\(ws.display.uuid.prefix(8)) \(current) → \(ws.index)")
        logRegistrySnapshot(reason: run)
        onChange?()
    }

    // MARK: - Moving a window into a workspace

    /// Send a window to `ws` and have it land on `landingFrameCG` there.
    ///
    /// When `ws` is already on screen the caller (DragEngine) has applied the
    /// frame itself — we only record the membership. When it is not, we record
    /// the frame as the restore target and park the window straight away.
    func move(windowID: CGWindowID, pid: pid_t, to ws: WorkspaceID, landingFrameCG: CGRect) {
        let run = WSDebug.newRun("move")
        WSDebug.log(run, "wid=\(windowID) pid=\(pid) → \(WSDebug.ws(ws)) landing=\(WSDebug.rect(landingFrameCG))")

        guard isEnabled else { return WSDebug.bail(run, "feature disabled") }
        guard let before = registry.window(id: windowID) else {
            return WSDebug.bail(run, "wid=\(windowID) is NOT in the registry — "
                + "it was never seen by a refresh, so nothing can be assigned")
        }
        WSDebug.log(run, "\(WSDebug.win(before)) was in ws\(before.workspaceIndex) "
            + "on \(before.display.uuid.prefix(8)), hidden=\(before.isHidden)")

        registry.assign(windowID, to: ws)
        registry.setRestoreFrame(windowID, landingFrameCG)
        WSDebug.log(run, "assigned → \(WSDebug.ws(ws)), restoreFrame=\(WSDebug.rect(landingFrameCG))")

        guard !isVisible(ws) else {
            WSDebug.log(run, "target workspace is ON SCREEN — no park; DragEngine already placed the window")
            logRegistrySnapshot(reason: run)
            return
        }
        guard let screen = ws.display.screen else {
            return WSDebug.bail(run, "target display not attached")
        }
        guard let w = registry.window(id: windowID) else {
            return WSDebug.bail(run, "window vanished from registry between assign and park")
        }
        park(w, visibleFrameCG: WSCoord.visibleFrameCG(of: screen),
             parkCorner: corner(for: screen), landingFrameCG: landingFrameCG, run: run)
        Self.log.info("moved \(w.appName)#\(windowID) → ws\(ws.index) (parked)")
        logRegistrySnapshot(reason: run)
    }

    // MARK: - Escape hatch

    /// Bring every parked window back into view, wherever it belongs.
    /// Always available, whatever the master switch says.
    func restoreAllWindows() {
        let run = WSDebug.newRun("restoreall")
        let parked = registry.hiddenWindows
        WSDebug.log(run, "restore-all: \(parked.count) tracked as parked, "
            + "\(WorkspaceStore.all.count) durable record(s) on disk")
        var restored = 0
        for w in parked where unpark(w, run: run) { restored += 1 }

        // Also sweep the durable store. It can hold records the live registry
        // knows nothing about — a window parked before the app was restarted,
        // or one whose registry entry was dropped when its process quit and
        // came back. Those are precisely the windows nothing else would reach.
        let sweptBack = WorkspaceStore.recoverOnLaunch().restored

        if !parked.isEmpty || sweptBack > 0 {
            Self.log.info("restore-all: \(restored)/\(parked.count) tracked + \(sweptBack) from records")
        }
        onChange?()
    }

    // MARK: - Park / un-park one window

    /// `landingFrameCG` is where the window should come back to. Pass it when
    /// the user just chose a destination (a bento drop); pass nil for a plain
    /// workspace switch, where "where it is now" is the right answer.
    private func park(_ w: ManagedWindow, visibleFrameCG: CGRect, parkCorner: HideCorner,
                      landingFrameCG: CGRect? = nil, run: String) {
        WSDebug.log(run, "park \(WSDebug.win(w)): stored restoreFrame=\(WSDebug.rect(w.restoreFrameCG))")

        guard let ax = WindowRegistry.axWindow(pid: w.pid, matchingCG: w.restoreFrameCG) else {
            return WSDebug.bail(run, "park \(WSDebug.win(w)) — no AX window matched "
                + "\(WSDebug.rect(w.restoreFrameCG)); window stays VISIBLE")
        }
        guard let live = WindowHider.frameCG(of: ax) else {
            return WSDebug.bail(run, "park \(WSDebug.win(w)) — could not read its live frame; stays VISIBLE")
        }
        WSDebug.log(run, "park \(WSDebug.win(w)): live frame=\(WSDebug.rect(live))")

        guard Self.isMostlyVisible(live) else {
            return WSDebug.bail(run, "park \(WSDebug.win(w)) — already off-screen at "
                + "\(WSDebug.point(live.origin)); refusing to re-park (would corrupt its restore frame)")
        }

        let restoreTo = landingFrameCG ?? live
        registry.setRestoreFrame(w.windowID, restoreTo)
        WSDebug.log(run, "park \(WSDebug.win(w)): will return to \(WSDebug.rect(restoreTo))"
            + (landingFrameCG != nil ? " (user-chosen landing)" : " (its current spot)"))

        let target = WindowHider.hidePoint(windowSize: live.size,
                                           visibleFrameCG: visibleFrameCG, corner: parkCorner)
        WSDebug.log(run, "park \(WSDebug.win(w)): target=\(WSDebug.point(target)) corner=\(parkCorner.rawValue)")

        let record = HiddenWindowRecord(id: UUID(), bundleID: w.bundleID, appName: w.appName,
                                        parkedAtCG: target, restoreFrameCG: restoreTo)
        guard WorkspaceStore.reserve(record) else {
            return WSDebug.bail(run, "park \(WSDebug.win(w)) — recovery record could not be persisted; "
                + "refusing to hide a window we could not promise to bring back")
        }

        guard let parked = WindowHider.hide(ax, pid: w.pid, windowSize: live.size,
                                            visibleFrameCG: visibleFrameCG, corner: parkCorner) else {
            WorkspaceStore.discard(id: record.id)
            return WSDebug.bail(run, "park \(WSDebug.win(w)) — app refused the move; stays VISIBLE")
        }
        registry.setHidden(w.windowID, parkedAtCG: parked, recordID: record.id)
        // Correct the write-ahead record to where it really landed.
        WorkspaceStore.confirmParked(id: record.id, actualCG: parked)
        WSDebug.log(run, "park \(WSDebug.win(w)): OK, now at \(WSDebug.point(parked))")
        Self.log.info("parked \(w.appName)#\(w.windowID) at \(WSDebug.point(parked)) "
            + "(returns to \(WSDebug.rect(restoreTo)))")
    }

    /// Is a meaningful part of this frame inside some display's visible area?
    static func isMostlyVisible(_ frameCG: CGRect) -> Bool {
        let overlap = NSScreen.screens.map { screen -> CGFloat in
            let v = WSCoord.visibleFrameCG(of: screen)
            let i = v.intersection(frameCG)
            guard !i.isNull, frameCG.width > 0, frameCG.height > 0 else { return 0 }
            return (i.width * i.height) / (frameCG.width * frameCG.height)
        }.max() ?? 0
        return overlap >= 0.25
    }

    /// Returns false when the window could not be reached — it is then LEFT
    /// marked as hidden on purpose, so its persisted record survives and a
    /// later restore-all (or the next launch) tries again.
    /// Returns false when the window could not be verified back on screen — it
    /// is then LEFT marked hidden and its durable record LEFT in place, so a
    /// later restore-all or the next launch tries again.
    @discardableResult
    private func unpark(_ w: ManagedWindow, run: String) -> Bool {
        WSDebug.log(run, "unpark \(WSDebug.win(w)): parkedAt=\(w.parkedAtCG.map(WSDebug.point) ?? "nil") "
            + "restoreTo=\(WSDebug.rect(w.restoreFrameCG))")

        guard let parked = w.parkedAtCG else {
            WSDebug.bail(run, "unpark \(WSDebug.win(w)) — no parked position recorded")
            return false
        }
        let byParked = WindowRegistry.axWindow(pid: w.pid,
                                               matchingCG: CGRect(origin: parked, size: .zero),
                                               tolerance: 12)
        let ax = byParked ?? WindowRegistry.axWindow(pid: w.pid, matchingCG: w.restoreFrameCG)
        guard let ax else {
            WSDebug.bail(run, "unpark \(WSDebug.win(w)) — no AX window matched either the parked spot "
                + "or the restore frame; KEPT marked hidden so it can be retried")
            return false
        }
        WSDebug.log(run, "unpark \(WSDebug.win(w)): matched by \(byParked != nil ? "parked spot" : "restore frame")")

        guard WindowHider.restore(ax, pid: w.pid, toCG: w.restoreFrameCG) else {
            WSDebug.bail(run, "unpark \(WSDebug.win(w)) — write refused / read-back failed; "
                + "KEPT marked hidden for retry")
            return false
        }
        if let id = w.recordID { WorkspaceStore.retire(id: id) }
        registry.setHidden(w.windowID, parkedAtCG: nil, recordID: nil)
        WSDebug.log(run, "unpark \(WSDebug.win(w)): OK")
        Self.log.info("unparked \(w.appName)#\(w.windowID) → \(WSDebug.rect(w.restoreFrameCG))")
        return true
    }

    // Records are written by `park` before the move and retired by `unpark`
    // after a verified restore. There is deliberately no "rewrite the file from
    // the live registry" step: that is what used to let an emptied or rebuilt
    // registry wipe the only records able to bring windows back.
}
