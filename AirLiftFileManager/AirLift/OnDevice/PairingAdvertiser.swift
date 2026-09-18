import Foundation
import Network

/// Publishes `_remotepairing-pairable-host._tcp` and accepts the first
/// incoming device connection (the user taps "Pair with AirLift" in
/// Settings › Developer Mode on the iPhone). Same role as StikPair's own
/// advertiser. Requires Local Network permission (prompted once by iOS).
@MainActor
final class PairingAdvertiser: NSObject, NetServiceDelegate {
    enum AdvertiseError: Error, Equatable {
        case listenerFailed(String)
        case publishFailed(String)
        case timeout
        case cancelled
    }

    private var listener: NWListener?
    private var netService: NetService?
    private var continuation: CheckedContinuation<(NWConnection, UInt16), Error>?
    private var servicePort: UInt16 = 0

    /// Advertise `identity` and wait for one device connection.
    /// Returns the accepted connection + our advertised port.
    func advertiseAndAccept(identity: PairingHost.HostIdentity,
                            timeout: TimeInterval = 180) async throws -> (NWConnection, UInt16) {
        let port = try await startListener()
        publish(identity: identity, port: port)
        do {
            return try await waitForConnection(timeout: timeout)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: AdvertiseError.cancelled)
        }
        netService?.stop()
        netService = nil
        listener?.cancel()
        listener = nil
    }

    // MARK: - Listener

    private func startListener() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            var done = false
            let listener: NWListener
            do {
                listener = try NWListener(using: .tcp, on: 0)
            } catch {
                cont.resume(throwing: AdvertiseError.listenerFailed(error.localizedDescription))
                return
            }
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if !done, let port = listener.port {
                        done = true
                        self.servicePort = port.rawValue
                        cont.resume(returning: port.rawValue)
                    }
                case .failed(let error):
                    if !done {
                        done = true
                        cont.resume(throwing: AdvertiseError.listenerFailed(
                            error.localizedDescription))
                    }
                case .cancelled:
                    if !done {
                        done = true
                        cont.resume(throwing: AdvertiseError.cancelled)
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleIncoming(connection)
            }
            listener.start(queue: .main)
        }
    }

    private func handleIncoming(_ connection: NWConnection) {
        guard let continuation else {
            connection.cancel() // not waiting (anymore) — refuse extras
            return
        }
        self.continuation = nil
        // Keep advertising until the pairing run finishes; the caller stops us.
        connection.start(queue: .main)
        continuation.resume(returning: (connection, servicePort))
    }

    private func waitForConnection(timeout: TimeInterval) async throws -> (NWConnection, UInt16) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(NWConnection, UInt16), Error>) in
            continuation = cont
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let continuation = self.continuation else { return }
                self.continuation = nil
                self.stop()
                continuation.resume(throwing: AdvertiseError.timeout)
            }
        }
    }

    // MARK: - mDNS publish

    private func publish(identity: PairingHost.HostIdentity, port: UInt16) {
        let service = NetService(domain: PairingHost.serviceDomain,
                                 type: PairingHost.serviceType,
                                 name: identity.identifier,
                                 port: Int32(port))
        service.delegate = self
        service.setTXTRecord(PairingHost.txtRecordData(identity: identity))
        netService = service
        service.publish()
        AppLogger.pairing.info("Advertising \(PairingHost.serviceType) as \(identity.name)",
                               event: "pairing.advertise")
    }

    func netServiceDidPublish(_ sender: NetService) {
        AppLogger.pairing.info("Pairing advertisement live", event: "pairing.advertise")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        AppLogger.pairing.error("Advertise failed: \(errorDict)", event: "pairing.advertise")
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: AdvertiseError.publishFailed("\(errorDict)"))
        }
    }
}
