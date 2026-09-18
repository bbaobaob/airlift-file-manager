import XCTest
@testable import AirLiftFileManager

/// Tests for the tunnel packet layer: IPv6 codec, TCP checksum (grounded by
/// an independent Python computation), segment codec, and a full TCP
/// handshake + data + close between two stacks wired loopback-style.
final class TunnelTCPTests: XCTestCase {
    // MARK: - IPv6 addresses

    func testParseAddresses() {
        XCTAssertEqual(IPv6.parseAddress("fd12::1")?.count, 16)
        XCTAssertEqual(IPv6.parseAddress("fd12::1")?.suffix(2), [0x00, 0x01])
        XCTAssertEqual(IPv6.parseAddress("::1")?.suffix(2), [0x00, 0x01])
        XCTAssertEqual(IPv6.parseAddress("::") ?? [], [UInt8](repeating: 0, count: 16))
        let full = IPv6.parseAddress("fd12:0:0:0:0:0:0:abcd")
        XCTAssertEqual(full?.prefix(2), [0xfd, 0x12])
        XCTAssertEqual(full?.suffix(2), [0xab, 0xcd])
        XCTAssertEqual(IPv6.parseAddress("::ffff:10.7.0.1")?.suffix(4),
                       [10, 7, 0, 1])
        XCTAssertNil(IPv6.parseAddress("not-an-address"))
        XCTAssertNil(IPv6.parseAddress("fd12:::1"))
    }

    // MARK: - Checksum (Python-grounded: 0xfd56)

    func testTCPChecksumVector() {
        let src = IPv6.parseAddress("fd12::2")!
        let dst = IPv6.parseAddress("fd12::1")!
        var segment = IPv6.buildSegment(srcPort: 40000, dstPort: 49152,
                                        sequence: 0x11223344, acknowledgement: 0,
                                        flags: [.syn], window: 65535,
                                        mss: 1460, payload: Data())
        segment = IPv6.withChecksum(src: src, dst: dst, segment: segment)
        XCTAssertEqual(segment[segment.startIndex + 16], 0xfd)
        XCTAssertEqual(segment[segment.startIndex + 17], 0x56)
    }

    // MARK: - Packet + segment round-trips

    func testIPv6PacketRoundTrip() throws {
        let src = IPv6.parseAddress("fd12::2")!
        let dst = IPv6.parseAddress("fd12::1")!
        let packet = IPv6.buildPacket(src: src, dst: dst, nextHeader: 6,
                                      payload: Data("hello".utf8))
        XCTAssertEqual(packet.count, 45)
        let parsed = try XCTUnwrap(IPv6.parsePacket(packet))
        XCTAssertEqual(parsed.src, src)
        XCTAssertEqual(parsed.dst, dst)
        XCTAssertEqual(parsed.nextHeader, 6)
        XCTAssertEqual(parsed.payload, Data("hello".utf8))
        XCTAssertNil(IPv6.parsePacket(Data(repeating: 0, count: 10)))
    }

    func testTCPSegmentRoundTrip() {
        let segment = IPv6.buildSegment(srcPort: 40000, dstPort: 80,
                                        sequence: 42, acknowledgement: 1000,
                                        flags: [.ack, .psh], window: 8192,
                                        payload: Data("data".utf8))
        let parsed = IPv6.parseSegment(segment)
        XCTAssertEqual(parsed?.srcPort, 40000)
        XCTAssertEqual(parsed?.dstPort, 80)
        XCTAssertEqual(parsed?.sequence, 42)
        XCTAssertEqual(parsed?.acknowledgement, 1000)
        XCTAssertTrue(parsed?.flags.contains(.ack) == true)
        XCTAssertTrue(parsed?.flags.contains(.psh) == true)
        XCTAssertEqual(parsed?.window, 8192)
        XCTAssertEqual(parsed?.payload, Data("data".utf8))
        XCTAssertEqual(parsed?.headerLength, 20)

        let mssHeader = IPv6.buildSegment(srcPort: 1, dstPort: 2, sequence: 0,
                                          acknowledgement: 0, flags: [.syn],
                                          window: 65535, mss: 1460)
        XCTAssertEqual(IPv6.parseMSS(mssHeader), 1460)
        XCTAssertNil(IPv6.parseMSS(segment))
    }

    // MARK: - Loopback TCP: two stacks, scripted responder

    /// In-memory packet pipe between exactly two stacks.
    final class LoopbackPipe: TunnelPacketTransport, @unchecked Sendable {
        var deliver: ((Data) async -> Void)?
        func send(_ packet: Data) async throws {
            await deliver?(packet)
        }
    }

    /// Minimal scripted TCP responder (the "device" side): answers SYN with
    /// SYN-ACK, ACKs data, echoes payloads, answers FIN. Built only from the
    /// public codec — independent state from the stack under test. Replies
    /// accumulate in `outbox` for the test to pump back in order.
    /// Test-only and driven sequentially: unchecked Sendable is safe here.
    final class ScriptedResponder: @unchecked Sendable {
        private let src: [UInt8]
        private let dst: [UInt8]
        private var rcvNxt: UInt32 = 0
        private var sndNxt: UInt32 = 0
        private var established = false
        private(set) var outbox: [Data] = []

        init(src: [UInt8], dst: [UInt8]) {
            self.src = src
            self.dst = dst
            sndNxt = UInt32.random(in: 0...UInt32.max)
        }

        func takeOutbox() -> [Data] {
            defer { outbox.removeAll() }
            return outbox
        }

        private func emit(srcPort: UInt16, dstPort: UInt16, seq: UInt32,
                          ack: UInt32, flags: IPv6.Flags, payload: Data) {
            var segment = IPv6.buildSegment(srcPort: srcPort, dstPort: dstPort,
                                            sequence: seq, acknowledgement: ack,
                                            flags: flags, window: 65535,
                                            payload: payload)
            segment = IPv6.withChecksum(src: src, dst: dst, segment: segment)
            outbox.append(IPv6.buildPacket(src: src, dst: dst, nextHeader: 6,
                                           payload: segment))
        }

        func receive(_ packet: Data) {
            guard let ip = IPv6.parsePacket(packet), ip.nextHeader == 6,
                  let seg = IPv6.parseSegment(ip.payload) else { return }
            if seg.flags.contains(.syn) && !established {
                rcvNxt = seg.sequence &+ 1
                emit(srcPort: seg.dstPort, dstPort: seg.srcPort, seq: sndNxt,
                     ack: rcvNxt, flags: [.syn, .ack], payload: Data())
                sndNxt &+= 1
                established = true
                return
            }
            guard established else { return }
            if seg.flags.contains(.rst) { return }
            if !seg.payload.isEmpty, seg.sequence == rcvNxt {
                rcvNxt &+= UInt32(seg.payload.count)
                // Echo the payload back as our own data.
                emit(srcPort: seg.dstPort, dstPort: seg.srcPort, seq: sndNxt,
                     ack: rcvNxt, flags: [.ack, .psh], payload: seg.payload)
                sndNxt &+= UInt32(seg.payload.count)
            } else {
                emit(srcPort: seg.dstPort, dstPort: seg.srcPort, seq: sndNxt,
                     ack: rcvNxt, flags: [.ack], payload: Data())
            }
            if seg.flags.contains(.fin) {
                rcvNxt &+= 1
                emit(srcPort: seg.dstPort, dstPort: seg.srcPort, seq: sndNxt,
                     ack: rcvNxt, flags: [.fin, .ack], payload: Data())
            }
        }
    }

    func testLoopbackHandshakeDataClose() async throws {
        let clientIP = IPv6.parseAddress("fd12::2")!
        let serverIP = IPv6.parseAddress("fd12::1")!
        let serverPort: UInt16 = 9999

        let clientPipe = LoopbackPipe()
        let clientStack = TunnelStack(transport: clientPipe, clientIP: clientIP,
                                      serverIP: serverIP, tunnelMTU: 1500)
        let responder = ScriptedResponder(src: serverIP, dst: clientIP)
        clientPipe.deliver = { packet in
            responder.receive(packet)
            for reply in responder.takeOutbox() {
                await clientStack.ingest(reply)
            }
        }

        let local = try await clientStack.connect(port: serverPort, timeout: 5)
        let stream = TunnelStream(stack: clientStack, port: local, label: "test")

        // 64KB across many segments exercises windowing + ACKs.
        let payload = Data((0..<65536).map { UInt8($0 & 0xff) })
        try await stream.write(payload, timeout: 10)
        let echoed = try await stream.readExactly(payload.count, timeout: 10)
        XCTAssertEqual(echoed, payload)
        stream.close()
    }
}
