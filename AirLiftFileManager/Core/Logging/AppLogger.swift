import Foundation
import os

/// Central logging service shared by every screen (no per-screen logging).
/// - Ring buffer with bounded memory (maxEntries).
/// - Every message passes through Redactor before storage and os_log.
/// - Filtering and export are pure functions (unit-tested).
/// - Posts .appLogDidAppend so views can follow logs in real time.
final class AppLogger: @unchecked Sendable {
    enum Category: String, CaseIterable {
        case app, airlift, vpn, files, fs, perm, net, pairing, security

        var osCategory: String { rawValue }
        /// Human title shown in the log viewer.
        var title: String {
            switch self {
            case .app: return "App"
            case .airlift: return "AirLift"
            case .vpn: return "VPN"
            case .files: return "Files"
            case .fs: return "Filesystem"
            case .perm: return "Permissions"
            case .net: return "Network"
            case .pairing: return "Pairing"
            case .security: return "Security"
            }
        }
    }

    struct Entry: Identifiable, Equatable {
        let id: UUID
        let date: Date
        let category: Category
        let level: Level
        let event: String?
        let message: String

        init(date: Date = Date(), category: Category, level: Level,
             event: String? = nil, message: String) {
            self.id = UUID()
            self.date = date
            self.category = category
            self.level = level
            self.event = event
            self.message = Redactor.redact(message)
        }

        enum Level: String, CaseIterable {
            case debug, info, warning, error

            var title: String {
                switch self {
                case .debug: return "Debug"
                case .info: return "Info"
                case .warning: return "Warning"
                case .error: return "Error"
                }
            }
        }
    }

    static let shared = AppLogger()

    static let appLogDidAppend = Notification.Name("com.bbaobaob.airliftfilemanager.logDidAppend")

    static let maxEntries = 2000

    private let lock = NSLock()
    private var buffer: [Entry] = []
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
    static let pairing = LoggerBridge(category: .pairing)
    static let security = LoggerBridge(category: .security)

    func record(_ level: Entry.Level, _ category: Category,
                _ message: String, event: String? = nil) {
        let entry = Entry(date: Date(), category: category, level: level,
                          event: event, message: message)
        lock.lock()
        buffer.append(entry)
        if buffer.count > Self.maxEntries {
            buffer.removeFirst(buffer.count - Self.maxEntries)
        }
        lock.unlock()
        let logger = osLoggers[category] ?? Logger(subsystem: "com.bbaobaob.airliftfilemanager",
                                                   category: category.rawValue)
        switch level {
        case .debug: logger.debug("\(entry.message, privacy: .public)")
        case .info: logger.info("\(entry.message, privacy: .public)")
        case .warning: logger.warning("\(entry.message, privacy: .public)")
        case .error: logger.error("\(entry.message, privacy: .public)")
        }
        NotificationCenter.default.post(name: Self.appLogDidAppend, object: nil)
    }

    func recentEntries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
    }

    // MARK: - Pure filtering (unit-tested)

    static func filter(entries: [Entry],
                       searchText: String,
                       levels: Set<Entry.Level> = [],
                       categories: Set<Category> = []) -> [Entry] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            if !levels.isEmpty && !levels.contains(entry.level) { return false }
            if !categories.isEmpty && !categories.contains(entry.category) { return false }
            if !trimmed.isEmpty {
                let haystack = "\(entry.message) \(entry.category.rawValue) \(entry.event ?? "")"
                if !haystack.localizedCaseInsensitiveContains(trimmed) { return false }
            }
            return true
        }
    }

    // MARK: - Pure export (unit-tested)

    static func exportTXT(_ entries: [Entry]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines: [String] = []
        lines.append("# AirLift File Manager log export")
        lines.append("# Entries: \(entries.count)")
        lines.append("# Sensitive values are redacted at record time ([REDACTED]).")
        for entry in entries {
            var line = "\(formatter.string(from: entry.date)) [\(entry.level.rawValue.uppercased())]"
            line += " [\(entry.category.rawValue)]"
            if let event = entry.event {
                line += " (\(event))"
            }
            line += " \(entry.message)"
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    struct ExportedEntry: Codable {
        let timestamp: Date
        let category: String
        let level: String
        let event: String?
        let message: String
    }

    static func exportJSON(_ entries: [Entry]) -> Data? {
        let exported = entries.map {
            ExportedEntry(timestamp: $0.date, category: $0.category.rawValue,
                          level: $0.level.rawValue, event: $0.event, message: $0.message)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(exported)
    }

    /// Facade exposing familiar Swift log call sites.
    struct LoggerBridge {
        let category: Category

        func debug(_ message: String, event: String? = nil) {
            AppLogger.shared.record(.debug, category, message, event: event)
        }

        func info(_ message: String, event: String? = nil) {
            AppLogger.shared.record(.info, category, message, event: event)
        }

        func warning(_ message: String, event: String? = nil) {
            AppLogger.shared.record(.warning, category, message, event: event)
        }

        func error(_ message: String, event: String? = nil) {
            AppLogger.shared.record(.error, category, message, event: event)
        }
    }
}

/// Redacts sensitive material at record time. Applied to every entry before
/// storage, os_log, and export.
enum Redactor {
    static func redact(_ message: String) -> String {
        var output = message
        // PEM blocks never survive logging.
        if let regex = try? NSRegularExpression(pattern: "-----BEGIN[ A-Z]*-----[\\s\\S]*?-----END[ A-Z]*-----") {
            output = regex.stringByReplacingMatches(
                in: output, range: NSRange(output.startIndex..., in: output),
                withTemplate: "[REDACTED:KEY-MATERIAL]")
        }
        // Long base64/hex runs (keys, tokens, certificate blobs).
        if let regex = try? NSRegularExpression(pattern: "[A-Za-z0-9+/=]{48,}") {
            output = regex.stringByReplacingMatches(
                in: output, range: NSRange(output.startIndex..., in: output),
                withTemplate: "[REDACTED]")
        }
        return output
    }
}
