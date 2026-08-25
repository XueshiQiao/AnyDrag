import AppKit
import ApplicationServices

/// Moves a window out of sight and back. Knows nothing about workspaces and
/// keeps no state — the caller owns "which window is where".
///
/// The trick (same one AeroSpace uses; see
/// `~/dotfiles/notes/aerospace-虚拟工作区调研.html`) is a single Accessibility
/// position write that parks the window just outside the display's visible
/// area. There is no per-frame work: hiding costs exactly one AX call per
/// window, which is why switching a workspace is instant.
enum WindowHider {

    private static let log = FileLog("WindowHider")

    /// macOS refuses to place a window entirely outside every display — the
    /// write is silently dropped and the window stays put. So one point has
    /// to remain inside.
    static let sliver: CGFloat = 1

    // MARK: - Pure math (unit-testable, no system calls)

    /// Where the window's TOP-LEFT corner has to go, in CG coords, so that
    /// only `sliver` points of it remain inside `visibleFrameCG`.
    static func hidePoint(windowSize: CGSize,
                          visibleFrameCG: CGRect,
                          corner: HideCorner) -> CGPoint {
        // Vertically both corners behave the same: the window's top edge sits
        // on the visible area's bottom edge, so the body hangs below it.
        let y = visibleFrameCG.maxY - sliver
        switch corner {
        case .bottomLeft:
            // Pushed left by a full window width; `sliver` points stay inside.
            return CGPoint(x: visibleFrameCG.minX - windowSize.width + sliver, y: y)
        case .bottomRight:
            // Top-left corner parks just inside the right edge; the rest is out.
            return CGPoint(x: visibleFrameCG.maxX - sliver, y: y)
        }
    }

    /// True when `pointCG` looks like somewhere we parked a window: within
    /// `tolerance` of `expectedCG`. Used by crash recovery to tell "AnyDrag
    /// hid this" apart from "the user left it there".
    static func isNear(_ pointCG: CGPoint, _ expectedCG: CGPoint, tolerance: CGFloat = 4) -> Bool {
        abs(pointCG.x - expectedCG.x) <= tolerance && abs(pointCG.y - expectedCG.y) <= tolerance
    }

    // MARK: - Animation suppression

    /// Run `body` with the app's `AXEnhancedUserInterface` forced off.
    ///
    /// That undocumented attribute is what makes macOS **animate** window
    /// frames changed through Accessibility. Leave it on and un-hiding a
    /// window plays a visible flight in from the parking corner, which is
    /// exactly the thing virtual workspaces are supposed to avoid — the whole
    /// point of this approach over native Spaces is that switching is instant.
    ///
    /// Toggling it off and back is the same trick yabai, Rectangle and
    /// AeroSpace all use (AeroSpace calls it `disableAnimations` and labels it
    /// "some undocumented magic"). AnyDrag already does this for linked
    /// resize — see `LinkedWindowResizeController.disableEnhancedUIForMembers`.
    ///
    /// The attribute is restored afterwards because it is a real accessibility
    /// feature: some apps enable it for assistive tooling and leaving it off
    /// would degrade that.
    static func withoutAnimation<T>(pid: pid_t, _ body: () -> T) -> T {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let wasEnabled = AXUIElementCopyAttributeValue(
            app, kEnhancedUserInterface as CFString, &value) == .success
            && (value as? NSNumber)?.boolValue == true
        WSDebug.log("axwrite", "pid=\(pid) AXEnhancedUserInterface was "
            + "\(wasEnabled ? "ON → suppressing animation" : "off → nothing to suppress"))")
        if wasEnabled {
            AXUIElementSetAttributeValue(app, kEnhancedUserInterface as CFString, kCFBooleanFalse)
        }
        defer {
            if wasEnabled {
                AXUIElementSetAttributeValue(app, kEnhancedUserInterface as CFString, kCFBooleanTrue)
            }
        }
        return body()
    }

    private static let kEnhancedUserInterface = "AXEnhancedUserInterface"

    // MARK: - Accessibility writes

    /// Park the window off-screen. Only the position is written — the size is
    /// left alone so `restore` can put it back byte-for-byte.
    ///
    /// Returns where it actually landed, or nil if the app refused to move
    /// (some apps clamp their own position). The caller persists the returned
    /// point so a crash-recovery pass can recognise the window later.
    /// What actually happened to a window we tried to park.
    ///
    /// Three outcomes, not two, and the third one is the point. "The read-back
    /// failed" and "the window did not move" are completely different
    /// situations: one means we do not know where the window is, the other
    /// means we know it is fine. Collapsing them into a single failure made the
    /// caller throw away the recovery record in both cases — including the case
    /// where the window had in fact been moved off-screen.
    enum ParkOutcome {
        /// Verified off-screen at this position.
        case parked(CGPoint)
        /// Verified still on screen and essentially where it started. Nothing
        /// happened; it is safe to forget about it.
        case unchanged
        /// Could not establish either. Treat as parked and KEEP the record —
        /// an unnecessary record costs nothing, a missing one costs a window.
        case indeterminate
    }

    static func hide(_ ax: AXUIElement,
                     pid: pid_t,
                     windowSize: CGSize,
                     visibleFrameCG: CGRect,
                     corner: HideCorner,
                     outerBoundsCG: CGRect? = nil) -> ParkOutcome {
        let before = position(of: ax)
        let target = hidePoint(windowSize: windowSize,
                               visibleFrameCG: outerBoundsCG ?? visibleFrameCG,
                               corner: corner)
        WSDebug.log("axwrite", "HIDE pid=\(pid) size=\(Int(windowSize.width))x\(Int(windowSize.height)) "
            + "against=\(WSDebug.rect(outerBoundsCG ?? visibleFrameCG))"
            + "\(outerBoundsCG != nil ? " [whole topology — this display is boxed in]" : "") "
            + "corner=\(corner.rawValue) → \(WSDebug.point(target))")
        withoutAnimation(pid: pid) { setPosition(ax, target) }

        guard let actual = position(of: ax) else {
            WSDebug.bail("axwrite", "HIDE pid=\(pid) — position read-back failed; "
                + "treating as parked so the recovery record is kept")
            return .indeterminate
        }

        // Judge the result by the question that actually matters — is the
        // window out of sight? — rather than by whether one coordinate matched.
        // macOS clamps Y on every park, so an exact-match test can only ever
        // report failure.
        let resulting = CGRect(origin: actual, size: windowSize)
        if !WSCoord.isReachable(resulting, minimumFraction: 0.02) {
            WSDebug.log("axwrite", "HIDE pid=\(pid) OK — now at \(WSDebug.point(actual)), off every display")
            return .parked(actual)
        }
        if let before, isNear(actual, before, tolerance: 4) {
            WSDebug.log("axwrite", "HIDE pid=\(pid) — app refused, window did not move; stays visible")
            return .unchanged
        }
        WSDebug.bail("axwrite", "HIDE pid=\(pid) — window moved to \(WSDebug.point(actual)) "
            + "but is still partly on screen; treating as parked so the record is kept")
        return .indeterminate
    }

    /// Put it back — position AND size.
    ///
    /// This is where AnyDrag differs from AeroSpace: AeroSpace only restores
    /// the position, because its tiling engine recomputes the size on the way
    /// back in. AnyDrag has no such engine behind it — whatever size the user
    /// dragged the window to is the size that has to come back.
    /// Returns false when the window is still sitting at (or very near) where
    /// it was parked after the write — i.e. the app refused to move.
    ///
    /// The AX setters give no useful error for a refused move, so the only
    /// honest check is to read the position back. Trusting the write and
    /// clearing the "hidden" flag on faith is how a window becomes
    /// unreachable: it stays off-screen while every record saying so is gone.
    @discardableResult
    static func restore(_ ax: AXUIElement, pid: pid_t, toCG frameCG: CGRect) -> Bool {
        WSDebug.log("axwrite", "RESTORE pid=\(pid) → \(WSDebug.rect(frameCG))")
        withoutAnimation(pid: pid) {
            // size -> position -> size, and the second size write is not
            // redundant. An app clamps its size against the display the window
            // is currently on, so the first write can be squeezed by the
            // parking corner's display; after the move it is on the right
            // display and the same value now goes through. AeroSpace arrived
            // at the same three-step order via its issues #143 and #335.
            setSize(ax, frameCG.size)
            setPosition(ax, frameCG.origin)
            setSize(ax, frameCG.size)

            // Re-assert the position if the app put the window somewhere else.
            //
            // This is what stops a window WALKING across the screen. The
            // restore is accepted within a loose tolerance, and the next park
            // records wherever the window actually ended up as its new home —
            // so a few points of clamping on each switch accumulate, and after
            // a handful of switches the window has visibly migrated. Writing
            // the position a second time removes the drift at the source
            // instead of letting it compound.
            if let landed = position(of: ax),
               abs(landed.x - frameCG.origin.x) > 2 || abs(landed.y - frameCG.origin.y) > 2 {
                WSDebug.log("axwrite", "RESTORE pid=\(pid) drifted to \(WSDebug.point(landed)), "
                    + "re-asserting \(WSDebug.point(frameCG.origin))")
                setPosition(ax, frameCG.origin)
            }
        }

        guard let actual = position(of: ax) else {
            WSDebug.bail("axwrite", "RESTORE pid=\(pid) — could not read the position back")
            return false
        }
        // Deliberately generous: an app that snaps to its own grid may land a
        // few points off, and that still counts as "back on screen". What we
        // are ruling out is the window not having moved at all.
        guard isNear(actual, frameCG.origin, tolerance: 40) else {
            WSDebug.bail("axwrite", "RESTORE pid=\(pid) refused: wanted "
                + "\(WSDebug.point(frameCG.origin)) but window is at \(WSDebug.point(actual))")
            log.warn("restore refused: wanted \(frameCG.origin) but window is at \(actual)")
            return false
        }
        WSDebug.log("axwrite", "RESTORE pid=\(pid) OK at \(WSDebug.point(actual))")
        return true
    }

    // MARK: - Raw AX

    static func position(of ax: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXPositionAttribute as CFString, &ref) == .success,
              let v = ref, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        AXValueGetValue(v as! AXValue, .cgPoint, &p)
        return p
    }

    static func size(of ax: AXUIElement) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXSizeAttribute as CFString, &ref) == .success,
              let v = ref, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        AXValueGetValue(v as! AXValue, .cgSize, &s)
        return s
    }

    static func frameCG(of ax: AXUIElement) -> CGRect? {
        guard let p = position(of: ax), let s = size(of: ax) else { return nil }
        return CGRect(origin: p, size: s)
    }

    private static func setPosition(_ ax: AXUIElement, _ p: CGPoint) {
        var m = p
        guard let v = AXValueCreate(.cgPoint, &m) else { return }
        AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, v)
    }

    private static func setSize(_ ax: AXUIElement, _ s: CGSize) {
        var m = s
        guard let v = AXValueCreate(.cgSize, &m) else { return }
        AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, v)
    }
}
