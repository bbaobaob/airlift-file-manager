import XCTest
@testable import AirLiftFileManager

/// Unit tests for the on-device protocol stack. Every pure codec is covered
/// (round-trips + hand-computed golden bytes from the ported specs); live
/// handshakes are verified on-device through the in-app AFC self-test.
final class OnDeviceWireTests: XCTestCase {
    // MARK: - TLV8

    func testTLV8RoundTrip() throws {
        let entries = [
            TLV8.Entry(.state, Data([0x01])),
            TLV8.Entry(.publicKey, Data(repeating: 0xAB, count: 32)),
            TLV8.Entry(.identifier, Data("id-9".utf8)),
        ]
        let decoded = try TLV8.deserialize(TLV8.serialize(entries))
        XCTAssertEqual(decoded, entries)
    }

    func testTLV8RejectsTruncation() {
        XCTAssertThrowsError(try TLV8.deserialize(Data([0x06, 0x01])))
        XCTAssertThrowsError(try TLV8.deserialize(Data([0x06])))
    }

    func testTLV8ComponentValues() {
        XCTAssertEqual(TLV8.Component.state.rawValue, 0x06)
        XCTAssertEqual(TLV8.Component.publicKey.rawValue, 0x03)
        XCTAssertEqual(TLV8.Component.identifier.rawValue, 0x01)
        XCTAssertEqual(TLV8.Component.signature.rawValue, 0x0a)
        XCTAssertEqual(TLV8.Component.encryptedData.rawValue, 0x05)
        XCTAssertEqual(TLV8.Component.errorResponse.rawValue, 0x07)
    }

    // MARK: - RPPairing wire

    func testFrameRoundTrip() throws {
        let object: [String: Any] = ["message": ["plain": ["_0": ["a": 1]]],
                                     "originatedBy": "host", "sequenceNumber": 7]
        let framed = try RPPairingWire.frame(jsonObject: object)
        XCTAssertTrue(framed.prefix(9) == Data("RPPairing".utf8))
        let (json, rest) = try XCTUnwrap(RPPairingWire.popFrame(from: framed))
        XCTAssertTrue(rest.isEmpty)
        let back = json as? [String: Any]
        XCTAssertEqual((back?["originatedBy"] as? String), "host")
        XCTAssertEqual((back?["sequenceNumber"] as? Int), 7)
    }

    func testFrameRejectsBadMagic() {
        XCTAssertThrowsError(try RPPairingWire.popFrame(from: Data("XXXXXXXXX".utf8) + Data([0x00, 0x05]) + Data("hello".utf8)))
    }

    func testFrameWaitsForCompleteBody() throws {
        let object: [String: Any] = ["k": "v"]
        let framed = try RPPairingWire.frame(jsonObject: object)
        XCTAssertNil(try RPPairingWire.popFrame(from: framed.prefix(5)))
        XCTAssertNil(try RPPairingWire.popFrame(from: framed.dropLast(2)))
    }

    func testM1AndSignBufferLayout() {
        let eph = Data(repeating: 0x11, count: 32)
        let m1 = RPPairingWire.m1TLV(ephemeralPublicKey: eph)
        // State(0x06, len 1, 0x01) + PublicKey(0x03, len 32, key).
        XCTAssertEqual(Array(m1.prefix(3)), [0x06, 0x01, 0x01])
        XCTAssertEqual(Array(m1.dropFirst(3).prefix(2)), [0x03, 0x20])
        XCTAssertEqual(m1.suffix(32), eph)

        let signbuf = RPPairingWire.signBuffer(ephemeralPublicKey: eph,
                                               identifier: "AB",
                                               devicePublicKey: Data(repeating: 0x22, count: 32))
        XCTAssertEqual(signbuf.count, 32 + 2 + 32)
        XCTAssertEqual(signbuf.prefix(32), eph)
        XCTAssertEqual(signbuf.dropFirst(32).prefix(2), Data("AB".utf8))

        XCTAssertEqual(RPPairingWire.pairVerifyNonce.count, 12)
        XCTAssertEqual(RPPairingWire.pairVerifyNonce.suffix(8), Data("PV-Msg03".utf8))
    }

    func testAttemptPairVerifyShape() {
        let request = RPPairingWire.attemptPairVerifyRequest()
        let handshake = RPPairingWire.navigate(request, "request", "_0", "handshake", "_0")
            as? [String: Any]
        XCTAssertEqual((handshake?["hostOptions"] as? [String: Any])?["attemptPairVerify"] as? Bool,
                       true)
        XCTAssertEqual(handshake?["wireProtocolVersion"] as? Int, 19)
    }

    // MARK: - AFC packets

    func testAFCEncodeDecodeRoundTrip() throws {
        let encoded = AFCClient.Packet.encode(operation: .fileOpen, packetNumber: 3,
                                              headerPayload: Data([1, 2, 3, 4, 5, 6, 7, 8]),
                                              payload: Data("hello".utf8))
        // Golden header: magic + entire(40+8+5=53) + headerPayloadLen(48) + num(3) + op(0x0d).
        let header = Array(encoded.prefix(40))
        XCTAssertEqual(Array(header[0..<8]), [0x43, 0x46, 0x41, 0x36, 0x4c, 0x50, 0x41, 0x41])
        XCTAssertEqual(header[8], 53) // entire_len low byte
        XCTAssertEqual(header[16], 48) // header_payload_len low byte
        XCTAssertEqual(header[24], 3) // packet_num low byte
        XCTAssertEqual(header[32], 0x0d) // FileOpen
        XCTAssertEqual(encoded.count, 53)

        let decoded = try AFCClient.Packet.decode(encoded)
        XCTAssertEqual(decoded.operation, .fileOpen)
        XCTAssertEqual(decoded.packetNumber, 3)
        XCTAssertEqual(decoded.headerPayload, Data([1, 2, 3, 4, 5, 6, 7, 8]))
        XCTAssertEqual(decoded.payload, Data("hello".utf8))
    }

    func testAFCRejectsBadMagic() {
        var encoded = AFCClient.Packet.encode(operation: .read, packetNumber: 0,
                                              headerPayload: Data(), payload: Data())
        encoded[0] = 0xFF
        XCTAssertThrowsError(try AFCClient.Packet.decode(encoded))
    }

    // MARK: - XPC codec

    func testXPCGoldenDictionaryBytes() throws {
        // Verified against a faithful transcription of the reference encoder:
        // magic + version + type + contentlen(20) + [count(1) + "a"+NUL+pad
        // + uint64(1)]. contentlen precedes count on the wire.
        let expected: [UInt8] = [
            0x42, 0x37, 0x13, 0x42, 0x05, 0x00, 0x00, 0x00,
            0x00, 0xf0, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00, 0x61, 0x00, 0x00, 0x00,
            0x00, 0x40, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ]
        let encoded = XPCCodec.encode(.dictionary([("a", .uint64(1))]))
        XCTAssertEqual(Array(encoded), expected)

        var reader = XPCCodec.Reader(encoded)
        let decoded = try XPCCodec.decodeTopLevel(&reader)
        XCTAssertTrue(XPCCodec.objectsEqual(decoded, .dictionary([("a", .uint64(1))])))
    }

    func testXPCRoundTrip() throws {
        let object = XPCCodec.Object.dictionary([
            ("MessageType", .string("Handshake")),
            ("MessagingProtocolVersion", .uint64(7)),
            ("UUID", .uuid(UUID(uuidString: "EC05A22F-7737-3E64-8A49-FA856B07A84E")!)),
            ("Properties", .dictionary([
                ("RemoteXPCVersionFlags", .uint64(0x0100_0000_0000_0006)),
                ("SensitivePropertiesVisible", .bool(true)),
            ])),
            ("Services", .dictionary([])),
            ("Count", .int64(-3)),
            ("Ratio", .double(0.5)),
            ("Blob", .data(Data([1, 2, 3]))),
            ("Nothing", .null),
        ])
        var reader = XPCCodec.Reader(XPCCodec.encode(object))
        XCTAssertTrue(XPCCodec.objectsEqual(try XPCCodec.decodeTopLevel(&reader), object))
    }

    func testXPCMessageWrapper() throws {
        let message = XPCCodec.Message(flags: 0x101,
                                       object: .dictionary([("k", .string("v"))]),
                                       messageId: 1)
        let encoded = XPCCodec.encodeMessage(message)
        XCTAssertEqual(Array(encoded.prefix(4)), [0x92, 0x0b, 0xb0, 0x29]) // 0x29b00b92 LE
        let (decoded, consumed) = try XPCCodec.decodeMessage(encoded)
        XCTAssertEqual(consumed, encoded.count)
        XCTAssertEqual(decoded.flags, 0x101)
        XCTAssertEqual(decoded.messageId, 1)
        XCTAssertTrue(XPCCodec.objectsEqual(decoded.object ?? .null,
                                            .dictionary([("k", .string("v"))])))
    }

    func testXPCBodylessMessage() throws {
        let message = XPCCodec.Message(flags: 0x400001, object: nil, messageId: 1)
        let encoded = XPCCodec.encodeMessage(message)
        XCTAssertEqual(encoded.count, 24)
        let (decoded, _) = try XPCCodec.decodeMessage(encoded)
        XCTAssertNil(decoded.object)
    }

    // MARK: - HTTP/2 frames

    func testHTTP2FrameRoundTrips() throws {
        let settings = Http2Frames.settings([.maxConcurrentStreams, .initialWindowSize(1048576)])
        let (parsedSettings, consumedSettings) = try XCTUnwrap(Http2Frames.parse(settings))
        XCTAssertEqual(consumedSettings, settings.count)
        if case .settings(_, let flags, let list) = parsedSettings {
            XCTAssertEqual(flags, 0)
            XCTAssertEqual(list, [.maxConcurrentStreams, .initialWindowSize(1048576)])
        } else {
            XCTFail("expected settings frame")
        }

        let window = Http2Frames.windowUpdate(increment: 983041, stream: 0)
        let (parsedWindow, _) = try XCTUnwrap(Http2Frames.parse(window))
        XCTAssertEqual(parsedWindow, .windowUpdate(stream: 0, increment: 983041))

        let headers = Http2Frames.headersOpen(stream: 1)
        let (parsedHeaders, _) = try XCTUnwrap(Http2Frames.parse(headers))
        XCTAssertEqual(parsedHeaders, .headers(stream: 1))

        let data = Http2Frames.data(Data("payload".utf8), stream: 3, endStream: false)
        let (parsedData, consumedData) = try XCTUnwrap(Http2Frames.parse(data))
        XCTAssertEqual(consumedData, data.count)
        XCTAssertEqual(parsedData, .data(stream: 3, payload: Data("payload".utf8), endStream: false))
    }

    func testHTTP2ParseWaitsForCompleteFrame() throws {
        let data = Http2Frames.data(Data("payload".utf8), stream: 1, endStream: false)
        XCTAssertNil(try Http2Frames.parse(data.prefix(5)))
    }

    func testHTTP2PingRoundTrip() throws {
        let opaque = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let ping = Http2Frames.ping(opaque: opaque, acknowledge: false)
        let (parsed, consumed) = try XCTUnwrap(Http2Frames.parse(ping))
        XCTAssertEqual(consumed, ping.count)
        XCTAssertEqual(parsed, .ping(opaque: opaque, acknowledge: false))

        let ack = Http2Frames.ping(opaque: opaque, acknowledge: true)
        let (parsedAck, _) = try XCTUnwrap(Http2Frames.parse(ack))
        XCTAssertEqual(parsedAck, .ping(opaque: opaque, acknowledge: true))
    }

    func testHTTP2IgnoresUnknownFrameType() throws {
        // PRIORITY (0x02), 5-byte payload on stream 1: consumed, never fatal.
        var raw = Data([0x00, 0x00, 0x05, 0x02, 0x00, 0x00, 0x00, 0x00, 0x01])
        raw.append(contentsOf: [0xAA, 0xBB, 0xCC, 0xDD, 0xEE])
        let (parsed, consumed) = try XCTUnwrap(Http2Frames.parse(raw))
        XCTAssertEqual(consumed, raw.count)
        XCTAssertEqual(parsed, .ignored(type: 0x02, stream: 1))
    }

    func testHTTP2IgnoresUnknownSettings() throws {
        // ENABLE_CONNECT_PROTOCOL (0x08) + MAX_CONCURRENT_STREAMS: unknown kept out.
        var body = Data()
        body.append(contentsOf: [0x00, 0x08, 0x00, 0x00, 0x00, 0x01])
        body.append(contentsOf: [0x00, 0x03, 0x00, 0x00, 0x00, 0x64])
        var raw = Data([0x00, 0x00, 0x0C, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00])
        raw.append(contentsOf: body)
        let (parsed, _) = try XCTUnwrap(Http2Frames.parse(raw))
        if case .settings(_, _, let list) = parsed {
            XCTAssertEqual(list, [.maxConcurrentStreams])
        } else {
            XCTFail("expected settings frame")
        }
    }

    func testXPCKeepaliveReplyRoundTrip() throws {
        // Device keepalive: bodyless, WantingReply, some message id.
        let keepalive = XPCCodec.Message(
            flags: XPCCodec.Flag.wantingReply.rawValue, object: nil, messageId: 7)
        let encoded = XPCCodec.encodeMessage(keepalive)
        XCTAssertEqual(encoded.count, 24)
        let (decoded, _) = try XPCCodec.decodeMessage(encoded)
        XCTAssertNil(decoded.object)
        XCTAssertEqual(decoded.flags, XPCCodec.Flag.wantingReply.rawValue)
        XCTAssertEqual(decoded.messageId, 7)
        // Our answer: Reply|AlwaysSet + the same message id.
        let reply = XPCCodec.Message(
            flags: XPCCodec.Flag.reply.rawValue | XPCCodec.Flag.alwaysSet.rawValue,
            object: nil,
            messageId: decoded.messageId)
        let (decodedReply, _) = try XPCCodec.decodeMessage(XPCCodec.encodeMessage(reply))
        XCTAssertNil(decodedReply.object)
        XCTAssertEqual(decodedReply.flags, 0x20001)
        XCTAssertEqual(decodedReply.messageId, 7)
    }

    func testHTTP2Magic() {
        XCTAssertEqual(Http2Frames.magic, Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8))
    }

    // MARK: - TLS-PSK pure parts

    func testTLSRecordFraming() {
        let record = TLSPsk.makeRecord(contentType: 0x16, payload: Data([1, 2, 3]))
        XCTAssertEqual(Array(record), [0x16, 0x03, 0x03, 0x00, 0x03, 0x01, 0x02, 0x03])
        let handshake = TLSPsk.makeHandshake(type: 0x01, body: Data([0xAA, 0xBB]))
        XCTAssertEqual(Array(handshake), [0x01, 0x00, 0x00, 0x02, 0xAA, 0xBB])
    }

    func testTLSCBCRoundTrip() throws {
        let keys = TLSPsk.keyBlock(master: Data(repeating: 0x11, count: 48),
                                   clientRandom: Data(repeating: 0x22, count: 32),
                                   serverRandom: Data(repeating: 0x33, count: 32),
                                   suite: .aes256CbcSha384)
        XCTAssertEqual(keys.clientWriteKey.count, 32)
        XCTAssertEqual(keys.clientMacKey.count, 48)
        let plaintext = Data("sixteen bytes ok".utf8) // exactly 16 bytes
        let encrypted = try TLSPsk.encryptRecord(keys: keys, sequence: 7,
                                                 contentType: 0x17, plaintext: plaintext)
        // IV(16) + 2 blocks (16 plaintext + 48 MAC + padding → 80 = 5 blocks).
        XCTAssertEqual(encrypted.count, 16 + 80)
        let decrypted = try TLSPsk.decryptRecord(keys: keys, fromServer: false, sequence: 7,
                                                 contentType: 0x17, encrypted: encrypted)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testTLSMACTamperDetected() throws {
        let keys = TLSPsk.keyBlock(master: Data(repeating: 0x11, count: 48),
                                   clientRandom: Data(repeating: 0x22, count: 32),
                                   serverRandom: Data(repeating: 0x33, count: 32),
                                   suite: .aes128CbcSha)
        var encrypted = try TLSPsk.encryptRecord(keys: keys, sequence: 0,
                                                 contentType: 0x17,
                                                 plaintext: Data(repeating: 0x41, count: 32))
        encrypted[20] ^= 0xff
        XCTAssertThrowsError(try TLSPsk.decryptRecord(keys: keys, fromServer: false, sequence: 0,
                                                      contentType: 0x17, encrypted: encrypted))
    }

    func testTLSFinishedVerifyData() {
        let transcript = Data("transcript".utf8)
        let first = TLSPsk.finishedVerifyData(master: Data(repeating: 0x07, count: 48),
                                              label: Data("client finished".utf8),
                                              transcript: transcript, suite: .aes256CbcSha384)
        let second = TLSPsk.finishedVerifyData(master: Data(repeating: 0x07, count: 48),
                                               label: Data("client finished".utf8),
                                               transcript: transcript, suite: .aes256CbcSha384)
        XCTAssertEqual(first.count, 12)
        XCTAssertEqual(first, second)
        let other = TLSPsk.finishedVerifyData(master: Data(repeating: 0x07, count: 48),
                                              label: Data("server finished".utf8),
                                              transcript: transcript, suite: .aes256CbcSha384)
        XCTAssertNotEqual(first, other)
    }

    // MARK: - CDTunnel

    func testCDTunnelHandshakeParse() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "clientParameters": ["address": "fd12::2", "mtu": 16000, "netmask": "ffff::"],
            "serverAddress": "fd12::1",
            "serverRSDPort": 9876,
        ] as [String: Any], options: [])
        var framed = CDTunnel.magic
        framed.append(contentsOf: RPPairingWire.withBE16(UInt16(body.count)))
        framed.append(contentsOf: body)
        let info = try CDTunnel.parseResponse(framed)
        XCTAssertEqual(info.clientAddress, "fd12::2")
        XCTAssertEqual(info.serverAddress, "fd12::1")
        XCTAssertEqual(info.mtu, 16000)
        XCTAssertEqual(info.serverRSDPort, 9876)
    }

    func testCDTunnelRejectsBadMagic() {
        XCTAssertThrowsError(try CDTunnel.parseResponse(Data("NOTUNNEL".utf8) + Data([0x00, 0x05]) + Data("hello".utf8)))
    }

    // MARK: - RSD handshake parse

    func testRSDHandshakeParse() throws {
        let root: [String: Any] = [
            "Services": [
                "com.apple.afc.shim.remote": [
                    "Entitlement": "com.apple.private.mobileafc",
                    "Port": "4567",
                    "Properties": ["UsesRemoteXPC": false],
                ],
                "broken": ["Entitlement": "x"], // skipped, like idevice
            ],
            "MessagingProtocolVersion": Int64(3),
            "UUID": "some-uuid",
        ]
        let handshake = try RSDClient.parseHandshake(root)
        XCTAssertEqual(handshake.protocolVersion, 3)
        XCTAssertEqual(handshake.uuid, "some-uuid")
        XCTAssertEqual(handshake.port(for: "com.apple.afc.shim.remote"), 4567)
        XCTAssertNil(handshake.port(for: "com.apple.missing"))
        XCTAssertNil(handshake.services["broken"])
    }

    func testRSDHandshakeRequestCarriesWantingReply() throws {
        // The device handshake must ask for a reply (Data|AlwaysSet|
        // WantingReply = 0x10101) or the device stalls mid-response.
        var flags = XPCCodec.Flag.data.rawValue | XPCCodec.Flag.alwaysSet.rawValue
        flags |= XPCCodec.Flag.wantingReply.rawValue
        XCTAssertEqual(flags, 0x10101)
        let message = XPCCodec.Message(flags: flags,
                                       object: .dictionary([("k", .string("v"))]),
                                       messageId: 1)
        let (decoded, _) = try XPCCodec.decodeMessage(XPCCodec.encodeMessage(message))
        XCTAssertEqual(decoded.flags, 0x10101)
        XCTAssertEqual(decoded.messageId, 1)
    }

    func testRSDHandshakeParsePeerInfoNesting() throws {
        // Some stacks nest the answer under peer_info; accept either shape.
        let root: [String: Any] = [
            "peer_info": [
                "Services": [
                    "com.apple.afc.shim.remote": [
                        "Entitlement": "com.apple.private.mobileafc",
                        "Port": "4567",
                    ],
                ],
                "MessagingProtocolVersion": Int64(7),
                "UUID": "nested-uuid",
            ],
        ]
        let handshake = try RSDClient.parseHandshake(root)
        XCTAssertEqual(handshake.protocolVersion, 7)
        XCTAssertEqual(handshake.uuid, "nested-uuid")
        XCTAssertEqual(handshake.port(for: "com.apple.afc.shim.remote"), 4567)
    }
}

extension OnDeviceWireTests {
    func testSilenceWAVStructure() {
        let wav = PairingKeepAlive.silenceWAV()
        XCTAssertEqual(Array(wav.prefix(4)), Array("RIFF".utf8))
        XCTAssertEqual(wav.count, 44 + 16000) // 1s × 8kHz × 16-bit mono
        // data chunk header at offset 36: "data" + u32LE(16000).
        XCTAssertEqual(Array(wav[36..<40]), Array("data".utf8))
        let size = UInt32(wav[40]) | (UInt32(wav[41]) << 8)
            | (UInt32(wav[42]) << 16) | (UInt32(wav[43]) << 24)
        XCTAssertEqual(size, 16000)
    }

    func testChainErrorMessages() {
        XCTAssertTrue(OnDeviceChain.ChainError.noPairingService.message.contains("_remotepairing"))
        XCTAssertTrue(OnDeviceChain.ChainError.tunnelDown.message.contains("10.7.0.1"))
        if case .failed(let step, _) = OnDeviceChain.Outcome.failed(step: "preflight", reason: "x") {
            XCTAssertEqual(step, "preflight")
        } else {
            XCTFail("expected failed outcome")
        }
    }
}
