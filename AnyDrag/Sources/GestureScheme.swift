import Foundation

/// How the **move** gesture is triggered with the main modifier. Resize
/// (modifier + right-drag), maximize (double-click), and tiling (right-click) are
/// unchanged in both.
///
/// - `.classic`: modifier + **left-drag** moves the window (the long-standing
///   default).
/// - `.pointerMove`: modifier + **pointer move, no button** moves the window under
///   the cursor; modifier + left-drag is left to the app.
///
/// The two are mutually exclusive (both would claim modifier + left-drag), so the
/// user picks one in Settings.
enum GestureScheme: String, CaseIterable {
    case classic
    case pointerMove
}
