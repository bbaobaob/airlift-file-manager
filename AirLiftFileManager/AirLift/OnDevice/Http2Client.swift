import Foundation

/// HTTP/2 client driver for RemoteXPC. Direct port of idevice
/// `xpc/http2` Http2Client: connection magic, our SETTINGS, WINDOW_UPDATE,
/// channel open, DATA send with connection+stream flow control, inbound pump
/// (SETTINGS ack + window accounting, per-stream DATA cache, RST/GOAWAY as
/// errors), cancellation-safe reassembly buffer.
final class Http2Client {
    enum ClientError: Error, Equatable {
        case closed
        case streamReset(UInt32)
        case goAway(String)
    }

    private let stream: TCPStream
    private let timeout: TimeInterval
    private var recvBuffer = Data()
    private var cache: [UInt32: [Data]] = [:]
    private var connectionSendWindow: Int64 = Http2Frames.defaultWindow
    private var streamSendWindows: [UInt32: Int64] = [:]
    private var peerInitialWindow: Int64 = Http2Frames.defaultWindow

    init(stream: TCPStream, timeout: TimeInterval = 10) async throws {
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
    func readAny(_ streamIds: [UInt32]) async throws -> (UInt32, Data) {
        for id in streamIds { cache[id] = cache[id] ?? [] }
        while true {
            for id in streamIds {
                if let data = cache[id]?.first {
                    cache[id]?.removeFirst()
                    return (id, data)
                }
            }
            try await pump()
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

    private func pump() async throws {
        while true {
            if let (frame, consumed) = try Http2Frames.parse(recvBuffer) {
                recvBuffer = Data(recvBuffer.dropFirst(consumed))
                switch frame {
                case .settings(_, let flags, let settings):
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
                    if streamId == 0 {
                        connectionSendWindow += Int64(increment)
                    } else {
                        streamSendWindows[streamId, default: peerInitialWindow] += Int64(increment)
                    }
                case .rstStream(let streamId):
                    throw ClientError.streamReset(streamId)
                case .data(let streamId, let payload, _):
                    cache[streamId, default: []].append(payload)
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
                case .headers:
                    continue
                case .goAway(let message):
                    throw ClientError.goAway(message)
                }
            } else {
                let chunk = try await stream.readExactly(
                    min(16384, max(1, 16384 - recvBuffer.count)), timeout: timeout)
                if chunk.isEmpty { throw ClientError.closed }
                recvBuffer.append(contentsOf: chunk)
            }
        }
    }
}
