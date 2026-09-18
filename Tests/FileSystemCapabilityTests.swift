import XCTest
@testable import AirLiftFileManager

@MainActor
final class FileSystemCapabilityTests: XCTestCase {
    func testAccessLevelSemantics() {
        XCTAssertTrue(AccessLevel.accessible.canBrowse)
        XCTAssertTrue(AccessLevel.accessible.canRead)
        XCTAssertTrue(AccessLevel.accessible.canWrite)

        XCTAssertFalse(AccessLevel.readOnly.canBrowse)
        XCTAssertTrue(AccessLevel.readOnly.canRead)
        XCTAssertFalse(AccessLevel.readOnly.canWrite)

        for level: AccessLevel in [.restricted, .notFound, .notTested,
                                   .connectionRequired, .unsupported,
                                   .requiresExternalComponent] {
            XCTAssertFalse(level.canBrowse, "\(level.rawValue) must not be browsable")
            XCTAssertFalse(level.canWrite, "\(level.rawValue) must not be writable")
        }
        XCTAssertFalse(AccessLevel.connectionRequired.canRead)
    }

    func testCapabilityOptionSetDefaults() {
        XCTAssertTrue(FileSystemCapabilities.fullSandbox.contains(.delete))
        XCTAssertTrue(FileSystemCapabilities.fullSandbox.contains(.getInfo))
        XCTAssertTrue(FileSystemCapabilities.readOnly.contains(.readFile))
        XCTAssertFalse(FileSystemCapabilities.readOnly.contains(.write))
        XCTAssertFalse(FileSystemCapabilities.readOnly.contains(.delete))
        XCTAssertTrue(FileSystemCapabilities.none.isEmpty)
    }

    func testContextMenuGatesActionsByCapability() {
        let file = FileItem(url: URL(fileURLWithPath: "/tmp/a.txt"),
                            isDirectory: false, size: 1, modificationDate: nil,
                            creationDate: nil, posixPermissions: nil, isHidden: false)
        let full = FileContextMenu.actions(for: file, capabilities: .fullSandbox)
        XCTAssertTrue(full.contains(.delete))
        XCTAssertTrue(full.contains(.rename))
        XCTAssertTrue(full.contains(.replace))

        let readOnly = FileContextMenu.actions(for: file, capabilities: .readOnly)
        XCTAssertTrue(readOnly.contains(.getInfo))
        XCTAssertTrue(readOnly.contains(.share))
        XCTAssertFalse(readOnly.contains(.delete))
        XCTAssertFalse(readOnly.contains(.rename))
        XCTAssertFalse(readOnly.contains(.replace))
        XCTAssertFalse(readOnly.contains(.compress))

        let none = FileContextMenu.actions(for: file, capabilities: .none)
        XCTAssertTrue(none.isEmpty)

        // Extract only offered for zip archives when capability present.
        let zip = FileItem(url: URL(fileURLWithPath: "/tmp/a.zip"),
                           isDirectory: false, size: 1, modificationDate: nil,
                           creationDate: nil, posixPermissions: nil, isHidden: false)
        XCTAssertTrue(FileContextMenu.actions(for: zip, capabilities: [.extract]).contains(.extract))
        XCTAssertFalse(FileContextMenu.actions(for: file, capabilities: [.extract]).contains(.extract))
    }
}

@MainActor
final class DirectoryHubViewModelTests: XCTestCase {
    private func report(_ path: String, _ level: AccessLevel) -> DirectoryAccessReport {
        DirectoryAccessReport(path: path, level: level, detail: "test detail")
    }

    func testHubShowsSandboxPlusProbedPathsAndAirLiftRowStaysHonest() async {
        let model = DirectoryHubViewModel { path in
            self.report(path, path == "/var/mobile" ? .accessible : .restricted)
        }
        await model.refresh()

        XCTAssertEqual(model.locations.count, 1 + PermissionService.probedPaths.count)
        XCTAssertEqual(model.locations.first?.backend, .sandbox)
        XCTAssertEqual(model.locations.first?.access, .accessible)

        let mobile = model.locations.first { $0.path == "/var/mobile" }
        XCTAssertEqual(mobile?.access, .accessible)
        let sms = model.locations.first { $0.path == "/var/mobile/Library/SMS" }
        XCTAssertEqual(sms?.access, .restricted)
        XCTAssertFalse(sms?.access.canBrowse ?? true, "restricted path must not be browsable")

        XCTAssertEqual(model.browsableCount, 2) // sandbox + /var/mobile
        XCTAssertNotNil(model.lastProbedAt)
    }

    func testHubProbesRunOnRefreshOnlyViaRealProbeFunction() async {
        final class Counter: @unchecked Sendable {
            var count = 0
        }
        let counter = Counter()
        let model = DirectoryHubViewModel { _ in
            counter.count += 1
            return self.report("/x", .restricted)
        }
        await model.refresh()
        await model.refresh()
        XCTAssertEqual(counter.count, 2 * PermissionService.probedPaths.count)
    }
}

@MainActor
final class UniqueDestinationTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniqdest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testFreeNamePassesThrough() {
        let service = SandboxFileSystemService(scopeRoots: [tempRoot])
        let base = tempRoot.appendingPathComponent("new.txt")
        XCTAssertEqual(service.uniqueDestination(base), base)
    }

    func testCollisionAppendsCounter() throws {
        try Data("x".utf8).write(to: tempRoot.appendingPathComponent("doc.txt"))
        try Data("x".utf8).write(to: tempRoot.appendingPathComponent("doc 2.txt"))
        let service = SandboxFileSystemService(scopeRoots: [tempRoot])
        let next = service.uniqueDestination(tempRoot.appendingPathComponent("doc.txt"))
        XCTAssertEqual(next.lastPathComponent, "doc 3.txt")
    }

    func testCollisionWithoutExtension() throws {
        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent("pack"),
                                                withIntermediateDirectories: true)
        let service = SandboxFileSystemService(scopeRoots: [tempRoot])
        let next = service.uniqueDestination(tempRoot.appendingPathComponent("pack"))
        XCTAssertEqual(next.lastPathComponent, "pack 2")
    }
}

@MainActor
final class OperationCancellationTests: XCTestCase {
    private var tempRoot: URL!
    private var service: SandboxFileSystemService!
    private var operations: FileOperationManager!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        service = SandboxFileSystemService(scopeRoots: [tempRoot])
        operations = FileOperationManager(service: service)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testCancelStopsMidwayAndReportsProgress() async throws {
        let dir = tempRoot.appendingPathComponent("many")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for i in 0..<10 {
            let f = dir.appendingPathComponent("f\(i).txt")
            try Data("x".utf8).write(to: f)
            urls.append(f)
        }
        let dest = tempRoot.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        operations.cancelCurrentOperation() // requested before running
        do {
            try await operations.copy(items: urls, to: dest)
            XCTFail("Expected cancellation error")
        } catch {
            XCTAssertTrue(String(describing: error).contains("cancel"),
                          "error should mention cancellation: \(error)")
        }
        let copied = try FileManager.default.contentsOfDirectory(atPath: dest.path).count
        XCTAssertLessThan(copied, 10, "cancellation must stop before all items copied")
        XCTAssertEqual(operations.progressCompleted, copied)
        XCTAssertFalse(operations.isRunning)
        XCTAssertNil(operations.activeOperation)
    }

    func testSuccessfulOperationPublishesProgress() async throws {
        let f = tempRoot.appendingPathComponent("one.txt")
        try Data("x".utf8).write(to: f)
        let dest = tempRoot.appendingPathComponent("out2")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        try await operations.copy(items: [f], to: dest)
        XCTAssertEqual(operations.progressCompleted, 1)
        XCTAssertFalse(operations.isRunning)
    }
}
