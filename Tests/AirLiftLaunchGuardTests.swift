import XCTest
@testable import AirLiftFileManager

/// Shared fakes. All probes are flags so each test can flip reality between
/// recheck and launch — exactly the situation the guard must catch.
final class ProbeBox: @unchecked Sendable {
    var vpnUp = true
    var lockdownReachable = true

    func vpnProbe() async -> Bool { vpnUp }
    func lockdownProbe() async -> LockdownProbeResult {
        LockdownProbeResult(reachable: lockdownReachable,
                            queryType: lockdownReachable ? "com.apple.mobile.lockdown" : nil,
                            productVersion: lockdownReachable ? "27.0" : nil,
                            productType: lockdownReachable ? "iPhone12,5" : nil,
                            error: lockdownReachable ? nil : "connection refused")
    }
}

final class FakeLauncher: AirLiftExecuting, @unchecked Sendable {
    var outcome: AirLiftExecutionOutcome
    var executeCount = 0

    init(outcome: AirLiftExecutionOutcome) {
        self.outcome = outcome
    }

    func execute() async -> AirLiftExecutionOutcome {
        executeCount += 1
        return outcome
    }
}

/// Keychain-free pairing store double (unit tests must not touch the real Keychain).
final class InMemoryPairingStore: PairingStoring, @unchecked Sendable {
    private var storedData: Data?

    var hasRecord: Bool { load() != nil }

    func load() -> Data? { storedData }

    func save(_ data: Data) -> Bool {
        storedData = data
        return true
    }

    func delete() {
        storedData = nil
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

    func inject(recordWithKeys keys: [String]) {
        var dict: [String: Any] = [:]
        for key in keys {
            dict[key] = String(repeating: "A", count: 64)
        }
        storedData = (try? PropertyListSerialization.data(
            fromPropertyList: dict, format: .binary, options: 0)) ?? Data()
    }
}

@MainActor
final class AirLiftLaunchGuardTests: XCTestCase {
    private var box: ProbeBox!
    private var store: InMemoryPairingStore!

    override func setUp() async throws {
        box = ProbeBox()
        store = InMemoryPairingStore()
    }

    // MARK: - Pairing file UTI support (document picker + Open-in)

    func testSupportedContentTypesMatchVerifiedSet() {
        let identifiers = PairingFileSupport.supportedContentTypes.map(\.identifier)
        XCTAssertTrue(identifiers.contains("com.apple.property-list"),
                      "StikPair exports .plist files")
        XCTAssertTrue(identifiers.contains { $0.contains("mobiledevicepair") },
                      "iloader-style .mobiledevicepairing files must be accepted")
        XCTAssertFalse(identifiers.contains("public.item"),
                       "generic .item grays out rows in the iOS document picker")
    }

    func testAppAcceptsPairingFilesViaOpenIn() {
        // CFBundleDocumentTypes in the checked-in Info.plist enable the
        // share-sheet path that bypasses the document picker entirely.
        guard let url = Bundle.main.url(forResource: "Info", withExtension: "plist"),
              let info = NSDictionary(contentsOf: url),
              let docTypes = info["CFBundleDocumentTypes"] as? [[String: Any]] else {
            XCTFail("app Info.plist must be present in the bundle")
            return
        }
        let contentTypes = docTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        XCTAssertTrue(contentTypes.contains("com.apple.property-list"))
        XCTAssertTrue(contentTypes.contains("com.apple.mobiledevicepairing"))
    }

    private func makeGuard(launcher: AirLiftExecuting,
                           watchdogInterval: TimeInterval = 3.0) -> AirLiftLaunchGuard {
        AirLiftLaunchGuard(pairingStore: store,
                           vpnProbe: { [box] in await box.vpnProbe() },
                           lockdownProbe: { [box] in await box.lockdownProbe() },
                           launcher: launcher,
                           watchdogInterval: watchdogInterval)
    }

    // MARK: - Startup ladder (spec pseudo-code)

    func testLockedWhenVPNDown() async {
        box.vpnUp = false
        let guardVM = makeGuard(launcher: TransportUnavailableLauncher())
        await guardVM.recheckConnection()

        XCTAssertEqual(guardVM.launchState, .locked)
        XCTAssertEqual(guardVM.vpnStatus, .disconnected)
        XCTAssertFalse(guardVM.canStartAirLift)
        XCTAssertTrue(guardVM.lastFailureReason?.contains("LocalDevVPN") == true)
    }

    func testLockedWhenPairingFileMissing() async {
        let guardVM = makeGuard(launcher: TransportUnavailableLauncher())
        await guardVM.recheckConnection()

        XCTAssertEqual(guardVM.launchState, .locked)
        XCTAssertEqual(guardVM.vpnStatus, .connected)
        XCTAssertEqual(guardVM.pairingStatus, .notImported)
        XCTAssertTrue(guardVM.lastFailureReason?.contains("Pairing File") == true)
        XCTAssertFalse(guardVM.canStartAirLift)
    }

    func testLockedWhenPairingFileInvalid() async {
        store.inject(recordWithKeys: ["HostPrivateKey"]) // missing certificate keys
        let guardVM = makeGuard(launcher: TransportUnavailableLauncher())
        await guardVM.recheckConnection()

        XCTAssertEqual(guardVM.launchState, .locked)
        XCTAssertEqual(guardVM.pairingStatus, .invalid)
        XCTAssertTrue(guardVM.lastFailureReason?.contains("invalid") == true)
        XCTAssertFalse(guardVM.canStartAirLift)
    }

    func testUnsupportedWhenFileIsNotAPairingRecord() async {
        store.save(Data("definitely not a pairing record".utf8))
        let guardVM = makeGuard(launcher: TransportUnavailableLauncher())
        await guardVM.recheckConnection()

        XCTAssertEqual(guardVM.pairingStatus, .unsupported)
        XCTAssertEqual(guardVM.launchState, .locked)
    }

    func testReadyToStartWhenAllGatesPass() async {
        store.inject(recordWithKeys: PairingRecordService.requiredKeys)
        let guardVM = makeGuard(launcher: TransportUnavailableLauncher())
        await guardVM.recheckConnection()

        XCTAssertEqual(guardVM.launchState, .readyToStart)
        XCTAssertEqual(guardVM.vpnStatus, .connected)
        XCTAssertEqual(guardVM.pairingStatus, .imported)
        XCTAssertTrue(guardVM.canStartAirLift)
        XCTAssertEqual(guardVM.lastPreflight?.transportReachable, true)
        XCTAssertEqual(guardVM.lastPreflight?.deviceResponded, true)
    }

    func testTransportDownAfterVpnUpLocks() async {
        store.inject(recordWithKeys: PairingRecordService.requiredKeys)
        box.lockdownReachable = false
        let guardVM = makeGuard(launcher: TransportUnavailableLauncher())
        await guardVM.recheckConnection()

        XCTAssertEqual(guardVM.launchState, .locked)
        XCTAssertTrue(guardVM.lastFailureReason?.contains("Transport unavailable") == true)
        XCTAssertEqual(guardVM.lastPreflight?.transportReachable, false)
    }

    // MARK: - Launch rules

    func testStartAirLiftRunsFullPreflightBeforeEveryLaunch() async {
        store.inject(recordWithKeys: PairingRecordService.requiredKeys)
        let launcher = FakeLauncher(outcome: .started(detail: "verified channel"))
        let guardVM = makeGuard(launcher: launcher)
        await guardVM.recheckConnection()
        XCTAssertEqual(guardVM.launchState, .readyToStart)

        // Reality changes between ready and start: VPN drops.
        box.vpnUp = false
        await guardVM.startAirLift()

        XCTAssertEqual(launcher.executeCount, 0, "launcher must never be called on failed preflight")
        XCTAssertEqual(guardVM.launchState, .locked)
        XCTAssertFalse(guardVM.canStartAirLift)
    }

    func testOnDeviceLaunchReportsTransportUnavailableNotRunning() async {
        store.inject(recordWithKeys: PairingRecordService.requiredKeys)
        let guardVM = makeGuard(launcher: TransportUnavailableLauncher())
        await guardVM.recheckConnection()
        await guardVM.startAirLift()

        XCTAssertEqual(guardVM.launchState, .failed)
        XCTAssertTrue(guardVM.lastFailureReason?.contains("Transport unavailable") == true)
        XCTAssertNotEqual(guardVM.launchState, .running,
                          "no mock Running state may ever be shown")
    }

    func testSuccessfulExecutorReachesRunning() async {
        store.inject(recordWithKeys: PairingRecordService.requiredKeys)
        let guardVM = makeGuard(
            launcher: FakeLauncher(outcome: .started(detail: "relay channel verified")),
            watchdogInterval: 60)
        await guardVM.recheckConnection()
        await guardVM.startAirLift()

        XCTAssertEqual(guardVM.launchState, .running)
        XCTAssertEqual(guardVM.lastFailureReason, nil)
    }

    func testWatchdogStopsEverythingWhenTunnelDropsWhileRunning() async {
        store.inject(recordWithKeys: PairingRecordService.requiredKeys)
        let guardVM = makeGuard(
            launcher: FakeLauncher(outcome: .started(detail: "verified channel")),
            watchdogInterval: 0.05)
        await guardVM.recheckConnection()
        await guardVM.startAirLift()
        XCTAssertEqual(guardVM.launchState, .running)

        box.vpnUp = false
        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(guardVM.launchState, .disconnected)
        XCTAssertTrue(guardVM.lastFailureReason?.contains("dropped") == true)
        XCTAssertFalse(guardVM.canStartAirLift)
    }

    // MARK: - Pairing actions

    func testInvalidPairingImportIsRejected() async {
        let guardVM = makeGuard(launcher: TransportUnavailableLauncher())
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-pairing-\(UUID().uuidString).plist")
        try? Data("not a pairing record".utf8).write(to: tmp)
        await guardVM.importPairing(from: tmp)

        XCTAssertTrue(guardVM.pairingStatusMessage.contains("rejected"))
        XCTAssertFalse(store.hasRecord)
        try? FileManager.default.removeItem(at: tmp)
    }

    func testRemovePairingLocksReadyState() async {
        store.inject(recordWithKeys: PairingRecordService.requiredKeys)
        let guardVM = makeGuard(launcher: TransportUnavailableLauncher())
        await guardVM.recheckConnection()
        XCTAssertEqual(guardVM.launchState, .readyToStart)

        guardVM.removePairing()
        XCTAssertEqual(guardVM.launchState, .locked)
        XCTAssertTrue(guardVM.lastFailureReason?.contains("Pairing File removed") == true)
    }

    // MARK: - Preflight checker unit behavior

    func testPreflightStopsAtFirstBlockingGate() async {
        box.vpnUp = false
        let checker = AirLiftPreflightChecker(
            vpnProbe: { [box] in await box.vpnProbe() },
            lockdownProbe: { [box] in await box.lockdownProbe() },
            pairingStore: store)
        let result = await checker.runPreflight()
        XCTAssertEqual(result.vpnStatus, .disconnected)
        XCTAssertEqual(result.transportReachable, false,
                       "transport must not be probed when the VPN gate already failed")
    }
}
