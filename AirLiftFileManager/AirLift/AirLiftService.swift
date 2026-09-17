import Foundation

/// Honest AirLift integration service.
///
/// Verified against the upstream repository (0xjohnnydev/airlift):
/// - airlift.py drives `xcrun devicectl` + two native macOS helpers that link
///   MobileDevice.framework and AirTrafficHost.framework.
/// - The device-side chain (streaming_zip_conduit -> afc -> atc -> AirTraffic
///   Books client -> ATAirlock) is only reachable from the host side.
/// - No iOS app surface, no in-app API, and no VPN component exist upstream.
///
/// This probe performs the checks that ARE possible from a sandboxed app:
/// 1. Whether a LocalDevVPN/StosVPN-style loopback tunnel is up (10.7.0.1).
/// 2. It reports precisely what that does and does not enable. A reachable
///    lockdown endpoint proves the tunnel works — it does NOT prove the
///    AirLift AirTraffic exploit path, which is not implemented on-device.
struct AirLiftService: AirLiftProbing {
    let tunnelProbe: () async -> Bool

    init(tunnelProbe: @escaping () async -> Bool = {
        await LocalDevVPNService().probeTunnel()
    }) {
        self.tunnelProbe = tunnelProbe
    }

    func probe() async -> AirLiftProbeResult {
        AppLogger.airLift.info("Probe started")
        let tunnelUp = await tunnelProbe()
        AppLogger.airLift.info("Tunnel probe result: \(tunnelUp ? "reachable" : "unreachable", privacy: .public)")

        if tunnelUp {
            return .unsupported(reason:
                "LocalDevVPN tunnel detected: 10.7.0.1:62078 (lockdown) is reachable from this " +
                "sandbox. That proves the on-device tunnel works — the same transport StikDebug/" +
                "SideStore-style apps use. However, driving the AirLift AirTraffic exploit through " +
                "the tunnel from on-device is not implemented or verified in this build. To write " +
                "into the verified scope today, run airlift from a Mac paired with this iPhone.")
        }
        return .unsupported(reason:
            "AirLift executes on the paired Mac (AirTrafficHost.framework + MobileDevice.framework). " +
            "iOS sandboxed apps cannot invoke that chain, and AirLift ships no device-side app, " +
            "API, or VPN component. No LocalDevVPN tunnel was detected either (10.7.0.1:62078 " +
            "unreachable). Use airlift on a Mac paired with this iPhone, or connect LocalDevVPN " +
            "to enable on-device lockdown access.")
    }
}
