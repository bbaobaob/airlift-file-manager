import XCTest
@testable import AirLiftFileManager

final class LockdownClientTests: XCTestCase {
    func testFramePrependsBigEndianLength() {
        let payload = Data([0x01, 0x02, 0x03])
        let framed = LockdownClient.frame(payload)
        XCTAssertEqual(Array(framed.prefix(4)), [0x00, 0x00, 0x00, 0x03])
        XCTAssertEqual(framed.dropFirst(4), payload)
    }

    func testPopFrameSplitsConsecutiveFrames() {
        let first = LockdownClient.frame(Data([0xAA]))
        let second = LockdownClient.frame(Data([0xBB, 0xCC]))
        var buffer = first
        buffer.append(second)

        guard let (frame1, rest) = LockdownClient.popFrame(from: buffer) else {
            XCTFail("Expected first frame")
            return
        }
        XCTAssertEqual(frame1, Data([0xAA]))
        XCTAssertEqual(rest, second)

        guard let (frame2, remaining) = LockdownClient.popFrame(from: rest) else {
            XCTFail("Expected second frame")
            return
        }
        XCTAssertEqual(frame2, Data([0xBB, 0xCC]))
        XCTAssertTrue(remaining.isEmpty)
    }

    func testPopFrameRejectsIncompleteBuffer() {
        XCTAssertNil(LockdownClient.popFrame(from: Data([0x00, 0x00])))
        XCTAssertNil(LockdownClient.popFrame(from: Data([0x00, 0x00, 0x00])))
        XCTAssertNil(LockdownClient.popFrame(from: LockdownClient.frame(Data([1])).dropLast(1)))
        XCTAssertNil(LockdownClient.popFrame(from: Data([0xFF, 0xFF, 0xFF, 0xFF])))
    }

    func testPlistRoundTripForLockdownRequests() throws {
        let body: [String: Any] = ["RequestType": "QueryType"]
        let payload = try PropertyListSerialization.data(
            fromPropertyList: body, format: .binary, options: 0)
        let framed = LockdownClient.frame(payload)
        let (frame, _) = LockdownClient.popFrame(from: framed)!
        let decoded = try PropertyListSerialization.propertyList(from: frame, format: nil)
        XCTAssertEqual(decoded as? [String: String], ["RequestType": "QueryType"])
    }
}
