import XCTest
@testable import Dal

final class AppUpdaterStatusTests: XCTestCase {
    func testPostUpdateFailureSummaryUsesLastBoundedError() {
        let log = """
        Dal updater started
        ERROR: transient mount detail
        ERROR: installed app strict signature verification failed \(String(repeating: "x", count: 600))
        FAILED
        """

        let summary = AppUpdater.postUpdateFailureSummaryForTesting(log)

        XCTAssertTrue(summary.hasPrefix("installed app strict signature verification failed"), summary)
        XCTAssertLessThanOrEqual(summary.count, 240)
        XCTAssertFalse(summary.contains("transient mount detail"), summary)
    }

    func testPostUpdateFailureSummaryHasReadableFallback() {
        let summary = AppUpdater.postUpdateFailureSummaryForTesting("FAILED")
        XCTAssertFalse(summary.isEmpty)
        XCTAssertFalse(summary.contains("已保留或恢复"), summary)
    }

    func testTerminalStatusUsesLastExactMarker() {
        let log = """
        SUCCESS appeared in diagnostic output
        ERROR: final verification failed
        FAILED
        """

        XCTAssertEqual(AppUpdater.postUpdateTerminalStatusForTesting(log), "FAILED")
        XCTAssertNil(AppUpdater.postUpdateTerminalStatusForTesting("ERROR: incomplete transaction"))
    }

    func testProcessLoggingCapturesFailureBeforeScriptRedirects() throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.trashItem(at: fixture, resultingItemURL: nil) }
        let logURL = fixture.appendingPathComponent("update.log")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "echo early-preflight-failure >&2"]

        let handle = try AppUpdater.configureUpdaterProcessLoggingForTesting(
            process,
            logURL: logURL
        )
        try process.run()
        process.waitUntilExit()
        try handle.close()

        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("early-preflight-failure"), log)
    }

    func testProcessLoggingRejectsDanglingSymlinkWithoutWritingTarget() throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.trashItem(at: fixture, resultingItemURL: nil) }
        let logURL = fixture.appendingPathComponent("update.log")
        let outsideTarget = fixture
            .deletingLastPathComponent()
            .appendingPathComponent("dal-log-target-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: logURL,
            withDestinationURL: outsideTarget
        )
        let process = Process()

        XCTAssertThrowsError(
            try AppUpdater.configureUpdaterProcessLoggingForTesting(
                process,
                logURL: logURL
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideTarget.path))
    }

    @MainActor
    func testParentQuitsOnlyAfterReadyMarker() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.trashItem(at: fixture, resultingItemURL: nil) }
        let readyURL = fixture.appendingPathComponent("updater.ready")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            "sleep 0.05; /bin/mkdir \"$1\"; sleep 0.05",
            "dal-test",
            readyURL.path,
        ]
        try process.run()

        let ready = await AppUpdater.waitForUpdaterReadyForTesting(
            process: process,
            readyURL: readyURL,
            attempts: 50,
            pollNanoseconds: 10_000_000
        )

        XCTAssertTrue(ready)
        process.waitUntilExit()
    }

    @MainActor
    func testRegularFileCannotSpoofReadyDirectory() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.trashItem(at: fixture, resultingItemURL: nil) }
        let readyURL = fixture.appendingPathComponent("updater-spoof.ready")
        try Data().write(to: readyURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["1"]
        try process.run()

        let ready = await AppUpdater.waitForUpdaterReadyForTesting(
            process: process,
            readyURL: readyURL,
            attempts: 2,
            pollNanoseconds: 10_000_000
        )

        XCTAssertFalse(ready)
        process.terminate()
        process.waitUntilExit()
    }

    func testReadyMarkerUsesUniqueUnpredictableName() {
        let stagingURL = URL(fileURLWithPath: "/tmp/dal-ready-test", isDirectory: true)
        let first = AppUpdater.updaterReadyURLForTesting(in: stagingURL)
        let second = AppUpdater.updaterReadyURLForTesting(in: stagingURL)

        XCTAssertEqual(first.deletingLastPathComponent(), stagingURL)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("updater-"))
        XCTAssertTrue(first.lastPathComponent.hasSuffix(".ready"))
    }

    @MainActor
    func testParentStaysRunningWhenUpdaterExitsBeforeReady() async throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.trashItem(at: fixture, resultingItemURL: nil) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/false")
        try process.run()

        let ready = await AppUpdater.waitForUpdaterReadyForTesting(
            process: process,
            readyURL: fixture.appendingPathComponent("missing.ready"),
            attempts: 50,
            pollNanoseconds: 10_000_000
        )

        XCTAssertFalse(ready)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dal-updater-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
