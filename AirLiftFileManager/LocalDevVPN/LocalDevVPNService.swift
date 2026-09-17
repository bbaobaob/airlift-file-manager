import Foundation
import Network

/// LocalDevVPN status as observed from this process.
///
/// Verified context (2026-09):
/// - Upstream AirLift (0xjohnnydev/airlift) contains zero references to
///   LocalDevVPN — it drives the device from a paired Mac instead.
/// - LocalDevVPN is a real, separately distributed packet-tunnel app
///   (SideStore's StosVPN is the same mechanism: NEPacketTunnelProvider with
///   device IP 10.7.0.0 / fake IP 10.7.0.1). It maps 10.7.0.1 back to this
///   iPhone's own services, so a sandboxed app can open TCP to lockdown
///   (port 62078) — the same transport AFC rides on, which is one hop of the
///   AirLift device-side chain.
/// - Apps like StikDebug and Locus already use this 10.7.0.1 endpoint.
enum VPNState: Equatable {
    /// 10.7.0.1 lockdown endpoint answered a TCP connect.
    case connected(detail: String)
    /// Endpoint did not answer (tunnel not installed, off, or blocked).
    case unreachable(reason: String)

    var displayTitle: String {
        switch self {
        case .connected: return "Connected (10.7.0.1)"
        case .unreachable: return "Not Detected"
        }
    }
}

struct LocalDevVPNService {
    /// Default loopback tunnel endpoint used by LocalDevVPN / StosVPN.
    static let tunnelHost = "10.7.0.1"
    /// Lockdown port — the service every tunnel user talks to first.
    static let lockdownPort: UInt16 = 62078

    /// Performs a REAL TCP connect probe against the tunnel endpoint.
    /// A successful connect proves the packet tunnel is up and routing to
    /// this device's lockdown; nothing is simulated.
    func probeTunnel(port: UInt16 = LocalDevVPNService.lockdownPort,
                     timeout: TimeInterval = 3.0) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(returning: false)
                return
            }
            let connection = NWConnection(
                host: NWEndpoint.Host(Self.tunnelHost),
                port: endpointPort,
                using: .tcp)
            let queue = DispatchQueue(label: "localdevvpn.probe")
            var finished = false

            func finish(_ result: Bool) {
                if finished { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    AppLogger.vpn.info("Tunnel probe: 10.7.0.1:\(port) reachable")
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            // Strong capture keeps the connection alive for the timeout window.
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
            connection.start(queue: queue)
        }
    }

    func evaluate(reachable: Bool) -> VPNState {
        if reachable {
            return .connected(detail:
                "Tunnel endpoint \(Self.tunnelHost):\(Self.lockdownPort) (lockdown) answered. " +
                "Device services are reachable from this sandbox — this is the on-device path " +
                "SideStore/StikDebug-style tools use.")
        }
        return .unreachable(reason:
            "No answer from \(Self.tunnelHost):\(Self.lockdownPort). Install/connect LocalDevVPN " +
            "(or SideStore StosVPN) and keep Wi-Fi on. Note: LocalDevVPN is not part of upstream " +
            "AirLift — AirLift itself talks to the device from a paired Mac.")
    }

    var backgroundInfo: String {
        "AirLift upstream does not reference LocalDevVPN (0 code matches). LocalDevVPN is a " +
        "separate packet-tunnel app that maps 10.7.0.1 to this device's own services " +
        "(lockdown 62078), enabling sandboxed apps to reach AFC/lockdown — the transport layer " +
        "the AirLift device-side chain also uses. Driving the full AirLift exploit through the " +
        "tunnel from on-device is NOT yet implemented or verified."
    }
}
