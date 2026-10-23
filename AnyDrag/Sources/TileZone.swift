import AppKit

// MARK: - Tile Zone Model

/// A target region on the screen, selected by drag direction.
enum TileZone {
    case full          // drag up
    case centered      // drag down (`DragEngine.centeredSizePercent` of the visible frame)
    case left, right
    case topLeft, topRight, bottomLeft, bottomRight
    /// Not a shape: "put the window on THIS display at the same relative
    /// position and proportion". Only the multi-display bento produces it,
    /// from the center cell of a card that isn't the one the gesture started
    /// on — that cell is the cancel ring on the current display's card, and
    /// "send it here proportionally" on every other one. Both the position and
    /// size are scaled proportionally from the source screen's visible frame
    /// to the destination screen's visible frame and rounded to whole points.
    case moveToDisplay

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
    /// relative position and same relative size within `v` as `source.frame`
    /// occupies within `source.visible`, with all coordinates and dimensions
    /// (`x`, `y`, `width`, `height`) rounded to integer points.
    ///
    /// On two displays of the same usable size, the window lands at the exact
    /// same point offset and dimensions; across displays of different
    /// resolutions (e.g. 2560×1440 → 1920×1080), both its relative placement
    /// and its screen-area proportion are preserved, matching every other
    /// proportional tile zone in the grid.
    static func sameSpotRect(_ source: Source, in v: NSRect) -> NSRect {
        let sv = source.visible
        guard sv.width > 0, sv.height > 0, v.width > 0, v.height > 0 else {
            let w = min(source.frame.width, v.width).rounded()
            let h = min(source.frame.height, v.height).rounded()
            return NSRect(x: v.minX.rounded(), y: v.minY.rounded(), width: w, height: h)
        }

        let relX = (source.frame.minX - sv.minX) / sv.width
        let relY = (source.frame.minY - sv.minY) / sv.height
        let relW = source.frame.width / sv.width
        let relH = source.frame.height / sv.height

        let minX = v.minX.rounded()
        let minY = v.minY.rounded()
        let maxW = v.width.rounded()
        let maxH = v.height.rounded()

        let width = min(maxW, max(1, (relW * v.width).rounded()))
        let height = min(maxH, max(1, (relH * v.height).rounded()))

        let rawX = (v.minX + relX * v.width).rounded()
        let rawY = (v.minY + relY * v.height).rounded()

        let x = min(max(rawX, minX), minX + maxW - width)
        let y = min(max(rawY, minY), minY + maxH - height)

        return NSRect(x: x, y: y, width: width, height: height)
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
        }
    }
}

// MARK: - Window actions (the bento's action strip)

/// The close / minimize / full-screen strip under the current card's grid.
/// Unlike a `TileZone` these don't produce a rect: they act on the window
/// itself.
enum WindowAction: CaseIterable {
    case close
    case minimize
    /// The same native full-screen toggle as a window's own green button.
    /// Filling the display is already the top-middle cell.
    case fullScreen

    /// The strip's text. Only minimize is wide enough to show it.
    var label: String {
        switch self {
        case .close:      return NSLocalizedString("windowAction.close", comment: "")
        case .minimize:   return NSLocalizedString("windowAction.minimize", comment: "")
        case .fullScreen: return NSLocalizedString("windowAction.fullScreen", comment: "")
        }
    }

    var analyticsKey: String {
        switch self {
        case .close:      return "close"
        case .minimize:   return "minimize"
        case .fullScreen: return "full_screen"
        }
    }
}

/// What the cursor is over in the bento: a tile cell (rect on a display), or
/// one of the action-strip segments.
enum BentoHit: Equatable {
    case tile(screen: NSScreen, zone: TileZone)
    case action(WindowAction)
}
