import Foundation

/// Establishes the front half of the on-device chain, shared by the AFC
/// self-test and the Books flow: discovery → pair-verify → tunnel listener →
/// TLS-PSK → CDTunnel → RSD handshake. Returns the RSD service table so
/// callers can dial any advertised service (AFC, streaming_zip_conduit, …)
/// straight through the LocalDevVPN tunnel.
struct RSDEstablisher {
    struct Established {
        let handshake: RSDClient.Handshake
        let pairingPort: UInt16
        let tunnelPort: UInt16
        let rsdPort: UInt16
        /// Held open for the session: the tunnel must stay up while tunneled
        /// connections (or direct dials alongside it) are in use, and the
        /// connector dials every subsequent service port (direct-first,
        /// packet-layer fallback).
        let connector: TunnelConnector
    }

    let host: String
    let discover: () async -> [WirelessPairingDiscovery.DiscoveredService]
    let log: (String) -> Void
    let timeout: TimeInterval

    init(host: String = LocalDevVPNService.tunnelHost,
         discover: @escaping () async -> [WirelessPairingDiscovery.DiscoveredService] = {
             await WirelessPairingBrowser().browse()
         },
         log: @escaping (String) -> Void = { line in
             AppLogger.airLift.info(line, event: "rsd")
         },
         timeout: TimeInterval = 10) {
        self.host = host
        self.discover = discover
        self.log = log
        self.timeout = timeout
    }

    func establish(recordData: Data) async throws -> Established {
        let services = await discover()
        guard let service = pickService(services, recordData: recordData) else {
            if services.isEmpty {
                throw OnDeviceChain.ChainError.noPairingService
            }
            throw OnDeviceChain.ChainError.stepFailed(
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

        let tunnelPort = try await mapError(step: "createListener") {
            try await verifier.createTunnelListener(encryptionKey: encryptionKey)
        }

        let tunnelStream = try await connect(step: "tunnel TCP", port: tunnelPort)
        let tls = try await mapError(step: "TLS-PSK handshake") {
            try await TLSPskSession.handshake(stream: tunnelStream, psk: encryptionKey,
                                              timeout: timeout)
        }
        try await mapError(step: "CDTunnel handshake") {
            try await tls.writeAppData(CDTunnel.handshakeRequest(), timeout: timeout)
        }
        var buffer = try await tls.readAppData(timeout: timeout)
        while buffer.count < CDTunnel.magic.count + 2 {
            buffer.append(contentsOf: try await tls.readAppData(timeout: timeout))
        }
        let length = Int(RPPairingWire.be16(buffer, at: CDTunnel.magic.count))
        while buffer.count < CDTunnel.magic.count + 2 + length {
            buffer.append(contentsOf: try await tls.readAppData(timeout: timeout))
        }
        let tunnel = try await mapError(step: "CDTunnel handshake") {
            try CDTunnel.parseResponse(buffer)
        }
        emit("RSD tunnel established (direct TCP via LocalDevVPN + handshake; RSD port \(tunnel.serverRSDPort))")

        // From here every service port goes through the connector: direct
        // TCP first (works where the bridge reaches), packet-layer TCP
        // through the held-open tunnel as fallback (RSD/AFC only listen
        // on the tunnel endpoint — proven by timeout on-device).
        let connector = TunnelConnector(tls: tls, info: tunnel, host: host)
        let rsdStream = try await mapError(step: "RSD TCP") {
            try await connector.connect(port: tunnel.serverRSDPort, label: "RSD")
        }
        let handshake = try await mapError(step: "RSD handshake") {
            try await RSDClient.handshake(stream: rsdStream, timeout: timeout)
        }
        emit("RSD services on this device:")
        for name in handshake.services.keys.sorted() {
            emit("  \(name) → port \(handshake.services[name]?.port ?? 0)")
        }
        pairingStream.close()
        return Established(handshake: handshake, pairingPort: service.port,
                           tunnelPort: tunnelPort, rsdPort: tunnel.serverRSDPort,
                           connector: connector)
    }

    // MARK: - Steps

    private func emit(_ line: String) {
        AppLogger.airLift.info(line, event: "rsd")
        log(line)
    }

    private func pickService(_ services: [WirelessPairingDiscovery.DiscoveredService],
                             recordData: Data) -> WirelessPairingDiscovery.DiscoveredService? {
        guard let altIrk = CapabilityProbeService.altIrk(from: recordData) else {
            return services.first { $0.port != 0 }
        }
        return services.first {
            $0.port != 0 && WirelessPairingDiscovery.matchesCredential(service: $0, altIrk: altIrk)
        }
    }

    private func connect(step: String, port: UInt16) async throws -> TCPStream {
        do {
            return try await TCPStream(host: host, port: port, timeout: timeout)
        } catch {
            throw OnDeviceChain.ChainError.stepFailed(
                step: step, reason: "TCP \(host):\(port) failed: \(error)")
        }
    }

    private func mapError<T>(step: String,
                             operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as OnDeviceChain.ChainError {
            throw error
        } catch {
            throw OnDeviceChain.ChainError.stepFailed(step: step, reason: String(describing: error))
        }
    }
}
