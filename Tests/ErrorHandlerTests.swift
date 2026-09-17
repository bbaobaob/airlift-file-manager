import XCTest
@testable import AirLiftFileManager

final class ErrorHandlerTests: XCTestCase {
    func testFileSystemErrorMessagesAreUserFacing() {
        XCTAssertFalse(ErrorHandler.userMessage(for: FileSystemError.notFound("/x")).isEmpty)
        XCTAssertFalse(ErrorHandler.userMessage(for: FileSystemError.permissionDenied("/x")).isEmpty)
        XCTAssertFalse(ErrorHandler.userMessage(for: FileSystemError.replaceNotConfirmed("/x")).isEmpty)
        XCTAssertTrue(ErrorHandler.userMessage(
            for: FileSystemError.unsupportedOperation("n/a")).contains("Unsupported"))
    }

    func testZipErrorMessages() {
        XCTAssertTrue(ErrorHandler.userMessage(for: ZipArchive.ZipError.notAZipFile)
            .contains("ZIP"))
    }

    func testPresentLogsAndReturnsMessage() {
        let message = ErrorHandler.present(FileSystemError.outsideScope("/etc"),
                                           context: "test-context")
        XCTAssertTrue(message.contains("/etc"))
        let logged = AppLogger.shared.recentEntries()
        XCTAssertTrue(logged.contains { $0.message.contains("test-context") })
    }

    func testPermissionServiceClassifiesSandboxPaths() {
        let service = PermissionService()
        let reports = service.probeAll()
        // All 12 spec directories must be probed with honest classifications.
        XCTAssertEqual(reports.count, 12)
        for report in reports {
            XCTAssertTrue(AccessLevel.allCasesAndRaw.contains(report.level))
        }
        // App sandbox Documents must be accessible inside a host app/test run.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        let docsReport = service.probe(path: docs)
        XCTAssertEqual(docsReport.level, .accessible)
    }
}

private extension AccessLevel {
    static let allCasesAndRaw: [AccessLevel] = [
        .accessible, .readOnly, .restricted, .unsupported, .notFound,
        .requiresExternalComponent]
}
