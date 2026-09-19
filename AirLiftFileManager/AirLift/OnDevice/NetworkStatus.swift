import Foundation
import Darwin

/// Local interface detection, ported from AirCard's NetworkStatus (itself
/// ported from SideInstaller): enumerates IPv4 interfaces so tunnel-port
/// dials can try the Wi-Fi address first, exactly like the working stacks.
/// The device's createListener port is reachable via Wi-Fi for a paired host;
///
/// Reference behavior copied:
/// - tunnel interface names: utun*/ipsec*/tap*/ppp*
/// - candidates: Wi-Fi (en0) first, tunnel & loopback excluded.
enum NetworkStatus {
    struct Interface {
        let name: String
        let ipv4: String
        let netmask: String?
    }

    static func interfaces() -> [Interface] {
        var result: [Interface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let addr = cur.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            guard let ipv4 = numericHost(addr) else { continue }
            result.append(Interface(name: name, ipv4: ipv4,
                                    netmask: cur.pointee.ifa_netmask.flatMap(numericHost)))
        }
        return result
    }

    /// Local interface addresses to try for the tunnel listener port.
    /// Wi-Fi (en0) first, tunnel & loopback excluded — AirCard order.
    static func tunnelHostCandidates() -> [String] {
        let ifs = interfaces().filter {
            !isTunnelInterface($0.name) && !$0.ipv4.hasPrefix("127.")
        }
        return (ifs.filter { $0.name == "en0" } + ifs.filter { $0.name != "en0" })
            .map(\.ipv4)
    }

    static func isTunnelInterface(_ name: String) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("ipsec")
            || name.hasPrefix("tap") || name.hasPrefix("ppp")
    }

    // MARK: - Pure helpers (unit-tested)

    static func ipv4Value(_ ip: String) -> UInt32? {
        let octets = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var value: UInt32 = 0
        for octet in octets {
            guard let byte = UInt8(octet) else { return nil }
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    private static func numericHost(_ addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
        else { return nil }
        return String(cString: host)
    }
}
