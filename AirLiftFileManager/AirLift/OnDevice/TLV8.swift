import Foundation

/// TLV8 codec (type: u8, length: u8, value) used by the RemotePairing
/// pair-verify handshake. Direct port of idevice `remote_pairing/tlv.rs`
/// for the component types this app uses.
enum TLV8 {
    struct Entry: Equatable {
        let type: UInt8
        let data: Data
    }

    /// HomeKit-style PairingDataComponentType values (idevice tlv.rs).
    enum Component: UInt8 {
        case method = 0x00
        case identifier = 0x01
        case salt = 0x02
        case publicKey = 0x03
        case proof = 0x04
        case encryptedData = 0x05
        case state = 0x06
        case errorResponse = 0x07
        case signature = 0x0a
        case info = 0x11
    }

    static func serialize(_ entries: [Entry]) -> Data {
        var out = Data()
        for entry in entries {
            out.append(entry.type)
            out.append(UInt8(entry.data.count & 0xff))
            out.append(contentsOf: entry.data)
        }
        return out
    }

    enum DecodeError: Error {
        case truncated
    }

    static func deserialize(_ data: Data) throws -> [Entry] {
        var out: [Entry] = []
        var i = data.startIndex
        while i < data.endIndex {
            guard data.index(after: i) < data.endIndex else { throw DecodeError.truncated }
            let type = data[i]
            let length = Int(data[data.index(after: i)])
            let valueStart = data.index(i, offsetBy: 2)
            guard let valueEnd = data.index(valueStart, offsetBy: length, limitedBy: data.endIndex),
                  valueEnd <= data.endIndex else { throw DecodeError.truncated }
            out.append(Entry(type: type, data: data[valueStart..<valueEnd]))
            i = valueEnd
        }
        return out
    }
}

extension TLV8.Entry {
    init(_ component: TLV8.Component, _ data: Data) {
        self.init(type: component.rawValue, data: data)
    }

    var component: TLV8.Component? { TLV8.Component(rawValue: type) }
}
