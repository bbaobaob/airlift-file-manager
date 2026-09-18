import Foundation

/// Wireless-pairing endpoint discovery — step 1 of the real wireless chain.
///
/// idevice (`idevice_pair::wireless::open_link`) works like this:
/// 1. Browse mDNS `_remotepairing._tcp`, validate each service's TXT
///    `authTag` against the pairing file's `alt_irk` (SipHash-2-4).
/// 2. Open an encrypted RemotePairing session to the matching device.
/// 3. Run RSD (Remote Service Discovery) over that session → lockdown.
///
/// This module implements step 1 for real (live NetServiceBrowser discovery
/// like StikPair's own, plus the exact authTag math). Steps 2–3 are NOT
/// implemented yet and are reported honestly wherever they surface.
struct WirelessPairingDiscovery {
    static let serviceType = "_remotepairing._tcp."
    static let serviceDomain = "local."

    struct DiscoveredService: Equatable {
        let name: String
        /// TCP port from the mDNS SRV record (0 until resolved).
        var port: UInt16
        /// TXT "identifier" — the service identifier the authTag binds to.
        let identifier: String?
        /// TXT "authTag" — standard-base64 6-byte tag.
        let authTag: String?
    }

    /// Pure, unit-tested: does this advertised service accept our credential?
    static func matchesCredential(service: DiscoveredService, altIrk: Data) -> Bool {
        guard altIrk.count == 16,
              let identifier = service.identifier, !identifier.isEmpty,
              let authTag = service.authTag, !authTag.isEmpty else {
            return false
        }
        return RemotePairingAuth.validates(authTagBase64: authTag,
                                           altIrk: altIrk,
                                           serviceIdentifier: identifier)
    }

    /// Parses a TXT record blob into (identifier, authTag).
    static func parseTXT(_ data: Data) -> (identifier: String?, authTag: String?) {
        // Non-optional API: garbage yields an empty dictionary.
        let dict = NetService.dictionary(fromTXTRecord: data)
        func string(_ key: String) -> String? {
            guard let raw = dict[key] else { return nil }
            return String(data: raw, encoding: .utf8)
        }
        return (string("identifier"), string("authTag"))
    }
}

/// Live mDNS browser. A fresh instance per browse; bounded by timeouts.
/// Requires NSLocalNetworkUsageDescription + NSBonjourServices (Info.plist) —
/// iOS prompts once, exactly like StikPair's own discovery.
@MainActor
final class WirelessPairingBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private var browser: NetServiceBrowser?
    private var pending: [NetService] = []
    private var services: [WirelessPairingDiscovery.DiscoveredService] = []
    private var resolveContinuation: CheckedContinuation<Void, Never>?

    /// Browse, then resolve everything found. Never hangs: every wait is bounded.
    func browse(timeout: TimeInterval = 6) async -> [WirelessPairingDiscovery.DiscoveredService] {
        services = []
        pending = []
        let active = NetServiceBrowser()
        browser = active
        active.delegate = self
        active.searchForServices(ofType: WirelessPairingDiscovery.serviceType,
                                 inDomain: WirelessPairingDiscovery.serviceDomain)
        AppLogger.net.info("Browsing \(WirelessPairingDiscovery.serviceType) (wireless pairing)",
                           event: "wireless.discover")
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        active.stop()
        for service in pending {
            await resolve(service, timeout: 2)
        }
        browser = nil
        pending = []
        AppLogger.net.info("Wireless discovery finished: \(services.count) service(s)",
                           event: "wireless.discover")
        return services
    }

    private func resolve(_ service: NetService, timeout: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            resolveContinuation = continuation
            service.delegate = self
            service.resolve(withTimeout: timeout)
        }
        resolveContinuation = nil
        let (identifier, authTag) = WirelessPairingDiscovery.parseTXT(
            service.txtRecordData() ?? Data())
        services.append(WirelessPairingDiscovery.DiscoveredService(
            name: service.name, port: UInt16(service.port),
            identifier: identifier, authTag: authTag))
    }

    // MARK: - NetServiceBrowserDelegate

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService,
                           moreComing: Bool) {
        pending.append(service)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didNotSearch errorDict: [String: NSNumber]) {
        AppLogger.net.error("mDNS search failed: \(errorDict)", event: "wireless.discover")
    }

    // MARK: - NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        resolveContinuation?.resume()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        AppLogger.net.warning("Service did not resolve: \(sender.name)", event: "wireless.discover")
        resolveContinuation?.resume()
    }
}
