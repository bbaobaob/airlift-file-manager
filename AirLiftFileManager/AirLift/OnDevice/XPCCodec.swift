import Foundation

/// Apple XPC binary codec + RemoteXPC message wrapper. Direct port of
/// idevice `xpc/format.rs`.
///
/// Object layout: magic u32LE (0x42133742) + version u32LE (5) + object.
/// Types: Null 0x1000, Bool 0x2000 (+1 byte + 3 pad), Int64 0x3000 (+8),
/// UInt64 0x4000 (+8), Double 0x5000 (+8), Date 0x7000 (+u64 ns since epoch),
/// Data 0x8000 (+u32 len + bytes + pad), String 0x9000 (+u32 len-incl-NUL +
/// bytes + NUL + pad), Uuid 0xa000 (+16), Array 0xe000 (+u32 count + u32
/// content-len + items), Dictionary 0xf000 (+u32 count + u32 content-len +
/// entries[key + NUL + pad + object]).
/// Message wrapper (24B): magic u32LE (0x29b00b92) + flags u32LE +
/// body_len u64LE + message_id u64LE + body.
enum XPCCodec {
    enum Object {
        case null
        case bool(Bool)
        case int64(Int64)
        case uint64(UInt64)
        case double(Double)
        case date(Date)
        case string(String)
        case data(Data)
        case uuid(UUID)
        case array([Object])
        case dictionary([(String, Object)])
    }

    enum Flag: UInt32 {
        case alwaysSet = 0x00000001
        case data = 0x00000100
        case reply = 0x00020000
        case wantingReply = 0x00010000
        case initHandshake = 0x00400000
        case custom201 = 0x201
    }

    struct Message {
        let flags: UInt32
        let object: Object?
        let messageId: UInt64
    }

    // Tuples are not Equatable, so equality is spelled out manually.
    static func objectsEqual(_ lhs: Object, _ rhs: Object) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int64(let a), .int64(let b)): return a == b
        case (.uint64(let a), .uint64(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.date(let a), .date(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.data(let a), .data(let b)): return a == b
        case (.uuid(let a), .uuid(let b)): return a == b
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy(objectsEqual)
        case (.dictionary(let a), .dictionary(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { x, y in
                x.0 == y.0 && objectsEqual(x.1, y.1)
            }
        default: return false
        }
    }

    enum CodecError: Error, Equatable {
        case truncated
        case badMagic
        case badVersion
        case unknownType(UInt32)
        case invalidUTF8
    }

    // MARK: - Padding

    static func padding(_ length: Int) -> Int {
        let chunks = Int(ceil(Double(length) / 4.0))
        return chunks * 4 - length
    }

    // MARK: - Encode

    static func encode(_ object: Object) -> Data {
        var out = Data()
        out.append(contentsOf: withLE32(0x42133742))
        out.append(contentsOf: withLE32(0x00000005))
        encodeObject(object, into: &out)
        return out
    }

    static func encodeObject(_ object: Object, into out: inout Data) {
        switch object {
        case .null:
            out.append(contentsOf: withLE32(0x00001000))
        case .bool(let value):
            out.append(contentsOf: withLE32(0x00002000))
            out.append(contentsOf: [value ? 1 : 0, 0, 0, 0])
        case .int64(let value):
            out.append(contentsOf: withLE32(0x00003000))
            out.append(contentsOf: withLE64(UInt64(bitPattern: value)))
        case .uint64(let value):
            out.append(contentsOf: withLE32(0x00004000))
            out.append(contentsOf: withLE64(value))
        case .double(let value):
            out.append(contentsOf: withLE32(0x00005000))
            out.append(contentsOf: withLE64(value.bitPattern))
        case .date(let value):
            out.append(contentsOf: withLE32(0x00007000))
            let nanos = UInt64(value.timeIntervalSince1970 * 1_000_000_000)
            out.append(contentsOf: withLE64(nanos))
        case .data(let value):
            out.append(contentsOf: withLE32(0x00008000))
            out.append(contentsOf: withLE32(UInt32(value.count)))
            out.append(contentsOf: value)
            out.append(contentsOf: Data(repeating: 0, count: padding(value.count)))
        case .string(let value):
            let bytes = Array(value.utf8)
            out.append(contentsOf: withLE32(0x00009000))
            out.append(contentsOf: withLE32(UInt32(bytes.count + 1)))
            out.append(contentsOf: bytes)
            out.append(0x00)
            out.append(contentsOf: Data(repeating: 0, count: padding(bytes.count + 1)))
        case .uuid(let value):
            out.append(contentsOf: withLE32(0x0000a000))
            out.append(contentsOf: uuidBytes(value))
        case .array(let items):
            out.append(contentsOf: withLE32(0x0000e000))
            var content = Data()
            content.append(contentsOf: withLE32(UInt32(items.count)))
            for item in items { encodeObject(item, into: &content) }
            out.append(contentsOf: withLE32(UInt32(content.count)))
            out.append(contentsOf: content)
        case .dictionary(let entries):
            out.append(contentsOf: withLE32(0x0000f000))
            var content = Data()
            content.append(contentsOf: withLE32(UInt32(entries.count)))
            for (key, value) in entries {
                let keyBytes = Array(key.utf8)
                content.append(contentsOf: keyBytes)
                content.append(0x00)
                content.append(contentsOf: Data(repeating: 0, count: padding(keyBytes.count + 1)))
                encodeObject(value, into: &content)
            }
            out.append(contentsOf: withLE32(UInt32(content.count)))
            out.append(contentsOf: content)
        }
    }

    static func encodeMessage(_ message: Message) -> Data {
        var out = Data()
        out.append(contentsOf: withLE32(0x29b00b92))
        out.append(contentsOf: withLE32(message.flags))
        if let object = message.object {
            let body = encode(object)
            out.append(contentsOf: withLE64(UInt64(body.count)))
            out.append(contentsOf: withLE64(message.messageId))
            out.append(contentsOf: body)
        } else {
            out.append(contentsOf: withLE64(0))
            out.append(contentsOf: withLE64(message.messageId))
        }
        return out
    }

    // MARK: - Decode

    struct Reader {
        let data: Data
        var pos: Data.Index

        init(_ data: Data) {
            self.data = data
            self.pos = data.startIndex
        }

        mutating func read(_ count: Int) throws -> Data {
            guard let end = data.index(pos, offsetBy: count, limitedBy: data.endIndex),
                  end <= data.endIndex else { throw CodecError.truncated }
            defer { pos = end }
            return data[pos..<end]
        }

        mutating func u32() throws -> UInt32 {
            let bytes = try read(4)
            return (UInt32(bytes[bytes.startIndex]) | (UInt32(bytes[bytes.startIndex + 1]) << 8)
                | (UInt32(bytes[bytes.startIndex + 2]) << 16)
                | (UInt32(bytes[bytes.startIndex + 3]) << 24))
        }

        mutating func u64() throws -> UInt64 {
            let bytes = try read(8)
            var value: UInt64 = 0
            for i in 0..<8 { value |= UInt64(bytes[bytes.startIndex + i]) << (8 * i) }
            return value
        }
    }

    /// Decodes one message; returns message + total bytes consumed.
    /// Throws truncated-equivalent when the buffer doesn't hold a whole message.
    static func decodeMessage(_ data: Data) throws -> (message: Message, consumed: Int) {
        var reader = Reader(data)
        guard (try? reader.read(0)) != nil else { throw CodecError.truncated }
        guard data.count >= 24 else { throw CodecError.truncated }
        let magic = try reader.u32()
        guard magic == 0x29b00b92 else { throw CodecError.badMagic }
        let flags = try reader.u32()
        let bodyLength = try reader.u64()
        let messageId = try reader.u64()
        guard data.count >= 24 + Int(bodyLength) else { throw CodecError.truncated }
        let object: Object?
        if bodyLength > 0 {
            var bodyReader = Reader(data[data.startIndex + 24..<(data.startIndex + 24 + Int(bodyLength))])
            object = try decodeTopLevel(&bodyReader)
        } else {
            object = nil
        }
        return (Message(flags: flags, object: object, messageId: messageId),
                24 + Int(bodyLength))
    }

    static func decodeTopLevel(_ reader: inout Reader) throws -> Object {
        let magic = try reader.u32()
        guard magic == 0x42133742 else { throw CodecError.badMagic }
        let version = try reader.u32()
        guard version == 0x00000005 else { throw CodecError.badVersion }
        return try decodeObject(&reader)
    }

    static func decodeObject(_ reader: inout Reader) throws -> Object {
        let type = try reader.u32()
        switch type {
        case 0x00001000:
            return .null
        case 0x00002000:
            let bytes = try reader.read(4)
            return .bool(bytes[bytes.startIndex] != 0)
        case 0x00003000:
            return .int64(Int64(bitPattern: try reader.u64()))
        case 0x00004000:
            return .uint64(try reader.u64())
        case 0x00005000:
            return .double(Double(bitPattern: try reader.u64()))
        case 0x00007000:
            let nanos = try reader.u64()
            return .date(Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000))
        case 0x00008000:
            let length = Int(try reader.u32())
            let bytes = try reader.read(length)
            _ = try reader.read(padding(length))
            return .data(Data(bytes))
        case 0x00009000:
            let length = Int(try reader.u32())
            let bytes = try reader.read(length)
            _ = try reader.read(padding(length))
            let content = bytes.prefix(max(0, length - 1))
            guard let string = String(data: Data(content), encoding: .utf8) else {
                throw CodecError.invalidUTF8
            }
            return .string(string)
        case 0x0000a000:
            let bytes = try reader.read(16)
            return .uuid(uuid(from: bytes))
        case 0x0000e000:
            _ = try reader.u32() // content length (count lives inside content)
            let count = Int(try reader.u32())
            var items: [Object] = []
            for _ in 0..<count { items.append(try decodeObject(&reader)) }
            return .array(items)
        case 0x0000f000:
            _ = try reader.u32() // content length (count lives inside content)
            let count = Int(try reader.u32())
            var entries: [(String, Object)] = []
            for _ in 0..<count {
                var keyBytes = Data()
                while true {
                    let byte = try reader.read(1)
                    if byte[byte.startIndex] == 0 { break }
                    keyBytes.append(contentsOf: byte)
                }
                _ = try reader.read(padding(keyBytes.count + 1))
                guard let key = String(data: keyBytes, encoding: .utf8) else {
                    throw CodecError.invalidUTF8
                }
                entries.append((key, try decodeObject(&reader)))
            }
            return .dictionary(entries)
        default:
            throw CodecError.unknownType(type)
        }
    }

    // MARK: - Conversion to plain Swift values (for RSD parsing)

    static func plainValue(_ object: Object) -> Any {
        switch object {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int64(let value): return value
        case .uint64(let value): return value
        case .double(let value): return value
        case .date(let value): return value
        case .string(let value): return value
        case .data(let value): return value
        case .uuid(let value): return value.uuidString
        case .array(let items): return items.map { plainValue($0) }
        case .dictionary(let entries):
            var out: [String: Any] = [:]
            for (key, value) in entries { out[key] = plainValue(value) }
            return out
        }
    }

    // MARK: - Byte helpers

    static func withLE32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
         UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)]
    }

    static func withLE64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> (8 * $0)) & 0xff) }
    }

    static func uuidBytes(_ uuid: UUID) -> Data {
        var string = uuid.uuidString.replacingOccurrences(of: "-", with: "")
        var out = Data()
        while !string.isEmpty {
            let pair = String(string.prefix(2))
            string = String(string.dropFirst(2))
            out.append(UInt8(pair, radix: 16) ?? 0)
        }
        return out
    }

    static func uuid(from data: Data) -> UUID {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let dashed = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-" +
            "\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-" +
            "\(hex.dropFirst(20))"
        return UUID(uuidString: String(dashed)) ?? UUID()
    }
}
