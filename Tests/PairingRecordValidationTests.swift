import XCTest
import Security
@testable import AirLiftFileManager

/// Validation tests for both accepted pairing formats. All fixtures are
/// SYNTHETIC (random bytes, same key names / lengths as the real formats) —
/// no real key material ever appears in tests, logs, or the repo.
final class PairingRecordValidationTests: XCTestCase {
    // MARK: - Fixture builders (synthetic only)

    private func remotePairingPlist(publicLen: Int = 32,
                                    privateLen: Int = 32,
                                    identifier: String? = UUID().uuidString,
                                    includeAltIrk: Bool = true,
                                    altIrkLen: Int = 16) -> Data {
        var dict: [String: Any] = [
            "public_key": Data(repeating: 0xA5, count: publicLen),
            "private_key": Data(repeating: 0x5A, count: privateLen),
        ]
        if let identifier { dict["identifier"] = identifier }
        if includeAltIrk { dict["alt_irk"] = Data(repeating: 0x1F, count: altIrkLen) }
        return (try? PropertyListSerialization.data(fromPropertyList: dict,
                                                    format: .xml, options: 0)) ?? Data()
    }

    private func lockdownPlist(keys: [String] = PairingRecordService.requiredKeys) -> Data {
        var dict: [String: Any] = [:]
        for key in keys { dict[key] = "synthetic-pem-placeholder" }
        return (try? PropertyListSerialization.data(fromPropertyList: dict,
                                                    format: .xml, options: 0)) ?? Data()
    }

    // MARK: - Remote-pairing format (StikPair on-device export)

    func testValidRemotePairingRecordAccepted() {
        let result = PairingRecordService.validate(remotePairingPlist())
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.format, .remotePairing)
        XCTAssertEqual(result.missingKeys, [])
        XCTAssertTrue(result.message.contains("remote-pairing"))
    }

    func testRemotePairingWithoutAltIrkStillAccepted() {
        let result = PairingRecordService.validate(remotePairingPlist(includeAltIrk: false))
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.format, .remotePairing)
    }

    func testRemotePairingRejectsWrongKeyLengths() {
        let short = PairingRecordService.validate(remotePairingPlist(publicLen: 16))
        XCTAssertFalse(short.isValid)
        XCTAssertEqual(short.format, .remotePairing)
        XCTAssertTrue(short.missingKeys.contains("public_key"))

        let badIrk = PairingRecordService.validate(remotePairingPlist(altIrkLen: 8))
        XCTAssertFalse(badIrk.isValid)
        XCTAssertTrue(badIrk.missingKeys.contains("alt_irk"))
    }

    func testRemotePairingRejectsNonUUIDIdentifier() {
        let badId = PairingRecordService.validate(remotePairingPlist(identifier: "not-a-uuid"))
        XCTAssertFalse(badId.isValid)
        XCTAssertTrue(badId.missingKeys.contains("identifier"))

        let missingId = PairingRecordService.validate(remotePairingPlist(identifier: nil))
        XCTAssertFalse(missingId.isValid)
        XCTAssertTrue(missingId.missingKeys.contains("identifier"))
    }

    // MARK: - Classic lockdown format (unchanged behavior)

    func testValidLockdownRecordStillAccepted() {
        let result = PairingRecordService.validate(lockdownPlist())
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.format, .lockdown)
    }

    func testIncompleteLockdownRecordRejected() {
        let result = PairingRecordService.validate(lockdownPlist(keys: ["HostPrivateKey"]))
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.format, .lockdown)
        XCTAssertTrue(result.missingKeys.contains("HostCertificate"))
        XCTAssertTrue(result.missingKeys.contains("DeviceCertificate"))
    }

    // MARK: - Unrecognized data

    func testNonPlistIsUnsupported() {
        let result = PairingRecordService.validate(Data("hello".utf8))
        XCTAssertFalse(result.isValid)
        XCTAssertNil(result.format)
    }

    func testPlistWithoutPairingKeysIsUnsupported() {
        let dict = ["foo": "bar", "count": 3] as [String: Any]
        let data = (try? PropertyListSerialization.data(fromPropertyList: dict,
                                                        format: .xml, options: 0)) ?? Data()
        let result = PairingRecordService.validate(data)
        XCTAssertFalse(result.isValid)
        XCTAssertNil(result.format)
    }

    // MARK: - End-to-end: validate → Keychain store → metadata → guard status

    func testRemotePairingEndToEndImportFlow() async {
        let store = InMemoryPairingStore()
        let data = remotePairingPlist()
        let importResult = store.importRecord(data)
        XCTAssertTrue(importResult.isValid, "synthetic remote-pairing record must import")

        let metadata = store.metadata()
        XCTAssertTrue(metadata.isValid)
        XCTAssertTrue(metadata.presentKeyNames.contains("public_key"))
        XCTAssertTrue(metadata.presentKeyNames.contains("private_key"))
        XCTAssertTrue(metadata.presentKeyNames.contains("identifier"))
    }

    @MainActor
    func testGuardClassifiesRemotePairingAsImported() async {
        let store = InMemoryPairingStore()
        store.save(remotePairingPlist())
        let guardVM = AirLiftLaunchGuard(pairingStore: store)
        await guardVM.recheckConnection()
        // VPN is down in the simulator, so the gate stops there — but the
        // pairing classification itself must be Imported, not Invalid.
        XCTAssertEqual(guardVM.pairingStatus, .imported)
        XCTAssertTrue(guardVM.lastFailureReason?.contains("LocalDevVPN") == true,
                      "with a valid pairing, the blocker must be the VPN gate, not pairing")
    }
}

/// Regression tests against the REAL Keychain store (the simulator has a
/// working Keychain). The Not-Imported-after-valid-import bug was caused by
/// load() omitting kSecReturnData — the InMemory double could never catch
/// it, so the real store is exercised here with synthetic data only.
///
/// NOTE: these run only where Keychain Services is available. CI builds the
/// test host with CODE_SIGNING_ALLOWED=NO (unsigned), and unsigned processes
/// cannot use the Keychain — the tests skip there with a logged OSStatus and
/// run for real on signed hosts (local Xcode runs, real devices).
final class KeychainPairingStoreTests: XCTestCase {
    private func makeStore() -> KeychainPairingStore {
        let suite = "test-keychain-\(UUID().uuidString)"
        return KeychainPairingStore(
            defaults: UserDefaults(suiteName: suite) ?? .standard)
    }

    private func keychainAvailable() -> Bool {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.bbaobaob.airliftfilemanager.probe",
            kSecAttrAccount as String: "probe-\(UUID().uuidString)",
            kSecValueData as String: Data([0x01]),
        ]
        let status = SecItemAdd(probe as CFDictionary, nil)
        SecItemDelete(probe as CFDictionary)
        if status != errSecSuccess {
            print("KEYCHAIN UNAVAILABLE IN TEST HOST (OSStatus \(status)) — skipping Keychain tests")
        }
        return status == errSecSuccess
    }

    func testSaveThenLoadRoundTrips() throws {
        try XCTSkipUnless(keychainAvailable(), "Keychain unavailable in this (unsigned) test host")
        let store = makeStore()
        defer { store.delete() }
        let payload = Data((0..<64).map { _ in UInt8.random(in: 0...255) })

        XCTAssertTrue(store.save(payload))
        XCTAssertEqual(store.load(), payload)
        XCTAssertTrue(store.hasRecord)
    }

    func testLoadReturnsNilWhenEmpty() throws {
        try XCTSkipUnless(keychainAvailable(), "Keychain unavailable in this (unsigned) test host")
        let store = makeStore()
        defer { store.delete() }
        XCTAssertNil(store.load())
        XCTAssertFalse(store.hasRecord)
    }

    func testDeleteRemovesRecord() throws {
        try XCTSkipUnless(keychainAvailable(), "Keychain unavailable in this (unsigned) test host")
        let store = makeStore()
        XCTAssertTrue(store.save(Data("synthetic".utf8)))
        XCTAssertTrue(store.hasRecord)
        store.delete()
        XCTAssertFalse(store.hasRecord)
        XCTAssertNil(store.load())
    }

    func testRemotePairingSurvivesKeychainRoundTrip() throws {
        try XCTSkipUnless(keychainAvailable(), "Keychain unavailable in this (unsigned) test host")
        let store = makeStore()
        defer { store.delete() }
        var dict: [String: Any] = [
            "public_key": Data(repeating: 0xA5, count: 32),
            "private_key": Data(repeating: 0x5A, count: 32),
            "identifier": UUID().uuidString,
            "alt_irk": Data(repeating: 0x1F, count: 16),
        ]
        let data = (try? PropertyListSerialization.data(fromPropertyList: dict,
                                                        format: .xml, options: 0)) ?? Data()
        let result = store.importRecord(data)
        XCTAssertTrue(result.isValid)
        // This is the exact assertion that failed before the kSecReturnData fix:
        // save() reported success while every load() returned nil.
        XCTAssertEqual(store.load(), data)
        XCTAssertTrue(store.metadata().isValid)
        XCTAssertEqual(store.metadata().presentKeyNames.count, 4)
    }
}
