import Foundation
import XCTest

final class RateSyncLoggingTests: XCTestCase {
    func testLocalDiagnosticLogRemovesEntriesOlderThanTwelveHours() throws {
        // Given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RateSyncLogTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = LocalDiagnosticLog(
            fileURL: directory.appendingPathComponent("RateSync-debug.log"),
            now: { now },
            startsMaintenanceTimer: false
        )
        log.append(level: "INFO", message: "expired-entry", at: now.addingTimeInterval(-LocalDiagnosticLog.retentionInterval - 1))
        log.append(level: "INFO", message: "boundary-entry", at: now.addingTimeInterval(-LocalDiagnosticLog.retentionInterval))
        log.append(level: "INFO", message: "recent-entry", at: now)
        log.flush()

        // When
        log.cleanupExpiredEntries(at: now)
        log.flush()

        // Then
        let contents = try String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertFalse(contents.contains("expired-entry"))
        XCTAssertTrue(contents.contains("boundary-entry"))
        XCTAssertTrue(contents.contains("recent-entry"))
    }

    func testDiagnosticLogMessagePreservesPublicAndRedactsPrivateInterpolations() {
        // Given
        let secretTrackName = "Private track title"

        // When
        let message: RateSyncLogMessage = "sampleRate=\(48_000, privacy: .public) track=\(secretTrackName)"

        // Then
        XCTAssertEqual(message.rendered, "sampleRate=48000 track=<private>")
    }

    func testDiagnosticLogMessageKeepsBareNumericDiagnosticsVisible() {
        let message: RateSyncLogMessage = "sampleRate=\(48_000) bitDepth=\(32)"

        XCTAssertEqual(message.rendered, "sampleRate=48000 bitDepth=32")
    }

    func testLocalDiagnosticFileLoggingRequiresExplicitBuildCondition() {
        // Given: the test target has no local-log compilation condition.
        // When: checking the production logger's build-mode setting.
        // Then: local file capture remains disabled in this target.
        XCTAssertFalse(RateSyncDiagnosticLogging.localFileEnabled)
    }
}
