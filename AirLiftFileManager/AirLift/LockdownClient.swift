import Foundation
import Network

/// Minimal lockdown client over the LocalDevVPN/StosVPN loopback tunnel.
///
/// Talks the real lockdown protocol on 10.7.0.1:62078:
/// - TCP connect through the tunnel (LocalDevVPN routes 10.7.0.1 back to this device)
/// - TLS with certificate validation disabled (device presents a self-signed cert;
///   pairing-record client identity is supported for later authenticated services)
/// - Length-prefixed binary plist exchange: QueryType / GetValue — the same
///   requests a paired Mac sends after usbmuxd, here sent from on-device.
///
/// This is the transport layer StikPair-class tools use; it is also the
/// lockdown/AFC hop of the AirLift device-side chain.
final class LockdownClient: @unchecked Sendable {
    enum LockdownError: LocalizedError {
        case connectionFailed(String)
        case timeout
        case badFrame
        case plistExchange(String)

        var errorDescription: String? {
            switch self {
            case .connectionFailed(let m): return "Lockdown connection failed: \(m)"
            case .timeout: return "Lockdown request timed out"
            case .badFrame: return "Malformed lockdown frame"
            case .plistExchange(let m): return "Lockdown exchange error: \(m)"
            }
        }
    }

    static let tunnelHost = "10.7.0.1"
    static let lockdownPort: UInt16 = 62078

    private let queue = DispatchQueue(label: "lockdown.client")
    private var connection: NWConnection?

    /// Optional pairing identity (from an imported StikPair-style pairing file)
    /// for trusted (paired) lockdown sessions.
    private let clientIdentity: SecIdentity?

    init(clientIdentity: SecIdentity? = nil) {
        self.clientIdentity = clientIdentity
    }

    // MARK: - Framing (pure, unit-tested)

    /// Lockdown TCP framing: 4-byte big-endian payload length + binary plist.
    static func frame(_ payload: Data) -> Data {
        var out = Data(count: 4)
        out[0] = UInt8((payload.count >> 24) & 0xFF)
        out[1] = UInt8((payload.count >> 16) & 0xFF)
        out[2] = UInt8((payload.count >> 8) & 0xFF)
        out[3] = UInt8(payload.count & 0xFF)
        out.append(payload)
        return out
    }

    /// Splits a receive buffer into (frame, remaining) using the 4-byte header.
    static func popFrame(from buffer: Data) -> (frame: Data, remaining: Data)? {
        guard buffer.count >= 4 else { return nil }
        let length = (Int(buffer[buffer.startIndex]) << 24)
            | (Int(buffer[buffer.startIndex + 1]) << 16)
            | (Int(buffer[buffer.startIndex + 2]) << 8)
            | Int(buffer[buffer.startIndex + 3])
        guard length > 0, length < 64 * 1024 * 1024 else { return nil }
        let headerEnd = buffer.index(buffer.startIndex, offsetBy: 4)
        guard buffer.distance(from: headerEnd, to: buffer.endIndex) >= length else { return nil }
        let frameEnd = buffer.index(headerEnd, offsetBy: length)
        return (buffer.subdata(in: headerEnd..<frameEnd),
                buffer.subdata(in: frameEnd..<buffer.endIndex))
    }

    // MARK: - High-level requests

    /// Queries the device over the tunnel. Returns the lockdown reply dict.
    func request(_ body: [String: Any], timeout: TimeInterval = 6) async throws -> [String: Any] {
        let payload = try PropertyListSerialization.data(
            fromPropertyList: body, format: .binary, options: 0)
        let conn = makeConnection()
        connection = conn
        try await connect(conn, timeout: timeout)
        let replyData = try await exchange(conn, payload: payload, timeout: timeout)
        guard let reply = try? PropertyListSerialization.propertyList(
            from: replyData, format: nil) as? [String: Any] else {
            throw LockdownError.plistExchange("reply is not a plist dict")
        }
        conn.cancel()
        return reply
    }

    func queryType(timeout: TimeInterval = 6) async throws -> String {
        let reply = try await request(["RequestType": "QueryType"], timeout: timeout)
        return reply["Type"] as? String ?? "unknown"
    }

    func getValue(_ key: String, timeout: TimeInterval = 6) async throws -> String? {
        let reply = try await request(
            ["RequestType": "GetValue", "Key": key], timeout: timeout)
        guard (reply["Status"] as? String ?? "Success") == "Success" else { return nil }
        return reply["Value"] as? String
    }

    /// One-shot convenience probe used by the AirLift tab.
    static func probeDevice(timeout: TimeInterval = 6) async -> LockdownProbeResult {
        let client = LockdownClient()
        do {
            let type = try await client.queryType(timeout: timeout)
            let version = (try? await client.getValue("ProductVersion", timeout: timeout)) ?? nil
            let product = (try? await client.getValue("ProductType", timeout: timeout)) ?? nil
            return LockdownProbeResult(
                reachable: true, queryType: type,
                productVersion: version, productType: product, error: nil)
        } catch {
            return LockdownProbeResult(reachable: false, queryType: nil,
                                       productVersion: nil, productType: nil,
                                       error: error.localizedDescription)
        }
    }

    // MARK: - Connection plumbing

    private func makeConnection() -> NWConnection {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions, { _, _, complete in complete(true) },
            queue)
        let params = NWParameters(tls: tls)
        params.allowLocalEndpointReuse = true
        return NWConnection(
            host: NWEndpoint.Host(Self.tunnelHost),
            port: NWEndpoint.Port(rawValue: Self.lockdownPort)!,
            using: params)
    }

    private func connect(_ conn: NWConnection, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var done = false
            func finish(_ error: Error?) {
                if done { return }
                done = true
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(nil)
                case .failed(let error):
                    finish(LockdownError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    finish(LockdownError.connectionFailed("cancelled"))
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(LockdownError.timeout)
            }
        }
    }

    private func exchange(_ conn: NWConnection, payload: Data,
                          timeout: TimeInterval) async throws -> Data {
        let framed = Self.frame(payload)
        try await send(conn, data: framed, timeout: timeout)
        return try await receiveReply(conn, timeout: timeout)
    }

    private func send(_ conn: NWConnection, data: Data, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var done = false
            conn.send(content: data, completion: .contentProcessed { error in
                if done { return }
                done = true
                if let error {
                    cont.resume(throwing: LockdownError.plistExchange(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
            queue.asyncAfter(deadline: .now() + timeout) {
                if !done {
                    done = true
                    cont.resume(throwing: LockdownError.timeout)
                }
            }
        }
    }

    private func receiveReply(_ conn: NWConnection, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            var buffer = Data()
            var done = false
            func finish(_ result: Result<Data, Error>) {
                if done { return }
                done = true
                cont.resume(with: result)
            }
            func pump() {
                conn.receive(minimumIncompleteLength: 1,
                             maximumLength: 256 * 1024) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        buffer.append(data)
                        if let (frame, _) = Self.popFrame(from: buffer) {
                            finish(.success(frame))
                            return
                        }
                    }
                    if let error {
                        finish(.failure(LockdownError.plistExchange(error.localizedDescription)))
                        return
                    }
                    if isComplete {
                        finish(.failure(LockdownError.badFrame))
                        return
                    }
                    pump()
                }
            }
            pump()
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(.failure(LockdownError.timeout))
            }
        }
    }
}

struct LockdownProbeResult: Equatable {
    let reachable: Bool
    let queryType: String?
    let productVersion: String?
    let productType: String?
    let error: String?
}
