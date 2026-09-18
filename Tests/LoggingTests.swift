import XCTest
@testable import AirLiftFileManager

final class LoggingTests: XCTestCase {
    private func entry(_ level: AppLogger.Entry.Level,
                       _ category: AppLogger.Category,
                       _ message: String,
                       event: String? = nil,
                       date: Date = Date()) -> AppLogger.Entry {
        AppLogger.Entry(date: date, category: category, level: level,
                        event: event, message: message)
    }

    // MARK: - Filtering

    func testFilterByText() {
        let entries = [
            entry(.info, .vpn, "Tunnel reachable"),
            entry(.error, .fs, "Permission denied: /var/mobile/Library/SMS"),
        ]
        let result = AppLogger.filter(entries: entries, searchText: "permission")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.category, .fs)
    }

    func testFilterByLevel() {
        let entries = [
            entry(.debug, .app, "d"),
            entry(.info, .app, "i"),
            entry(.warning, .app, "w"),
            entry(.error, .app, "e"),
        ]
        XCTAssertEqual(AppLogger.filter(entries: entries, searchText: "",
                                        levels: [.warning, .error]).count, 2)
        XCTAssertEqual(AppLogger.filter(entries: entries, searchText: "",
                                        levels: []).count, 4, "empty set means no level filter")
    }

    func testFilterByCategory() {
        let entries = [
            entry(.info, .vpn, "a"),
            entry(.info, .airlift, "b"),
            entry(.info, .pairing, "c"),
        ]
        let result = AppLogger.filter(entries: entries, searchText: "",
                                      categories: [.vpn, .pairing])
        XCTAssertEqual(result.count, 2)
        XCTAssertFalse(result.contains { $0.category == .airlift })
    }

    func testFilterMatchesEventName() {
        let entries = [
            entry(.info, .pairing, "record validated", event: "pairing.import"),
        ]
        XCTAssertEqual(AppLogger.filter(entries: entries, searchText: "pairing.import").count, 1)
    }

    func testFilterCombinesAllDimensions() {
        let entries = [
            entry(.error, .fs, "delete failed", event: "fs.delete"),
            entry(.error, .vpn, "tunnel failed"),
            entry(.info, .fs, "delete done", event: "fs.delete"),
        ]
        let result = AppLogger.filter(entries: entries, searchText: "delete",
                                      levels: [.error], categories: [.fs])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.event, "fs.delete")
    }

    // MARK: - Export

    func testExportTXTContainsStructuredLines() {
        let date = Date(timeIntervalSince1970: 1_789_000_000)
        let entries = [
            entry(.warning, .security, "invalid pairing rejected", event: "pairing.validate", date: date),
        ]
        let text = AppLogger.exportTXT(entries)
        XCTAssertTrue(text.contains("[WARNING]"))
        XCTAssertTrue(text.contains("[security]"))
        XCTAssertTrue(text.contains("(pairing.validate)"))
        XCTAssertTrue(text.contains("invalid pairing rejected"))
        XCTAssertTrue(text.hasPrefix("# AirLift File Manager log export"))
        XCTAssertTrue(text.contains("Entries: 1"))
    }

    func testExportJSONRoundTripsFields() throws {
        let entries = [
            entry(.error, .net, "lockdown timeout", event: "lockdown.exchange"),
        ]
        let data = try XCTUnwrap(AppLogger.exportJSON(entries))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([AppLogger.ExportedEntry].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].category, "net")
        XCTAssertEqual(decoded[0].level, "error")
        XCTAssertEqual(decoded[0].event, "lockdown.exchange")
    }

    // MARK: - Redaction

    func testRedactionMasksPEMBlocks() {
        let message = """
        imported record with -----BEGIN RSA PRIVATE KEY-----
        MIIEpAIBAAKCAQEA1234567890abcdefghij
        -----END RSA PRIVATE KEY-----
        done
        """
        let redacted = Redactor.redact(message)
        XCTAssertFalse(redacted.contains("MIIEpAIBAAKCAQEA"))
        XCTAssertTrue(redacted.contains("[REDACTED"))
    }

    func testRedactionMasksLongTokenRuns() {
        let secret = String(repeating: "aB3+", count: 20) // 80 chars of base64-ish material
        let redacted = Redactor.redact("host key \(secret) end")
        XCTAssertFalse(redacted.contains(secret))
        XCTAssertTrue(redacted.contains("[REDACTED]"))
    }

    func testRedactionKeepsNormalMessages() {
        let message = "copy report.txt -> backup/report.txt (12 items)"
        XCTAssertEqual(Redactor.redact(message), message)
    }

    func testEntryRedactsAtConstruction() {
        let secret = String(repeating: "x9", count: 40)
        let e = entry(.info, .security, "storing \(secret)")
        XCTAssertTrue(e.message.contains("[REDACTED]"))
        XCTAssertFalse(e.message.contains(secret))
    }

    // MARK: - Ring buffer capacity

    func testRingBufferBoundsMemory() {
        let logger = AppLogger.shared
        logger.clear()
        for i in 0..<(AppLogger.maxEntries + 250) {
            logger.record(.debug, .app, "filler \(i)")
        }
        XCTAssertLessThanOrEqual(logger.entryCount, AppLogger.maxEntries)
        logger.clear()
    }

    // MARK: - Diagnostic report text

    func testCapabilityReportText() {
        let report = CapabilityReport(
            startedAt: Date(), finishedAt: Date(),
            checks: [
                CapabilityCheck(id: "tunnel.reachability", status: .passed, detail: "up"),
                CapabilityCheck(id: "airlift.on-device", status: .notImplemented, detail: "needs Mac"),
            ])
        let text = report.text(bundleVersion: "1.0 (42)")
        XCTAssertTrue(text.contains("[Verified] tunnel.reachability"))
        XCTAssertTrue(text.contains("[Not implemented] airlift.on-device"))
        XCTAssertTrue(text.contains("Passed 1 · Failed 0 of 2 checks"))
        XCTAssertTrue(text.contains("NOT"))
        XCTAssertTrue(text.contains("proof of AirLift exploit access"))
    }
}
