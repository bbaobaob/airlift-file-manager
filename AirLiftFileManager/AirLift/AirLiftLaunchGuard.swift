import Foundation

// MARK: - Status models (spec: AirLift Startup Requirements)

/// LocalDevVPN status as shown on the setup screen.
enum VPNCheckStatus: String, Equatable {
    case connected = "Connected"
    case disconnected = "Disconnected"
    case checking = "Checking"
    case permissionRequired = "Permission Required"
}

/// Pairing File status. `expired`/`unsupported` are used only when they can
/// actually be determined — never guessed.
enum PairingCheckStatus: String, Equatable {
    case notImported = "Not Imported"
    case imported = "Imported"
    case invalid = "Invalid"
    case expired = "Expired"
    case unsupported = "Unsupported"
}

/// AirLift launch state. `running` is reachable only through a verified
/// executor; this build's on-device executor honestly reports
/// "Transport unavailable" instead of faking a Running state.
enum AirLiftLaunchState: String, Equatable {
    case locked = "Locked"
    case readyToStart = "Ready to Start"
    case starting = "Starting"
    case running = "Running"
    case failed = "Failed"
    case disconnected = "Disconnected"
}

/// Result of one preflight run. `failureReason` carries the EXACT blocking
/// reason for display and Technical Logs.
struct AirLiftPreflightResult: Equatable {
    let vpnStatus: VPNCheckStatus
    let pairingStatus: PairingCheckStatus
    let transportReachable: Bool
    let deviceResponded: Bool
    let failureReason: String?

    var passed: Bool { failureReason == nil }
}

// MARK: - Preflight checker

/// Runs the mandatory startup checks in order:
/// 1. LocalDevVPN connected?  2. Pairing File present?  3. Pairing File valid?
/// 4. Transport reachable?  5. Target device responds?
/// Stops at the first blocking gate and reports its exact reason.
struct AirLiftPreflightChecker: Sendable {
    let vpnProbe: @Sendable () async -> Bool
    let lockdownProbe: @Sendable () async -> LockdownProbeResult
    let pairingStore: any PairingStoring

    init(vpnProbe: @escaping @Sendable () async -> Bool = {
             await LocalDevVPNService().probeTunnel()
         },
         lockdownProbe: @escaping @Sendable () async -> LockdownProbeResult = {
             await LockdownClient.probeDevice()
         },
         pairingStore: any PairingStoring = KeychainPairingStore()) {
        self.vpnProbe = vpnProbe
        self.lockdownProbe = lockdownProbe
        self.pairingStore = pairingStore
    }

    /// Local classification (no network): presence + key validation.
    func classifyPairing() -> PairingCheckStatus {
        pairingStore.migrateLegacyFileIfNeeded()
        guard let data = pairingStore.load() else { return .notImported }
        let validation = PairingRecordService.validate(data)
        if validation.isValid { return .imported }
        // A record that carries none of the lockdown keys cannot come from a
        // lockdown pairing at all.
        if validation.presentKeys.isEmpty { return .unsupported }
        return .invalid
    }

    func runPreflight() async -> AirLiftPreflightResult {
        AppLogger.vpn.info("AirLift preflight started", event: "preflight")
        let pairing = classifyPairing()

        // Gate 1: LocalDevVPN.
        let vpnUp = await vpnProbe()
        guard vpnUp else {
            let reason = "LocalDevVPN is not connected. AirLift is Locked — connect LocalDevVPN " +
                "(or SideStore StosVPN), keep Wi-Fi on, then Recheck Connection."
            AppLogger.vpn.warning("Preflight blocked at VPN gate", event: "preflight")
            return AirLiftPreflightResult(vpnStatus: .disconnected, pairingStatus: pairing,
                                          transportReachable: false, deviceResponded: false,
                                          failureReason: reason)
        }

        // Gates 2–3: pairing presence + validity.
        switch pairing {
        case .notImported:
            let reason = "No Pairing File imported. AirLift is Locked — pair on-device with " +
                "StikPair (Developer Mode → Pair with StikPair), export the plist, and import it here."
            AppLogger.pairing.warning("Preflight blocked: pairing file missing", event: "preflight")
            return AirLiftPreflightResult(vpnStatus: .connected, pairingStatus: pairing,
                                          transportReachable: false, deviceResponded: false,
                                          failureReason: reason)
        case .invalid:
            let reason = "The imported Pairing File is invalid (required lockdown keys are missing). " +
                "AirLift is Locked — re-export from StikPair and import again."
            AppLogger.pairing.warning("Preflight blocked: pairing file invalid", event: "preflight")
            return AirLiftPreflightResult(vpnStatus: .connected, pairingStatus: pairing,
                                          transportReachable: false, deviceResponded: false,
                                          failureReason: reason)
        case .expired:
            let reason = "The Pairing File has expired. AirLift is Locked — re-pair with StikPair " +
                "and import the new record."
            AppLogger.pairing.warning("Preflight blocked: pairing file expired", event: "preflight")
            return AirLiftPreflightResult(vpnStatus: .connected, pairingStatus: pairing,
                                          transportReachable: false, deviceResponded: false,
                                          failureReason: reason)
        case .unsupported:
            let reason = "The imported file is not a supported lockdown pairing record. AirLift is " +
                "Locked — export the pairing plist from StikPair and import that file."
            AppLogger.pairing.warning("Preflight blocked: pairing file unsupported", event: "preflight")
            return AirLiftPreflightResult(vpnStatus: .connected, pairingStatus: pairing,
                                          transportReachable: false, deviceResponded: false,
                                          failureReason: reason)
        case .imported:
            break
        }

        // Gates 4–5: transport reachability + device response (real exchange).
        let lockdown = await lockdownProbe()
        guard lockdown.reachable else {
            let reason = "Transport unavailable: lockdown did not answer over the tunnel " +
                "(\(lockdown.error ?? "unknown error")). AirLift is Locked."
            AppLogger.net.error("Preflight blocked: transport unreachable", event: "preflight")
            return AirLiftPreflightResult(vpnStatus: .connected, pairingStatus: pairing,
                                          transportReachable: false, deviceResponded: false,
                                          failureReason: reason)
        }
        guard lockdown.queryType != nil else {
            let reason = "Target device did not respond to the lockdown plist exchange. AirLift is Locked."
            AppLogger.net.error("Preflight blocked: device did not respond", event: "preflight")
            return AirLiftPreflightResult(vpnStatus: .connected, pairingStatus: pairing,
                                          transportReachable: true, deviceResponded: false,
                                          failureReason: reason)
        }

        AppLogger.airLift.info("AirLift preflight passed (all gates)", event: "preflight")
        return AirLiftPreflightResult(vpnStatus: .connected, pairingStatus: pairing,
                                      transportReachable: true, deviceResponded: true,
                                      failureReason: nil)
    }
}

// MARK: - Launch executor seam

enum AirLiftExecutionOutcome: Equatable {
    /// A real execution channel was verified and started.
    case started(detail: String)
    /// The launch cannot proceed on this device — reported honestly
    /// (no fake Running state).
    case unavailable(reason: String)
    /// The attempt was made and failed.
    case failed(reason: String)
}

/// The ONLY way AirLift actually starts. UI never launches AirLift directly —
/// everything goes through AirLiftLaunchGuard, which delegates here after a
/// full preflight.
protocol AirLiftExecuting: Sendable {
    func execute() async -> AirLiftExecutionOutcome
}

/// Current on-device reality: the AirLift exploit executes inside
/// AirTrafficHost.framework on a paired macOS host. There is no on-device
/// execution channel yet, so this executor refuses — loudly and honestly.
struct TransportUnavailableLauncher: AirLiftExecuting {
    func execute() async -> AirLiftExecutionOutcome {
        AppLogger.airLift.error("Launch refused: on-device AirLift execution is not implemented", event: "guard.launch")
        return .unavailable(reason:
            "Transport unavailable: AirLift executes inside AirTrafficHost.framework on a paired " +
            "macOS host. On-device execution is not implemented in this build, so no Running " +
            "state is shown. Run airlift from a paired Mac, or add a Mac-host relay behind the " +
            "AirLiftExecuting seam.")
    }
}

// MARK: - Launch guard

/// Single authority for AirLift launches.
///
/// Rules enforced (spec: AirLift Execution Rules):
/// - Every launch re-runs the full preflight — no cached permission.
/// - Any failed gate refuses the launch with the exact reason, logged to
///   Technical Logs; the user can retry.
/// - If the tunnel drops while running, the watchdog stops everything safely
///   and flips the state to Locked/Disconnected — never a fake success.
@MainActor
final class AirLiftLaunchGuard: ObservableObject {
    @Published private(set) var launchState: AirLiftLaunchState = .locked
    @Published private(set) var vpnStatus: VPNCheckStatus = .checking
    @Published private(set) var pairingStatus: PairingCheckStatus = .notImported
    @Published private(set) var lastPreflight: AirLiftPreflightResult?
    @Published private(set) var lastFailureReason: String?
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheckedAt: Date?
    @Published var pairingStatusMessage: String

    let pairingStore: any PairingStoring

    private let checker: AirLiftPreflightChecker
    private let launcher: AirLiftExecuting
    private let watchdogInterval: TimeInterval
    private var watchdogTask: Task<Void, Never>?

    init(pairingStore: any PairingStoring = KeychainPairingStore(),
         vpnProbe: @escaping @Sendable () async -> Bool = {
             await LocalDevVPNService().probeTunnel()
         },
         lockdownProbe: @escaping @Sendable () async -> LockdownProbeResult = {
             await LockdownClient.probeDevice()
         },
         launcher: AirLiftExecuting = TransportUnavailableLauncher(),
         watchdogInterval: TimeInterval = 3.0) {
        self.pairingStore = pairingStore
        self.launcher = launcher
        self.watchdogInterval = watchdogInterval
        self.checker = AirLiftPreflightChecker(vpnProbe: vpnProbe,
                                               lockdownProbe: lockdownProbe,
                                               pairingStore: pairingStore)
        pairingStatusMessage = pairingStore.hasRecord
            ? "Pairing record stored in Keychain."
            : "No pairing record imported yet."
        AppLogger.app.info("AirLiftLaunchGuard init (state: Locked)", event: "guard.init")
    }

    deinit {
        watchdogTask?.cancel()
    }

    /// Start AirLift is enabled only when VPN is Connected AND the pairing
    /// file is imported AND preflight has reached Ready to Start.
    var canStartAirLift: Bool {
        vpnStatus == .connected
            && pairingStatus == .imported
            && launchState == .readyToStart
    }

    var setupSummary: String {
        switch launchState {
        case .locked:
            return lastFailureReason ?? "Requirements are not met yet."
        case .readyToStart:
            return "All requirements met. AirLift can start."
        case .starting:
            return "Starting AirLift…"
        case .running:
            return "AirLift is running."
        case .failed:
            return lastFailureReason ?? "The last attempt failed."
        case .disconnected:
            return lastFailureReason ?? "The connection dropped."
        }
    }

    // MARK: - Recheck (spec: Recheck Connection)

    func recheckConnection() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        vpnStatus = .checking
        let result = await checker.runPreflight()
        apply(result)
        lastCheckedAt = Date()
    }

    private func apply(_ result: AirLiftPreflightResult) {
        vpnStatus = result.vpnStatus
        pairingStatus = result.pairingStatus
        lastPreflight = result
        if let reason = result.failureReason {
            launchState = .locked
            lastFailureReason = reason
        } else {
            launchState = .readyToStart
            lastFailureReason = nil
        }
    }

    // MARK: - Launch (spec: all launches go through the guard)

    func startAirLift() async {
        guard launchState != .starting, launchState != .running else { return }
        // Full preflight before EVERY launch — never trust a cached pass.
        isChecking = true
        let result = await checker.runPreflight()
        isChecking = false
        apply(result)
        lastCheckedAt = Date()
        guard result.passed else {
            AppLogger.airLift.error(
                "Launch refused by preflight: \(result.failureReason ?? "unknown")",
                event: "guard.launch")
            return
        }

        launchState = .starting
        AppLogger.airLift.info("AirLift starting (preflight passed)", event: "guard.launch")
        let outcome = await launcher.execute()
        switch outcome {
        case .started(let detail):
            launchState = .running
            lastFailureReason = nil
            AppLogger.airLift.info("AirLift running: \(detail)", event: "guard.launch")
            startWatchdog()
        case .unavailable(let reason):
            launchState = .failed
            lastFailureReason = reason
            AppLogger.airLift.error("AirLift launch unavailable: \(reason)", event: "guard.launch")
        case .failed(let reason):
            launchState = .failed
            lastFailureReason = reason
            AppLogger.airLift.error("AirLift launch failed: \(reason)", event: "guard.launch")
        }
    }

    /// Stops any running/starting attempt safely (tunnel drop, user request).
    func stopIfRunning(reason: String, newState: AirLiftLaunchState = .locked) {
        guard launchState == .running || launchState == .starting else { return }
        watchdogTask?.cancel()
        watchdogTask = nil
        launchState = newState
        lastFailureReason = reason
        AppLogger.airLift.warning("AirLift stopped: \(reason)", event: "guard.watchdog")
    }

    // MARK: - Tunnel watchdog

    /// While running, polls the tunnel; a drop stops everything safely.
    private func startWatchdog() {
        watchdogTask?.cancel()
        let interval = watchdogInterval
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, self.launchState == .running, !Task.isCancelled else { return }
                let up = await self.checker.vpnProbe()
                if !up {
                    self.stopIfRunning(reason:
                        "LocalDevVPN dropped while AirLift was running. Current work was stopped " +
                        "safely and no success state is shown.",
                        newState: .disconnected)
                    return
                }
                AppLogger.vpn.debug("Watchdog: tunnel still up", event: "guard.watchdog")
            }
        }
    }

    // MARK: - Pairing actions (Keychain-backed, never logged)

    func importPairing(from sourceURL: URL) async {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: sourceURL)
            let result = pairingStore.importRecord(data)
            pairingStatusMessage = result.isValid
                ? result.message
                : "Import rejected: \(result.message)"
            AppLogger.pairing.info(
                result.isValid ? "Pairing imported and stored in Keychain"
                               : "Pairing import rejected", event: "pairing.import")
        } catch {
            pairingStatusMessage = "Could not read pairing file: \(error.localizedDescription)"
            AppLogger.pairing.error("Pairing import failed: \(error.localizedDescription)",
                                    event: "pairing.import")
        }
    }

    func removePairing() {
        pairingStore.delete()
        pairingStatusMessage = "Pairing record removed."
        AppLogger.pairing.info("Pairing record removed", event: "pairing.remove")
        if launchState == .readyToStart {
            launchState = .locked
            lastFailureReason = "Pairing File removed. AirLift is Locked until a valid record is imported."
        }
    }
}
