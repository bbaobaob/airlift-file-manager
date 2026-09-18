import Foundation

/// Userspace TCP over the CDTunnel IPv6 packet pipe (the idevice Adapter
/// role). The device's RSD/AFC ports listen on the tunnel endpoint address,
/// NOT on loopback — direct TCP to 10.7.0.1:<port> times out (proven on
/// device). So every post-handshake connection runs here: SYN → ESTABLISHED
/// → sliding-window data with cumulative ACKs + RTO retransmit → FIN.
///
/// All state lives in this actor; the wire goes through one serialized
/// TLS writer. One instance serves every connection of a session.
actor TunnelStack {
    enum StackError: Error, Equatable {
        case timeout(String)
        case reset(String)
        case closed
        case noRoute
    }

    private enum ConnState {
        case synSent
        case established
        case finWait
        case closed
        case failed
    }

    private struct Connection {
        var state: ConnState = .synSent
        var serverPort: UInt16 = 0
        var sndUna: UInt32 = 0
        var sndNxt: UInt32 = 0
        var rcvNxt: UInt32 = 0
        var peerWindow: UInt16 = 0
        var recvBuffer = Data()
        var eof = false
        var failure: Error?
        var pendingRead: CheckedContinuation<Void, Never>?
        var unacked: [(sequence: UInt32, data: Data, retries: Int)] = []
        var rtoTask: Task<Void, Never>?
        var rto: TimeInterval = 1.0
    }

    private let transport: any TunnelPacketTransport
    private let clientIP: [UInt8]
    private let serverIP: [UInt8]
    private let maxSegment: Int
    private var connections: [UInt16: Connection] = [:]
    private var nextPort: UInt16 = 40000
    private var reassembly = Data()

    static let initialRTO: TimeInterval = 1.0
    static let maxRetries = 5

    init(transport: any TunnelPacketTransport, clientIP: [UInt8], serverIP: [UInt8],
         tunnelMTU: Int) {
        self.transport = transport
        self.clientIP = clientIP
        self.serverIP = serverIP
        maxSegment = max(536, tunnelMTU - 60)
    }

    // MARK: - Connect

    /// Opens a TCP connection to serverIP:port through the tunnel.
    /// Returns the local port (the TunnelStream handle is built by the caller).
    func connect(port: UInt16, timeout: TimeInterval = 10) async throws -> UInt16 {
        let local = allocatePort()
        let isn = UInt32.random(in: 0...UInt32.max)
        var conn = Connection()
        conn.serverPort = port
        conn.sndUna = isn
        conn.sndNxt = isn
        conn.rcvNxt = 0
        conn.peerWindow = 65535
        conn.sndNxt = isn &+ 1
        connections[local] = conn
        try await sendSegment(local: local, sequence: isn, acknowledgement: 0,
                              flags: [.syn], window: 65535, mss: UInt16(maxSegment),
                              payload: Data())
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let current = connections[local] else { throw StackError.closed }
            switch current.state {
            case .established:
                return local
            case .failed:
                connections.removeValue(forKey: local)
                throw current.failure ?? StackError.reset("connection refused")
            case .closed:
                connections.removeValue(forKey: local)
                throw StackError.closed
            case .synSent, .finWait:
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        connections.removeValue(forKey: local)
        throw StackError.timeout("SYN to port \(port) unanswered")
    }

    private func allocatePort() -> UInt16 {
        while connections[nextPort] != nil {
            nextPort = nextPort == UInt16.max ? 40000 : nextPort + 1
        }
        let port = nextPort
        nextPort = nextPort == UInt16.max ? 40000 : nextPort + 1
        return port
    }

    // MARK: - Write

    /// Queues bytes for sending (returns once queued, like TCPStream.write).
    /// Segments honor the peer window; RTO retransmits or fails loudly.
    func write(port: UInt16, data: Data) async throws {
        var offset = data.startIndex
        while offset < data.endIndex {
            guard var conn = connections[port], conn.state == .established else {
                throw StackError.closed
            }
            if let failure = conn.failure { throw failure }
            let end = data.index(offset, offsetBy: maxSegment, limitedBy: data.endIndex)
                ?? data.endIndex
            let chunk = Data(data[offset..<end])
            // Respect the peer window for in-flight bytes (re-read state:
            // inbound ACKs may advance it while we wait).
            while inflight(conn) + Int64(chunk.count) > Int64(conn.peerWindow) {
                try await waitForWindow(port: port)
                guard let updated = connections[port],
                      updated.state == .established else { throw StackError.closed }
                if let failure = updated.failure { throw failure }
                conn = updated
            }
            let sequence = conn.sndNxt
            conn.sndNxt &+= UInt32(chunk.count)
            connections[port] = conn
            try await sendSegment(local: port, sequence: sequence,
                                  acknowledgement: conn.rcvNxt,
                                  flags: [.ack, .psh], window: 65535,
                                  payload: chunk)
            guard var updated = connections[port],
                  updated.state == .established else { throw StackError.closed }
            if let failure = updated.failure { throw failure }
            updated.unacked.append((sequence: sequence, data: chunk, retries: 0))
            connections[port] = updated
            armRTO(port: port)
            offset = end
        }
    }

    private func inflight(_ conn: Connection) -> Int64 {
        Int64(bitPattern: UInt64(conn.sndNxt) &- UInt64(conn.sndUna))
    }

    private func waitForWindow(port: UInt16) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            guard let conn = connections[port] else { throw StackError.closed }
            if let failure = conn.failure { throw failure }
            if inflight(conn) < Int64(conn.peerWindow) { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw StackError.timeout("peer window stuck")
    }

    // MARK: - Read

    /// Takes up to `count` buffered bytes, waiting for arrival (single
    /// pending read per connection by design — all our protocols are
    /// strictly sequential per connection).
    func takeBytes(port: UInt16, count: Int) async throws -> Data {
        while true {
            guard var conn = connections[port] else { throw StackError.closed }
            if let failure = conn.failure, conn.recvBuffer.isEmpty {
                throw failure
            }
            if !conn.recvBuffer.isEmpty {
                let take = min(count, conn.recvBuffer.count)
                let out = Data(conn.recvBuffer.prefix(take))
                conn.recvBuffer.removeFirst(take)
                connections[port] = conn
                return out
            }
            if conn.eof { throw StackError.closed }
            if conn.pendingRead != nil {
                fatalError("TunnelStack: overlapping reads on one connection")
            }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                connections[port]?.pendingRead = cont
            }
        }
    }

    func cancelPendingRead(port: UInt16) {
        if let cont = connections[port]?.pendingRead {
            connections[port]?.pendingRead = nil
            cont.resume()
        }
    }

    // MARK: - Close

    func close(port: UInt16) async {
        guard var conn = connections[port], conn.state == .established else {
            connections.removeValue(forKey: port)
            return
        }
        // Flush: wait for all acknowledgements (bounded).
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            guard let current = connections[port] else { return }
            if current.sndUna == current.sndNxt { break }
            if current.failure != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard var current = connections[port], current.state == .established else {
            connections.removeValue(forKey: port)
            return
        }
        current.state = .finWait
        current.sndNxt &+= 1
        connections[port] = current
        try? await sendSegment(local: port, sequence: current.sndNxt &- 1,
                               acknowledgement: current.rcvNxt,
                               flags: [.fin, .ack], window: 65535,
                               payload: Data())
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        connections.removeValue(forKey: port)
    }

    func failAll(_ error: Error) {
        for port in connections.keys {
            fail(port: port, error: error)
        }
    }

    private func fail(port: UInt16, error: Error) {
        guard var conn = connections[port] else { return }
        conn.state = .failed
        conn.failure = error
        conn.rtoTask?.cancel()
        conn.rtoTask = nil
        if let cont = conn.pendingRead {
            conn.pendingRead = nil
            cont.resume()
        }
        connections[port] = conn
    }

    // MARK: - RTO

    private func armRTO(port: UInt16) {
        guard let conn = connections[port], conn.rtoTask == nil,
              !conn.unacked.isEmpty else { return }
        connections[port]?.rtoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await self?.onRTO(port: port)
        }
    }

    private func onRTO(port: UInt16) async {
        guard var conn = connections[port],
              conn.state == .established, !conn.unacked.isEmpty else { return }
        conn.rtoTask = nil
        let retries = conn.unacked.map(\.retries).max() ?? 0
        guard retries < Self.maxRetries else {
            fail(port: port, error: StackError.timeout("RTO exhausted"))
            return
        }
        for index in conn.unacked.indices {
            let entry = conn.unacked[index]
            try? await sendSegment(local: port, sequence: entry.sequence,
                                   acknowledgement: conn.rcvNxt,
                                   flags: [.ack, .psh], window: 65535,
                                   payload: entry.data)
            conn.unacked[index].retries += 1
        }
        connections[port] = conn
        armRTO(port: port)
    }

    // MARK: - Packet ingest (pump calls this with decrypted TLS bytes)

    func ingest(_ bytes: Data) {
        reassembly.append(contentsOf: bytes)
        while let packet = IPv6.parsePacket(reassembly) {
            let consumed = 40 + packet.payload.count
            reassembly.removeFirst(consumed)
            handlePacket(packet)
        }
        if reassembly.count > 256 * 1024 {
            reassembly.removeAll() // defensive: never grow unbounded
        }
    }

    private func handlePacket(_ packet: IPv6.Packet) {
        guard packet.nextHeader == 6,
              packet.dst == clientIP,
              let segment = IPv6.parseSegment(packet.payload) else { return }
        guard var conn = connections[segment.dstPort],
              conn.state == .synSent || conn.state == .established
              || conn.state == .finWait else { return }
        let flags = segment.flags

        if flags.contains(.rst) {
            fail(port: segment.dstPort, error: StackError.reset("peer reset"))
            return
        }

        switch conn.state {
        case .synSent:
            guard flags.contains(.syn) && flags.contains(.ack),
                  segment.acknowledgement == conn.sndNxt else { return }
            conn.rcvNxt = segment.sequence &+ 1
            conn.peerWindow = segment.window
            if IPv6.parseMSS(segment.header) != nil {
                // Noted; our MSS stays tunnel-derived.
            }
            conn.state = .established
            connections[segment.dstPort] = conn
            Task { [weak self] in
                guard let self else { return }
                try? await self.sendSegment(local: segment.dstPort,
                                            sequence: conn.sndNxt,
                                            acknowledgement: conn.rcvNxt,
                                            flags: [.ack], window: 65535,
                                            payload: Data())
            }
        case .established, .finWait:
            // Slide the send window on cumulative ACKs.
            if segment.acknowledgement != conn.sndUna {
                // Accept forward ACKs within [sndUna, sndNxt].
                let acked = segment.acknowledgement &- conn.sndUna
                if acked <= (conn.sndNxt &- conn.sndUna) {
                    conn.sndUna = segment.acknowledgement
                    conn.unacked.removeAll { $0.sequence &+ UInt32($0.data.count) <= segment.acknowledgement }
                    conn.peerWindow = segment.window
                    if conn.unacked.isEmpty {
                        conn.rtoTask?.cancel()
                        conn.rtoTask = nil
                    }
                }
            } else {
                conn.peerWindow = segment.window
            }
            // In-order data (buffer nothing out of order: ACK + drop, sender retries).
            if !segment.payload.isEmpty {
                if segment.sequence == conn.rcvNxt {
                    conn.recvBuffer.append(contentsOf: segment.payload)
                    conn.rcvNxt &+= UInt32(segment.payload.count)
                    if let cont = conn.pendingRead {
                        conn.pendingRead = nil
                        cont.resume()
                    }
                }
                connections[segment.dstPort] = conn
                Task { [weak self] in
                    guard let self else { return }
                    try? await self.sendSegment(local: segment.dstPort,
                                                sequence: conn.sndNxt,
                                                acknowledgement: conn.rcvNxt,
                                                flags: [.ack], window: 65535,
                                                payload: Data())
                }
                return
            }
            if flags.contains(.fin) {
                conn.rcvNxt &+= 1
                conn.eof = true
                if let cont = conn.pendingRead {
                    conn.pendingRead = nil
                    cont.resume()
                }
                connections[segment.dstPort] = conn
                Task { [weak self] in
                    guard let self else { return }
                    try? await self.sendSegment(local: segment.dstPort,
                                                sequence: conn.sndNxt,
                                                acknowledgement: conn.rcvNxt,
                                                flags: [.ack], window: 65535,
                                                payload: Data())
                }
                return
            }
            connections[segment.dstPort] = conn
        case .closed, .failed:
            break
        }
    }

    // MARK: - Wire

    private func sendSegment(local: UInt16, sequence: UInt32,
                             acknowledgement: UInt32, flags: IPv6.Flags,
                             window: UInt16, mss: UInt16? = nil,
                             payload: Data) async throws {
        guard let serverPort = connections[local]?.serverPort else { return }
        var segment = IPv6.buildSegment(srcPort: local, dstPort: serverPort,
                                        sequence: sequence,
                                        acknowledgement: acknowledgement,
                                        flags: flags, window: window,
                                        mss: mss, payload: payload)
        segment = IPv6.withChecksum(src: clientIP, dst: serverIP, segment: segment)
        let packet = IPv6.buildPacket(src: clientIP, dst: serverIP,
                                      nextHeader: 6, payload: segment)
        try await transport.send(packet)
    }
}
