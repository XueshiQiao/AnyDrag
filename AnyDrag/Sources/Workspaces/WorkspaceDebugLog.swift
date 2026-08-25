import AppKit

/// Verbose tracing for the virtual-workspace prototype.
///
/// While this feature is being evaluated, **every** window move and every
/// workspace switch has to be reconstructable from the log alone — including
/// the paths that decided to do nothing. A silent success and a silent bail
/// look identical afterwards, and that is exactly what made "this window
/// followed me across a switch" undiagnosable the first time round.
///
/// Rules this file exists to enforce:
///   * every guard logs WHY it bailed, never just returns
///   * every state change logs the before and the after value
///   * every multi-step operation carries a short run id, so one report of
///     "it went wrong on run 7f3a" is enough to find the whole sequence
///
/// **Temporary scaffolding.** Compiled out of Release entirely; before this
/// feature ships, the call sites go too.
enum WSDebug {

    private static let sink = FileLog("WSDebug")

    /// Off with `defaults write me.xueshi.anydrag.debug AnyDragWorkspaceTrace -bool false`.
    /// On by default while the feature is a prototype — during evaluation the
    /// cost of a missing line is far higher than the cost of a noisy log.
    static var enabled: Bool = {
        #if DEBUG
        (UserDefaults.standard.object(forKey: "AnyDragWorkspaceTrace") as? Bool) ?? true
        #else
        false
        #endif
    }()

    private static var counter: UInt32 = 0

    /// Short, human-quotable id tying one operation's lines together.
    static func newRun(_ kind: String) -> String {
        counter &+= 1
        return "\(kind)-\(String(format: "%04x", counter))"
    }

    static func log(_ run: String, _ message: @autoclosure () -> String) {
        guard enabled else { return }
        sink.debug("[\(run)] \(message())")
    }

    /// A guard that decided to do nothing. Logged at warn so bail-outs stand
    /// out from ordinary flow when scanning.
    static func bail(_ run: String, _ reason: @autoclosure () -> String) {
        guard enabled else { return }
        sink.warn("[\(run)] BAILED: \(reason())")
    }

    // MARK: - Formatting helpers

    static func rect(_ r: CGRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", r.origin.x, r.origin.y, r.width, r.height)
    }

    static func point(_ p: CGPoint) -> String {
        String(format: "(%.0f,%.0f)", p.x, p.y)
    }

    static func win(_ w: ManagedWindow) -> String {
        "\(w.appName)#\(w.windowID)"
    }

    static func ws(_ id: WorkspaceID) -> String {
        "\(id.display.uuid.prefix(8))/ws\(id.index)"
    }
}
