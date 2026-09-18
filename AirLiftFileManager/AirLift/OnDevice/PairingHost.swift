import CryptoKit
import CryptoKit
import Foundation
import Network
import Security

/// In-app pairing host (StikPair flow, no separate app needed). Direct port
/// of idevice `remote_pairing/responder.rs` PairableHost (+ StikPair's own
/// usage): this phone advertises `_remotepairing-pairable-host._tcp`, the
/// user taps "Pair with AirLift" in Settings › Developer Mode, enters the
/// 6-digit PIN shown here, and SRP pair-setup (M1–M6) produces a valid
/// RpPairingFile that is saved to the Keychain through the normal import
/// path (validated, never logged).
///
/// License note: protocol port only — no StikPair/idevice code is copied.
/// See docs/ATTRIBUTION.md (idevice MIT, StikPair MIT non-commercial).
struct PairingHost {
    /// Identity this host presents (persisted in Keychain across runs so
    /// paired devices keep recognizing us).
    struct HostIdentity: Equatable {
        let seed: Data        // 32-byte Ed25519 seed (secret)
        let publicKey: Data   // 32-byte Ed25519 public key
        let identifier: String // UUID string
        let altIrk: Data      // 16-byte mDNS identity key (sensitive)
        let name: String
        let model: String

        static func generate(name: String = "AirLift", model: String = "Mac17,7") -> HostIdentity {
            // Random Ed25519 keypair; rawRepresentation is the 32-byte seed.
            // (Any 32 bytes form a valid seed; generating the key first
            // avoids any throwing initializer.)
            let privateKey = Curve25519.Signing.PrivateKey()
            let seed = Data(privateKey.rawRepresentation)
            var irk = Data(count: 16)
            for i in irk.indices { irk[i] = UInt8.random(in: 0...255) }
            return HostIdentity(seed: seed,
                                publicKey: Data(privateKey.publicKey.rawRepresentation),
                                identifier: UUID().uuidString,
                                altIrk: irk,
                                name: name,
                                model: model)
        }

        func plist() -> [String: Any] {
            ["seed": seed, "publicKey": publicKey, "identifier": identifier,
             "altIrk": altIrk, "name": name, "model": model]
        }

        static func from(plist dict: [String: Any]) -> HostIdentity? {
            guard let seed = dict["seed"] as? Data, seed.count == 32,
                  let publicKey = dict["publicKey"] as? Data, publicKey.count == 32,
                  let identifier = dict["identifier"] as? String,
                  UUID(uuidString: identifier) != nil,
                  let altIrk = dict["altIrk"] as? Data, altIrk.count == 16,
                  let name = dict["name"] as? String,
                  let model = dict["model"] as? String else {
                return nil
            }
            return HostIdentity(seed: seed, publicKey: publicKey, identifier: identifier,
                                altIrk: altIrk, name: name, model: model)
        }
    }

    struct PeerDevice: Equatable {
        let accountID: String
        let altIrk: Data
        let model: String
        let name: String
        let udid: String
    }

    enum PairError: Error, Equatable {
        case listenerFailed(String)
        case publishFailed(String)
        case timeout(String)
        case protocolError(String)
        case srpFailed(String)
        case cancelled
    }

    // MARK: - mDNS TXT records (responder mdns_txt_records)

    static let serviceType = "_remotepairing-pairable-host._tcp."
    static let serviceDomain = "local."

    /// (key, value) TXT pairs; authTag = base64(SipHash(authTag inputs)).
    static func txtRecords(identity: HostIdentity) -> [(String, String)] {
        let tag = RemotePairingAuth.computeAuthTag(altIrk: Array(identity.altIrk),
                                                   serviceIdentifier: identity.identifier) ?? []
        return [
            ("name", identity.name),
            ("identifier", identity.identifier),
            ("authTag", Data(tag).base64EncodedString()),
            ("model", identity.model),
            ("flags", "1"),
            ("ver", "26"),
            ("minVer", "17"),
        ]
    }

    static func txtRecordData(identity: HostIdentity) -> Data {
        var dict: [String: Data] = [:]
        for (key, value) in txtRecords(identity: identity) {
            dict[key] = Data(value.utf8)
        }
        return NetService.data(fromTXTRecord: dict)
    }

    // MARK: - Pair-setup messages (pure builders, tested)

    static func handshakeReply(identity: HostIdentity) -> [String: Any] {
        ["response": ["forRequestIdentifier": 0, "_1": ["handshake": ["_0": [
            "wireProtocolVersion": 26,
            "minimumSupportedWireProtocolVersion": 8,
            "deviceOptions": [
                "allowsPairSetup": true,
                "allowsPinlessPairing": false,
                "allowsIncomingTunnelConnections": false,
                "allowsUpgradeOfLockdownPairings": false,
                "allowsSharingSensitiveInfo": false,
            ],
            "peerDeviceInfo": [
                "udid": "",
                "deviceKVSIncludesSensitiveInfo": false,
                "identifier": identity.identifier,
                "name": identity.name,
                "model": identity.model,
            ],
        ]]]]]
    }

    static func authFailureTLV() -> Data {
        TLV8.serialize([
            TLV8.Entry(.state, Data([0x04])),
            TLV8.Entry(.errorResponse, Data([0x02])),
        ])
    }
}

// MARK: - Host identity store (Keychain blob + defaults metadata)

/// Persists the pairing-host identity in the Keychain (seed + alt_irk are
/// sensitive; identifier is not). Non-secret presence flag in defaults.
struct HostIdentityStore: Sendable {
    static let service = "com.bbaobaob.airliftfilemanager.pairing-host"
    static let account = "host.identity"
    static let metadataKey = "airlift.pairing-host.present"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PairingHost.HostIdentity? {
        var result: AnyObject?
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let dict = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: Any],
              let identity = PairingHost.HostIdentity.from(plist: dict) else {
            return nil
        }
        return identity
    }

    @discardableResult
    func save(_ identity: PairingHost.HostIdentity) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        guard let blob = try? PropertyListSerialization.data(
            fromPropertyList: identity.plist(), format: .binary, options: 0) else {
            return false
        }
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecValueData as String: blob,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        guard SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess else {
            return false
        }
        defaults.set(true, forKey: Self.metadataKey)
        AppLogger.pairing.info("Pairing-host identity stored in Keychain", event: "pairing.host")
        return true
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
        defaults.removeObject(forKey: Self.metadataKey)
    }

    var hasIdentity: Bool { load() != nil }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }
}
