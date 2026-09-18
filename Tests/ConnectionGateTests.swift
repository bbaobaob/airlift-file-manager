import XCTest
@testable import AirLiftFileManager

final class ConnectionGateTests: XCTestCase {
    // MARK: - Pure state machine

    func testLadderWalksInOrder() {
        var machine = ConnectionMachine()
        XCTAssertEqual(machine.phase, .disconnected)

        for expected in ConnectionPhase.ladder.dropFirst() {
            XCTAssertTrue(machine.advance(), "advance to \(expected.rawValue) must succeed")
            XCTAssertEqual(machine.phase, expected)
        }
        // Terminal: no further advance.
        XCTAssertFalse(machine.advance())
        XCTAssertEqual(machine.phase, .ready)
    }

    func testFailFromAnyCheckableState() {
        for start in ConnectionPhase.ladder {
            var machine = ConnectionMachine(initial: start)
            machine.fail("boom")
            XCTAssertEqual(machine.phase, .failed)
            XCTAssertEqual(machine.failureReason, "boom")
        }
    }

    func testIllegalJumpRejected() {
        XCTAssertFalse(ConnectionMachine.canReach(.transportChecking, from: .vpnRequired))
        XCTAssertTrue(ConnectionMachine.canReach(.vpnConnected, from: .vpnRequired))
        XCTAssertFalse(ConnectionMachine.canReach(.ready, from: .pairingImported))
    }

    func testResetClearsFailure() {
        var machine = ConnectionMachine(initial: .transportChecking)
        machine.fail("timeout")
        machine.reset()
        XCTAssertEqual(machine.phase, .disconnected)
        XCTAssertNil(machine.failureReason)
    }

    func testFeatureGating() {
        XCTAssertTrue(ConnectionPhase.ready.allowsAirLiftFeatures)
        for phase in ConnectionPhase.allCases where phase != .ready {
            XCTAssertFalse(phase.allowsAirLiftFeatures,
                           "\(phase.rawValue) must not unlock AirLift features")
        }
        XCTAssertTrue(ConnectionPhase.failed.allowsSandboxFeatures)
    }

    // MARK: - Full ladder with injected probes

    @MainActor
    func testLadderPausesAtVpnRequiredWhenTunnelMissing() async {
        let gate = ConnectionGateViewModel(
            vpnProbe: { false },
            lockdownProbe: { LockdownProbeResult(reachable: false, queryType: nil,
                                                 productVersion: nil, productType: nil,
                                                 error: "not called") },
            capabilityProbe: FailingCapabilityProbe())
        await gate.runChecks()

        XCTAssertEqual(gate.phase, .vpnRequired)
        XCTAssertEqual(gate.steps.first?.status, .waitingForUser)
        XCTAssertFalse(gate.airLiftFeaturesAllowed)
        XCTAssertTrue(gate.sandboxFeaturesAllowed)
    }

    @MainActor
    func testLadderPausesAtPairingWhenNoRecord() async {
        let store = InMemoryPairingStore()
        let gate = ConnectionGateViewModel(
            pairingStore: store,
            vpnProbe: { true },
            lockdownProbe: { LockdownProbeResult(reachable: false, queryType: nil,
                                                 productVersion: nil, productType: nil,
                                                 error: "not called") },
            capabilityProbe: FailingCapabilityProbe())
        await gate.runChecks()

        XCTAssertEqual(gate.phase, .pairingRequired)
        XCTAssertFalse(gate.airLiftFeaturesAllowed)
    }

    @MainActor
    func testLadderFailsWhenLockdownExchangeFails() async {
        let store = InMemoryPairingStore()
        store.injectValid = true
        let gate = ConnectionGateViewModel(
            pairingStore: store,
            vpnProbe: { true },
            lockdownProbe: { LockdownProbeResult(reachable: false, queryType: nil,
                                                 productVersion: nil, productType: nil,
                                                 error: "lockdown timeout") },
            capabilityProbe: FailingCapabilityProbe())
        await gate.runChecks()

        XCTAssertEqual(gate.phase, .failed)
        XCTAssertTrue(gate.machine.failureReason?.contains("timeout") == true)
        XCTAssertFalse(gate.airLiftFeaturesAllowed)
    }

    @MainActor
    func testLadderReachesReadyOnlyWithRealVerification() async {
        let store = InMemoryPairingStore()
        store.injectValid = true
        let gate = ConnectionGateViewModel(
            pairingStore: store,
            vpnProbe: { true },
            lockdownProbe: { LockdownProbeResult(reachable: true, queryType: "com.apple.mobile.lockdown",
                                                 productVersion: "27.0", productType: "iPhone12,5",
                                                 error: nil) },
            capabilityProbe: PassingCapabilityProbe())
        await gate.runChecks()

        XCTAssertEqual(gate.phase, .ready)
        XCTAssertTrue(gate.airLiftFeaturesAllowed)
        XCTAssertEqual(gate.steps.last?.status, .passed)
        XCTAssertNotNil(gate.lastRunAt)
        XCTAssertEqual(gate.lastLockdownResult?.queryType, "com.apple.mobile.lockdown")
    }

    // MARK: - Pairing import validation through the gate

    @MainActor
    func testInvalidPairingImportIsRejected() async {
        let store = InMemoryPairingStore()
        let gate = ConnectionGateViewModel(pairingStore: store)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-pairing-\(UUID().uuidString).plist")
        try? Data("not a pairing record".utf8).write(to: tmp)
        await gate.importPairing(from: tmp)
        XCTAssertTrue(gate.pairingStatusMessage.contains("rejected"))
        XCTAssertFalse(store.hasRecord)
        try? FileManager.default.removeItem(at: tmp)
    }
}

// MARK: - Test doubles

/// Capability probe double that fails on purpose.
private struct FailingCapabilityProbe: CapabilityProbing {
    func run() async -> CapabilityReport {
        CapabilityReport(
            startedAt: Date(), finishedAt: Date(),
            checks: [CapabilityCheck(id: "lockdown.exchange", status: .failed,
                                     detail: "forced failure")])
    }
}

/// Capability probe double that verifies transport.
private struct PassingCapabilityProbe: CapabilityProbing {
    func run() async -> CapabilityReport {
        CapabilityReport(
            startedAt: Date(), finishedAt: Date(),
            checks: [
                CapabilityCheck(id: "lockdown.exchange", status: .passed,
                                detail: "verified"),
                CapabilityCheck(id: "airlift.on-device", status: .notImplemented,
                                detail: "documented"),
            ])
    }
}

/// Keychain-free pairing store double (unit tests must not touch the real Keychain).
final class InMemoryPairingStore: PairingStoring, @unchecked Sendable {
    var injectValid = false
    private var storedData: Data?

    var hasRecord: Bool { load() != nil }

    func load() -> Data? {
        injectValid ? validPairingData() : storedData
    }

    func save(_ data: Data) -> Bool {
        storedData = data
        return true
    }

    func delete() {
        storedData = nil
        injectValid = false
    }

    func metadata() -> PairingMetadata {
        guard let data = load() else {
            return PairingMetadata(importedAt: nil, presentKeyNames: [], isValid: false)
        }
        let validation = PairingRecordService.validate(data)
        return PairingMetadata(importedAt: Date(), presentKeyNames: validation.presentKeys,
                               isValid: validation.isValid)
    }

    func importRecord(_ data: Data) -> PairingRecordService.ValidationResult {
        let validation = PairingRecordService.validate(data)
        if validation.isValid { save(data) }
        return validation
    }

    func migrateLegacyFileIfNeeded() {}

    private func validPairingData() -> Data {
        var dict: [String: Any] = [:]
        for key in PairingRecordService.requiredKeys {
            dict[key] = String(repeating: "A", count: 64)
        }
        return (try? PropertyListSerialization.data(fromPropertyList: dict,
                                                    format: .binary, options: 0)) ?? Data()
    }
}
