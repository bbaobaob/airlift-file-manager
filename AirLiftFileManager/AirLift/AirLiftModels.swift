import Foundation

/// The nine activation states required by the product spec.
/// Every transition is driven by a real probe result — never by cosmetics.
enum AirLiftState: String, CaseIterable, Codable {
    case notActivated = "Not Activated"
    case preparing = "Preparing"
    case connecting = "Connecting"
    case activating = "Activating"
    case verifying = "Verifying"
    case activated = "Activated"
    case failed = "Failed"
    case disconnected = "Disconnected"
    case unsupported = "Unsupported"

    var isTerminal: Bool {
        switch self {
        case .activated, .failed, .disconnected, .unsupported, .notActivated:
            return true
        default:
            return false
        }
    }

    var isActiveState: Bool { self == .activated }
}

/// Static capability facts, all sourced from the upstream repository analysis.
struct AirLiftCapabilities: Equatable {
    /// In-app activation is impossible: the exploit runs inside
    /// AirTrafficHost.framework on the paired Mac, not on the device.
    let inAppActivationSupported: Bool
    /// AirLift itself offers no VPN component.
    let localDevVPNReferenced: Bool
    /// Host frameworks the exploit requires.
    let requiredHostComponents: [String]
    /// Verified write scope (fresh-file writes confirmed upstream).
    let verifiedWriteScope: [String]
    /// Reads happen indirectly: move into Media, read via AFC, move back.
    let readModel: String
    /// iOS builds the PoC was verified on.
    let testedBuilds: [String]

    static let current = AirLiftCapabilities(
        inAppActivationSupported: false,
        localDevVPNReferenced: false,
        requiredHostComponents: [
            "macOS + MobileDevice.framework",
            "AirTrafficHost.framework",
            "Paired physical iPhone (USB or Wi-Fi)",
        ],
        verifiedWriteScope: AppConstants.AirLift.verifiedWriteScope,
        readModel: "Indirect: move file into Media, read through AFC, move back",
        testedBuilds: AppConstants.AirLift.testedBuilds)
}

/// What a probe reports after checking the real environment.
enum AirLiftProbeResult: Equatable {
    /// A working AirLift channel was verified end-to-end.
    case activated(detail: String)
    /// The environment cannot run AirLift from this app; reason is shown to the user.
    case unsupported(reason: String)
    /// Environment looked viable but the attempt did not complete.
    case failed(reason: String)
    /// A previously working channel is no longer reachable.
    case disconnected(reason: String)
}

protocol AirLiftProbing: Sendable {
    func probe() async -> AirLiftProbeResult
}
