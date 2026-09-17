import Foundation

/// LocalDevVPN status as observed from this codebase.
enum VPNState: Equatable {
    /// LocalDevVPN is referenced by AirLift and functioning.
    case connected(detail: String)
    /// AirLift contains no VPN component at all (verified: 0 references in the repo).
    case notPartOfAirLift
    /// A VPN component exists elsewhere but is not reachable from this app.
    case unavailable(reason: String)

    var displayTitle: String {
        switch self {
        case .connected: return "Connected"
        case .notPartOfAirLift: return "Not Found in AirLift"
        case .unavailable: return "Unavailable"
        }
    }
}

/// Honest LocalDevVPN reporting.
///
/// Verification performed on the upstream repository (0xjohnnydev/airlift):
/// a code search for "LocalDevVPN" returns 0 results; airlift.py uses
/// `xcrun devicectl` + AirTrafficHost.framework directly over the standard
/// paired-device transport (USB/Wi-Fi). No VPN tunnel, pairing step beyond
/// normal device pairing, or background daemon is involved.
struct LocalDevVPNService {
    private(set) var state: VPNState

    init() {
        self.state = .notPartOfAirLift
        AppLogger.vpn.info("LocalDevVPN check: not referenced by AirLift (0 code matches)")
    }

    var summary: String {
        switch state {
        case .connected(let detail):
            return detail
        case .notPartOfAirLift:
            return "AirLift does not use LocalDevVPN. It communicates with the iPhone " +
                "through the standard paired-Mac transport (USB or Wi-Fi) via " +
                "MobileDevice.framework and AirTrafficHost.framework. No VPN tunnel " +
                "is required, so there is nothing to activate or keep alive in this app."
        case .unavailable(let reason):
            return reason
        }
    }
}
