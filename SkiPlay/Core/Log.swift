import Foundation
import os

/// Keeps the last few hundred log lines so they can be shown when something goes wrong.
final class Log: ObservableObject {
    static let shared = Log()
    private let logger = Logger(subsystem: "com.skistudio.play", category: "chiaki")
    private let queue = DispatchQueue(label: "log")
    private var lines: [String] = []

    func add(_ line: String, level: Int = 4) {
        logger.log("\(line, privacy: .public)")
        let stamp = Self.formatter.string(from: Date())
        queue.async {
            self.lines.append("\(stamp) \(line)")
            if self.lines.count > 400 { self.lines.removeFirst(self.lines.count - 400) }
        }
    }

    var text: String { queue.sync { lines.joined(separator: "\n") } }

    func recentErrors(_ count: Int = 6) -> String {
        queue.sync {
            lines.filter { $0.contains("[E]") || $0.contains("[W]") }.suffix(count).joined(separator: "\n")
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

enum Chiaki {
    private static var initialized = false

    static func start() {
        guard !initialized else { return }
        initialized = true
        let err = sp_init({ level, msg, _ in
            guard let msg else { return }
            let tag: String
            switch level {
            case 1: tag = "[E]"
            case 2: tag = "[W]"
            case 4: tag = "[I]"
            default: tag = "[D]"
            }
            Log.shared.add("\(tag) \(String(cString: msg))", level: Int(level))
        }, nil)
        Log.shared.add("Remote Play library ready (\(errorString(err)))")
    }

    static func errorString(_ code: Int32) -> String {
        guard let s = sp_error_string(code) else { return "error \(code)" }
        return String(cString: s)
    }
}
