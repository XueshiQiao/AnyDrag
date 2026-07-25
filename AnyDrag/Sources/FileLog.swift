import Foundation

/// Thread-safe append-only file logger.
///
/// Writes to `~/Library/Logs/AnyDrag/AnyDrag.log`. Use one instance per
/// component (the `category` shows up in every line):
///
///     private static let log = FileLog("DragEngine")
///     Self.log.info("started up")
///     Self.log.error("failed: \(error)")
///
/// Tail live with: `tail -F ~/Library/Logs/AnyDrag/AnyDrag.log`
final class FileLog {

    private let category: String

    init(_ category: String = "App") {
        self.category = category
    }

    func debug(_ message: String) { write("DEBUG", message) }
    func info (_ message: String) { write("INFO",  message) }
    func warn (_ message: String) { write("WARN",  message) }
    func error(_ message: String) { write("ERROR", message) }

    /// The on-disk log path. Exposed for diagnostics / About pane "Reveal in Finder".
    static var url: URL { Self.logURL }

    // MARK: - Internals

    private static let queue = DispatchQueue(label: "me.xueshi.anydrag.filelog", qos: .utility)

    private static let logURL: URL = {
        let library = (try? FileManager.default.url(
            for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        let dir = library.appendingPathComponent("Logs/AnyDrag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("AnyDrag.log")
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Formats the whole line on the calling thread, then hands the finished
    /// bytes to the queue — only the file I/O is deferred.
    ///
    /// The message used to be an `@autoclosure` evaluated on the log queue,
    /// which made a line report whatever the state had become by the time the
    /// write ran, not what it was at the call. That is how
    /// `"tap disabled \(tapDisableCount)x"` printed `0x` while the branch that
    /// logged it only runs at a count of 3 — the counter had already been
    /// reset. The timestamp had the same problem: it recorded when the write
    /// happened rather than when the event did, so lines could also be
    /// stamped out of order relative to the events they describe.
    ///
    /// `timeFormatter` is only read (never mutated) after its initializer, and
    /// `DateFormatter` is documented as thread-safe for that, so formatting
    /// from arbitrary threads is fine.
    private func write(_ level: String, _ message: String) {
        let line = "[\(Self.timeFormatter.string(from: Date()))] [\(level)] [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        Self.queue.async {
            let url = Self.logURL
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
