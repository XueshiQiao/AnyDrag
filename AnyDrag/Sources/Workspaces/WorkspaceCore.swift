import AppKit

// MARK: - Coordinate helpers
//
// Two coordinate systems are in play and mixing them up is the single
// easiest way to send a window somewhere it can never be recovered from:
//
//   • CG / Quartz — origin at the PRIMARY screen's top-left, Y grows DOWN.
//     Used by CGWindowList and by the Accessibility position/size attributes.
//   • NS / AppKit — origin at the primary screen's bottom-left, Y grows UP.
//     Used by NSScreen.frame / visibleFrame.
//
// Every rect and point in the Workspaces module carries a `CG` or `NS` suffix
// in its name. Anything without a suffix is a bug waiting to happen.

enum WSCoord {
    static func nsRect(fromCG cg: CGRect) -> NSRect {
        guard let primary = NSScreen.screens.first else { return cg }
        return NSRect(x: cg.origin.x,
                      y: primary.frame.height - cg.origin.y - cg.height,
                      width: cg.width, height: cg.height)
    }

    static func cgRect(fromNS ns: NSRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return ns }
        return CGRect(x: ns.origin.x,
                      y: primary.frame.height - ns.origin.y - ns.height,
                      width: ns.width, height: ns.height)
    }

    /// The screen whose frame contains this CG point, or nil if it is on no
    /// display at all.
    ///
    /// Returning nil matters. This used to fall back to the primary display,
    /// which meant any window sitting off-screen — every parked window, by
    /// definition — was reported as living on the primary. A refresh would
    /// then see "this window changed display" and refile it into the primary's
    /// visible workspace, so a parked window silently joined whichever
    /// workspace you happened to be looking at.
    static func screen(containingCG cg: CGPoint) -> NSScreen? {
        guard let primary = NSScreen.screens.first else { return nil }
        let ns = NSPoint(x: cg.x, y: primary.frame.height - cg.y)
        return NSScreen.screens.first { $0.frame.contains(ns) }
    }

    /// Same, but never nil — for callers that just need somewhere sensible to
    /// put a window (a fallback placement), not an answer about where it is.
    static func screenOrPrimary(containingCG cg: CGPoint) -> NSScreen? {
        screen(containingCG: cg) ?? NSScreen.screens.first
    }

    /// The attached display nearest to a CG point, measured as the distance
    /// from the point to that display's frame (zero when inside).
    ///
    /// Borrowed from AeroSpace's `monitorApproximation`. The value of asking
    /// "which is nearest" instead of "which contains it" is that it still has
    /// an answer when the point is on no display at all — which is the normal
    /// case for a parked window, and the ONLY case after a display is unplugged.
    static func nearestScreen(toCG point: CGPoint) -> NSScreen? {
        NSScreen.screens.min { a, b in
            distance(fromCG: point, toCG: visibleFrameCG(of: a))
                < distance(fromCG: point, toCG: visibleFrameCG(of: b))
        }
    }

    private static func distance(fromCG p: CGPoint, toCG r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// A frame that is definitely reachable, derived from one that may not be.
    ///
    /// Restoring a window means writing absolute coordinates that were recorded
    /// earlier — possibly before a display was unplugged, before the
    /// arrangement changed, or before a resolution change. Writing them back
    /// blind is how a window gets "restored" to somewhere that no longer
    /// exists, which strands it exactly like the bug we were trying to prevent.
    ///
    /// The rule, taken from how AeroSpace handles its termination path: when
    /// reality does not match what was recorded, stop trying to be precise.
    /// Put the window somewhere unambiguously visible instead.
    ///
    /// - Returns: `desired` untouched when it still lands on an attached
    ///   display; otherwise the same size centred on the nearest display,
    ///   shrunk if it no longer fits.
    static func reachableFrame(_ desired: CGRect) -> CGRect {
        if isReachable(desired) { return desired }
        let centre = CGPoint(x: desired.midX, y: desired.midY)
        guard let screen = nearestScreen(toCG: centre) ?? NSScreen.main else { return desired }
        let v = visibleFrameCG(of: screen)
        let w = min(desired.width, v.width)
        let h = min(desired.height, v.height)
        return CGRect(x: v.minX + (v.width - w) / 2,
                      y: v.minY + (v.height - h) / 2,
                      width: w, height: h)
    }

    /// Does enough of this frame land on an attached display to be usable?
    static func isReachable(_ frameCG: CGRect, minimumFraction: CGFloat = 0.4) -> Bool {
        guard frameCG.width > 0, frameCG.height > 0 else { return false }
        let area = frameCG.width * frameCG.height
        return NSScreen.screens.contains { screen in
            let i = visibleFrameCG(of: screen).intersection(frameCG)
            guard !i.isNull else { return false }
            return (i.width * i.height) / area >= minimumFraction
        }
    }

    /// The bounding box of every attached display's visible area. Parking
    /// against this rather than one display's own edges is what lets a display
    /// with neighbours on both sides still hide a window.
    static func topologyBoundsCG() -> CGRect {
        NSScreen.screens
            .map { visibleFrameCG(of: $0) }
            .reduce(CGRect.null) { $0.union($1) }
    }

    /// A screen's visible area (menu bar and Dock excluded) in CG coords.
    static func visibleFrameCG(of screen: NSScreen) -> CGRect {
        cgRect(fromNS: screen.visibleFrame)
    }
}

// MARK: - Display identity

/// A display's identity that survives sleep, unplugging and reboot.
///
/// `CGDirectDisplayID` deliberately NOT used: it is a per-session handle that
/// changes when you unplug and replug, so anything persisted against it stops
/// matching. The UUID is derived from the panel itself and stays put.
struct DisplayKey: Hashable, Codable {
    let uuid: String

    /// displayID → key. `CGDisplayCreateUUIDFromDisplayID` is a CoreGraphics
    /// round trip, and the bento panel asks for a key once per card while it
    /// is being built — i.e. on middle-button-down, the one moment nothing may
    /// touch the window server. The mapping is stable for as long as a display
    /// is attached, so it is cached and dropped on a display change.
    private static var cache: [CGDirectDisplayID: DisplayKey] = [:]

    static func invalidateCache() { cache.removeAll() }

    static func from(_ screen: NSScreen) -> DisplayKey? {
        guard let num = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(num.uint32Value)
        if let hit = cache[displayID] { return hit }
        guard let cf = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        let key = DisplayKey(uuid: CFUUIDCreateString(nil, cf.takeRetainedValue()) as String)
        cache[displayID] = key
        return key
    }

    /// The live NSScreen for this key, if that display is currently attached.
    var screen: NSScreen? {
        NSScreen.screens.first { DisplayKey.from($0) == self }
    }
}

// MARK: - Workspace identity

/// Which display, and which workspace on it. `index` is 0-based; humans see
/// `index + 1`.
struct WorkspaceID: Hashable, Codable {
    let display: DisplayKey
    let index: Int
}

enum Workspace {
    /// v1: every display gets the same number of workspaces. Per-display
    /// counts are issue #42.
    static let countRange: ClosedRange<Int> = 1...4

    static func displayName(index: Int) -> String { String(index + 1) }
}

// MARK: - Hide corner

/// Which off-screen corner hidden windows are parked in. Pick one that is
/// empty in your display arrangement, otherwise you will see the parked
/// windows peeking onto the neighbouring screen.
enum HideCorner: String, Codable, CaseIterable {
    case bottomLeft, bottomRight

    /// Pick the side of `screen` that actually leads off into nothing.
    ///
    /// This has to be decided **per display**, and getting it wrong doesn't
    /// hide the window — it teleports it into the middle of the neighbouring
    /// screen. With two monitors side by side at x = -2560…0 and 0…2560, the
    /// "empty space" to the left of the right-hand monitor is the left-hand
    /// monitor's centre. A window parked there is fully visible, just in the
    /// wrong place, which looks exactly like the app has gone haywire.
    ///
    /// So: park towards whichever horizontal side has no other display next to
    /// it. When both sides are free, prefer the one further from the others so
    /// a later display arrangement change is less likely to collide.
    static func best(for screen: NSScreen, among screens: [NSScreen] = NSScreen.screens) -> HideCorner {
        let me = WSCoord.visibleFrameCG(of: screen)
        let others = screens.filter { $0 != screen }.map { WSCoord.visibleFrameCG(of: $0) }

        /// Does any other display occupy the band immediately to this side,
        /// at a vertical range that overlaps ours? A monitor stacked far above
        /// or below doesn't block a sideways park.
        func occupied(towardLeft: Bool) -> Bool {
            others.contains { other in
                let verticallyOverlaps = other.maxY > me.minY && other.minY < me.maxY
                guard verticallyOverlaps else { return false }
                return towardLeft ? other.minX < me.minX : other.maxX > me.maxX
            }
        }

        let leftBlocked = occupied(towardLeft: true)
        let rightBlocked = occupied(towardLeft: false)

        switch (leftBlocked, rightBlocked) {
        case (false, true): return .bottomLeft
        case (true, false): return .bottomRight
        case (true, true):
            // Boxed in on both sides — the middle display of three in a row.
            // NEITHER side of this display hides anything: park left and the
            // window lands on the left monitor in full view. The caller has to
            // park against the whole topology instead, so just pick the closer
            // outer edge and let `needsOuterBounds` tell it to do that.
            let toLeftEdge = me.minX - (others.map(\.minX).min() ?? me.minX)
            let toRightEdge = (others.map(\.maxX).max() ?? me.maxX) - me.maxX
            return toLeftEdge <= toRightEdge ? .bottomLeft : .bottomRight
        case (false, false):
            return .bottomLeft
        }
    }

    /// True when this display has another display on BOTH sides, so parking
    /// against its own edges would drop the window onto a neighbour in plain
    /// sight. The caller must park against `WSCoord.topologyBoundsCG` instead.
    static func needsOuterBounds(for screen: NSScreen,
                                 among screens: [NSScreen] = NSScreen.screens) -> Bool {
        let me = WSCoord.visibleFrameCG(of: screen)
        let others = screens.filter { $0 != screen }.map { WSCoord.visibleFrameCG(of: $0) }
        func occupied(towardLeft: Bool) -> Bool {
            others.contains { other in
                guard other.maxY > me.minY && other.minY < me.maxY else { return false }
                return towardLeft ? other.minX < me.minX : other.maxX > me.maxX
            }
        }
        return occupied(towardLeft: true) && occupied(towardLeft: false)
    }
}
