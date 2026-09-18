import Foundation

/// Serializes TLS writes for one tunnel (TLS records from concurrent
/// connections must never interleave mid-message).
actor TunnelWriter {
    private let tls: TLSPskSession

    init(tls: TLSPskSession) {
        self.tls = tls
    }

    func write(_ data: Data, timeout: TimeInterval = 10) async throws {
        try await tls.writeAppData(data, timeout: timeout)
    }
}

/// Packet pipe abstraction so the TCP stack is testable loopback-style
/// without a live tunnel (the real TunnelWriter speaks TLS app-data).
protocol TunnelPacketTransport: Sendable {
    func send(_ packet: Data) async throws
}

extension TunnelWriter: TunnelPacketTransport {
    func send(_ packet: Data) async throws {
        try await write(packet)
    }
}

/// A TCP-like byte stream over the tunnel stack. Same API contract as
/// TCPStream so protocol clients work on either transport unchanged.
final class TunnelStream: DataStream, @unchecked Sendable {
    enum TunnelStreamError: Error {
        case closed
    }

    private let stack: TunnelStack
    private let port: UInt16
    private let label: String

    init(stack: TunnelStack, port: UInt16, label: String) {
        self.stack = stack
        self.port = port
        self.label = label
    }

    func write(_ data: Data, timeout: TimeInterval = 8) async throws {
        _ = timeout
        do {
            try await stack.write(port: port, data: data)
        } catch {
            throw TunnelStreamError.closed
        }
    }

    func readExactly(_ count: Int, timeout: TimeInterval = 8) async throws -> Data {
        var out = Data()
        out.reserveCapacity(count)
        let deadline = Date().addingTimeInterval(timeout)
        while out.count < count {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw TCPStream.StreamError.timeout }
            do {
                let chunk = try await withTimeout(remaining) {
                    try await self.stack.takeBytes(port: self.port, count: count - out.count)
                }
                if chunk.isEmpty { throw TunnelStreamError.closed }
                out.append(contentsOf: chunk)
            } catch is CancellationError {
                throw TCPStream.StreamError.timeout
            }
        }
        return out
    }

    private func withTimeout<T>(_ seconds: TimeInterval,
                                operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TCPStream.StreamError.timeout
            }
            guard let result = try await group.next() else {
                throw TCPStream.StreamError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    func close() {
        Task { [weak self] in
            guard let self else { return }
            await stack.close(port: port)
        }
    }
}

/// Owns one established tunnel: the held-open TLS session, the packet pump
/// and the TCP stack. `connect(port:)` dials a service port, trying direct
/// TCP through the LocalDevVPN bridge first (3s) and falling back to
/// packet-layer TCP through the tunnel — the device only listens on the
/// tunnel endpoint address, so direct dials fail there and the fallback is
/// the real path (proven by timeout on-device).
final class TunnelConnector {
    private let tls: TLSPskSession
    private let info: CDTunnel.Info
    private let host: String
    private let writer: TunnelWriter
    private let stack: TunnelStack
    private let packetCapable: Bool
    private var pumpTask: Task<Void, Never>?
    private var directUnreachable = false

    init(tls: TLSPskSession, info: CDTunnel.Info,
         host: String = LocalDevVPNService.tunnelHost) {
        self.tls = tls
        self.info = info
        self.host = host
        writer = TunnelWriter(tls: tls)
        if let serverIP = IPv6.parseAddress(info.serverAddress),
           let clientIP = IPv6.parseAddress(info.clientAddress) {
            packetCapable = true
            stack = TunnelStack(transport: writer, clientIP: clientIP, serverIP: serverIP,
                                tunnelMTU: info.mtu == 0 ? 1500 : Int(info.mtu))
        } else {
            // Degraded: endpoint addresses unparseable — direct dials may
            // still work; packet-layer dials will report noRoute.
            packetCapable = false
            stack = TunnelStack(transport: writer,
                                clientIP: [UInt8](repeating: 0, count: 16),
                                serverIP: [UInt8](repeating: 0, count: 16),
                                tunnelMTU: 1500)
        }
        startPump()
    }

    deinit {
        pumpTask?.cancel()
    }

    /// Dial a service port on the device. Direct first, packet-layer fallback.
    func connect(port: UInt16, label: String,
                 timeout: TimeInterval = 10) async throws -> any DataStream {
        if !directUnreachable {
            do {
                let direct = try await TCPStream(host: host, port: port, timeout: 3)
                AppLogger.net.info("\(label): direct TCP \(host):\(port) answered",
                                   event: "tunnel.dial")
                return direct
            } catch {
                directUnreachable = true
                AppLogger.net.info(
                    "\(label): direct TCP \(host):\(port) failed (\(error)) — " +
                    "using packet-layer TCP through the tunnel",
                    event: "tunnel.dial")
            }
        }
        return try await connectViaTunnel(port: port, label: label, timeout: timeout)
    }

    private func connectViaTunnel(port: UInt16, label: String,
                                  timeout: TimeInterval) async throws -> any DataStream {
        guard packetCapable else {
            throw TunnelStack.StackError.noRoute
        }
        let local = try await stack.connect(port: port, timeout: timeout)
        AppLogger.net.info("\(label): packet-layer TCP established (local \(local))",
                           event: "tunnel.dial")
        return TunnelStream(stack: stack, port: local, label: label)
    }

    private func startPump() {
        pumpTask?.cancel()
        pumpTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let bytes = try await tls.readAppData(timeout: 30)
                    await stack.ingest(bytes)
                } catch {
                    if !Task.isCancelled {
                        AppLogger.net.warning("Tunnel pump ended: \(error)",
                                              event: "tunnel.pump")
                        await stack.failAll(error)
                    }
                    return
                }
            }
        }
    }
}
