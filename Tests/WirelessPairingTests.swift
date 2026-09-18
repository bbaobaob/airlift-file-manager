import XCTest
@testable import AirLiftFileManager

/// Tests for the real wireless-pairing step 1: SipHash-2-4 core (reference
/// vectors), authTag math (exact idevice port), TXT parsing, credential
/// matching, and the discoverable capability check. All fixtures synthetic.
final class WirelessPairingTests: XCTestCase {
    // MARK: - SipHash-2-4 reference vectors (key 00..0f)

    func testSipHashEmptyInput() {
        let key = Array(UInt8(0)...UInt8(15))
        let digest = SipHash24.hash(key0: loadLE64(key, 0), key1: loadLE64(key, 8), message: [])
        XCTAssertEqual(digest, 0x726fdb47dd0e0e31)
    }

    func testSipHashSingleZeroByte() {
        let key = Array(UInt8(0)...UInt8(15))
        let digest = SipHash24.hash(key0: loadLE64(key, 0), key1: loadLE64(key, 8), message: [0x00])
        XCTAssertEqual(digest, 0x74f839c593dc67fd)
    }

    func testSipHashMultiBlockVectors() {
        // Grounded against an independent C oracle (lengths 2, 15, 32).
        let key = Array(UInt8(0)...UInt8(15))
        let k0 = loadLE64(key, 0)
        let k1 = loadLE64(key, 8)
        XCTAssertEqual(SipHash24.hash(key0: k0, key1: k1, message: [0x00, 0x01]),
                       0x0d6c8009d9a94f5a)
        XCTAssertEqual(SipHash24.hash(key0: k0, key1: k1, message: Array(UInt8(0)..<UInt8(15))),
                       0xa129ca6149be45e5)
        XCTAssertEqual(SipHash24.hash(key0: k0, key1: k1, message: Array(UInt8(0)..<UInt8(32))),
                       0x7127512f72f27cce)
    }

    private func loadLE64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(bytes[offset + i]) << (8 * i) }
        return value
    }

    // MARK: - authTag math

    private let altIrk = Data((0..<16).map { UInt8($0) })

    func testComputeAuthTagIsSixBytesAndDeterministic() {
        let a = RemotePairingAuth.computeAuthTag(altIrk: Array(altIrk), serviceIdentifier: "test-device")
        let b = RemotePairingAuth.computeAuthTag(altIrk: Array(altIrk), serviceIdentifier: "test-device")
        XCTAssertEqual(a?.count, 6)
        XCTAssertEqual(a, b)
    }

    func testComputeAuthTagRejectsBadKeyLength() {
        XCTAssertNil(RemotePairingAuth.computeAuthTag(altIrk: [UInt8](repeating: 0, count: 8),
                                                      serviceIdentifier: "x"))
    }

    func testValidatesRoundTrip() {
        guard let tag = RemotePairingAuth.computeAuthTag(altIrk: Array(altIrk),
                                                         serviceIdentifier: "my-iphone") else {
            XCTFail("tag must compute"); return
        }
        let encoded = Data(tag).base64EncodedString()
        XCTAssertTrue(RemotePairingAuth.validates(authTagBase64: encoded, altIrk: altIrk,
                                                  serviceIdentifier: "my-iphone"))
    }

    func testValidatesRejectsTampering() {
        guard var tag = RemotePairingAuth.computeAuthTag(altIrk: Array(altIrk),
                                                         serviceIdentifier: "my-iphone") else {
            XCTFail("tag must compute"); return
        }
        tag[0] ^= 0xff
        XCTAssertFalse(RemotePairingAuth.validates(authTagBase64: Data(tag).base64EncodedString(),
                                                   altIrk: altIrk, serviceIdentifier: "my-iphone"))
    }

    func testValidatesRejectsWrongCredentialOrIdentifier() {
        guard let tag = RemotePairingAuth.computeAuthTag(altIrk: Array(altIrk),
                                                         serviceIdentifier: "my-iphone") else {
            XCTFail("tag must compute"); return
        }
        let encoded = Data(tag).base64EncodedString()
        let otherIrk = Data(repeating: 0xAB, count: 16)
        XCTAssertFalse(RemotePairingAuth.validates(authTagBase64: encoded, altIrk: otherIrk,
                                                   serviceIdentifier: "my-iphone"))
        XCTAssertFalse(RemotePairingAuth.validates(authTagBase64: encoded, altIrk: altIrk,
                                                   serviceIdentifier: "other-device"))
    }

    func testValidatesRejectsMalformedInput() {
        XCTAssertFalse(RemotePairingAuth.validates(authTagBase64: "!!!not-base64!!!",
                                                   altIrk: altIrk, serviceIdentifier: "x"))
        let short = Data([1, 2, 3]).base64EncodedString()
        XCTAssertFalse(RemotePairingAuth.validates(authTagBase64: short,
                                                   altIrk: altIrk, serviceIdentifier: "x"))
    }

    // MARK: - TXT parsing + credential matching

    func testParseTXTRecord() {
        let blob = NetService.data(fromTXTRecord: [
            "identifier": Data("dev-123".utf8),
            "authTag": Data("dGFnMTIz".utf8),
        ])
        let (identifier, authTag) = WirelessPairingDiscovery.parseTXT(blob)
        XCTAssertEqual(identifier, "dev-123")
        XCTAssertEqual(authTag, "dGFnMTIz")
    }

    func testParseTXTRecordMissingKeys() {
        let (identifier, authTag) = WirelessPairingDiscovery.parseTXT(Data())
        XCTAssertNil(identifier)
        XCTAssertNil(authTag)
    }

    func testMatchesCredentialEndToEnd() {
        let identifier = "test-service-id"
        guard let tag = RemotePairingAuth.computeAuthTag(altIrk: Array(altIrk),
                                                         serviceIdentifier: identifier) else {
            XCTFail("tag must compute"); return
        }
        let service = WirelessPairingDiscovery.DiscoveredService(
            name: "Test iPhone", port: 49152, identifier: identifier,
            authTag: Data(tag).base64EncodedString())
        XCTAssertTrue(WirelessPairingDiscovery.matchesCredential(service: service, altIrk: altIrk))

        let stranger = WirelessPairingDiscovery.DiscoveredService(
            name: "Stranger", port: 49152, identifier: "someone-else",
            authTag: Data(tag).base64EncodedString())
        XCTAssertFalse(WirelessPairingDiscovery.matchesCredential(service: stranger, altIrk: altIrk))

        let noTXT = WirelessPairingDiscovery.DiscoveredService(
            name: "Silent", port: 0, identifier: nil, authTag: nil)
        XCTAssertFalse(WirelessPairingDiscovery.matchesCredential(service: noTXT, altIrk: altIrk))
    }

    // MARK: - Capability check wiring

    private func remoteRecord(altIrk: Data) -> Data {
        let dict: [String: Any] = [
            "public_key": Data(repeating: 0xA5, count: 32),
            "private_key": Data(repeating: 0x5A, count: 32),
            "identifier": UUID().uuidString,
            "alt_irk": altIrk,
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: dict,
                                                    format: .xml, options: 0)) ?? Data()
    }

    private func probeService(store: InMemoryPairingStore,
                              services: [WirelessPairingDiscovery.DiscoveredService]) -> CapabilityProbeService {
        CapabilityProbeService(
            vpnProbe: { false },
            lockdownProbe: { LockdownProbeResult(reachable: false, queryType: nil,
                                                 productVersion: nil, productType: nil,
                                                 error: "down") },
            pairingStore: store,
            discover: { services })
    }

    func testDiscoverablePassedWhenCredentialMatches() async {
        let store = InMemoryPairingStore()
        store.save(remoteRecord(altIrk: altIrk))
        let identifier = "matching-device"
        let tag = RemotePairingAuth.computeAuthTag(altIrk: Array(altIrk),
                                                   serviceIdentifier: identifier)!
        let service = WirelessPairingDiscovery.DiscoveredService(
            name: "iPhone", port: 49152, identifier: identifier,
            authTag: Data(tag).base64EncodedString())
        let report = await probeService(store: store, services: [service]).run()
        let check = report.checks.first { $0.id == "wireless-pairing.discoverable" }
        XCTAssertEqual(check?.status, .passed)
        XCTAssertTrue(check?.detail.contains("authTag verified") == true)
    }

    func testDiscoverableNotAvailableWhenNothingSeen() async {
        let store = InMemoryPairingStore()
        store.save(remoteRecord(altIrk: altIrk))
        let report = await probeService(store: store, services: []).run()
        let check = report.checks.first { $0.id == "wireless-pairing.discoverable" }
        XCTAssertEqual(check?.status, .notAvailable)
    }

    func testDiscoverableFailedOnAuthTagMismatch() async {
        let store = InMemoryPairingStore()
        store.save(remoteRecord(altIrk: altIrk))
        let service = WirelessPairingDiscovery.DiscoveredService(
            name: "Stranger", port: 49152, identifier: "not-ours",
            authTag: Data(repeating: 0x11, count: 6).base64EncodedString())
        let report = await probeService(store: store, services: [service]).run()
        let check = report.checks.first { $0.id == "wireless-pairing.discoverable" }
        XCTAssertEqual(check?.status, .failed)
    }

    func testDiscoverableSkippedWithoutRemoteRecord() async {
        let store = InMemoryPairingStore() // empty: no pairing at all
        let report = await probeService(store: store, services: []).run()
        let check = report.checks.first { $0.id == "wireless-pairing.discoverable" }
        XCTAssertEqual(check?.status, .skipped)
    }
}
