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
/// 1. Tunnel routes to the device? (lockdown 62078, else the remotepairing
///    endpoint our chain actually uses — cached port first, then discovery;
///    the port is always re-verified, never trusted)
/// 2. Pairing File present?  3. Pairing File valid?
/// 4. Remotepairing transport reachable? (fresh TCP to the endpoint)
/// 5. Target device responds? (real pair-verify with our credential)
/// Stops at the first blocking gate and reports its exact reason.
///
/// Why not lockdown 62078: the on-device chain (pair-verify → tunnel →
/// RSD → AFC) never touches lockdown. Setups where only the remotepairing
/// port is bridged are fully working setups — blocking them on lockdown
/// was the real cause of "Preflight blocked: transport unreachable".
/// Lockdown is still probed opportunistically for diagnostics, never gating.
struct AirLiftPreflightChecker: Sendable {
    let vpnProbe: @Sendable () async -> Bool
    let lockdownProbe: @Sendable () async -> LockdownProbeResult
    let remoteConnect: @Sendable (UInt16) async -> Bool
    let discover: @Sendable () async -> [WirelessPairingDiscovery.DiscoveredService]
    let verifyDevice: @Sendable (Data, UInt16) async -> String?
    let pairingStore: any PairingStoring
    let host: String

    static let cachedPortKey = "airlift.tunnel.remotepairingPort"

    init(vpnProbe: @escaping @Sendable () async -> Bool = {
             await LocalDevVPNService().probeTunnel()
         },
         lockdownProbe: @escaping @Sendable () async -> LockdownProbeResult = {
             await LockdownClient.probeDevice()
         },
         remoteConnect: (@Sendable (UInt16) async -> Bool)? = nil,
         discover: (@Sendable () async -> [WirelessPairingDiscovery.DiscoveredService])? = nil,
         verifyDevice: (@Sendable (Data, UInt16) async -> String?)? = nil,
         pairingStore: any PairingStoring = KeychainPairingStore(),
         host: String = LocalDevVPNService.tunnelHost) {
        self.vpnProbe = vpnProbe
        self.lockdownProbe = lockdownProbe
        self.pairingStore = pairingStore
        self.host = host
        let tunnelHost = host
        self.remoteConnect = remoteConnect ?? { port in
            do {
                let stream = try await TCPStream(host: tunnelHost, port: port, timeout: 3)
                stream.close()
                return true
            } catch {
                return false
            }
        }
        self.discover = discover ?? {
            await WirelessPairingBrowser().browse(timeout: 4)
        }
        self.verifyDevice = verifyDevice ?? { record, port in
            await Self.verifyDeviceRecord(record, port: port, host: tunnelHost)
        }
    }

    /// Non-secret port cache (just a number; always re-verified by connecting).
    static func cachedRemotePort() -> UInt16 {
        UInt16(clamping: UserDefaults.standard.integer(forKey: cachedPortKey))
    }

    static func setCachedRemotePort(_ port: UInt16) {
        UserDefaults.standard.set(Int(port), forKey: cachedPortKey)
    }

    /// Real pair-verify against the device using the stored credential.
    /// Returns nil when the device completes the exchange, else the reason.
    static func verifyDeviceRecord(_ record: Data, port: UInt16,
                                   host: String) async -> String? {
        do {
            let stream = try await TCPStream(host: host, port: port, timeout: 6)
            defer { stream.close() }
            var verifier = RemotePairingVerify(stream: stream)
            let credential = try RemotePairingVerify.credential(from: record)
            _ = try await verifier.run(credential: credential)
            AppLogger.net.info("Pair-verify completed with the device",
                               event: "preflight")
            return nil
        } catch let error as RemotePairingVerify.VerifyError {
            switch error {
            case .badCredential(let message):
                return "pairing credential unusable: \(message)"
            case .protocolError(let message):
                return "pair-verify rejected: \(message)"
            case .cryptoFailure(let message):
                return "pair-verify crypto failed: \(message)"
            }
        } catch {
            return "pair-verify transport failed: \(error.localizedDescription)"
        }
    }

    /// Local classification (no network): presence + key validation.
    /// Accepts both the classic lockdown format and the StikPair
    /// remote-pairing format (wireless pairing credential).
    func classifyPairing() -> PairingCheckStatus {
        pairingStore.migrateLegacyFileIfNeeded()
        guard let data = pairingStore.load() else { return .notImported }
        let validation = PairingRecordService.validate(data)
        if validation.isValid { return .imported }
        // format == nil: the stored data is not a recognized pairing record.
        if validation.format == nil { return .unsupported }
        return .invalid
    }

    func runPreflight() async -> AirLiftPreflightResult {
        AppLogger.vpn.info("AirLift preflight started", event: "preflight")
        let pairing = classifyPairing()

        // Gate 1: the tunnel routes to this device. Fast lockdown probe
        // first; otherwise the remotepairing endpoint (cached port, then
        // fresh discovery). Success is always a live TCP connect.
        var viaDescription = ""
        if await vpnProbe() {
            viaDescription = "lockdown 10.7.0.1:62078"
        } else if await firstDialableRemotePort() != nil {
            viaDescription = "remotepairing endpoint (cached, re-verified live)"
        } else {
            let reason = "LocalDevVPN tunnel is not routing to this device — neither " +
                "lockdown 10.7.0.1:62078 nor any _remotepairing port answered. AirLift " +
                "is Locked: connect LocalDevVPN, join Wi-Fi, allow Local Network access, " +
                "then Recheck Connection."
            AppLogger.vpn.warning("Preflight blocked at VPN gate", event: "preflight")
            return AirLiftPreflightResult(vpnStatus: .disconnected, pairingStatus: pairing,
                                          transportReachable: false, deviceResponded: false,
                                          failureReason: reason)
        }
        AppLogger.vpn.info("Tunnel routes to device via \(viaDescription)", event: "preflight")

        // Gates 2–3: pairing presence + validity.
        switch pairing {
        case .notImported:
            let reason = "No Pairing File imported. AirLift is Locked — pair this iPhone " +
                "here (Pair This iPhone) or import a pairing record."
            AppLogger.pairing.warning("Preflight blocked: pairing file missing", event: "preflight")
            return AirLiftPreflightResult(vpnStatus: .connected, pairingStatus: pairing,
                                          transportReachable: false, deviceResponded: false,
                                          failureReason: reason)
        case .invalid:
            let reason = "The imported Pairing File is invalid (not a complete lockdown or " +
                "remote-pairing record). " +
                "AirLift is Locked — pair this iPhone here or import a valid record."
            AppLogger.pairing.warning("Preflight blocked: pairing file invalid", event: "preflight")
            return AirLiftPreflightResult(vpnStatus: .connected, pairingStatus: pairing,
                                          transportReachable: false, deviceResponded: false,
                                          failureReason: reason)
        case .expired:
            let reason = "The Pairing File has expired. AirLift is Locked — pair this " +
                "iPhone here and import the new record."
            AppLogger.pairing.warning("Preflight blocked: pairing file expired", event: "preflight")
            return AirLiftPreflightResult(vpnStatus: .connected, pairingStatus: pairing,
                                          transportReachable: false, deviceResponded: false,
                                          failureReason: reason)
        case .unsupported:
            let reason = "The imported file is not a supported pairing record. AirLift is " +
                "Locked — pair this iPhone here or import a StikPair/iloader record."
            AppLogger.pairing.warning("Preflight blocked: pairing file unsupported", event: "preflight")
            return AirLiftPreflightResult(vpnStatus: .connected, pairingStatus: pairing,
                                          transportReachable: false, deviceResponded: false,
                                          failureReason: reason)
        case .imported:
            break
        }

        // Gate 4: remotepairing transport — a fresh TCP connect to the
        // endpoint the real chain dials first. (Lockdown 62078 is probed
        // below for diagnostics only; it never gates.)
        // firstDialableRemotePort reuses the gate-1 result via the cache,
        // so discovery runs at most once per preflight.
        guard let remotePort = await firstDialableRemotePort(),
              await remoteConnect(remotePort) else {
            let reason = "No _remotepairing endpoint answered over the tunnel, so the " +
                "on-device chain cannot start. AirLift is Locked: keep LocalDevVPN " +
                "connected and Wi-Fi on, then Recheck Connection."
            AppLogger.net.error("Preflight blocked: no remotepairing endpoint", event: "preflight")
            return AirLiftPreflightResult(vpnStatus: .connected, pairingStatus: pairing,
                                          transportReachable: false, deviceResponded: false,
                                          failureReason: reason)
        }

        // Supplementary lockdown exchange (informational only).
        let lockdown = await lockdownProbe()
        if lockdown.reachable {
            AppLogger.net.info("Lockdown supplementary check answered " +
                "(\(lockdown.queryType ?? "?")) — informational only", event: "preflight")
        } else {
            AppLogger.net.info("Lockdown supplementary check unreachable " +
                "(\(lockdown.error ?? "no route")) — informational only, not blocking",
                event: "preflight")
        }

        // Gate 5: the device completes a real pair-verify with our credential.
        guard let recordData = pairingStore.load() else {
            let reason = "Pairing record vanished mid-check. AirLift is Locked."
            return AirLiftPreflightResult(vpnStatus: .connected, pairingStatus: pairing,
                                          transportReachable: true, deviceResponded: false,
                                          failureReason: reason)
        }
        if let problem = await verifyDevice(recordData, remotePort) {
            let reason = "Target device did not complete pair-verify: \(problem). " +
                "AirLift is Locked."
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

    /// First remotepairing port that answers a live TCP connect (cached port
    /// first, then fresh discovery). Caches winners for next time.
    private func firstDialableRemotePort() async -> UInt16? {
        let cached = Self.cachedRemotePort()
        if cached != 0, await remoteConnect(cached) {
            return cached
        }
        for service in await discover() where service.port != 0 {
            if await remoteConnect(service.port) {
                Self.setCachedRemotePort(service.port)
                return service.port
            }
        }
        return nil
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
         remoteConnect: (@Sendable (UInt16) async -> Bool)? = nil,
         discover: (@Sendable () async -> [WirelessPairingDiscovery.DiscoveredService])? = nil,
         verifyDevice: (@Sendable (Data, UInt16) async -> String?)? = nil,
         launcher: AirLiftExecuting = OnDeviceChain.Launcher(),
         watchdogInterval: TimeInterval = 3.0) {
        self.pairingStore = pairingStore
        self.launcher = launcher
        self.watchdogInterval = watchdogInterval
        self.checker = AirLiftPreflightChecker(vpnProbe: vpnProbe,
                                               lockdownProbe: lockdownProbe,
                                               remoteConnect: remoteConnect,
                                               discover: discover,
                                               verifyDevice: verifyDevice,
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
            guard !data.isEmpty else {
                pairingStatusMessage = "Import rejected: the selected file is empty (0 bytes)."
                AppLogger.pairing.error("Pairing import failed: empty file \(sourceURL.lastPathComponent)",
                                        event: "pairing.import")
                return
            }
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
