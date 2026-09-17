import Foundation

enum AppConstants {
    /// Bundle-level identity used across UI and logs.
    static let appName = "AirLift File Manager"

    /// LocalDevVPN / StosVPN-style loopback tunnel endpoint facts.
    enum LocalDevVPN {
        static let tunnelHost = "10.7.0.1"
        static let lockdownPort: UInt16 = 62078
        static let relatedProjects = [
            "SideStore/StosVPN (same NEPacketTunnelProvider mechanism)",
            "StikDebug (connects to 10.7.0.1 for device services)",
            "Locus (LocalDevVPN + pairing file + RemoteXPC)",
        ]
    }

    /// AirLift upstream facts (from github.com/0xjohnnydev/airlift README, verified 2026-09).
    enum AirLift {
        static let repositoryURL = "https://github.com/0xjohnnydev/airlift"
        /// iOS builds the upstream PoC was verified against.
        static let testedBuilds = ["24A435", "24A437"]
        /// Where the exploit actually executes.
        static let executionHost = "macOS (paired Mac)"
        /// Directories where upstream confirmed fresh-file writes.
        static let verifiedWriteScope = [
            "/var/mobile",
            "/var/mobile/Documents",
            "/var/mobile/Library",
            "/var/mobile/Library/Preferences",
            "/var/mobile/Library/Caches",
            "/var/mobile/Library/SpringBoard",
            "/var/mobile/Library/SMS",
            "/var/mobile/Library/Safari",
            "/var/mobile/Containers",
            "/var/mobile/Containers/Data/Application",
            "/var/mobile/Containers/Shared/AppGroup",
            "/var/tmp",
        ]
    }
}
