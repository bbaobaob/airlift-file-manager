import Foundation

/// One independently verified capability. Every status comes from a real
/// check — never from defaults, flags, or wishes.
struct CapabilityCheck: Identifiable, Equatable {
    enum Status: String {
        case passed = "Verified"
        case failed = "Failed"
        case notAvailable = "Not available"
        case notImplemented = "Not implemented"
        case skipped = "Skipped"
    }

    let id: String
    let status: Status
    let detail: String

    var isError: Bool { status == .failed }
}

/// Full capability report produced by one diagnostic run.
struct CapabilityReport: Equatable {
    let startedAt: Date
    let finishedAt: Date
    let checks: [CapabilityCheck]

    var passedCount: Int { checks.filter { $0.status == .passed }.count }
    var failureCount: Int { checks.filter { $0.isError }.count }

    /// Lockdown transport verified end-to-end (tunnel + real plist exchange)?
    var transportReady: Bool {
        checks.first { $0.id == "lockdown.exchange" }?.status == .passed
    }

    /// Plain-text diagnostic report for Copy/Export.
    func text(bundleVersion: String) -> String {
        var lines: [String] = []
        lines.append("AirLift File Manager — Diagnostic Report")
        lines.append("Generated: \(Formatters.date(startedAt))")
        lines.append("App build: \(bundleVersion)")
        lines.append("")
        for check in checks {
            lines.append("[\(check.status.rawValue)] \(check.id)")
            lines.append("    \(check.detail)")
        }
        lines.append("")
        lines.append("Passed \(passedCount) · Failed \(failureCount) of \(checks.count) checks")
        lines.append("Note: a reachable lockdown endpoint proves transport only — it is NOT")
        lines.append("proof of AirLift exploit access or out-of-sandbox filesystem writes.")
        return lines.joined(separator: "\n")
    }
}

protocol CapabilityProbing: Sendable {
    func run() async -> CapabilityReport
}

/// Runs every capability check independently and records honest results.
struct CapabilityProbeService: CapabilityProbing {
    let vpnProbe: () async -> Bool
    let lockdownProbe: () async -> LockdownProbeResult
    let pairingStore: any PairingStoring

    init(vpnProbe: @escaping () async -> Bool = { await LocalDevVPNService().probeTunnel() },
         lockdownProbe: @escaping () async -> LockdownProbeResult = {
             await LockdownClient.probeDevice()
         },
         pairingStore: any PairingStoring = KeychainPairingStore()) {
        self.vpnProbe = vpnProbe
        self.lockdownProbe = lockdownProbe
        self.pairingStore = pairingStore
    }

    func run() async -> CapabilityReport {
        AppLogger.airLift.info("Capability probe started")
        let start = Date()
        var checks: [CapabilityCheck] = []

        // 1. Tunnel reachability — real TCP connect.
        let tunnelUp = await vpnProbe()
        checks.append(CapabilityCheck(
            id: "tunnel.reachability",
            status: tunnelUp ? .passed : .failed,
            detail: tunnelUp
                ? "10.7.0.1:62078 answered a TCP connect (LocalDevVPN/StosVPN-style tunnel up)."
                : "10.7.0.1:62078 did not answer. Install or connect LocalDevVPN (or SideStore StosVPN) and keep Wi-Fi on."))

        // 2. Lockdown exchange — real binary-plist QueryType round trip.
        var lockdown: LockdownProbeResult?
        if tunnelUp {
            lockdown = await lockdownProbe()
            if lockdown?.reachable == true {
                var facts = ["QueryType=\(lockdown?.queryType ?? "?")"]
                if let v = lockdown?.productVersion { facts.append("iOS \(v)") }
                if let p = lockdown?.productType { facts.append(p) }
                checks.append(CapabilityCheck(
                    id: "lockdown.exchange", status: .passed,
                    detail: "Lockdown plist exchange verified over the tunnel (\(facts.joined(separator: ", ")))."))
            } else {
                checks.append(CapabilityCheck(
                    id: "lockdown.exchange", status: .failed,
                    detail: lockdown?.error ?? "Lockdown did not answer although the tunnel is up."))
            }
        } else {
            checks.append(CapabilityCheck(
                id: "lockdown.exchange", status: .skipped,
                detail: "Skipped: tunnel not reachable."))
        }

        // 3. Pairing record — presence + validity of the imported record.
        pairingStore.migrateLegacyFileIfNeeded()
        let metadata = pairingStore.metadata()
        if metadata.isValid {
            checks.append(CapabilityCheck(
                id: "pairing.record", status: .passed,
                detail: "Valid pairing record in Keychain (keys: \(metadata.presentKeyNames.joined(separator: ", ")))."))
        } else if pairingStore.hasRecord {
            checks.append(CapabilityCheck(
                id: "pairing.record", status: .failed,
                detail: "Stored pairing record is invalid or incomplete. Re-export from StikPair and import again."))
        } else {
            checks.append(CapabilityCheck(
                id: "pairing.record", status: .notAvailable,
                detail: "No pairing record imported. Pair on-device with StikPair (Developer Mode) and import the exported plist."))
        }

        // 4. Trusted lockdown session (StartService with pairing identity) —
        //    TLS client identity from the pairing record is plumbed, but the
        //    authenticated StartService flow is not implemented on-device yet.
        checks.append(CapabilityCheck(
            id: "lockdown.trusted-session", status: .notImplemented,
            detail: "Authenticated lockdown session (StartService: com.apple.afc and friends) using the imported pairing identity is not implemented in this build."))

        // 5. AirLift on-device execution — impossible in-process; documented.
        checks.append(CapabilityCheck(
            id: "airlift.on-device", status: .notImplemented,
            detail: "The AirLift exploit executes inside AirTrafficHost.framework on a paired macOS host. A sandboxed iOS app cannot run that chain, and no Mac-host relay exists yet. Writes to the verified scope therefore require running airlift from a paired Mac."))

        // 6. Sandbox scope — what THIS app can really touch.
        let reports = PermissionService().probeAll()
        let browsable = reports.filter { $0.level.canBrowse }.count
        let writable = reports.filter { $0.level.canWrite }.count
        checks.append(CapabilityCheck(
            id: "sandbox.scope", status: .passed,
            detail: "Probed \(reports.count) spec paths from this sandbox: \(browsable) browsable, \(writable) writable. See the Files tab for per-path status."))

        let report = CapabilityReport(startedAt: start, finishedAt: Date(), checks: checks)
        AppLogger.airLift.info("Capability probe finished: passed=\(report.passedCount) failed=\(report.failureCount)")
        return report
    }
}
