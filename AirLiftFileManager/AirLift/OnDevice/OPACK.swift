import Foundation

/// Apple OPACK codec. Direct port of idevice `remote_pairing/opack.rs`:
/// used to build the M6 accessory-identity blob and to parse the M5 device
/// identity blob during pair-setup.
///
/// Tags: bool 0x01/0x02; ints 0x08–0x2F inline, 0x30/0x31/0x32/0x33 sized;
/// reals 0x35/0x36 (big-endian bits); strings 0x40+len / 0x61..0x64 sized;
/// data 0x70+len / 0x91..0x94 sized; back-refs 0xA0–0xC0 inline index,
/// 0xC1..0xC4 sized index; arrays 0xD0+count / 0xDF + 0x03 terminator;
/// dicts 0xE0+count / 0xEF + 0x03 terminator.
enum OPACK {
    enum Value {
        case bool(Bool)
        case int(UInt64)
        case real(Double)
        case string(String)
        case data(Data)
        case array([Value])
        case dictionary([(String, Value)])
    }

    enum CodecError: Error, Equatable {
        case truncated
        case unsupportedTag(UInt8)
        case badBackReference(Int)
        case unexpectedTerminator
        case trailingBytes(Int)
        case invalidUTF8
    }

    // MARK: - Encode

    static func encode(_ value: Value) -> Data {
        var out = Data()
        encodeInto(value, into: &out)
        return out
    }

    private static func encodeInto(_ value: Value, into out: inout Data) {
        switch value {
        case .bool(let flag):
            out.append(flag ? 0x01 : 0x02)
        case .int(let number):
            if number <= 0x27 {
                out.append(UInt8(8 + number))
            } else if number <= 0xff {
                out.append(contentsOf: [0x30, UInt8(number)])
            } else if number <= 0xffff_ffff {
                out.append(0x32)
                out.append(contentsOf: withLE32(UInt32(number)))
            } else {
                out.append(0x33)
                out.append(contentsOf: withLE64(number))
            }
        case .real(let number):
            let asFloat = Float(number)
            if Double(asFloat) == number {
                out.append(0x35)
                out.append(contentsOf: withBE32(asFloat.bitPattern))
            } else {
                out.append(0x36)
                out.append(contentsOf: withBE64(number.bitPattern))
            }
        case .string(let text):
            let bytes = Array(text.utf8)
            encodeSized(base: 0x40, extended: [0x61, 0x62, 0x63, 0x64],
                        length: bytes.count, into: &out)
            out.append(contentsOf: bytes)
        case .data(let blob):
            encodeSized(base: 0x70, extended: [0x91, 0x92, 0x93, 0x94],
                        length: blob.count, into: &out)
            out.append(contentsOf: blob)
        case .array(let items):
            if items.count < 15 {
                out.append(UInt8(0xD0 + items.count))
                for item in items { encodeInto(item, into: &out) }
            } else {
                out.append(0xDF)
                for item in items { encodeInto(item, into: &out) }
                out.append(0x03)
            }
        case .dictionary(let entries):
            if entries.count < 15 {
                out.append(UInt8(0xE0 + entries.count))
                for (key, value) in entries {
                    encodeInto(.string(key), into: &out)
                    encodeInto(value, into: &out)
                }
            } else {
                out.append(0xEF)
                for (key, value) in entries {
                    encodeInto(.string(key), into: &out)
                    encodeInto(value, into: &out)
                }
                out.append(0x03)
            }
        }
    }

    private static func encodeSized(base: UInt8, extended: [UInt8],
                                    length: Int, into out: inout Data) {
        if length <= 0x20 {
            out.append(base + UInt8(length))
        } else if length <= 0xff {
            out.append(contentsOf: [extended[0], UInt8(length)])
        } else if length <= 0xffff {
            out.append(extended[1])
            out.append(contentsOf: withLE16(UInt16(length)))
        } else if length <= 0xffff_ffff {
            out.append(extended[2])
            out.append(contentsOf: withLE32(UInt32(length)))
        } else {
            out.append(extended[3])
            out.append(contentsOf: withLE64(UInt64(length)))
        }
    }

    // MARK: - Decode

    struct Reader {
        let data: Data
        var pos: Data.Index
        var objects: [Value] = []

        mutating func read(_ count: Int) throws -> Data {
            guard let end = data.index(pos, offsetBy: count, limitedBy: data.endIndex),
                  end <= data.endIndex else { throw CodecError.truncated }
            defer { pos = end }
            return data[pos..<end]
        }

        mutating func byte() throws -> UInt8 {
            let bytes = try read(1)
            return bytes[bytes.startIndex]
        }
    }

    static func decode(_ data: Data) throws -> Value {
        var reader = Reader(data: data, pos: data.startIndex)
        let value = try decodeValue(&reader)
        guard reader.pos == data.endIndex else {
            throw CodecError.trailingBytes(data.count - reader.pos)
        }
        return value
    }

    static func decodeValue(_ reader: inout Reader) throws -> Value {
        let tag = try reader.byte()
        switch tag {
        case 0x01: return .bool(true)
        case 0x02: return .bool(false)
        case 0x08...0x2F: return .int(UInt64(tag) - 8)
        case 0x30:
            let value = UInt64(try reader.byte())
            return remember(.int(value), in: &reader)
        case 0x31:
            let bytes = try reader.read(2)
            return remember(.int(UInt64(le16(bytes))), in: &reader)
        case 0x32:
            let bytes = try reader.read(4)
            return remember(.int(UInt64(le32(bytes))), in: &reader)
        case 0x33:
            let bytes = try reader.read(8)
            return remember(.int(le64(bytes)), in: &reader)
        case 0x35:
            let bytes = try reader.read(4)
            let bits = UInt32(bigEndianBytes: bytes)
            return remember(.real(Double(Float(bitPattern: bits))), in: &reader)
        case 0x36:
            let bytes = try reader.read(8)
            return remember(.real(Double(bitPattern: le64toBE(bytes))), in: &reader)
        case 0x40...0x64:
            let value = try readSized(base: 0x40, extended: [0x61, 0x62, 0x63, 0x64],
                                      tag: tag, reader: &reader)
            guard let text = String(data: value, encoding: .utf8) else {
                throw CodecError.invalidUTF8
            }
            return remember(.string(text), in: &reader)
        case 0x70...0x94:
            let value = try readSized(base: 0x70, extended: [0x91, 0x92, 0x93, 0x94],
                                      tag: tag, reader: &reader)
            return remember(.data(value), in: &reader)
        case 0xA0...0xC0:
            return try lookup(Int(tag) - 0xA0, in: &reader)
        case 0xC1...0xC4:
            let widths = [1, 2, 4, 8]
            let bytes = try reader.read(widths[Int(tag) - 0xC1])
            var index = 0
            for (i, byte) in bytes.enumerated() {
                index |= Int(byte) << (8 * i)
            }
            return try lookup(index, in: &reader)
        case 0xD0...0xDE:
            return try parseArray(count: Int(tag) - 0xD0, reader: &reader)
        case 0xDF:
            return try parseArray(count: nil, reader: &reader)
        case 0xE0...0xEE:
            return try parseDictionary(count: Int(tag) - 0xE0, reader: &reader)
        case 0xEF:
            return try parseDictionary(count: nil, reader: &reader)
        case 0x03:
            throw CodecError.unexpectedTerminator
        default:
            throw CodecError.unsupportedTag(tag)
        }
    }

    private static func remember(_ value: Value, in reader: inout Reader) -> Value {
        if !reader.objects.contains(where: { isEqual($0, value) }) {
            reader.objects.append(value)
        }
        return value
    }

    /// Tuples are not Equatable, so equality is spelled out manually.
    static func isEqual(_ lhs: Value, _ rhs: Value) -> Bool {
        switch (lhs, rhs) {
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.real(let a), .real(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.data(let a), .data(let b)): return a == b
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy(isEqual)
        case (.dictionary(let a), .dictionary(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { x, y in
                x.0 == y.0 && isEqual(x.1, y.1)
            }
        default: return false
        }
    }

    private static func lookup(_ index: Int, in reader: inout Reader) throws -> Value {
        guard index < reader.objects.count else {
            throw CodecError.badBackReference(index)
        }
        return reader.objects[index]
    }

    private static func readSized(base: UInt8, extended: [UInt8], tag: UInt8,
                                  reader: inout Reader) throws -> Data {
        if tag < extended[0] {
            return try reader.read(Int(tag) - Int(base))
        }
        switch tag {
        case extended[0]: return try reader.read(Int(try reader.byte()))
        case extended[1]:
            let bytes = try reader.read(2)
            return try reader.read(Int(le16(bytes)))
        case extended[2]:
            let bytes = try reader.read(4)
            return try reader.read(Int(le32(bytes)))
        case extended[3]:
            let bytes = try reader.read(8)
            let length = le64(bytes)
            guard length <= UInt64(Int.max) else { throw CodecError.truncated }
            return try reader.read(Int(length))
        default: throw CodecError.unsupportedTag(tag)
        }
    }

    private static func parseArray(count: Int?, reader: inout Reader) throws -> Value {
        var items: [Value] = []
        if let count {
            for _ in 0..<count { items.append(try decodeValue(&reader)) }
        } else {
            while true {
                guard reader.pos < reader.data.endIndex else { throw CodecError.truncated }
                if reader.data[reader.pos] == 0x03 {
                    reader.pos = reader.data.index(after: reader.pos)
                    break
                }
                items.append(try decodeValue(&reader))
            }
        }
        return .array(items)
    }

    private static func parseDictionary(count: Int?, reader: inout Reader) throws -> Value {
        var entries: [(String, Value)] = []
        func one() throws {
            let key = try decodeValue(&reader)
            guard case .string(let name) = key else {
                throw CodecError.invalidUTF8
            }
            entries.append((name, try decodeValue(&reader)))
        }
        if let count {
            for _ in 0..<count { try one() }
        } else {
            while true {
                guard reader.pos < reader.data.endIndex else { throw CodecError.truncated }
                if reader.data[reader.pos] == 0x03 {
                    reader.pos = reader.data.index(after: reader.pos)
                    break
                }
                try one()
            }
        }
        return .dictionary(entries)
    }

    // MARK: - Integer helpers

    static func withLE16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]
    }

    static func withLE32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
         UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)]
    }

    static func withLE64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> (8 * $0)) & 0xff) }
    }

    static func withBE32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
         UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    static func withBE64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> (8 * (7 - $0))) & 0xff) }
    }

    static func le16(_ data: Data) -> UInt16 {
        UInt16(data[data.startIndex]) | (UInt16(data[data.startIndex + 1]) << 8)
    }

    static func le32(_ data: Data) -> UInt32 {
        UInt32(data[data.startIndex]) | (UInt32(data[data.startIndex + 1]) << 8)
            | (UInt32(data[data.startIndex + 2]) << 16)
            | (UInt32(data[data.startIndex + 3]) << 24)
    }

    static func le64(_ data: Data) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(data[data.startIndex + i]) << (8 * i) }
        return value
    }
}

private extension UInt32 {
    /// Interprets 4 big-endian bytes as UInt32 (for OPACK float/double bits,
    /// which are stored big-endian per the reference implementation).
    init(bigEndianBytes data: Data) {
        self = (UInt32(data[data.startIndex]) << 24)
            | (UInt32(data[data.startIndex + 1]) << 16)
            | (UInt32(data[data.startIndex + 2]) << 8)
            | UInt32(data[data.startIndex + 3])
    }
}

private func le64toBE(_ data: Data) -> UInt64 {
    var value: UInt64 = 0
    for i in 0..<8 { value = (value << 8) | UInt64(data[data.startIndex + i]) }
    return value
}
