import Foundation
import Network

/// Async byte stream over a TCP NWConnection with per-operation timeouts.
/// Used for every hop of the on-device chain (remote-pairing, tunnel,
/// RSD, AFC) through the LocalDevVPN loopback.
final class TCPStream: Sendable {
    enum StreamError: Error, Equatable {
        case connectionFailed(String)
        case timeout
        case closed
    }

    private let connection: NWConnection
    private let queue: DispatchQueue

    init(host: String, port: UInt16, timeout: TimeInterval = 8) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw StreamError.connectionFailed("bad port \(port)")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "airlift.tcpstream")
        self.connection = connection
        self.queue = queue
        try await Self.connect(connection, queue: queue, timeout: timeout)
    }

    /// Test seam: wrap an already-connected NWConnection (loopback tests).
    init(wrapping connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    deinit { connection.cancel() }

    func close() { connection.cancel() }

    // MARK: - I/O

    func write(_ data: Data, timeout: TimeInterval = 8) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var done = false
            connection.send(content: data, completion: .contentProcessed { error in
                guard !done else { return }
                done = true
                if let error {
                    cont.resume(throwing: StreamError.connectionFailed(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
            queue.asyncAfter(deadline: .now() + timeout) {
                guard !done else { return }
                done = true
                cont.resume(throwing: StreamError.timeout)
            }
        }
    }

    /// Reads exactly `count` bytes (loops over partial receives).
    func readExactly(_ count: Int, timeout: TimeInterval = 8) async throws -> Data {
        var out = Data()
        out.reserveCapacity(count)
        let deadline = Date().addingTimeInterval(timeout)
        while out.count < count {
            let slice = try await receiveUpTo(count - out.count,
                                              timeout: max(0.1, deadline.timeIntervalSinceNow))
            if slice.isEmpty { throw StreamError.closed }
            out.append(contentsOf: slice)
        }
        return out
    }

    /// Reads one RPPairing frame (magic + u16BE length + JSON body).
    func readRPPairingFrame(timeout: TimeInterval = 8) async throws -> Any {
        let header = try await readExactly(RPPairingWire.magic.count + 2, timeout: timeout)
        guard header.prefix(RPPairingWire.magic.count) == RPPairingWire.magic else {
            throw RPPairingWire.WireError.badMagic
        }
        let length = Int(RPPairingWire.be16(header, at: RPPairingWire.magic.count))
        let body = try await readExactly(length, timeout: timeout)
        guard let json = try? JSONSerialization.jsonObject(with: body, options: []) else {
            throw RPPairingWire.WireError.invalidJSON
        }
        return json
    }

    // MARK: - Plumbing

    private static func connect(_ connection: NWConnection, queue: DispatchQueue,
                                timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var done = false
            func finish(_ error: Error?) {
                guard !done else { return }
                done = true
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(nil)
                case .failed(let error):
                    finish(StreamError.connectionFailed(error.localizedDescription))
                case .cancelled: finish(StreamError.connectionFailed("cancelled"))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(StreamError.timeout)
            }
        }
    }

    private func receiveUpTo(_ maxLength: Int, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            var done = false
            connection.receive(minimumIncompleteLength: 1,
                               maximumLength: max(maxLength, 1)) { data, _, isComplete, error in
                guard !done else { return }
                done = true
                if let error {
                    cont.resume(throwing: StreamError.connectionFailed(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(returning: Data())
                } else {
                    cont.resume(returning: data ?? Data())
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                guard !done else { return }
                done = true
                cont.resume(throwing: StreamError.timeout)
            }
        }
    }
}
