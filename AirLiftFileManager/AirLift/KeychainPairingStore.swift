import Foundation
import Security

/// Non-secret metadata about the stored pairing record.
struct PairingMetadata: Equatable {
    let importedAt: Date?
    let presentKeyNames: [String]
    let isValid: Bool
}

/// Abstraction over pairing-record storage so the connection gate and
/// capability probe can be unit-tested without touching the Keychain.
protocol PairingStoring: Sendable {
    var hasRecord: Bool { get }
    func load() -> Data?
    @discardableResult func save(_ data: Data) -> Bool
    func delete()
    func metadata() -> PairingMetadata
    func importRecord(_ data: Data) -> PairingRecordService.ValidationResult
    func migrateLegacyFileIfNeeded()
}

/// Stores the imported lockdown pairing record in the Keychain
/// (kSecClassGenericPassword), not in plain files or defaults.
///
/// Security rules:
/// - The raw pairing data (host private key, certificates) never touches
///   UserDefaults, logs, or Documents after migration.
/// - Only non-secret metadata (import date, which key NAMES are present)
///   is persisted as defaults for the UI.
/// - Migration: a legacy Documents/pairing.plist (previous build) is imported
///   into the Keychain and the plain file is deleted.
struct KeychainPairingStore: PairingStoring {
    static let service = "com.bbaobaob.airliftfilemanager.pairing"
    static let account = "lockdown.pairing.record"
    static let metadataKey = "airlift.pairing.metadata"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Keychain

    @discardableResult
    func save(_ data: Data) -> Bool {
        SecItemDelete(query as CFDictionary)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            AppLogger.security.error("Keychain save failed: OSStatus \(status)")
            return false
        }
        AppLogger.security.info("Pairing record stored in Keychain (size \(data.count) bytes, contents never logged)")
        return true
    }

    func load() -> Data? {
        var result: AnyObject?
        // NOTE: kSecReturnData is mandatory — without it SecItemCopyMatching
        // returns errSecSuccess but gives nothing back (result stays nil).
        // That exact omission once made every load() return nil while save()
        // reported success, so pairing status was stuck at Not Imported.
        let status = SecItemCopyMatching(readQuery as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                AppLogger.security.error("Keychain read failed: OSStatus \(status)")
            }
            return nil
        }
        return result as? Data
    }

    func delete() {
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            AppLogger.security.info("Pairing record removed from Keychain")
        } else {
            AppLogger.security.error("Keychain delete failed: OSStatus \(status)")
        }
        defaults.removeObject(forKey: Self.metadataKey)
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    /// Read query: must request the data back explicitly.
    private var readQuery: [String: Any] {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return q
    }

    // MARK: - Metadata (non-secret)

    func metadata() -> PairingMetadata {
        guard let data = load() else {
            return PairingMetadata(importedAt: nil, presentKeyNames: [], isValid: false)
        }
        let validation = PairingRecordService.validate(data)
        let importedAt = defaults.object(forKey: Self.metadataKey) as? Date
        return PairingMetadata(importedAt: importedAt,
                               presentKeyNames: validation.presentKeys,
                               isValid: validation.isValid)
    }

    /// Import: validates first, stores in Keychain, records non-secret metadata.
    func importRecord(_ data: Data) -> PairingRecordService.ValidationResult {
        let validation = PairingRecordService.validate(data)
        guard validation.isValid else {
            AppLogger.security.warning("Pairing import rejected: missing \(validation.missingKeys.joined(separator: ","))")
            return validation
        }
        guard save(data) else {
            return PairingRecordService.ValidationResult(
                isValid: false, presentKeys: validation.presentKeys,
                missingKeys: validation.missingKeys,
                message: "Keychain write failed. Pairing record was not stored.",
                format: validation.format)
        }
        defaults.set(Date(), forKey: Self.metadataKey)
        return validation
    }

    /// Migrates the legacy plain-file record into the Keychain, then removes it.
    func migrateLegacyFileIfNeeded() {
        let legacyURL = PairingRecordService.storedURL
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        guard let data = try? Data(contentsOf: legacyURL) else {
            try? FileManager.default.removeItem(at: legacyURL)
            return
        }
        let validation = PairingRecordService.validate(data)
        if validation.isValid {
            let ok = save(data)
            AppLogger.security.info("Legacy pairing file migration to Keychain: \(ok ? "done" : "failed")")
        } else {
            AppLogger.security.warning("Legacy pairing file was invalid; deleted")
        }
        try? FileManager.default.removeItem(at: legacyURL)
    }

    var hasRecord: Bool { load() != nil }
}
