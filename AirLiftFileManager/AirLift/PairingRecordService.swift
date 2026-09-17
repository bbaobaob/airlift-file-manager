import Foundation

/// Imports and validates a StikPair-style on-device pairing file.
///
/// StikPair (iOS 27 Developer Mode "Pair with <app>") exports a lockdown
/// pairing record from the device itself. This service imports the exported
/// plist, validates the keys needed for trusted lockdown sessions, and stores
/// it in the app container for later authenticated service requests
/// (StartService: com.apple.afc and friends).
struct PairingRecordService {
    struct ValidationResult: Equatable {
        let isValid: Bool
        let presentKeys: [String]
        let missingKeys: [String]
        let message: String
    }

    /// Keys a usable lockdown pairing record must carry.
    static let requiredKeys = ["HostPrivateKey", "HostCertificate", "DeviceCertificate"]

    static var storedURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairing.plist")
    }

    static func hasStoredPairing() -> Bool {
        FileManager.default.fileExists(atPath: storedURL.path)
    }

    /// Validates raw plist data without touching the keychain.
    static func validate(_ data: Data) -> ValidationResult {
        guard let dict = (try? PropertyListSerialization.propertyList(
            from: data, format: nil)) as? [String: Any] else {
            return ValidationResult(isValid: false, presentKeys: [], missingKeys: requiredKeys,
                                    message: "Not a valid plist pairing record.")
        }
        let present = requiredKeys.filter { dict[$0] != nil }
        let missing = requiredKeys.filter { dict[$0] == nil }
        if missing.isEmpty {
            return ValidationResult(
                isValid: true, presentKeys: present, missingKeys: [],
                message: "Valid pairing record. Trusted lockdown services can use this record.")
        }
        return ValidationResult(
            isValid: false, presentKeys: present, missingKeys: missing,
            message: "Pairing record is missing: \(missing.joined(separator: ", ")).")
    }

    static func importPairing(data: Data) throws -> ValidationResult {
        let result = validate(data)
        guard result.isValid else { return result }
        try data.write(to: storedURL, options: .atomic)
        AppLogger.airLift.info("Pairing record imported (\(result.presentKeys.count) keys)")
        return result
    }

    static func removePairing() {
        try? FileManager.default.removeItem(at: storedURL)
        AppLogger.airLift.info("Pairing record removed")
    }
}
