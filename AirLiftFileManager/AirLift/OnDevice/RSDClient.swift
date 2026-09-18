import Foundation

/// RSD (Remote Service Discovery) client. Direct port of idevice
/// `services/rsd.rs` RsdHandshake: XPC handshake over the service
/// connection, then parse the Services dictionary
/// (`{name: {Entitlement, Port (string!), Properties?{UsesRemoteXPC,
/// Features, ServiceVersion}}}`), MessagingProtocolVersion and UUID.
struct RSDClient {
    struct Service: Equatable {
        let name: String
        let entitlement: String
        let port: UInt16
    }

    struct Handshake: Equatable {
        let services: [String: Service]
        let protocolVersion: Int
        let uuid: String

        func port(for serviceName: String) -> UInt16? {
            services[serviceName]?.port
        }
    }

    /// AFC service name on RSD (idevice `RsdService for AfcClient`).
    static let afcServiceName = "com.apple.afc.shim.remote"

    enum RSDError: Error, Equatable {
        case missingServices
        case missingField(String)
        case serviceNotFound(String)
    }

    /// Runs the RSD handshake on an already-connected TCP stream.
    static func handshake(stream: TCPStream, timeout: TimeInterval = 10) async throws -> Handshake {
        let xpc = try await RemoteXPCClient(stream: stream, timeout: timeout)
        try await xpc.doHandshake()
        try await xpc.sendDeviceHandshake()
        let root = try await xpc.recvRoot()
        return try parseHandshake(root)
    }

    /// Pure, unit-tested: parses the RSD handshake dictionary.
    static func parseHandshake(_ root: [String: Any]) throws -> Handshake {
        guard let servicesDict = root["Services"] as? [String: Any] else {
            throw RSDError.missingServices
        }
        var services: [String: Service] = [:]
        for (name, raw) in servicesDict {
            guard let service = raw as? [String: Any],
                  let entitlement = service["Entitlement"] as? String,
                  let portString = service["Port"] as? String,
                  let port = UInt16(portString) else {
                continue // idevice warns and skips malformed entries
            }
            services[name] = Service(name: name, entitlement: entitlement, port: port)
        }
        guard let version = root["MessagingProtocolVersion"] as? Int64
                ?? (root["MessagingProtocolVersion"] as? Int).map(Int64.init) else {
            throw RSDError.missingField("MessagingProtocolVersion")
        }
        guard let uuid = root["UUID"] as? String else {
            throw RSDError.missingField("UUID")
        }
        return Handshake(services: services, protocolVersion: Int(version), uuid: uuid)
    }

    /// RSDCheckin exchange on a fresh service connection (idevice
    /// `Idevice::rsd_checkin`): send {Label, ProtocolVersion "2",
    /// Request RSDCheckin} as u32BE-length-prefixed XML plist; expect a
    /// plist with Request RSDCheckin, then one with Request StartService.
    static func checkin(stream: TCPStream, label: String,
                        timeout: TimeInterval = 10) async throws {
        let request: [String: Any] = ["Label": label, "ProtocolVersion": "2",
                                      "Request": "RSDCheckin"]
        try await stream.write(framedPlist(request), timeout: timeout)
        let first = try await readFramedPlist(stream: stream, timeout: timeout)
        guard first["Request"] as? String == "RSDCheckin" else {
            throw RSDError.missingField("RSDCheckin acknowledgement")
        }
        let second = try await readFramedPlist(stream: stream, timeout: timeout)
        guard second["Request"] as? String == "StartService" else {
            throw RSDError.missingField("StartService announcement")
        }
    }

    static func framedPlist(_ dict: [String: Any]) throws -> Data {
        let body = try PropertyListSerialization.data(fromPropertyList: dict,
                                                      format: .xml, options: 0)
        var out = Data()
        let length = UInt32(body.count)
        out.append(contentsOf: [UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
                                UInt8((length >> 8) & 0xff), UInt8(length & 0xff)])
        out.append(contentsOf: body)
        return out
    }

    static func readFramedPlist(stream: TCPStream,
                                timeout: TimeInterval) async throws -> [String: Any] {
        let header = try await stream.readExactly(4, timeout: timeout)
        let length = (Int(header[header.startIndex]) << 24)
            | (Int(header[header.startIndex + 1]) << 16)
            | (Int(header[header.startIndex + 2]) << 8)
            | Int(header[header.startIndex + 3])
        let body = try await stream.readExactly(length, timeout: timeout)
        guard let dict = try? PropertyListSerialization.propertyList(
            from: body, format: nil) as? [String: Any] else {
            throw RSDError.missingField("plist dictionary")
        }
        return dict
    }
}
