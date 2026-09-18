import Foundation

/// CDTunnel handshake over the TLS-PSK stream. Direct port of idevice
/// `tunnel.rs` / `remote_pairing/tunnel.rs` handshake half (the raw-IPv6
/// packet layer is NOT needed on-device: LocalDevVPN already routes
/// 10.7.0.1 to the phone, so after this handshake we open plain TCP to the
/// advertised service ports through the tunnel instead of feeding packets
/// into a userspace TCP stack).
///
/// Request: `"CDTunnel"` + u16BE(len) + `{"type":"clientHandshakeRequest",
/// "mtu":16000}`. Response: same framing, JSON with `clientParameters`
/// (address/mtu/netmask), `serverAddress`, `serverRSDPort`.
struct CDTunnel {
    struct Info: Equatable {
        let clientAddress: String
        let netmask: String
        let serverAddress: String
        let mtu: UInt16
        let serverRSDPort: UInt16
    }

    static let magic = Data("CDTunnel".utf8)
    static let mtu: UInt16 = 16000

    enum TunnelError: Error, Equatable {
        case badMagic
        case truncated
        case invalidJSON
        case missingField(String)
    }

    static func handshakeRequest() -> Data {
        let body = try? JSONSerialization.data(
            withJSONObject: ["type": "clientHandshakeRequest", "mtu": Int(mtu)], options: [])
        var out = Data()
        out.append(magic)
        out.append(contentsOf: RPPairingWire.withBE16(UInt16(body?.count ?? 0)))
        out.append(contentsOf: body ?? Data())
        return out
    }

    static func parseResponse(_ data: Data) throws -> Info {
        guard data.count >= magic.count + 2,
              data.prefix(magic.count) == magic else {
            throw TunnelError.badMagic
        }
        let length = Int(RPPairingWire.be16(data, at: magic.count))
        let start = data.startIndex + magic.count + 2
        guard data.count >= magic.count + 2 + length else { throw TunnelError.truncated }
        let body = data[start..<(start + length)]
        guard let json = try? JSONSerialization.jsonObject(with: body, options: []) as? [String: Any] else {
            throw TunnelError.invalidJSON
        }
        func string(_ dict: [String: Any], _ key: String) throws -> String {
            guard let value = dict[key] as? String else { throw TunnelError.missingField(key) }
            return value
        }
        guard let params = json["clientParameters"] as? [String: Any] else {
            throw TunnelError.missingField("clientParameters")
        }
        let mtuValue = (params["mtu"] as? NSNumber)?.uint16Value ?? 1500
        let rsdPort = (json["serverRSDPort"] as? NSNumber)?.uint16Value ?? 0
        return Info(clientAddress: try string(params, "address"),
                    netmask: (params["netmask"] as? String) ?? "",
                    serverAddress: try string(json, "serverAddress"),
                    mtu: mtuValue,
                    serverRSDPort: rsdPort)
    }
}
