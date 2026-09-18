import Foundation

/// Drives the connection setup ladder with REAL checks only:
/// 1. LocalDevVPN tunnel reachability (TCP connect to 10.7.0.1:62078)
/// 2. Pairing record import/status (StikPair-style, Keychain-backed)
/// 3. Lockdown transport (real binary-plist QueryType exchange)
/// 4. Capability probe (independent per-capability verification)
///
/// A passed step is the only thing that moves the machine forward. Missing
/// VPN or missing pairing leaves the machine waiting for the user — it never
/// fakes progress. `ready` is reached only after a verified lockdown exchange
/// plus capability probe, and is re-verified every launch.
@MainActor
final class ConnectionGateViewModel: ObservableObject {
    @Published private(set) var machine = ConnectionMachine()
    @Published private(set) var steps: [ConnectionCheckStep] = Self.initialSteps
    @Published private(set) var isBusy = false
    @Published private(set) var lastLockdownResult: LockdownProbeResult?
    @Published private(set) var lastCapabilityReport: CapabilityReport?
    @Published private(set) var lastRunAt: Date?
    @Published var pairingStatusMessage: String

    let pairingStore: any PairingStoring

    private let vpnProbe: () async -> Bool
    private let lockdownProbe: () async -> LockdownProbeResult
    private let capabilityProbe: CapabilityProbing

    static var initialSteps: [ConnectionCheckStep] = [
        ConnectionCheckStep(id: .vpnRequired,
                            title: "LocalDevVPN connection",
                            detail: "TCP probe of 10.7.0.1:62078."),
        ConnectionCheckStep(id: .pairingRequired,
                            title: "Pairing file",
                            detail: "Import a StikPair-style lockdown pairing record."),
        ConnectionCheckStep(id: .transportChecking,
                            title: "Lockdown transport",
                            detail: "Real plist exchange (QueryType/GetValue)."),
        ConnectionCheckStep(id: .capabilityChecking,
                            title: "Capabilities",
                            detail: "Independent verification of each capability."),
    ]

    init(pairingStore: any PairingStoring = KeychainPairingStore(),
         vpnProbe: @escaping () async -> Bool = { await LocalDevVPNService().probeTunnel() },
         lockdownProbe: @escaping () async -> LockdownProbeResult = {
             await LockdownClient.probeDevice()
         },
         capabilityProbe: CapabilityProbing = CapabilityProbeService()) {
        self.pairingStore = pairingStore
        self.vpnProbe = vpnProbe
        self.lockdownProbe = lockdownProbe
        self.capabilityProbe = capabilityProbe
        pairingStatusMessage = pairingStore.hasRecord
            ? "Pairing record stored in Keychain."
            : "No pairing record imported yet."
        AppLogger.app.info("ConnectionGate init: phase=\(machine.phase.rawValue)")
    }

    var phase: ConnectionPhase { machine.phase }

    var statusSummary: String {
        switch machine.phase {
        case .ready:
            return "Connection verified. Lockdown transport answered a real plist exchange."
        case .failed:
            return machine.failureReason ?? "A check failed."
        case .vpnRequired:
            return "LocalDevVPN tunnel not detected yet."
        case .pairingRequired:
            return "Waiting for a pairing record."
        case .disconnected:
            return "Setup has not run yet."
        case .vpnConnected, .pairingImported:
            return "Checks in progress…"
        case .transportChecking, .capabilityChecking:
            return "Verifying…"
        case .transportReady:
            return "Transport verified."
        }
    }

    /// Updates one step row without faking outcomes.
    private func setStep(_ phase: ConnectionPhase,
                         status: ConnectionCheckStep.Status,
                         detail: String? = nil) {
        guard let index = steps.firstIndex(where: { $0.id == phase }) else { return }
        steps[index].status = status
        if let detail { steps[index].detail = detail }
    }

    func reset() {
        machine.reset()
        steps = Self.initialSteps
        lastLockdownResult = nil
        lastCapabilityReport = nil
        AppLogger.app.info("ConnectionGate reset")
    }

    /// Runs the whole ladder from the top. Every call re-verifies everything
    /// (cheap: one TCP probe + one plist exchange + capability checks), which
    /// keeps the state machine honest — no persisted "ready" is ever trusted.
    func runChecks() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        machine.reset()
        steps = Self.initialSteps
        AppLogger.vpn.info("Connection checks starting")

        // Step 1: VPN tunnel.
        machine.advance() // disconnected -> vpnRequired
        setStep(.vpnRequired, status: .running)
        let tunnelUp = await vpnProbe()
        guard tunnelUp else {
            setStep(.vpnRequired, status: .waitingForUser,
                    detail: "No answer from 10.7.0.1:62078. Connect LocalDevVPN (or SideStore StosVPN) and keep Wi-Fi on, then run checks again.")
            AppLogger.vpn.warning("Tunnel not reachable; ladder paused at vpnRequired")
            lastRunAt = Date()
            return
        }
        machine.advance() // -> vpnConnected
        setStep(.vpnRequired, status: .passed,
                detail: "10.7.0.1:62078 answered. Tunnel up.")
        AppLogger.vpn.info("Tunnel reachable")
        machine.advance() // vpnConnected -> pairingRequired

        // Step 2: Pairing record.
        setStep(.pairingRequired, status: .running)
        pairingStore.migrateLegacyFileIfNeeded()
        let metadata = pairingStore.metadata()
        if metadata.isValid {
            machine.advance() // -> pairingImported
            setStep(.pairingRequired, status: .passed,
                    detail: "Valid pairing record in Keychain (\(metadata.presentKeyNames.count) required keys).")
            AppLogger.pairing.info("Pairing record present and valid")
        } else if pairingStore.hasRecord {
            setStep(.pairingRequired, status: .waitingForUser,
                    detail: "Stored pairing record is invalid or incomplete. Re-export from StikPair and import again.")
            AppLogger.pairing.warning("Pairing record invalid")
            lastRunAt = Date()
            return
        } else {
            setStep(.pairingRequired, status: .waitingForUser,
                    detail: "No pairing record yet. Pair on-device with StikPair (Developer Mode → Pair with StikPair), export the plist, then import below.")
            AppLogger.pairing.info("Pairing record missing; ladder paused at pairingRequired")
            lastRunAt = Date()
            return
        }
        machine.advance() // pairingImported -> transportChecking

        // Step 3: Lockdown transport (real exchange).
        setStep(.transportChecking, status: .running)
        let lockdown = await lockdownProbe()
        lastLockdownResult = lockdown
        if lockdown.reachable {
            machine.advance() // -> transportReady
            var facts = ["QueryType=\(lockdown.queryType ?? "?")"]
            if let v = lockdown.productVersion { facts.append("iOS \(v)") }
            if let p = lockdown.productType { facts.append(p) }
            setStep(.transportChecking, status: .passed,
                    detail: "Lockdown exchange verified (\(facts.joined(separator: ", "))).")
            AppLogger.net.info("Lockdown transport verified: \(facts.joined(separator: ", "))")
        } else {
            machine.fail(lockdown.error ?? "Lockdown unreachable although the tunnel is up.")
            setStep(.transportChecking, status: .failed,
                    detail: lockdown.error ?? "Lockdown unreachable.")
            AppLogger.net.error("Lockdown exchange failed: \(lockdown.error ?? "unknown")")
            lastRunAt = Date()
            return
        }
        machine.advance() // transportReady -> capabilityChecking

        // Step 4: Capability probe.
        setStep(.capabilityChecking, status: .running)
        let report = await capabilityProbe.run()
        lastCapabilityReport = report
        if report.transportReady {
            machine.advance() // -> ready
            setStep(.capabilityChecking, status: .passed,
                    detail: "\(report.passedCount) of \(report.checks.count) capability checks verified. Out-of-sandbox write access still requires the paired-Mac AirLift tool (honestly reported per check).")
            AppLogger.airLift.info("Connection gate reached ready state")
        } else {
            machine.fail("Capability probe did not verify the lockdown transport.")
            setStep(.capabilityChecking, status: .failed,
                    detail: "Capability probe failed. See Access Status for details.")
            AppLogger.airLift.error("Capability probe failed")
        }
        lastRunAt = Date()
    }

    // MARK: - Pairing actions

    func importPairing(from sourceURL: URL) async {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: sourceURL)
            let result = pairingStore.importRecord(data)
            pairingStatusMessage = result.isValid
                ? result.message
                : "Import rejected: \(result.message)"
            if result.isValid {
                AppLogger.pairing.info("Pairing imported and stored in Keychain")
            }
        } catch {
            pairingStatusMessage = "Could not read pairing file: \(error.localizedDescription)"
            AppLogger.pairing.error("Pairing import failed: \(error.localizedDescription)")
        }
    }

    func removePairing() {
        pairingStore.delete()
        pairingStatusMessage = "Pairing record removed."
        if machine.phase.allowsAirLiftFeatures || machine.phase == .transportReady {
            machine.reset()
            steps = Self.initialSteps
        }
    }

    // MARK: - AirLift feature gating

    /// AirLift-dependent features are enabled only after full verification.
    var airLiftFeaturesAllowed: Bool { machine.phase.allowsAirLiftFeatures }

    /// The Files tab (sandbox backend) works regardless of connection state.
    var sandboxFeaturesAllowed: Bool { true }
}
