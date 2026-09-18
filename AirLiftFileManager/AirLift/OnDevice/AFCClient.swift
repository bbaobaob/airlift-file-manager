import Foundation

/// AFC (Apple File Conduit) client over a connected stream. Direct port of
/// idevice `services/afc` packet layer (packet.rs, opcode.rs, mod.rs,
/// inner_file.rs) for exactly the operations the self-test needs.
///
/// Packet: magic u64LE (0x4141504c36414643) + entire_len u64LE +
/// header_payload_len u64LE + packet_num u64LE + operation u64LE (40 bytes),
/// then header_payload, then payload. Responses are Data packets or Status
/// packets (u64LE code in header_payload; 0 = success).
struct AFCClient {
    static let magic: UInt64 = 0x4141504c36414643
    static let headerLength: UInt64 = 40
    static let maxTransfer = 1_048_576

    enum Opcode: UInt64 {
        case status = 0x01
        case data = 0x02
        case readFile = 0x04
        case writeFile = 0x05
        case removePath = 0x08
        case makeDir = 0x09
        case getFileInfo = 0x0a
        case fileOpen = 0x0d
        case fileOpenResult = 0x0e
        case read = 0x0f
        case write = 0x10
        case fileClose = 0x14
        case renamePath = 0x18
    }

    /// fopen modes (idevice AfcFopenMode).
    enum OpenMode: UInt64 {
        case readOnly = 0x01   // r
        case readWrite = 0x02  // r+
        case writeOnly = 0x03  // w (create+truncate)
        case writeRead = 0x04  // w+
        case append = 0x05     // a
    }

    enum AFCError: Error, Equatable {
        case badMagic
        case truncated
        case deviceStatus(UInt64)
        case unexpectedReply(String)
        case shortFileOpenResult
    }

    struct Packet: Equatable {
        let operation: Opcode
        let packetNumber: UInt64
        let headerPayload: Data
        let payload: Data

        static func encode(operation: Opcode, packetNumber: UInt64,
                           headerPayload: Data, payload: Data) -> Data {
            var out = Data()
            out.append(contentsOf: withLE64(magic))
            out.append(contentsOf: withLE64(UInt64(headerLength) + UInt64(headerPayload.count) + UInt64(payload.count)))
            out.append(contentsOf: withLE64(UInt64(headerLength) + UInt64(headerPayload.count)))
            out.append(contentsOf: withLE64(packetNumber))
            out.append(contentsOf: withLE64(operation.rawValue))
            out.append(contentsOf: headerPayload)
            out.append(contentsOf: payload)
            return out
        }

        static func decode(_ data: Data) throws -> Packet {
            guard data.count >= Int(headerLength) else { throw AFCError.truncated }
            guard le64(data, at: 0) == magic else { throw AFCError.badMagic }
            let entire = le64(data, at: 8)
            let headerPayloadLength = le64(data, at: 16)
            let number = le64(data, at: 24)
            guard let operation = Opcode(rawValue: le64(data, at: 32)) else {
                throw AFCError.unexpectedReply("unknown opcode")
            }
            guard data.count >= Int(entire) else { throw AFCError.truncated }
            let headerEnd = Int(headerPayloadLength)
            let headerPayload = data[Int(headerLength)..<headerEnd]
            let payload = data[headerEnd..<Int(entire)]
            return Packet(operation: operation, packetNumber: number,
                          headerPayload: Data(headerPayload), payload: Data(payload))
        }

        static func le64(_ data: Data, at offset: Int) -> UInt64 {
            let base = data.startIndex + offset
            var value: UInt64 = 0
            for i in 0..<8 { value |= UInt64(data[base + i]) << (8 * i) }
            return value
        }

        static func withLE64(_ value: UInt64) -> [UInt8] {
            (0..<8).map { UInt8((value >> (8 * $0)) & 0xff) }
        }
    }

    // MARK: - Live session

    private let stream: TCPStream
    private let timeout: TimeInterval
    private var packetNumber: UInt64 = 0

    init(stream: TCPStream, timeout: TimeInterval = 10) {
        self.stream = stream
        self.timeout = timeout
    }

    /// Opens an AFC session on a fresh service connection: RSDCheckin
    /// exchange, then packets flow.
    func checkin(label: String = "AirLift") async throws {
        try await RSDClient.checkin(stream: stream, label: label, timeout: timeout)
    }

    @discardableResult
    private func exchange(operation: Opcode, headerPayload: Data,
                          payload: Data = Data()) async throws -> Packet {
        let number = packetNumber
        packetNumber += 1
        try await stream.write(Packet.encode(operation: operation, packetNumber: number,
                                             headerPayload: headerPayload, payload: payload),
                               timeout: timeout)
        let header = try await stream.readExactly(Int(Self.headerLength), timeout: timeout)
        let entire = Int(Packet.le64(header, at: 8))
        let rest = try await stream.readExactly(entire - Int(Self.headerLength), timeout: timeout)
        let packet = try Packet.decode(header + rest)
        if packet.operation == .status {
            guard packet.headerPayload.count >= 8 else {
                throw AFCError.unexpectedReply("status without code")
            }
            let code = Packet.le64(packet.headerPayload, at: 0)
            guard code == 0 else { throw AFCError.deviceStatus(code) }
        }
        return packet
    }

    /// FileRefOpen: mode(8LE) + path bytes → device file descriptor.
    func open(path: String, mode: OpenMode) async throws -> UInt64 {
        var headerPayload = Data(Packet.withLE64(mode.rawValue))
        headerPayload.append(contentsOf: Data(path.utf8))
        let reply = try await exchange(operation: .fileOpen, headerPayload: headerPayload)
        guard reply.operation == .fileOpenResult, reply.headerPayload.count >= 8 else {
            throw AFCError.shortFileOpenResult
        }
        return Packet.le64(reply.headerPayload, at: 0)
    }

    func write(fd: UInt64, data: Data) async throws {
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: Self.maxTransfer, limitedBy: data.endIndex)
                ?? data.endIndex
            let chunk = data[offset..<end]
            let headerPayload = Data(Packet.withLE64(fd))
            _ = try await exchange(operation: .write, headerPayload: headerPayload,
                                   payload: Data(chunk))
            offset = end
        }
    }

    /// FileRefRead: fd(8LE) + size(8LE) → payload bytes (empty = EOF).
    func read(fd: UInt64, size: Int) async throws -> Data {
        var headerPayload = Data(Packet.withLE64(fd))
        headerPayload.append(contentsOf: Packet.withLE64(UInt64(size)))
        let reply = try await exchange(operation: .read, headerPayload: headerPayload)
        return reply.payload
    }

    func readAll(fd: UInt64) async throws -> Data {
        var out = Data()
        while true {
            let chunk = try await read(fd: fd, size: Self.maxTransfer)
            if chunk.isEmpty { break }
            out.append(contentsOf: chunk)
        }
        return out
    }

    func close(fd: UInt64) async throws {
        _ = try await exchange(operation: .fileClose,
                               headerPayload: Data(Packet.withLE64(fd)))
    }

    func remove(path: String) async throws {
        _ = try await exchange(operation: .removePath,
                               headerPayload: Data(path.utf8))
    }
}
