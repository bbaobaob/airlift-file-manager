import XCTest
@testable import AirLiftFileManager

final class FileSystemServiceTests: XCTestCase {
    private var tempRoot: URL!
    private var service: SandboxFileSystemService!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fstests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        service = SandboxFileSystemService(scopeRoots: [tempRoot])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testListDirectoryReturnsRealEntries() async throws {
        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tempRoot.appendingPathComponent("a.txt").path,
                                       contents: Data("hello".utf8))

        let items = try await service.listDirectory(at: tempRoot, includeHidden: false)

        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.contains { $0.isDirectory && $0.name == "sub" })
        XCTAssertTrue(items.contains { !$0.isDirectory && $0.name == "a.txt" })
    }

    func testListDirectoryHonorsHiddenFilter() async throws {
        FileManager.default.createFile(atPath: tempRoot.appendingPathComponent(".secret").path,
                                       contents: Data())
        FileManager.default.createFile(atPath: tempRoot.appendingPathComponent("visible").path,
                                       contents: Data())

        let hidden = try await service.listDirectory(at: tempRoot, includeHidden: true)
        let visible = try await service.listDirectory(at: tempRoot, includeHidden: false)

        XCTAssertTrue(hidden.contains { $0.name == ".secret" })
        XCTAssertFalse(visible.contains { $0.name == ".secret" })
    }

    func testListDirectoryThrowsNotFoundForMissingFolder() async {
        do {
            _ = try await service.listDirectory(at: tempRoot.appendingPathComponent("missing"),
                                                includeHidden: false)
            XCTFail("Expected notFound")
        } catch let error as FileSystemError {
            XCTAssertEqual(error, .notFound(tempRoot.appendingPathComponent("missing").path))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testMetadataForFile() async throws {
        let payload = Data(repeating: 7, count: 128)
        FileManager.default.createFile(atPath: tempRoot.appendingPathComponent("blob.bin").path,
                                       contents: payload)

        let meta = try await service.getFileMetadata(at: tempRoot.appendingPathComponent("blob.bin"))

        XCTAssertEqual(meta.size, 128)
        XCTAssertFalse(meta.isDirectory)
        XCTAssertNotNil(meta.modificationDate)
    }

    func testOutOfScopeRejected() async {
        let outside = URL(fileURLWithPath: "/var/mobile/Library/SMS")
        do {
            _ = try await service.listDirectory(at: outside, includeHidden: false)
            XCTFail("Expected outsideScope")
        } catch let error as FileSystemError {
            XCTAssertEqual(error, .outsideScope(outside.path))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testCreateDirectoryAndRename() async throws {
        let target = tempRoot.appendingPathComponent("NewFolder")
        try await service.createDirectory(at: target)
        let created = await service.fileExists(at: target)
        XCTAssertTrue(created)

        let renamed = try await service.renameItem(at: target, to: "RenamedFolder")
        XCTAssertEqual(renamed.lastPathComponent, "RenamedFolder")
        let stillThere = await service.fileExists(at: target)
        XCTAssertFalse(stillThere)
    }

    func testRenameToExistingNameThrows() async throws {
        FileManager.default.createFile(atPath: tempRoot.appendingPathComponent("one").path, contents: Data())
        FileManager.default.createFile(atPath: tempRoot.appendingPathComponent("two").path, contents: Data())
        do {
            _ = try await service.renameItem(at: tempRoot.appendingPathComponent("one"), to: "two")
            XCTFail("Expected alreadyExists")
        } catch let error as FileSystemError {
            XCTAssertEqual(error, .alreadyExists(tempRoot.appendingPathComponent("two").path))
        }
    }
}
