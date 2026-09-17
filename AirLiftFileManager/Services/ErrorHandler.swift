import Foundation

/// Central error presentation. Turns typed errors into user-facing messages
/// and logs every failure once, in one place.
enum ErrorHandler {
    static func userMessage(for error: Error) -> String {
        if let fsError = error as? FileSystemError {
            return fsError.localizedDescription
        }
        if let zipError = error as? ZipArchive.ZipError {
            return zipError.localizedDescription
        }
        return error.localizedDescription
    }

    static func handle(_ error: Error,
                       context: String,
                       logger: AppLogger.LoggerBridge = AppLogger.fs) {
        logger.error("\(context): \(userMessage(for: error))")
    }

    static func present(_ error: Error, context: String) -> String {
        handle(error, context: context)
        return userMessage(for: error)
    }
}
