import XCTest
@testable import AirLiftFileManager

/// Shared fakes. All probes are flags so each test can flip reality between
/// recheck and launch — exactly the situation the guard must catch.
final class ProbeBox: @unchecked Sendable {
    var vpnUp = true
    var lockdownReachable = true
    var remoteConnectUp = true
    var discoveredPorts: [UInt16] = [49152]
    var verifyProblem: String? = nil
    var discoveryCalls = 0

    func vpnProbe() async -> Bool { vpnUp }
    func lockdownProbe() async -> LockdownProbeResult {
        LockdownProbeResult(reachable: lockdownReachable,
                            queryType: lockdownReachable ? "com.apple.mobile.lockdown" : nil,
                            productVersion: lockdownReachable ? "27.0" : nil,
                            productType: lockdownReachable ? "iPhone12,5" : nil,
                            error: lockdownReachable ? nil : "connection refused")
    }
    func remoteConnect(_ port: UInt16) async -> Bool { remoteConnectUp }
    func discover() async -> [WirelessPairingDiscovery.DiscoveredService] {
        discoveryCalls += 1
        return discoveredPorts.map {
            WirelessPairingDiscovery.DiscoveredService(
                name: "TestDevice", port: $0,
                identifier: "test-id", authTag: nil)
        }
    }
    func verifyDevice(_ record: Data, _ port: UInt16) async -> String? { verifyProblem }
}

/// Fails the test loudly if the launch path is ever reached.
final class NeverRunsLauncher: AirLiftExecuting, @unchecked Sendable {
    func execute() async -> AirLiftExecutionOutcome {
        XCTFail("launcher must not run on this path")
        return .failed(reason: "test double invoked")
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
        UserDefaults.standard.removeObject(
            forKey: AirLiftPreflightChecker.cachedPortKey)
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
                           remoteConnect: { [box] port in await box.remoteConnect(port) },
                           discover: { [box] in await box.discover() },
                           verifyDevice: { [box] record, port in
                               await box.verifyDevice(record, port)
                           },
                           launcher: launcher,
                           watchdogInterval: watchdogInterval)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(
            forKey: AirLiftPreflightChecker.cachedPortKey)
        try await super.tearDown()
    }

    // MARK: - Startup ladder (spec pseudo-code)

    func testLockedWhenVPNDown() async {
        box.vpnUp = false
        box.remoteConnectUp = false
        box.discoveredPorts = []
        let guardVM = makeGuard(launcher: NeverRunsLauncher())
        await guardVM.recheckConnection()

        XCTAssertEqual(guardVM.launchState, .locked)
        XCTAssertEqual(guardVM.vpnStatus, .disconnected)
        XCTAssertFalse(guardVM.canStartAirLift)
        XCTAssertTrue(guardVM.lastFailureReason?.contains("LocalDevVPN") == true)
    }

    func testLockedWhenPairingFileMissing() async {
        let guardVM = makeGuard(launcher: NeverRunsLauncher())
        await guardVM.recheckConnection()

        XCTAssertEqual(guardVM.launchState, .locked)
        XCTAssertEqual(guardVM.vpnStatus, .connected)
        XCTAssertEqual(guardVM.pairingStatus, .notImported)
        XCTAssertTrue(guardVM.lastFailureReason?.contains("Pairing File") == true)
        XCTAssertFalse(guardVM.canStartAirLift)
    }

    func testLockedWhenPairingFileInvalid() async {
        store.inject(recordWithKeys: ["HostPrivateKey"]) // missing certificate keys
        let guardVM = makeGuard(launcher: NeverRunsLauncher())
        await guardVM.recheckConnection()

        XCTAssertEqual(guardVM.launchState, .locked)
        XCTAssertEqual(guardVM.pairingStatus, .invalid)
        XCTAssertTrue(guardVM.lastFailureReason?.contains("invalid") == true)
        XCTAssertFalse(guardVM.canStartAirLift)
    }

    func testUnsupportedWhenFileIsNotAPairingRecord() async {
        store.save(Data("definitely not a pairing record".utf8))
        let guardVM = makeGuard(launcher: NeverRunsLauncher())
        await guardVM.recheckConnection()

        XCTAssertEqual(guardVM.pairingStatus, .unsupported)
        XCTAssertEqual(guardVM.launchState, .locked)
    }

    func testReadyToStartWhenAllGatesPass() async {
        store.inject(recordWithKeys: PairingRecordService.requiredKeys)
        let guardVM = makeGuard(launcher: NeverRunsLauncher())
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
        box.remoteConnectUp = false
        box.discoveredPorts = []
        let guardVM = makeGuard(launcher: NeverRunsLauncher())
        await guardVM.recheckConnection()

        XCTAssertEqual(guardVM.launchState, .locked)
        XCTAssertTrue(guardVM.lastFailureReason?.contains("_remotepairing") == true)
        XCTAssertEqual(guardVM.lastPreflight?.transportReachable, false)
    }

    func testLockdownFailureDoesNotBlockWhenChainTransportWorks() async {
        // Lockdown 62078 is supplementary diagnostics, never gating: the
        // chain dials the remotepairing endpoint, not lockdown.
        store.inject(recordWithKeys: PairingRecordService.requiredKeys)
        box.lockdownReachable = false
        let guardVM = makeGuard(launcher: NeverRunsLauncher())
        await guardVM.recheckConnection()

        XCTAssertEqual(guardVM.launchState, .readyToStart)
        XCTAssertTrue(guardVM.canStartAirLift)
    }

    func testPairVerifyFailureBlocksLaunch() async {
        store.inject(recordWithKeys: PairingRecordService.requiredKeys)
        box.verifyProblem = "pair-verify rejected: device refused"
        let guardVM = makeGuard(launcher: NeverRunsLauncher())
        await guardVM.recheckConnection()

        XCTAssertEqual(guardVM.launchState, .locked)
        XCTAssertEqual(guardVM.lastPreflight?.transportReachable, true)
        XCTAssertEqual(guardVM.lastPreflight?.deviceResponded, false)
        XCTAssertTrue(guardVM.lastFailureReason?.contains("pair-verify") == true)
        XCTAssertFalse(guardVM.canStartAirLift)
    }

    func testCachedRemotePortSkipsDiscovery() async {
        // A cached port is re-verified live (never trusted blindly).
        UserDefaults.standard.set(49999, forKey: AirLiftPreflightChecker.cachedPortKey)
        box.vpnUp = false
        let guardVM = makeGuard(launcher: NeverRunsLauncher())
        store.inject(recordWithKeys: PairingRecordService.requiredKeys)
        await guardVM.recheckConnection()

        XCTAssertEqual(box.discoveryCalls, 0, "cached port must be tried before discovery")
        XCTAssertEqual(guardVM.launchState, .readyToStart)
    }

    // MARK: - Launch rules

    func testStartAirLiftRunsFullPreflightBeforeEveryLaunch() async {
        store.inject(recordWithKeys: PairingRecordService.requiredKeys)
        let launcher = FakeLauncher(outcome: .started(detail: "verified channel"))
        let guardVM = makeGuard(launcher: launcher)
        await guardVM.recheckConnection()
        XCTAssertEqual(guardVM.launchState, .readyToStart)

        // Reality changes between ready and start: the whole tunnel drops.
        box.vpnUp = false
        box.remoteConnectUp = false
        await guardVM.startAirLift()

        XCTAssertEqual(launcher.executeCount, 0, "launcher must never be called on failed preflight")
        XCTAssertEqual(guardVM.launchState, .locked)
        XCTAssertFalse(guardVM.canStartAirLift)
    }

    func testStartRunsRealChainAndReportsExactFailure() async {
        store.inject(recordWithKeys: PairingRecordService.requiredKeys)
        let chain = OnDeviceChain(
            pairingStore: store,
            vpnProbe: { true },
            discover: { [] },
            log: { _ in })
        let guardVM = makeGuard(launcher: OnDeviceChain.Launcher(chain: chain))
        await guardVM.recheckConnection()
        XCTAssertEqual(guardVM.launchState, .readyToStart)
        await guardVM.startAirLift()

        XCTAssertEqual(guardVM.launchState, .failed)
        XCTAssertTrue(guardVM.lastFailureReason?.contains("_remotepairing") == true)
        XCTAssertNotEqual(guardVM.launchState, .running,
                          "no mock Running state may ever be shown")
    }

    func testChainLauncherMapsOutcomes() async {
        let failing = OnDeviceChain(
            pairingStore: InMemoryPairingStore(),
            vpnProbe: { true },
            discover: { [] },
            log: { _ in })
        let failed = await OnDeviceChain.Launcher(chain: failing).execute()
        guard case .failed(let reason) = failed else {
            XCTFail("expected failed outcome"); return
        }
        XCTAssertTrue(reason.contains("preflight"))
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
        let guardVM = makeGuard(launcher: NeverRunsLauncher())
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
        let guardVM = makeGuard(launcher: NeverRunsLauncher())
        await guardVM.recheckConnection()
        XCTAssertEqual(guardVM.launchState, .readyToStart)

        guardVM.removePairing()
        XCTAssertEqual(guardVM.launchState, .locked)
        XCTAssertTrue(guardVM.lastFailureReason?.contains("Pairing File removed") == true)
    }

    // MARK: - Preflight checker unit behavior

    func testPreflightStopsAtFirstBlockingGate() async {
        box.vpnUp = false
        box.remoteConnectUp = false
        box.discoveredPorts = []
        let checker = AirLiftPreflightChecker(
            vpnProbe: { [box] in await box.vpnProbe() },
            lockdownProbe: { [box] in await box.lockdownProbe() },
            remoteConnect: { [box] port in await box.remoteConnect(port) },
            discover: { [box] in await box.discover() },
            verifyDevice: { [box] record, port in await box.verifyDevice(record, port) },
            pairingStore: store)
        let result = await checker.runPreflight()
        XCTAssertEqual(result.vpnStatus, .disconnected)
        XCTAssertEqual(result.transportReachable, false,
                       "transport must not be probed when the VPN gate already failed")
    }
}
