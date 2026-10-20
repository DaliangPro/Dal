import XCTest
@testable import Dal

final class ModeNameEditingTests: XCTestCase {
    func testSanitizedNameTrimsWhitespace() {
        XCTAssertEqual(
            ModeNameEditing.sanitizedName("  会议纪要  ", fallback: "新模式"),
            "会议纪要"
        )
    }

    func testSanitizedNameFallsBackWhenBlank() {
        XCTAssertEqual(
            ModeNameEditing.sanitizedName("   ", fallback: "新模式"),
            "新模式"
        )
    }

    func testUniqueNameUsesBaseWhenAvailable() {
        XCTAssertEqual(
            ModeNameEditing.uniqueName(base: "新模式", existingNames: ["语音润色"]),
            "新模式"
        )
    }

    func testUniqueNameAppendsNextAvailableIndex() {
        XCTAssertEqual(
            ModeNameEditing.uniqueName(base: "新模式", existingNames: ["新模式", "新模式 2"]),
            "新模式 3"
        )
    }
}
