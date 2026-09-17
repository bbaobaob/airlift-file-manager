import Foundation
import Combine

/// Honest companion activation manager.
/// - Does NOT perform on-device exploit or activation.
/// - ONLY verifies TetherResult JSON (udid, iosBuild, timestamp, sha256, cleanupConfirmed).
/// - Missing/invalid fields -> .verificationFailed. No fake boolean success.
@MainActor
final class ActivationManager: ObservableObject {
    @Published private(set) var state: ActivationState = .notActivated
    @Published private(set) var lastResult: TetherResult?
    @Published private(set) var lastError: String?

    func markTetherRequired() {
        state = .tetherRequired
        lastError = nil
    }

    /// Verify TetherResult JSON data. Returns verified result or throws.
    @discardableResult
    func verify(data: Data) throws -> TetherResult {
        state = .verificationPending
        do {
            let result = try TetherResult.decode(from: data)
            lastResult = result
            lastError = nil
            state = .verifiedViaTether
            return result
        } catch {
            lastResult = nil
            lastError = error.localizedDescription
            state = .verificationFailed
            throw error
        }
    }

    func verify(fileURL: URL) throws -> TetherResult {
        let data = try Data(contentsOf: fileURL)
        return try verify(data: data)
    }

    func markUnsupported(reason: String) {
        state = .unsupported
        lastError = reason
    }

    func reset() {
        state = .notActivated
        lastResult = nil
        lastError = nil
    }
}
