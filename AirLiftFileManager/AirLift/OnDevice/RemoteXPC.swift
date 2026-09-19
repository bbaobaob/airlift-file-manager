import Foundation

/// RemoteXPC client over HTTP/2 streams. Direct port of idevice
/// `xpc/mod.rs` RemoteXpcClient (handshake subset used by RSD):
/// settings + window update, open streams 1 (root) and 3 (reply), empty
/// dictionary on root, init-handshake on reply, 0x201 flags on root,
/// device handshake object on root, then root-channel reads skipping
/// empty-dictionary keepalives, answering WantingReply keepalives with
/// Reply + the same message id, draining the reply channel the same way,
/// and reassembling split messages.
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

    /// Reads root-channel messages, skipping empty-dictionary keepalives and
    /// bodyless frames. A bodyless frame carrying WantingReply (0x10000) is the
    /// RemoteXPC keepalive: it is answered with Reply (0x20000) + the same
    /// message id, otherwise the device withholds the rest of its response and
    /// the handshake stalls until timeout.
    func recvRoot() async throws -> [String: Any] {
        AppLogger.net.info("RSD-XPC: waiting for root-channel response…", event: "rsd.xpc")
        while true {
            // The device also talks on the reply channel (stream 3, e.g. its
            // init-handshake answer). Drain it opportunistically: its keepalives
            // get answered, anything else is logged, and a Services dictionary
            // is accepted wherever it arrives.
            if let viaReply = try await drainReplyChannel() { return viaReply }
            let chunk = try await h2.read(streamId: Self.rootChannel)
            AppLogger.net.info("RSD-XPC: root chunk \(chunk.count)B", event: "rsd.xpc")
            partial[Self.rootChannel, default: Data()].append(contentsOf: chunk)
            guard let message = try takeWholeMessage(channel: Self.rootChannel) else {
                let buffered = partial[Self.rootChannel]?.count ?? 0
                AppLogger.net.info(
                    "RSD-XPC: partial root buffer (have \(buffered)B, need \(neededBytes(channel: Self.rootChannel))B), waiting for more…",
                    event: "rsd.xpc")
                continue
            }
            guard let object = message.object else {
                AppLogger.net.info(
                    "RSD-XPC: bodyless frame flags=0x\(String(message.flags, radix: 16)) id=\(message.messageId), continuing…",
                    event: "rsd.xpc")
                if message.flags & XPCCodec.Flag.wantingReply.rawValue != 0 {
                    AppLogger.net.info(
                        "RSD-XPC: answering keepalive id=\(message.messageId)",
                        event: "rsd.xpc")
                    // Reply + AlwaysSet: every other message on this connection
                    // carries bit0, so a bare 0x20000 risks looking malformed.
                    try await sendRoot(XPCCodec.Message(
                        flags: XPCCodec.Flag.reply.rawValue
                            | XPCCodec.Flag.alwaysSet.rawValue,
                        object: nil,
                        messageId: message.messageId))
                }
                continue
            }
            let plain = XPCCodec.plainValue(object)
            if let dict = plain as? [String: Any], dict.isEmpty {
                AppLogger.net.info("RSD-XPC: empty-dict keepalive, waiting…",
                                   event: "rsd.xpc")
                continue
            }
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

    private func sendRoot(_ message: XPCCodec.Message) async throws {
        try await h2.send(XPCCodec.encodeMessage(message), streamId: Self.rootChannel)
    }

    private func sendReply(_ message: XPCCodec.Message) async throws {
        try await h2.send(XPCCodec.encodeMessage(message), streamId: Self.replyChannel)
    }

    /// Non-blocking drain of the reply channel. Answers WantingReply keepalives
    /// on stream 3 (the device may gate further root responses on them) and
    /// returns a Services dictionary if one arrives off the root channel.
    private func drainReplyChannel() async throws -> [String: Any]? {
        guard let chunk = h2.poll(streamId: Self.replyChannel) else { return nil }
        AppLogger.net.info("RSD-XPC: reply chunk \(chunk.count)B", event: "rsd.xpc")
        partial[Self.replyChannel, default: Data()].append(contentsOf: chunk)
        guard let message = try takeWholeMessage(channel: Self.replyChannel) else {
            let buffered = partial[Self.replyChannel]?.count ?? 0
            AppLogger.net.info(
                "RSD-XPC: partial reply buffer (have \(buffered)B, need \(neededBytes(channel: Self.replyChannel))B)",
                event: "rsd.xpc")
            return nil
        }
        guard let object = message.object else {
            AppLogger.net.info(
                "RSD-XPC: bodyless reply frame flags=0x\(String(message.flags, radix: 16)) id=\(message.messageId)",
                event: "rsd.xpc")
            if message.flags & XPCCodec.Flag.wantingReply.rawValue != 0 {
                AppLogger.net.info(
                    "RSD-XPC: answering reply-channel keepalive id=\(message.messageId)",
                    event: "rsd.xpc")
                try await sendReply(XPCCodec.Message(
                    flags: XPCCodec.Flag.reply.rawValue
                        | XPCCodec.Flag.alwaysSet.rawValue,
                    object: nil,
                    messageId: message.messageId))
            }
            return nil
        }
        let plain = XPCCodec.plainValue(object)
        if let dict = plain as? [String: Any], !dict.isEmpty,
           dict["Services"] != nil {
            AppLogger.net.info(
                "RSD-XPC: Services arrived on reply channel keys=\(dict.keys.sorted().joined(separator: ","))",
                event: "rsd.xpc")
            return dict
        }
        AppLogger.net.info("RSD-XPC: reply-channel message skipped", event: "rsd.xpc")
        return nil
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

    /// Bytes the current partial buffer claims to need (24 + body_len from the
    /// wrapper header), for diagnostics. Returns -1 when not even the 24-byte
    /// header has arrived yet.
    private func neededBytes(channel: UInt32) -> Int {
        guard let buffer = partial[channel], buffer.count >= 24 else { return -1 }
        var length: UInt64 = 0
        for i in 0..<8 { length |= UInt64(buffer[buffer.startIndex + 8 + i]) << (8 * i) }
        return 24 + Int(length)
    }
}
