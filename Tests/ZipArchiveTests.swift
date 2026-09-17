import XCTest
@testable import AirLiftFileManager

final class ZipArchiveTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ziptests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testRoundTripStoredAndDeflated() throws {
        let small = tempRoot.appendingPathComponent("small.txt")
        try Data("tiny content".utf8).write(to: small)

        let big = tempRoot.appendingPathComponent("big.bin")
        try Data(repeating: 0x41, count: 10_000).write(to: big) // highly compressible

        let nested = tempRoot.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("deep".utf8).write(to: nested.appendingPathComponent("deep.txt"))

        let archive = tempRoot.appendingPathComponent("out.zip")
        try ZipArchive.write(entries: [small, big, nested], to: archive)

        let entries = try ZipArchive.listEntries(in: archive)
        XCTAssertTrue(entries.contains { $0.path == "small.txt" })
        XCTAssertTrue(entries.contains { $0.path == "big.bin" })
        XCTAssertTrue(entries.contains { $0.path == "nested/" })
        XCTAssertTrue(entries.contains { $0.path == "nested/deep.txt" })

        let outDir = tempRoot.appendingPathComponent("unpacked")
        try ZipArchive.extract(archiveURL: archive, to: outDir)

        XCTAssertEqual(try Data(contentsOf: outDir.appendingPathComponent("small.txt")),
                       Data("tiny content".utf8))
        XCTAssertEqual(try Data(contentsOf: outDir.appendingPathComponent("big.bin")).count, 10_000)
        XCTAssertEqual(try Data(contentsOf: outDir.appendingPathComponent("nested/deep.txt")),
                       Data("deep".utf8))
    }

    func testExtractRejectsZipSlipPaths() throws {
        // Hand-craft a zip whose entry path contains ../ traversal.
        let archive = tempRoot.appendingPathComponent("evil.zip")
        var data = Data()
        let name = "../escaped.txt"
        let nameData = name.data(using: .utf8)!
        // local header
        data.appendLE(UInt32(0x04034b50)); data.appendLE(UInt16(20)); data.appendLE(UInt16(0))
        data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0x5D5A))
        data.appendLE(UInt32(0)); data.appendLE(UInt32(0)); data.appendLE(UInt32(0))
        data.appendLE(UInt16(nameData.count)); data.appendLE(UInt16(0))
        data.append(nameData)
        // EOCD only (no central directory entries) — reader must fail cleanly.
        data.appendLE(UInt32(0x06054b50)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0))
        data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(UInt32(0))
        data.appendLE(UInt32(22)); data.appendLE(UInt16(0))
        try data.write(to: archive)

        XCTAssertThrowsError(try ZipArchive.extract(archiveURL: archive,
                                                    to: tempRoot.appendingPathComponent("out")))
    }

    func testListEntriesRejectsNonZip() throws {
        let notZip = tempRoot.appendingPathComponent("plain.txt")
        try Data("hello".utf8).write(to: notZip)
        XCTAssertThrowsError(try ZipArchive.listEntries(in: notZip)) { error in
            guard case ZipArchive.ZipError.notAZipFile = error else {
                XCTFail("Expected notAZipFile, got \(error)")
                return
            }
        }
    }
}
