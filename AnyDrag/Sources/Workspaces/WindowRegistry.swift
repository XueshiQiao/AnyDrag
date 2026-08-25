import AppKit
import ApplicationServices

/// One window AnyDrag is keeping track of.
struct ManagedWindow {
    let windowID: CGWindowID
    let pid: pid_t
    let bundleID: String
    let appName: String

    /// Which display + workspace it belongs to.
    var display: DisplayKey
    var workspaceIndex: Int

    /// Where the window belongs when its workspace is visible — position AND
    /// size, in CG coords. For a hidden window this is NOT where it currently
    /// is; it is where `restore` has to put it back.
    var restoreFrameCG: CGRect

    var isHidden: Bool
    /// Where we parked it. nil when visible. Persisted so a crash-recovery
    /// pass can recognise our own handiwork.
    var parkedAtCG: CGPoint?
    /// The durable recovery record covering this window while it is parked.
    /// Retired only once the window is verified back on screen.
    var recordID: UUID?

    var icon: NSImage?
}

/// The single source of truth for "which window belongs to which workspace".
///
/// **Prototype-stage refresh strategy.** `refresh()` walks the system window
/// list and merges. It is called on workspace switch, on app activation and
/// on a slow timer — never from the drag hot path. Reads (`windows(on:...)`)
/// are pure dictionary lookups.
///
/// That split is the one architectural rule that must survive: the bento panel
/// pops up on middle-button-down, which is the most latency-sensitive moment
/// in the whole app. It may only ever read memory. Swapping this coarse
/// refresh for proper AXObserver-driven incremental updates later is a change
/// of implementation, not of interface.
final class WindowRegistry {

    private static let log = FileLog("WindowRegistry")

    /// windowID → window. Written and read on the main thread only.
    private var byID: [CGWindowID: ManagedWindow] = [:]
    /// Cheap grouped index so `windows(on:workspace:)` never filters the world.
    private var byWorkspace: [WorkspaceID: Set<CGWindowID>] = [:]

    private var iconCache: [String: NSImage] = [:]

    /// Bundle IDs the user has excluded; supplied by DragEngine.
    var isExcluded: (String) -> Bool = { _ in false }

    /// Windows smaller than this in either axis are ignored — palettes,
    /// tooltips and the little floating panels apps litter the screen with.
    private static let minSide: CGFloat = 120

    // MARK: - Reads (memory only — safe on the hot path)

    func windows(in ws: WorkspaceID) -> [ManagedWindow] {
        (byWorkspace[ws] ?? []).compactMap { byID[$0] }
    }

    func window(id: CGWindowID) -> ManagedWindow? { byID[id] }

    var allWindows: [ManagedWindow] { Array(byID.values) }

    var hiddenWindows: [ManagedWindow] { byID.values.filter(\.isHidden) }

    // MARK: - Refresh

    /// Merge the live system window list into the registry.
    ///
    /// `visibleWorkspaceIndex` tells us, for a display, which workspace is on
    /// screen right now — that is where a newly-seen window gets filed.
    func refresh(visibleWorkspaceIndex: (DisplayKey) -> Int) {
        let run = WSDebug.newRun("refresh")
        let listed = Self.enumerateWindows(isExcluded: isExcluded, run: run)
        var seen = Set<CGWindowID>()
        var added = 0, reassigned = 0, dropped = 0, kept = 0

        for w in listed {
            seen.insert(w.windowID)

            if var existing = byID[w.windowID] {
                // A parked window's on-screen position is the parking spot, not
                // anything meaningful — never let it overwrite the restore
                // frame, or the window can never be put back properly.
                if existing.isHidden {
                    WSDebug.log(run, "keep \(WSDebug.win(existing)) — parked, left untouched")
                    kept += 1
                } else if !Self.isOnScreen(w.frameCG) {
                    // The list still shows this window off-screen even though we
                    // do not consider it parked. Almost always this is a STALE
                    // read: un-parking is an Accessibility write, the window
                    // server needs a few milliseconds to catch up, and un-parking
                    // activates the app — which triggers a refresh immediately.
                    // CGWindowList then reports the old parking coordinates.
                    //
                    // Recording that as the window's home is how a window ends
                    // up being "restored" to the corner it was hidden in. Never
                    // let an off-screen frame become a home position.
                    WSDebug.log(run, "IGNORED stale frame for \(WSDebug.win(existing)): list says "
                        + "\(WSDebug.rect(w.frameCG)) which is off-screen — keeping "
                        + "\(WSDebug.rect(existing.restoreFrameCG))")
                } else {
                    if existing.restoreFrameCG != w.frameCG {
                        WSDebug.log(run, "frame \(WSDebug.win(existing)): "
                            + "\(WSDebug.rect(existing.restoreFrameCG)) → \(WSDebug.rect(w.frameCG))")
                    }
                    existing.restoreFrameCG = w.frameCG
                    // A visible window that moved to another display joins that
                    // display's currently-visible workspace. Without this rule,
                    // dragging a window across screens leaves it filed under a
                    // workspace it is no longer on.
                    if let key = displayKey(forCG: w.frameCG), key != existing.display {
                        let to = WorkspaceID(display: key, index: visibleWorkspaceIndex(key))
                        WSDebug.log(run, "REASSIGN \(WSDebug.win(existing)): "
                            + "\(WSDebug.ws(WorkspaceID(display: existing.display, index: existing.workspaceIndex)))"
                            + " → \(WSDebug.ws(to)) (window changed display)")
                        reindex(existing, to: to)
                        existing.display = key
                        existing.workspaceIndex = to.index
                        reassigned += 1
                    }
                }
                byID[w.windowID] = existing
            } else {
                // On no display at all = a stray left parked by an earlier run.
                // File it under the nearest display rather than dropping it, so
                // the escape hatch can still reach it.
                guard let key = displayKey(forCG: w.frameCG) ?? nearestDisplayKey(forCG: w.frameCG) else {
                    WSDebug.bail(run, "new \(w.appName)#\(w.windowID) — no displays at all?")
                    continue
                }
                let idx = visibleWorkspaceIndex(key)

                // A window we have never seen before that is ALREADY sitting
                // off-screen is almost certainly one a previous run parked and
                // never got to bring back (a crash, a force-quit, a rebuild).
                //
                // Adopting it as an ordinary window would bake the parking spot
                // in as "where it lives", after which it can never be restored
                // to anywhere visible again. Instead adopt it as parked, with a
                // restore frame clamped back into view, so the escape hatch and
                // the next workspace switch can both reach it.
                let strayOffScreen = !Self.isOnScreen(w.frameCG)
                let restore = strayOffScreen
                    ? Self.clampIntoView(w.frameCG, on: key) ?? w.frameCG
                    : w.frameCG

                let entry = ManagedWindow(
                    windowID: w.windowID, pid: w.pid,
                    bundleID: w.bundleID, appName: w.appName,
                    display: key, workspaceIndex: idx,
                    restoreFrameCG: restore,
                    isHidden: strayOffScreen,
                    parkedAtCG: strayOffScreen ? w.frameCG.origin : nil,
                    recordID: nil,
                    icon: icon(forPid: w.pid, bundleID: w.bundleID))
                byID[w.windowID] = entry
                byWorkspace[WorkspaceID(display: key, index: idx), default: []].insert(w.windowID)
                if strayOffScreen {
                    WSDebug.log(run, "STRAY \(w.appName)#\(w.windowID) found off-screen at "
                        + "\(WSDebug.rect(w.frameCG)) — adopted as parked, will restore to "
                        + "\(WSDebug.rect(restore))")
                } else {
                    WSDebug.log(run, "NEW \(w.appName)#\(w.windowID) → "
                        + "\(WSDebug.ws(WorkspaceID(display: key, index: idx))) at \(WSDebug.rect(w.frameCG))")
                }
                added += 1
            }
        }

        // Drop windows that no longer exist — but NEVER a parked one just
        // because it didn't show up in the list. A window pushed off-screen may
        // or may not still count as "on screen" to CGWindowList, and this
        // refresh runs on every app activation: dropping parked windows here
        // would quietly forget them seconds after they were hidden.
        for id in byID.keys where !seen.contains(id) {
            guard let gone = byID[id] else { continue }
            if gone.isHidden, NSRunningApplication(processIdentifier: gone.pid) != nil {
                WSDebug.log(run, "keep \(WSDebug.win(gone)) — parked and its app is alive, "
                    + "not in the on-screen list but NOT forgotten")
                kept += 1
                continue
            }
            WSDebug.log(run, "DROP \(WSDebug.win(gone)) — "
                + (gone.isHidden ? "parked but its app is gone" : "window no longer exists"))
            byWorkspace[WorkspaceID(display: gone.display, index: gone.workspaceIndex)]?.remove(id)
            byID[id] = nil
            dropped += 1
        }

        WSDebug.log(run, "done: listed=\(listed.count) tracked=\(byID.count) "
            + "new=\(added) reassigned=\(reassigned) dropped=\(dropped) keptParked=\(kept)")
    }

    // MARK: - Mutations

    func assign(_ id: CGWindowID, to ws: WorkspaceID) {
        guard var w = byID[id] else {
            WSDebug.bail("assign", "wid=\(id) not tracked — assignment silently lost")
            return
        }
        reindex(w, to: ws)
        w.display = ws.display
        w.workspaceIndex = ws.index
        byID[id] = w
    }

    func setHidden(_ id: CGWindowID, parkedAtCG: CGPoint?, recordID: UUID?) {
        guard var w = byID[id] else { return }
        w.isHidden = parkedAtCG != nil
        w.parkedAtCG = parkedAtCG
        w.recordID = recordID
        byID[id] = w
    }

    func setRestoreFrame(_ id: CGWindowID, _ frameCG: CGRect) {
        guard var w = byID[id] else { return }
        w.restoreFrameCG = frameCG
        byID[id] = w
    }

    /// Forget everything. Used when the feature is switched off.
    func reset() {
        byID.removeAll()
        byWorkspace.removeAll()
    }

    private func reindex(_ w: ManagedWindow, to ws: WorkspaceID) {
        byWorkspace[WorkspaceID(display: w.display, index: w.workspaceIndex)]?.remove(w.windowID)
        byWorkspace[ws, default: []].insert(w.windowID)
    }

    /// Is a meaningful part of this frame inside some display's visible area?
    static func isOnScreen(_ frameCG: CGRect) -> Bool {
        guard frameCG.width > 0, frameCG.height > 0 else { return false }
        return NSScreen.screens.contains { screen in
            let v = WSCoord.visibleFrameCG(of: screen)
            let i = v.intersection(frameCG)
            guard !i.isNull else { return false }
            return (i.width * i.height) / (frameCG.width * frameCG.height) >= 0.25
        }
    }

    /// Nudge a frame back inside a display's visible area, keeping its size.
    static func clampIntoView(_ frameCG: CGRect, on display: DisplayKey) -> CGRect? {
        guard let screen = display.screen ?? NSScreen.main else { return nil }
        let v = WSCoord.visibleFrameCG(of: screen)
        let w = min(frameCG.width, v.width)
        let h = min(frameCG.height, v.height)
        let x = min(max(frameCG.origin.x, v.minX), max(v.minX, v.maxX - w))
        let y = min(max(frameCG.origin.y, v.minY), max(v.minY, v.maxY - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Which display this frame is ON. nil when it is on none — which is the
    /// answer that keeps a parked window from being refiled onto the primary.
    private func displayKey(forCG frame: CGRect) -> DisplayKey? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = WSCoord.screen(containingCG: center) else { return nil }
        return DisplayKey.from(screen)
    }

    /// Which display a stray off-screen window should be FILED under. It isn't
    /// really on any display, so pick the nearest one by horizontal distance —
    /// a window parked off the left edge of the second monitor belongs to that
    /// monitor, not to the primary.
    private func nearestDisplayKey(forCG frame: CGRect) -> DisplayKey? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let best = NSScreen.screens.min { a, b in
            let va = WSCoord.visibleFrameCG(of: a), vb = WSCoord.visibleFrameCG(of: b)
            return abs(va.midX - center.x) < abs(vb.midX - center.x)
        }
        return best.flatMap(DisplayKey.from)
    }

    // MARK: - Icons

    /// Icons are pre-scaled to the size the bento card draws them at and cached
    /// per app. The originals are 512×512; rescaling four cards' worth of them
    /// while the panel is being drawn would be visible.
    private func icon(forPid pid: pid_t, bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        guard let app = NSRunningApplication(processIdentifier: pid),
              let raw = app.icon else { return nil }
        let side: CGFloat = 16
        let scaled = NSImage(size: NSSize(width: side, height: side))
        scaled.lockFocus()
        raw.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                 from: .zero, operation: .sourceOver, fraction: 1)
        scaled.unlockFocus()
        iconCache[bundleID] = scaled
        return scaled
    }

    // MARK: - System enumeration

    private struct ListedWindow {
        let windowID: CGWindowID
        let pid: pid_t
        let bundleID: String
        let appName: String
        let frameCG: CGRect
    }

    /// Walk `CGWindowListCopyWindowInfo`. **Never call this from the drag
    /// path** — it is a synchronous window-server round trip.
    private static func enumerateWindows(isExcluded: (String) -> Bool, run: String) -> [ListedWindow] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        let ownPid = ProcessInfo.processInfo.processIdentifier
        var out: [ListedWindow] = []

        for info in raw {
            // Layer 0 is the normal window layer. Anything else is a panel,
            // the Dock, the menu bar, a screensaver, etc.
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pidNum = info[kCGWindowOwnerPID as String] as? Int,
                  pid_t(pidNum) != ownPid,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  frame.width >= minSide, frame.height >= minSide
            else { continue }

            let pid = pid_t(pidNum)
            let app = NSRunningApplication(processIdentifier: pid)
            let bundleID = app?.bundleIdentifier ?? "pid.\(pid)"
            guard !isExcluded(bundleID) else {
                WSDebug.log(run, "filtered out \(bundleID) — on the user's excluded list")
                continue
            }

            out.append(ListedWindow(
                windowID: id, pid: pid, bundleID: bundleID,
                appName: app?.localizedName
                    ?? (info[kCGWindowOwnerName as String] as? String ?? "?"),
                frameCG: frame))
        }
        return out
    }

    // MARK: - Finding the AX element for a window

    /// Locate the `AXUIElement` for a tracked window by matching its frame.
    ///
    /// The Accessibility API exposes no window id, so frame matching is the
    /// only bridge from `CGWindowID` to `AXUIElement`. Same approach the rest
    /// of AnyDrag already uses (`DragEngine.findAXWindow`).
    static func axWindow(pid: pid_t, matchingCG frame: CGRect, tolerance: CGFloat = 8) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return nil }
        if windows.count == 1 { return windows[0] }

        // Score every candidate instead of taking the first one within
        // tolerance, and weigh the SIZE as well as the origin.
        //
        // Origin alone is not enough once parking is involved: every window an
        // app parks in the same corner ends up at very nearly the same point,
        // so a browser with three windows open has three candidates a few
        // points apart. Picking the first match then restores one window to
        // another's frame — which from the outside looks like a window
        // teleporting for no reason.
        var best: (element: AXUIElement, score: CGFloat)?
        for w in windows {
            guard let f = WindowHider.frameCG(of: w) else { continue }
            let dOrigin = abs(f.origin.x - frame.origin.x) + abs(f.origin.y - frame.origin.y)
            // A zero-size probe frame means "match on position only" (used when
            // looking a window up by where it was parked).
            let dSize = frame.size == .zero ? 0
                : abs(f.width - frame.width) + abs(f.height - frame.height)
            let score = dOrigin + dSize
            guard dOrigin <= tolerance * 2 else { continue }
            if best == nil || score < best!.score { best = (w, score) }
        }
        return best?.element
    }
}
