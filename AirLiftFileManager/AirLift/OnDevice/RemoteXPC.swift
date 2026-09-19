import Foundation

/// RemoteXPC client over HTTP/2 streams. Direct port of idevice
/// `xpc/mod.rs` RemoteXpcClient (handshake subset used by RSD):
/// settings + window update, open streams 1 (root) and 3 (reply), empty
/// dictionary on root, init-handshake on reply, 0x201 flags on root,
/// device handshake object on root, then root-channel reads skipping
/// empty-dictionary keepalives and bodyless frames.
final class RemoteXPCClient {
    static let rootChannel: UInt32 = 1
    static let replyChannel: UInt32 = 3

    enum XPCError: Error, Equatable {
        case unexpectedResponse(String)
    }

    private let h2: Http2Client
    private let timeout: TimeInterval
    private var partial: [UInt32: Data] = [:]
    private let rootId: UInt64 = 1

    init(stream: any DataStream, timeout: TimeInterval = 10) async throws {
        self.timeout = timeout
        h2 = try await Http2Client(stream: stream, timeout: timeout)
    }

    // MARK: - Handshake

    func doHandshake() async throws {
        AppLogger.net.info("RSD-XPC: sending magic + SETTINGS + window_update", event: "rsd.xpc")
        try await h2.setSettings()
        try await h2.windowUpdate(increment: 983041, streamId: 0)
        try await h2.openStream(Self.rootChannel)
        let emptyDict = XPCCodec.encodeMessage(XPCCodec.Message(
            flags: XPCCodec.Flag.alwaysSet.rawValue,
            object: .dictionary([]),
            messageId: rootId))
        AppLogger.net.info("RSD-XPC: open stream 1, empty dict (\(emptyDict.count)B)",
                           event: "rsd.xpc")
        try await sendRoot(XPCCodec.Message(
            flags: XPCCodec.Flag.alwaysSet.rawValue,
            object: .dictionary([]),
            messageId: rootId))
        try await h2.openStream(Self.replyChannel)
        AppLogger.net.info("RSD-XPC: open stream 3, init-handshake (no body)",
                           event: "rsd.xpc")
        try await sendReply(XPCCodec.Message(
            flags: XPCCodec.Flag.initHandshake.rawValue | XPCCodec.Flag.alwaysSet.rawValue,
            object: nil,
            messageId: rootId))
        AppLogger.net.info("RSD-XPC: 0x201 flags on stream 1 (no body)", event: "rsd.xpc")
        try await sendRoot(XPCCodec.Message(flags: XPCCodec.Flag.custom201.rawValue,
                                            object: nil,
                                            messageId: rootId))
    }

    /// Announces this peer as a modern (non-legacy) RemoteXPC client.
    func sendDeviceHandshake() async throws {
        let object = XPCCodec.Object.dictionary([
            ("MessageType", .string("Handshake")),
            ("MessagingProtocolVersion", .uint64(7)),
            ("UUID", .uuid(UUID())),
            ("Properties", .dictionary([
                ("RemoteXPCVersionFlags", .uint64(0x0100_0000_0000_0006)),
                ("SensitivePropertiesVisible", .bool(true)),
            ])),
            ("Services", .dictionary([])),
        ])
        let bytes = XPCCodec.encode(object)
        AppLogger.net.info("RSD-XPC: device handshake object (\(bytes.count)B)", event: "rsd.xpc")
        try await sendObject(object, expectReply: false)
    }

    // MARK: - Messaging

    func sendObject(_ object: XPCCodec.Object, expectReply: Bool) async throws {
        var flags = XPCCodec.Flag.data.rawValue | XPCCodec.Flag.alwaysSet.rawValue
        if expectReply { flags |= XPCCodec.Flag.wantingReply.rawValue }
        try await sendRoot(XPCCodec.Message(flags: flags, object: object, messageId: rootId))
    }

    /// Reads root-channel messages, skipping empty-dictionary keepalives.
    func recvRoot() async throws -> [String: Any] {
        AppLogger.net.info("RSD-XPC: waiting for root-channel response…", event: "rsd.xpc")
        while true {
            let chunk = try await h2.read(streamId: Self.rootChannel)
            AppLogger.net.info("RSD-XPC: root chunk \(chunk.count)B", event: "rsd.xpc")
            partial[Self.rootChannel, default: Data()].append(contentsOf: chunk)
            if let message = try takeWholeMessage(channel: Self.rootChannel),
               let object = message.object {
                let plain = XPCCodec.plainValue(object)
                if let dict = plain as? [String: Any], dict.isEmpty { continue }
                guard let dict = plain as? [String: Any] else {
                    throw XPCError.unexpectedResponse("root message is not a dictionary")
                }
                AppLogger.net.info(
                    "RSD-XPC: root message flags=\(String(message.flags, radix: 16)) " +
                    "keys=\(dict.keys.sorted().joined(separator: ","))",
                    event: "rsd.xpc")
                return dict
            }
        }
    }

    private func sendRoot(_ message: XPCCodec.Message) async throws {
        try await h2.send(XPCCodec.encodeMessage(message), streamId: Self.rootChannel)
    }

    private func sendReply(_ message: XPCCodec.Message) async throws {
        try await h2.send(XPCCodec.encodeMessage(message), streamId: Self.replyChannel)
    }

    private func takeWholeMessage(channel: UInt32) throws -> XPCCodec.Message? {
        var buffer = partial[channel] ?? Data()
        guard buffer.count >= 24 else { return nil }
        do {
            let (message, consumed) = try XPCCodec.decodeMessage(buffer)
            buffer = Data(buffer.dropFirst(consumed))
            partial[channel] = buffer
            return message
        } catch XPCCodec.CodecError.truncated {
            return nil
        }
    }
}
