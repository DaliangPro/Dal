import XCTest
@testable import Dal

/// REPAIR_PLAN A2：更新包校验闸门——缺校验值/缺实际值/不匹配一律拒绝
final class AppUpdaterChecksumTests: XCTestCase {

    func testMissingExpectedHashIsRejected() {
        XCTAssertFalse(AppUpdater.isChecksumAcceptable(expected: nil, actual: "abc123"))
    }

    func testEmptyExpectedHashIsRejected() {
        XCTAssertFalse(AppUpdater.isChecksumAcceptable(expected: "", actual: "abc123"))
    }

    func testMissingActualHashIsRejected() {
        XCTAssertFalse(AppUpdater.isChecksumAcceptable(expected: "abc123", actual: nil))
    }

    func testMismatchIsRejected() {
        XCTAssertFalse(AppUpdater.isChecksumAcceptable(expected: "abc123", actual: "def456"))
    }

    func testExactMatchIsAccepted() {
        XCTAssertTrue(AppUpdater.isChecksumAcceptable(expected: "abc123", actual: "abc123"))
    }

    func testCaseInsensitiveMatchIsAccepted() {
        XCTAssertTrue(AppUpdater.isChecksumAcceptable(expected: "ABC123", actual: "abc123"))
    }

    func testStagedDMGIsNeverPermanentlyDeleted() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Dal/Services/AppUpdater.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("removeItem(at: destination)"))
        XCTAssertTrue(source.contains("trashItem(at: destination"))
    }
}
