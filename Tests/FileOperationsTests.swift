import XCTest
@testable import AirLiftFileManager

@MainActor
final class FileOperationsTests: XCTestCase {
    private var tempRoot: URL!
    private var service: SandboxFileSystemService!
    private var operations: FileOperationManager!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("optests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        service = SandboxFileSystemService(scopeRoots: [tempRoot])
        operations = FileOperationManager(service: service)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testCopyAndMoveWithReplaceGuard() async throws {
        let source = tempRoot.appendingPathComponent("src.txt")
        try Data("payload".utf8).write(to: source)
        let destDir = tempRoot.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // First copy succeeds.
        try await service.copyItem(at: source, to: destDir.appendingPathComponent("src.txt"),
                                   replaceConfirmed: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("src.txt").path))

        // Second copy without confirmation must be refused.
        do {
            try await service.copyItem(at: source, to: destDir.appendingPathComponent("src.txt"),
                                       replaceConfirmed: false)
            XCTFail("Expected replaceNotConfirmed")
        } catch let error as FileSystemError {
            XCTAssertEqual(error, .replaceNotConfirmed(destDir.appendingPathComponent("src.txt").path))
        }

        // With confirmation it succeeds and content is replaced.
        try Data("NEW".utf8).write(to: source)
        try await service.copyItem(at: source, to: destDir.appendingPathComponent("src.txt"),
                                   replaceConfirmed: true)
        let replaced = try Data(contentsOf: destDir.appendingPathComponent("src.txt"))
        XCTAssertEqual(replaced, Data("NEW".utf8))
    }

    func testMoveAcrossFolders() async throws {
        let source = tempRoot.appendingPathComponent("movable.txt")
        try Data("m".utf8).write(to: source)
        let dirA = tempRoot.appendingPathComponent("A")
        let dirB = tempRoot.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try await service.moveItem(at: source, to: dirA.appendingPathComponent("movable.txt"),
                                   replaceConfirmed: false)
        try await operations.move(items: [dirA.appendingPathComponent("movable.txt")], to: dirB)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirB.appendingPathComponent("movable.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirA.appendingPathComponent("movable.txt").path))
    }

    func testDeleteAndDuplicate() async throws {
        let file = tempRoot.appendingPathComponent("item.txt")
        try Data("x".utf8).write(to: file)
        try await operations.delete(items: [file])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        try Data("dup".utf8).write(to: file)
        let copy = try await operations.duplicate(item: file)
        XCTAssertEqual(copy.lastPathComponent, "item copy.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    }

    func testReplaceExplicit() async throws {
        let target = tempRoot.appendingPathComponent("target.txt")
        let source = tempRoot.appendingPathComponent("source.txt")
        try Data("old".utf8).write(to: target)
        try Data("fresh".utf8).write(to: source)

        try await operations.replace(target: target, with: source)
        let content = try Data(contentsOf: target)
        XCTAssertEqual(content, Data("fresh".utf8))
    }

    func testCompressAndExtractRoundTrip() async throws {
        let folder = tempRoot.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: folder.appendingPathComponent("alpha.txt"))
        try Data(repeating: 9, count: 4096).write(to: folder.appendingPathComponent("blob.bin"))

        let items = try await service.listDirectory(at: tempRoot, includeHidden: false)
        let archive = try await operations.compress(items: items.filter { $0.name == "pack" },
                                                    in: tempRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))

        let extracted = try await operations.extract(archive: archive)
        let alpha = try Data(contentsOf: extracted.appendingPathComponent("pack/alpha.txt"))
        XCTAssertEqual(alpha, Data("alpha".utf8))
        let blob = try Data(contentsOf: extracted.appendingPathComponent("pack/blob.bin"))
        XCTAssertEqual(blob.count, 4096)
    }
}
