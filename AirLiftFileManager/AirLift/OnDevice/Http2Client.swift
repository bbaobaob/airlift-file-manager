import Foundation

/// HTTP/2 client driver for RemoteXPC. Direct port of idevice
/// `xpc/http2` Http2Client: connection magic, our SETTINGS, WINDOW_UPDATE,
/// channel open, DATA send with connection+stream flow control, inbound pump
/// (SETTINGS ack + window accounting, PING answers, per-stream DATA cache,
/// RST/GOAWAY as errors, unknown frames ignored per RFC 9113 §5.5),
/// cancellation-safe reassembly buffer.
final class Http2Client {
    enum ClientError: Error, Equatable {
        case closed
        case streamReset(UInt32)
        case goAway(String)
    }

    private let stream: any DataStream
    private let timeout: TimeInterval
    private var recvBuffer = Data()
    private var cache: [UInt32: [Data]] = [:]
    private var connectionSendWindow: Int64 = Http2Frames.defaultWindow
    private var streamSendWindows: [UInt32: Int64] = [:]
    private var peerInitialWindow: Int64 = Http2Frames.defaultWindow

    init(stream: any DataStream, timeout: TimeInterval = 10) async throws {
        self.stream = stream
        self.timeout = timeout
        try await stream.write(Http2Frames.magic, timeout: timeout)
    }

    // MARK: - Outbound

    func setSettings(maxConcurrentStreams: UInt32 = 100,
                     initialWindowSize: UInt32 = 1_048_576) async throws {
        try await stream.write(Http2Frames.settings(
            [.maxConcurrentStreams, .initialWindowSize(initialWindowSize)]), timeout: timeout)
    }

    func windowUpdate(increment: UInt32, streamId: UInt32) async throws {
        try await stream.write(Http2Frames.windowUpdate(increment: increment, stream: streamId),
                               timeout: timeout)
    }

    func openStream(_ streamId: UInt32) async throws {
        cache[streamId] = cache[streamId] ?? []
        try await stream.write(Http2Frames.headersOpen(stream: streamId), timeout: timeout)
    }

    func send(_ payload: Data, streamId: UInt32) async throws {
        var offset = payload.startIndex
        var first = true
        repeat {
            let end = payload.index(offset, offsetBy: Http2Frames.maxFramePayload,
                                    limitedBy: payload.endIndex) ?? payload.endIndex
            let chunk = Data(payload[offset..<end])
            let need = Int64(chunk.count)
            while connectionSendWindow < need || sendWindow(streamId) < need {
                try await pump()
            }
            try await stream.write(Http2Frames.data(chunk, stream: streamId, endStream: false),
                                   timeout: timeout)
            connectionSendWindow -= need
            streamSendWindows[streamId] = sendWindow(streamId) - need
            offset = end
            first = false
        } while offset < payload.endIndex || first
    }

    private func sendWindow(_ streamId: UInt32) -> Int64 {
        if let window = streamSendWindows[streamId] { return window }
        streamSendWindows[streamId] = peerInitialWindow
        return peerInitialWindow
    }

    // MARK: - Inbound

    /// Next buffered payload from any of the streams, with its stream id.
    /// With `timeout`, each pump wait is bounded (default: the connection
    /// timeout) so callers can nudge-and-retry instead of blocking.
    func readAny(_ streamIds: [UInt32], timeout: TimeInterval? = nil) async throws -> (UInt32, Data) {
        for id in streamIds { cache[id] = cache[id] ?? [] }
        while true {
            for id in streamIds {
                if let data = cache[id]?.first {
                    cache[id]?.removeFirst()
                    return (id, data)
                }
            }
            try await pump(timeout: timeout)
        }
    }

    func read(streamId: UInt32) async throws -> Data {
        cache[streamId] = cache[streamId] ?? []
        while true {
            if let data = cache[streamId]?.first {
                cache[streamId]?.removeFirst()
                return data
            }
            try await pump()
        }
    }

    /// Non-blocking drain of already-buffered payloads for a stream (inbound
    /// frames for it were pumped while reading another stream). Returns nil
    /// when nothing is buffered — never suspends.
    func poll(streamId: UInt32) -> Data? {
        guard let data = cache[streamId]?.first else { return nil }
        cache[streamId]?.removeFirst()
        return data
    }

    private func pump(timeout pumpTimeout: TimeInterval? = nil) async throws {
        while true {
            if let (frame, consumed) = try Http2Frames.parse(recvBuffer) {
                recvBuffer = Data(recvBuffer.dropFirst(consumed))
                switch frame {
                case .settings(_, let flags, let settings):
                    AppLogger.net.info(
                        "h2 ← settings flags=\(flags) ids=\(settings.map { $0.identifier })",
                        event: "tunnel.pump")
                    if flags != 1 {
                        for setting in settings where setting.identifier == 0x04 {
                            let delta = Int64(setting.value) - peerInitialWindow
                            peerInitialWindow = Int64(setting.value)
                            for key in streamSendWindows.keys {
                                streamSendWindows[key]? += delta
                            }
                        }
                        try await stream.write(
                            Http2Frames.settings([], stream: 0, flags: 1), timeout: timeout)
                    }
                case .windowUpdate(let streamId, let increment):
                    AppLogger.net.info(
                        "h2 ← window_update stream=\(streamId) +\(increment)",
                        event: "tunnel.pump")
                    if streamId == 0 {
                        connectionSendWindow += Int64(increment)
                    } else {
                        streamSendWindows[streamId, default: peerInitialWindow] += Int64(increment)
                    }
                case .rstStream(let streamId):
                    throw ClientError.streamReset(streamId)
                case .ping(let opaque, let acknowledge):
                    if !acknowledge {
                        // RFC 9113 §6.7: PING must be answered with the same
                        // opaque data and the ACK flag set. An unanswered PING
                        // makes the peer believe the connection is dead.
                        try await stream.write(
                            Http2Frames.ping(opaque: opaque, acknowledge: true),
                            timeout: timeout)
                    }
                    AppLogger.net.info("h2 ← ping ack=\(acknowledge)",
                                       event: "tunnel.pump")
                    continue
                case .ignored(let type, let streamId):
                    AppLogger.net.info(
                        "h2 ← ignored frame type=0x\(String(type, radix: 16)) stream=\(streamId)",
                        event: "tunnel.pump")
                    continue
                case .headers(let streamId):
                    // The device opening new streams (or trailers) must be
                    // visible: a response continued elsewhere would otherwise
                    // look exactly like a stall.
                    AppLogger.net.info("h2 ← headers stream=\(streamId)",
                                       event: "tunnel.pump")
                    continue
                case .data(let streamId, let payload, _):
                    cache[streamId, default: []].append(payload)
                    AppLogger.net.info("h2 ← data stream=\(streamId) \(payload.count)B",
                                       event: "tunnel.pump")
                    if !payload.isEmpty {
                        let length = UInt32(payload.count)
                        try await stream.write(
                            Http2Frames.windowUpdate(increment: length, stream: 0),
                            timeout: timeout)
                        try await stream.write(
                            Http2Frames.windowUpdate(increment: length, stream: streamId),
                            timeout: timeout)
                    }
                    return
                case .goAway(let message):
                    throw ClientError.goAway(message)
                }
            } else {
                let chunk = try await stream.readExactly(
                    min(16384, max(1, 16384 - recvBuffer.count)),
                    timeout: pumpTimeout ?? timeout)
                if chunk.isEmpty { throw ClientError.closed }
                recvBuffer.append(contentsOf: chunk)
            }
        }
    }
}
