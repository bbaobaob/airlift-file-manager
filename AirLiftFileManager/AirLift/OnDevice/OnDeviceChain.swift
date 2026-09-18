import Foundation

/// On-device chain: RPPairing record → remote-pairing TCP (discovered port)
/// → pair-verify → tunnel listener → TLS-PSK → CDTunnel → RSD → AFC, then an
/// AFC write/read/remove self-test. Direct port of the flow demonstrated
/// on-device (idevice `open_link` + RSD + AFC), adapted for the LocalDevVPN
/// loopback: every hop is plain TCP to 10.7.0.1 through the tunnel instead
/// of a userspace IPv6/TCP stack (which normal Mac hosts need, but the
/// on-device tunnel already routes).
///
/// Self-guarding: refuses to run without a valid pairing record AND a live
/// tunnel (same gates as AirLiftLaunchGuard), even if invoked directly.
struct OnDeviceChain {
    enum ChainError: Error, Equatable {
        case noPairingRecord
        case invalidPairingRecord(String)
        case tunnelDown
        case noPairingService
        case stepFailed(step: String, reason: String)

        /// User-facing explanation (never includes key material).
        var message: String {
            switch self {
            case .noPairingRecord:
                return "No pairing record stored. Pair this iPhone first."
            case .invalidPairingRecord(let detail):
                return "Stored pairing record is invalid: \(detail)"
            case .tunnelDown:
                return "LocalDevVPN tunnel is not routing (10.7.0.1 unreachable)."
            case .noPairingService:
                return "No _remotepairing service discovered on the local network. " +
                    "Join Wi-Fi, allow Local Network access, then retry."
            case .stepFailed(let step, let reason):
                return "\(step): \(reason)"
            }
        }
    }

    enum Outcome: Equatable {
        case passed(detail: String)
        case failed(step: String, reason: String)
    }

    let pairingStore: any PairingStoring
    let vpnProbe: () async -> Bool
    let discover: () async -> [WirelessPairingDiscovery.DiscoveredService]
    let host: String
    /// Emits user-visible log lines (the SELF-TEST transcript).
    let log: (String) -> Void

    init(pairingStore: any PairingStoring = KeychainPairingStore(),
         vpnProbe: @escaping () async -> Bool = { await LocalDevVPNService().probeTunnel() },
         discover: @escaping () async -> [WirelessPairingDiscovery.DiscoveredService] = {
             await WirelessPairingBrowser().browse()
         },
         host: String = LocalDevVPNService.tunnelHost,
         log: @escaping (String) -> Void = { line in
             AppLogger.airLift.info(line, event: "selftest")
         }) {
        self.pairingStore = pairingStore
        self.vpnProbe = vpnProbe
        self.discover = discover
        self.host = host
        self.log = log
    }

    /// Runs the full chain + self-test. Never throws: every failure becomes
    /// `.failed(step:reason:)` with the exact step that broke.
    func runSelfTest() async -> Outcome {
        do {
            return try await performSelfTest()
        } catch let error as ChainError {
            switch error {
            case .stepFailed(let step, let reason):
                return .failed(step: step, reason: reason)
            default:
                return .failed(step: "preflight", reason: error.message)
            }
        } catch {
            return .failed(step: "unknown", reason: error.localizedDescription)
        }
    }

    private func performSelfTest() async throws -> Outcome {
        // Preflight gates (same rules as the launch guard).
        guard let recordData = pairingStore.load() else {
            throw ChainError.noPairingRecord
        }
        let validation = PairingRecordService.validate(recordData)
        guard validation.isValid else {
            throw ChainError.invalidPairingRecord(validation.message)
        }
        guard await vpnProbe() else {
            throw ChainError.tunnelDown
        }
        emit("RPPairing record loaded")

        // 1. Pair-verify over the discovered _remotepairing port.
        let services = await discover()
        guard let service = pickService(services, recordData: recordData) else {
            if services.isEmpty {
                throw ChainError.noPairingService
            }
            throw ChainError.stepFailed(
                step: "discovery",
                reason: "found \(services.count) _remotepairing service(s) but none accepts " +
                    "this pairing credential (authTag mismatch) — re-pair in StikPair")
        }
        let pairingStream = try await connect(step: "RPPairing tunnel", port: service.port)
        emit("RPPairing tunnel → \(host):\(service.port)")
        var verifier = RemotePairingVerify(stream: pairingStream)
        let credential = try await mapError(step: "pair-verify",
                                              operation: { try RemotePairingVerify.credential(from: recordData) })
        let encryptionKey = try await mapError(step: "pair-verify") {
            try await verifier.run(credential: credential)
        }

        // 2. Ask the device for a tunnel listener.
        let tunnelPort = try await mapError(step: "createListener") {
            try await verifier.createTunnelListener(encryptionKey: encryptionKey)
        }

        // 3. TLS-PSK + CDTunnel on the tunnel port.
        let tunnelStream = try await connect(step: "tunnel TCP", port: tunnelPort)
        let tls = try await mapError(step: "TLS-PSK handshake") {
            try await TLSPskSession.handshake(stream: tunnelStream, psk: encryptionKey)
        }
        try await mapError(step: "CDTunnel handshake") {
            try await tls.writeAppData(CDTunnel.handshakeRequest())
        }
        let rawResponse = try await readCDTunnelResponse(tls: tls)
        let tunnel = try await mapError(step: "CDTunnel handshake") {
            try CDTunnel.parseResponse(rawResponse)
        }
        emit("RSD tunnel established (direct TCP via LocalDevVPN + handshake; RSD port \(tunnel.serverRSDPort))")

        // 4. RSD handshake → AFC port.
        let rsdStream = try await connect(step: "RSD TCP", port: tunnel.serverRSDPort)
        let handshake = try await mapError(step: "RSD handshake") {
            try await RSDClient.handshake(stream: rsdStream)
        }
        guard let afcPort = handshake.port(for: RSDClient.afcServiceName) else {
            throw ChainError.stepFailed(step: "RSD services",
                                        reason: "RSD advertises \(handshake.services.count) service(s) but no \(RSDClient.afcServiceName)")
        }

        // 5. AFC session + write/read/remove self-test.
        let afcStream = try await connect(step: "AFC TCP", port: afcPort)
        var afc = AFCClient(stream: afcStream)
        try await mapError(step: "AFC checkin") { try await afc.checkin() }
        emit("AFC connected (over RSD)")

        let stamp = Int(Date().timeIntervalSince1970)
        let markerName = "airlift-mini-ok-\(stamp).txt"
        let markerBody = Data("airlift on-device self-test \(stamp)\n".utf8)

        let writeFD = try await mapError(step: "AFC file open (write)") {
            try await afc.open(path: markerName, mode: .writeOnly)
        }
        emit("AFC file open (write) OK — \(markerName)")
        try await mapError(step: "AFC write") { try await afc.write(fd: writeFD, data: markerBody) }
        try await mapError(step: "AFC close (write)") { try await afc.close(fd: writeFD) }
        emit("AFC write OK (\(markerBody.count) bytes)")

        let readFD = try await mapError(step: "AFC file open (read)") {
            try await afc.open(path: markerName, mode: .readOnly)
        }
        let readBack = try await mapError(step: "AFC read") { try await afc.readAll(fd: readFD) }
        try await mapError(step: "AFC close (read)") { try await afc.close(fd: readFD) }
        guard readBack == markerBody else {
            throw ChainError.stepFailed(step: "AFC read-back",
                                        reason: "byte mismatch (wrote \(markerBody.count), read \(readBack.count))")
        }
        emit("AFC read-back verified: \(readBack.count) bytes match")

        try await mapError(step: "AFC cleanup") { try await afc.remove(path: markerName) }
        emit("AFC cleanup done (marker removed)")
        emit("SELF-TEST PASSED ✓ (RSD tunnel + AFC write/read/remove)")

        pairingStream.close()
        return .passed(detail: "RSD tunnel + AFC write/read/remove verified (\(markerBody.count) bytes)")
    }

    // MARK: - Launch-guard executor

    /// What Start AirLift executes: the real on-device chain above.
    /// Maps the self-test outcome to the guard's launch states — a pass
    /// means exactly what was verified (AFC-scope file access), never more.
    /// The guard invokes execute() serially (busy/starting gates), which is
    /// what the unchecked conformance relies on.
    final class Launcher: AirLiftExecuting, @unchecked Sendable {
        let chain: OnDeviceChain

        init(chain: OnDeviceChain = OnDeviceChain()) {
            self.chain = chain
        }

        func execute() async -> AirLiftExecutionOutcome {
            switch await chain.runSelfTest() {
            case .passed(let detail):
                return .started(detail: "On-device chain verified: \(detail). " +
                    "Scope: AFC file access only — not /var/mobile.")
            case .failed(let step, let reason):
                return .failed(reason: "On-device chain failed at \(step): \(reason)")
            }
        }
    }

    // MARK: - Steps

    private func emit(_ line: String) {
        AppLogger.airLift.info(line, event: "selftest")
        log(line)
    }

    private func pickService(_ services: [WirelessPairingDiscovery.DiscoveredService],
                             recordData: Data) -> WirelessPairingDiscovery.DiscoveredService? {
        // Prefer a service that accepts our credential (authTag check first),
        // like idevice's find_remote_pairing. Unresolved entries (port 0)
        // cannot be dialed.
        guard let altIrk = CapabilityProbeService.altIrk(from: recordData) else {
            return services.first { $0.port != 0 }
        }
        return services.first {
            $0.port != 0 && WirelessPairingDiscovery.matchesCredential(service: $0, altIrk: altIrk)
        }
    }

    private func connect(step: String, port: UInt16) async throws -> TCPStream {
        do {
            return try await TCPStream(host: host, port: port)
        } catch {
            throw ChainError.stepFailed(step: step, reason: "TCP \(host):\(port) failed: \(error)")
        }
    }

    private func mapError<T>(step: String, operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as ChainError {
            throw error
        } catch {
            throw ChainError.stepFailed(step: step, reason: String(describing: error))
        }
    }

    private func readCDTunnelResponse(tls: TLSPskSession) async throws -> Data {
        // Response framing: "CDTunnel" + u16BE length + JSON. Read enough for
        // the header first, then the body.
        var buffer = try await tls.readAppData()
        while buffer.count < CDTunnel.magic.count + 2 {
            buffer.append(contentsOf: try await tls.readAppData())
        }
        let length = Int(RPPairingWire.be16(buffer, at: CDTunnel.magic.count))
        while buffer.count < CDTunnel.magic.count + 2 + length {
            buffer.append(contentsOf: try await tls.readAppData())
        }
        return buffer
    }
}
