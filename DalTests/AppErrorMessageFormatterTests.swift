import XCTest
@testable import Dal

final class AppErrorMessageFormatterTests: XCTestCase {
    func testUsesLocalizedErrorDescription() {
        let message = AppErrorMessageFormatter.userFacingMessage(for: LocalizedTestError())

        XCTAssertEqual(message, "Localized failure")
    }

    func testUsesNSErrorLocalizedDescription() {
        let error = NSError(
            domain: "DalTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "NSError failure"]
        )

        let message = AppErrorMessageFormatter.userFacingMessage(for: error)

        XCTAssertEqual(message, "NSError failure")
    }

    func testFallsBackForPlainError() {
        let message = AppErrorMessageFormatter.userFacingMessage(for: PlainError.failed)

        XCTAssertEqual(message, L("录音启动失败", "Failed to start recording"))
    }
}

private struct LocalizedTestError: LocalizedError {
    var errorDescription: String? { "Localized failure" }
}

private enum PlainError: Error {
    case failed
}
