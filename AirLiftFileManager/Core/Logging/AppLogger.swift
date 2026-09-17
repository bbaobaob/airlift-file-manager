import Foundation
import os

/// Structured logging with an in-memory ring buffer surfaced in the Debug Logs screen.
/// Never log user file contents; log relative paths only.
final class AppLogger: @unchecked Sendable {
    enum Category: String, CaseIterable {
        case app, airlift, vpn, files, fs, perm, net

        var osCategory: String { rawValue }
    }

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let category: Category
        let level: Level
        let message: String

        enum Level: String {
            case debug, info, error
        }
    }

    static let shared = AppLogger()

    private let lock = NSLock()
    private var buffer: [Entry] = []
    private let capacity = 500
    private var osLoggers: [Category: Logger] = [:]

    private init() {
        for category in Category.allCases {
            osLoggers[category] = Logger(subsystem: "com.bbaobaob.airliftfilemanager",
                                         category: category.osCategory)
        }
    }

    static let app = LoggerBridge(category: .app)
    static let airLift = LoggerBridge(category: .airlift)
    static let vpn = LoggerBridge(category: .vpn)
    static let files = LoggerBridge(category: .files)
    static let fs = LoggerBridge(category: .fs)
    static let perm = LoggerBridge(category: .perm)
    static let net = LoggerBridge(category: .net)

    func record(_ level: Entry.Level, _ category: Category, _ message: String) {
        let entry = Entry(date: Date(), category: category, level: level, message: message)
        lock.lock()
        buffer.append(entry)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        lock.unlock()
        let logger = osLoggers[category] ?? Logger(subsystem: "com.bbaobaob.airliftfilemanager",
                                                   category: category.rawValue)
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }

    func recentEntries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
    }

    /// Facade exposing familiar Swift log call sites.
    struct LoggerBridge {
        let category: Category

        func debug(_ message: String) {
            AppLogger.shared.record(.debug, category, message)
        }

        func info(_ message: String) {
            AppLogger.shared.record(.info, category, message)
        }

        func error(_ message: String) {
            AppLogger.shared.record(.error, category, message)
        }
    }
}
