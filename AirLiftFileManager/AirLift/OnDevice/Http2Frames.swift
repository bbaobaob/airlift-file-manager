import Foundation

/// Minimal HTTP/2 client for RemoteXPC. Direct port of idevice
/// `xpc/http2` (frame.rs + Http2Client): connection magic, SETTINGS,
/// WINDOW_UPDATE, empty HEADERS (channel open), DATA with flow control,
/// inbound pump (settings ACK, window accounting, per-stream DATA cache,
/// RST/GOAWAY as errors). No HPACK — HEADERS frames carry no payload.
enum Http2Frames {
    static let magic = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
    static let headerLength = 9
    static let defaultWindow: Int64 = 65535
    static let maxFramePayload = 16384

    enum FrameType: UInt8 {
        case data = 0x00
        case headers = 0x01
        case rstStream = 0x03
        case settings = 0x04
        case ping = 0x06
        case goAway = 0x07
        case windowUpdate = 0x08
    }

    struct Setting: Equatable {
        let identifier: UInt16
        let value: UInt32

        static let maxConcurrentStreams = Setting(identifier: 0x03, value: 100)
        static func initialWindowSize(_ value: UInt32) -> Setting {
            Setting(identifier: 0x04, value: value)
        }
    }

    enum Frame: Equatable {
        case data(stream: UInt32, payload: Data, endStream: Bool)
        case headers(stream: UInt32)
        case rstStream(stream: UInt32)
        case settings(stream: UInt32, flags: UInt8, settings: [Setting])
        case ping(opaque: Data, acknowledge: Bool)
        /// Benign frame the client doesn't act on (unknown types per RFC 9113
        /// §5.5, PRIORITY/CONTINUATION, …): consumed and skipped, never fatal.
        /// Carries the raw type byte + stream for diagnostics.
        case ignored(type: UInt8, stream: UInt32)
        case goAway(message: String)
        case windowUpdate(stream: UInt32, increment: UInt32)
    }

    enum FrameError: Error, Equatable {
        case goAway(String)
        case streamReset(UInt32)
        case badWindowUpdate
        case badPing
    }

    // MARK: - Encode

    static func header(length: Int, type: FrameType, flags: UInt8, stream: UInt32) -> Data {
        var out = Data([
            UInt8((length >> 16) & 0xff), UInt8((length >> 8) & 0xff), UInt8(length & 0xff),
            type.rawValue, flags,
        ])
        out.append(contentsOf: withBE32(stream))
        return out
    }

    static func settings(_ settings: [Setting], stream: UInt32 = 0, flags: UInt8 = 0) -> Data {
        var body = Data()
        for setting in settings {
            body.append(contentsOf: withBE16(setting.identifier))
            body.append(contentsOf: withBE32(setting.value))
        }
        var out = header(length: body.count, type: .settings, flags: flags, stream: stream)
        out.append(contentsOf: body)
        return out
    }

    static func windowUpdate(increment: UInt32, stream: UInt32) -> Data {
        var out = header(length: 4, type: .windowUpdate, flags: 0, stream: stream)
        out.append(contentsOf: withBE32(increment))
        return out
    }

    /// PING frame (always stream 0, 8 bytes opaque data). Responses echo the
    /// opaque bytes with the ACK flag set (RFC 9113 §6.7).
    static func ping(opaque data: Data, acknowledge: Bool) -> Data {
        precondition(data.count == 8)
        var out = header(length: 8, type: .ping, flags: acknowledge ? 0x01 : 0x00, stream: 0)
        out.append(contentsOf: data)
        return out
    }

    static func headersOpen(stream: UInt32) -> Data {
        // Empty HEADERS with END_HEADERS — just opens the channel.
        header(length: 0, type: .headers, flags: 0x04, stream: stream)
    }

    static func data(_ payload: Data, stream: UInt32, endStream: Bool) -> Data {
        var out = header(length: payload.count, type: .data,
                         flags: endStream ? 0x01 : 0x00, stream: stream)
        out.append(contentsOf: payload)
        return out
    }

    // MARK: - Parse (returns frame + bytes consumed, nil when incomplete)

    static func parse(_ buffer: Data) throws -> (frame: Frame, consumed: Int)? {
        guard buffer.count >= headerLength else { return nil }
        let length = (Int(buffer[buffer.startIndex]) << 16)
            | (Int(buffer[buffer.startIndex + 1]) << 8)
            | Int(buffer[buffer.startIndex + 2])
        let type = buffer[buffer.startIndex + 3]
        let flags = buffer[buffer.startIndex + 4]
        let stream = be32(buffer, at: 5)
        let total = headerLength + length
        guard buffer.count >= total else { return nil }
        let body = buffer[(buffer.startIndex + headerLength)..<(buffer.startIndex + total)]
        switch type {
        case FrameType.data.rawValue:
            return (.data(stream: stream, payload: Data(body),
                          endStream: flags & 0x01 != 0), total)
        case FrameType.headers.rawValue:
            return (.headers(stream: stream), total)
        case FrameType.rstStream.rawValue:
            return (.rstStream(stream: stream), total)
        case FrameType.settings.rawValue:
            var settings: [Setting] = []
            var i = body.startIndex
            while i + 6 <= body.endIndex {
                let identifier = (UInt16(body[i]) << 8) | UInt16(body[i + 1])
                let value = (UInt32(body[i + 2]) << 24) | (UInt32(body[i + 3]) << 16)
                    | (UInt32(body[i + 4]) << 8) | UInt32(body[i + 5])
                switch identifier {
                case 0x03: settings.append(Setting(identifier: 0x03, value: value))
                case 0x04: settings.append(.initialWindowSize(value))
                // RFC 9113 §6.5.2: unknown settings MUST be ignored.
                default: break
                }
                i += 6
            }
            return (.settings(stream: stream, flags: flags, settings: settings), total)
        case FrameType.ping.rawValue:
            guard stream == 0, body.count == 8 else { throw FrameError.badPing }
            return (.ping(opaque: Data(body), acknowledge: flags & 0x01 != 0), total)
        case FrameType.goAway.rawValue:
            let text = body.count >= 8 ? String(data: Data(body.dropFirst(8)), encoding: .utf8) : nil
            throw FrameError.goAway(text ?? "<missing>")
        case FrameType.windowUpdate.rawValue:
            guard body.count == 4 else { throw FrameError.badWindowUpdate }
            return (.windowUpdate(stream: stream, increment: be32(body, at: 0)), total)
        // RFC 9113 §5.5: frames of unknown type MUST be ignored and discarded.
        // Without this, a benign PRIORITY/CONTINUATION/extension frame would
        // kill the connection with an error instead of stalling analysis.
        default:
            return (.ignored(type: type, stream: stream), total)
        }
    }

    // MARK: - Helpers

    static func withBE16(_ value: UInt16) -> [UInt8] {
        [UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    static func withBE32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
         UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    static func be32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24) | (UInt32(data[base + 1]) << 16)
            | (UInt32(data[base + 2]) << 8) | UInt32(data[base + 3])
    }
}
