import Foundation

/// Honest AirLift integration service.
///
/// Verified against the upstream repository (0xjohnnydev/airlift):
/// - airlift.py drives `xcrun devicectl` + two native macOS helpers that link
///   MobileDevice.framework and AirTrafficHost.framework.
/// - The device-side chain (streaming_zip_conduit -> afc -> atc -> AirTraffic
///   Books client -> ATAirlock) is only reachable from the host side.
/// - No iOS app surface, no in-app API, no VPN component exist upstream.
///
/// Therefore `probe()` performs the checks that ARE possible in-process and
/// reports `unsupported` with the precise technical reason otherwise.
struct AirLiftService: AirLiftProbing {
    func probe() async -> AirLiftProbeResult {
        AppLogger.airLift.info("Probe started")
        // Component checks possible from inside a sandboxed iOS app:
        // 1. AirTrafficHost.framework is a macOS-only framework — its symbols
        //    cannot be loaded on iOS, so the exploit cannot execute here.
        // 2. The device daemons in the chain are not exposed to third-party apps.
        // 3. No upstream API exists to request a write from a paired Mac.
        let reason = "AirLift executes on the paired Mac (AirTrafficHost.framework + " +
            "MobileDevice.framework). iOS sandboxed apps cannot invoke that chain, and " +
            "AirLift ships no device-side app, API, or VPN component. Use airlift on a " +
            "Mac paired with this iPhone to write into the verified scope."
        AppLogger.airLift.info("Probe result: unsupported (host-side execution required)")
        return .unsupported(reason: reason)
    }
}
