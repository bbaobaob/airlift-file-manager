import Foundation
import OSLog

enum AppLog {
    static let activation = OSLog(subsystem: "com.example.airliftmanager", category: "activation")
    static let files = OSLog(subsystem: "com.example.airliftmanager", category: "files")

    static func info(_ msg: String, log: OSLog = activation) {
        os_log("%{public}@", log: log, type: .info, msg)
    }
    static func error(_ msg: String, log: OSLog = activation) {
        os_log("%{public}@", log: log, type: .error, msg)
    }
}
