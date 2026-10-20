import XCTest
@testable import Dal

final class ModePickerControlTests: XCTestCase {
    func testPopoverHeightIncludesCreateRowDividerSpacingAndPadding() {
        let optionCount = 5

        let height = ModePickerControlMetrics.popoverHeight(optionCount: optionCount)

        XCTAssertEqual(height, 243)
    }

    func testPopoverHeightHandlesEmptyModeList() {
        let height = ModePickerControlMetrics.popoverHeight(optionCount: 0)

        XCTAssertEqual(height, 58)
    }
}
