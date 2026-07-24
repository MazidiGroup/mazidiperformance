import Foundation

/// Minimal logging façade so MazidiKit never binds to os.Logger (Apple-only).
/// The app installs an os.Logger-backed sink; tests install a capturing sink.
public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0, info = 1, warning = 2, error = 3

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public protocol LogSink: Sendable {
    func log(_ level: LogLevel, _ message: String, category: String)
}

public struct PrintLogSink: LogSink {
    public init() {}
    public func log(_ level: LogLevel, _ message: String, category: String) {
        print("[\(level)] [\(category)] \(message)")
    }
}

public struct AppLog: Sendable {
    public let category: String
    private let sink: LogSink

    public init(category: String, sink: LogSink = PrintLogSink()) {
        self.category = category
        self.sink = sink
    }

    public func debug(_ message: String) { sink.log(.debug, message, category: category) }
    public func info(_ message: String) { sink.log(.info, message, category: category) }
    public func warning(_ message: String) { sink.log(.warning, message, category: category) }
    public func error(_ message: String) { sink.log(.error, message, category: category) }
}
