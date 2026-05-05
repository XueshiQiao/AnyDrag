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

    func debug(_ message: @autoclosure @escaping () -> String) { write("DEBUG", message) }
    func info (_ message: @autoclosure @escaping () -> String) { write("INFO",  message) }
    func warn (_ message: @autoclosure @escaping () -> String) { write("WARN",  message) }
    func error(_ message: @autoclosure @escaping () -> String) { write("ERROR", message) }

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

    private func write(_ level: String, _ messageProducer: @escaping () -> String) {
        let cat = category
        Self.queue.async {
            let line = "[\(Self.timeFormatter.string(from: Date()))] [\(level)] [\(cat)] \(messageProducer())\n"
            guard let data = line.data(using: .utf8) else { return }
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
