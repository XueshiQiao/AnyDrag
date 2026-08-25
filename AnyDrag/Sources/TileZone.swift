import AppKit

// MARK: - Tile Zone Model

/// A target region on the screen, selected by drag direction.
enum TileZone {
    case full          // drag up
    case centered      // drag down (`DragEngine.centeredSizePercent` of the visible frame)
    case left, right
    case topLeft, topRight, bottomLeft, bottomRight
    /// Not a shape: "put the window on THIS display exactly as it is". Only
    /// the multi-display bento produces it, from the center cell of a card
    /// that isn't the one the gesture started on — that cell is the cancel
    /// ring on the current display's card, and "send it here untouched" on
    /// every other one. The size is preserved verbatim; the position is the
    /// same relative spot on the destination screen.
    case moveToDisplay
    /// Not a placement at all: "take me to this workspace, leave the window
    /// where it is". Produced by the jump frame around a workspace card —
    /// the ring of padding plus the title row. Deliberately means the same
    /// thing whether or not a window is being dragged, so the frame has one
    /// meaning the user can learn once.
    case jump

    /// The window a tile gesture is acting on. `.moveToDisplay` is the only
    /// zone whose target rect depends on where the window ALREADY is, so that
    /// geometry is threaded through separately instead of being smuggled into
    /// the zone itself.
    struct Source {
        /// The window's current frame, NSScreen coords (bottom-left origin).
        let frame: NSRect
        /// Visible frame of the screen the window is currently on, same coords.
        let visible: NSRect
    }

    /// Map a cursor offset (in CG coords, Y-down) relative to the bento
    /// overlay's center to a tile zone via 3×3 cell hit-testing. Returns
    /// nil when the cursor is inside the center deadzone (cancel cell).
    ///
    /// Cell boundaries align with the visible gaps in `TileCancelDot`'s
    /// 3×3 grid — keep the half-deadzone constants in sync with the
    /// drawn cell geometry so "cursor crossing the visible gap" matches
    /// "cursor commits to the adjacent tile".
    ///
    /// This is the SINGLE-display path only, so `.moveToDisplay` is not
    /// reachable here: there is no other card to send the window to.
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

    /// The centered-window rect for a visible frame, at `fraction` of its width
    /// and height. THE one place that turns the user's centered-size preference
    /// into a frame — both centered entry points (the middle-drag-down gesture
    /// and the tiling panel's Center button) come through here.
    ///
    /// Centering is symmetric, so this is correct in either coordinate space:
    /// pass an NS visible frame (bottom-left origin) or a CG one (top-left) and
    /// the result comes back in the same space.
    static func centeredRect(in visible: CGRect, fraction: CGFloat) -> CGRect {
        let w = visible.width * fraction
        let h = visible.height * fraction
        return CGRect(x: visible.minX + (visible.width - w) / 2,
                      y: visible.minY + (visible.height - h) / 2,
                      width: w, height: h)
    }

    /// Where `source` lands on the screen whose visible frame is `v`: same
    /// size, same spot. "Same spot" is the window's offset from the visible
    /// frame's TOP-LEFT corner — the corner a person reads a window's position
    /// from — carried over verbatim. On two displays of the same usable size
    /// that is pixel-for-pixel the same position; where the usable areas
    /// differ (one display carries the menu bar) the window keeps the same gap
    /// to the top-left rather than the same percentage across, which is the
    /// literal reading of "just change which screen it's on".
    ///
    /// The result is clamped so the window can't hang off the destination. A
    /// window too big for the destination is pinned to the top-left corner
    /// rather than resized: the size is the one thing this zone promises to
    /// leave alone.
    static func sameSpotRect(_ source: Source, in v: NSRect) -> NSRect {
        let sv = source.visible
        let size = source.frame.size
        // NS coords put y at the BOTTOM, so the offset from the top is
        // measured against maxY on both sides.
        var x = v.minX + (source.frame.minX - sv.minX)
        var y = v.maxY - (sv.maxY - source.frame.maxY) - size.height
        x = size.width  <= v.width  ? min(max(x, v.minX), v.maxX - size.width) : v.minX
        y = size.height <= v.height ? min(max(y, v.minY), v.maxY - size.height) : v.maxY - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Compute the target rect within the screen's visible NSScreen-coord frame
    /// (bottom-left origin).
    ///
    /// `centeredFraction` deliberately has NO default value: it is the user's
    /// setting, and every call site must pass `DragEngine.centeredFraction` so
    /// the commit and its live preview can never disagree. Adding a default
    /// back would let a call site silently fall out of sync again.
    ///
    /// `source` is likewise required rather than optional — only
    /// `.moveToDisplay` reads it, but making it mandatory means that zone can
    /// never be evaluated without the geometry it needs.
    func rect(in v: NSRect, centeredFraction: CGFloat, source: Source) -> NSRect {
        switch self {
        case .full:
            return v
        case .centered:
            return Self.centeredRect(in: v, fraction: centeredFraction)
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
        case .moveToDisplay:
            return Self.sameSpotRect(source, in: v)
        case .jump:
            // The window does not move. Returning its current frame keeps
            // every caller's arithmetic valid without a special case.
            return source.frame
        }
    }
}
