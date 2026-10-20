import XCTest
@testable import Dal

final class SetupWizardLayoutTests: XCTestCase {

    func testCenteredTitleBandHeightUsesSpaceAboveCenteredContent() {
        XCTAssertEqual(
            SetupWizardLayout.centeredTitleBandHeight(pageHeight: 600, referenceContentHeight: 132),
            234
        )
    }

    func testCenteredTitleBandHeightClampsForShortPages() {
        XCTAssertEqual(
            SetupWizardLayout.centeredTitleBandHeight(pageHeight: 120, referenceContentHeight: 132),
            0
        )
    }

    func testLowerBandCenterYUsesRemainingSpaceBelowCenteredContent() {
        XCTAssertEqual(
            SetupWizardLayout.lowerBandCenterY(pageHeight: 600, centeredContentHeight: 158),
            489.5
        )
    }
}
