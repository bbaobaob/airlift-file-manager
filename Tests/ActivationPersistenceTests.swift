import XCTest
@testable import AirLiftFileManager

/// Verifies the honest activation rules:
/// - activated is only reached via a passing probe
/// - persisted activation is re-verified on launch and downgraded if stale
/// - unsupported environments never masquerade as activated
@MainActor
final class ActivationPersistenceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var persistence: PersistenceService!

    override func setUp() {
        super.setUp()
        suiteName = "ActivationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        persistence = PersistenceService(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private struct StaticProbe: AirLiftProbing {
        let result: AirLiftProbeResult
        func probe() async -> AirLiftProbeResult { result }
    }

    func testInitialStateWithoutHistory() {
        let manager = ActivationManager(probe: StaticProbe(result: .unsupported(reason: "x")),
                                        persistence: persistence,
                                        initialState: nil)
        XCTAssertEqual(manager.state, .notActivated)
    }

    func testUnsupportedEnvironmentNeverActivates() async {
        let manager = ActivationManager(
            probe: StaticProbe(result: .unsupported(reason: "host-side only")),
            persistence: persistence,
            initialState: nil)
        await manager.activate()
        XCTAssertEqual(manager.state, .unsupported)
        XCTAssertNotEqual(manager.state, .activated)
        XCTAssertTrue(manager.lastMessage.contains("host-side only"))
    }

    func testActivatedStatePersistsAndRestores() async {
        let first = ActivationManager(
            probe: StaticProbe(result: .activated(detail: "channel verified")),
            persistence: persistence,
            initialState: nil)
        await first.activate()
        XCTAssertEqual(first.state, .activated)
        XCTAssertNotNil(first.lastVerifiedAt)

        let restored = ActivationManager(
            probe: StaticProbe(result: .activated(detail: "re-verified")),
            persistence: persistence,
            initialState: nil)
        XCTAssertEqual(restored.state, .activated, "restored from persistence")
    }

    func testLaunchReverificationDowngradesStaleActivation() async {
        // Persist an "activated" state as if from an earlier session.
        persistence.setString(AirLiftState.activated.rawValue, forKey: .activationStateRaw)

        // New session: probe says the channel is gone.
        let manager = ActivationManager(
            probe: StaticProbe(result: .disconnected(reason: "paired Mac unreachable")),
            persistence: persistence,
            initialState: nil)
        XCTAssertEqual(manager.state, .activated, "restored stale state initially")

        await manager.verifyOnLaunch()
        XCTAssertEqual(manager.state, .disconnected,
                       "stale activation must downgrade, never silently persist")
        XCTAssertTrue(manager.lastMessage.contains("unreachable"))
    }

    func testLaunchProbeUnsupportedOverridesNotActivated() async {
        let manager = ActivationManager(
            probe: StaticProbe(result: .unsupported(reason: "no host components")),
            persistence: persistence,
            initialState: nil)
        await manager.verifyOnLaunch()
        XCTAssertEqual(manager.state, .unsupported)
    }

    func testFailedAttemptKeepsReason() async {
        let manager = ActivationManager(
            probe: StaticProbe(result: .failed(reason: "boom")),
            persistence: persistence,
            initialState: nil)
        await manager.activate()
        XCTAssertEqual(manager.state, .failed)
        XCTAssertTrue(manager.lastMessage.contains("boom"))
    }

    func testResetClearsPersistence() async {
        let manager = ActivationManager(
            probe: StaticProbe(result: .activated(detail: "ok")),
            persistence: persistence,
            initialState: nil)
        await manager.activate()
        manager.reset()
        XCTAssertEqual(manager.state, .notActivated)
        XCTAssertEqual(persistence.string(forKey: .activationStateRaw),
                       AirLiftState.notActivated.rawValue)
        XCTAssertNil(persistence.date(forKey: .activationLastVerified))
    }

    func testAllNineStatesExist() {
        XCTAssertEqual(AirLiftState.allCases.count, 9)
        XCTAssertEqual(Set(AirLiftState.allCases.map(\.rawValue)),
                       Set(["Not Activated", "Preparing", "Connecting", "Activating",
                            "Verifying", "Activated", "Failed", "Disconnected",
                            "Unsupported"]))
    }
}
