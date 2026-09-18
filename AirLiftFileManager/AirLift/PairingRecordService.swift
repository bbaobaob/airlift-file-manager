import Foundation

/// Imports and validates a StikPair-style on-device pairing file.
///
/// StikPair (iOS 27 Developer Mode "Pair with <app>") exports the pairing
/// record from the device itself. Two formats are accepted, each validated
/// strictly (key presence AND value type/length) — validation is never
/// skipped just to make an import succeed:
///
/// 1. `lockdown` — classic lockdown pairing record with PEM material:
///    `HostPrivateKey`, `HostCertificate`, `DeviceCertificate`.
/// 2. `remote-pairing` — StikPair wireless (RemotePairing) record, as
///    observed on-device: `public_key` + `private_key` (32-byte raw keys),
///    `identifier` (UUID string), optional `alt_irk` (16 bytes when present).
///
/// Storage lives in `KeychainPairingStore` (kSecClassGenericPassword) —
/// pairing secrets are never written to plain files or defaults, and no
/// message below ever includes key material (key NAMES only).
struct PairingRecordService {
    enum PairingFormat: String {
        case lockdown
        case remotePairing = "remote-pairing"
    }

    struct ValidationResult: Equatable {
        let isValid: Bool
        let presentKeys: [String]
        let missingKeys: [String]
        let message: String
        /// nil = the data is not a recognized pairing record at all.
        let format: PairingFormat?
    }

    /// Keys a usable classic lockdown pairing record must carry.
    static let requiredKeys = ["HostPrivateKey", "HostCertificate", "DeviceCertificate"]

    /// Core keys of a StikPair remote-pairing record.
    static let remotePairingKeys = ["public_key", "private_key", "identifier"]

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
            return ValidationResult(isValid: false, presentKeys: [], missingKeys: [],
                                    message: "Not a valid plist pairing record.",
                                    format: nil)
        }
        let remoteHit = remotePairingKeys.contains { dict[$0] != nil }
        let lockdownHit = requiredKeys.contains { dict[$0] != nil }
        switch (remoteHit, lockdownHit) {
        case (true, false):
            return validateRemotePairing(dict)
        case (false, true):
            return validateLockdown(dict)
        case (true, true):
            // Ambiguous hybrid: the lockdown set is the stricter contract.
            return validateLockdown(dict)
        case (false, false):
            return ValidationResult(
                isValid: false, presentKeys: [], missingKeys: [],
                message: "Not a recognized pairing record (neither lockdown nor " +
                    "StikPair remote-pairing format).",
                format: nil)
        }
    }

    // MARK: - Classic lockdown format

    private static func validateLockdown(_ dict: [String: Any]) -> ValidationResult {
        let present = requiredKeys.filter { dict[$0] != nil }
        let missing = requiredKeys.filter { dict[$0] == nil }
        if missing.isEmpty {
            return ValidationResult(
                isValid: true, presentKeys: present, missingKeys: [],
                message: "Valid lockdown pairing record. Trusted lockdown services " +
                    "can use this record.",
                format: .lockdown)
        }
        return ValidationResult(
            isValid: false, presentKeys: present, missingKeys: missing,
            message: "Pairing record is missing: \(missing.joined(separator: ", ")).",
            format: .lockdown)
    }

    // MARK: - StikPair remote-pairing format

    private static func validateRemotePairing(_ dict: [String: Any]) -> ValidationResult {
        // Fixed order keeps present/missing deterministic.
        let publicOK = (dict["public_key"] as? Data)?.count == 32
        let privateOK = (dict["private_key"] as? Data)?.count == 32
        let identifierOK: Bool = {
            guard let raw = dict["identifier"] as? String else { return false }
            return UUID(uuidString: raw) != nil
        }()
        let checks: [(String, Bool)] = [
            ("public_key", publicOK),
            ("private_key", privateOK),
            ("identifier", identifierOK),
        ]
        var present = checks.filter(\.1).map(\.0)
        var missing = checks.filter { !$0.1 }.map(\.0)

        // alt_irk is optional; when present it must be a 16-byte blob.
        if let irk = dict["alt_irk"] {
            if let bytes = irk as? Data, bytes.count == 16 {
                present.append("alt_irk")
            } else {
                missing.append("alt_irk")
            }
        }

        if missing.isEmpty {
            return ValidationResult(
                isValid: true, presentKeys: present, missingKeys: [],
                message: "Valid StikPair remote-pairing record (wireless pairing " +
                    "credential). Keys present: \(present.joined(separator: ", ")).",
                format: .remotePairing)
        }
        return ValidationResult(
            isValid: false, presentKeys: present, missingKeys: missing,
            message: "Remote-pairing record is invalid or incomplete " +
                "(expected: 32-byte public_key, 32-byte private_key, UUID identifier" +
                "\(dict["alt_irk"] != nil ? ", 16-byte alt_irk" : "")" +
                "; problem: \(missing.joined(separator: ", "))).",
            format: .remotePairing)
    }
}
