import XCTest
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
