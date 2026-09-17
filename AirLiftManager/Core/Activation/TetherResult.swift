import Foundation

/// TetherResult produced by Mac-side tooling (Requires Mac).
/// On-device code ONLY verifies this JSON; it never performs activation itself.
struct TetherResult: Codable, Equatable {
    var udid: String
    var iosBuild: String
    var timestamp: Date
    var sha256: String
    var cleanupConfirmed: Bool

    enum ValidationError: LocalizedError {
        case missingField(String)
        case cleanupNotConfirmed
        case badChecksum

        var errorDescription: String? {
            switch self {
            case .missingField(let f): return "VerificationFailed: missing field '\(f)'"
            case .cleanupNotConfirmed: return "VerificationFailed: cleanupConfirmed == false"
            case .badChecksum: return "VerificationFailed: sha256 empty/invalid"
            }
        }
    }

    func validate() throws {
        if udid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError.missingField("udid")
        }
        if iosBuild.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError.missingField("iosBuild")
        }
        if sha256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError.missingField("sha256")
        }
        if !cleanupConfirmed {
            throw ValidationError.cleanupNotConfirmed
        }
    }

    static func decode(from data: Data) throws -> TetherResult {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            let r = try dec.decode(TetherResult.self, from: data)
            try r.validate()
            return r
        } catch let e as ValidationError {
            throw e
        } catch {
            throw ValidationError.missingField("decode: \(error.localizedDescription)")
        }
    }
}
