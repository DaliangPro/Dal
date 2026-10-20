import XCTest
@testable import Dal

final class VoicePolishFixtureTests: XCTestCase {
    func testCatalogContainsExactlyOneHundredFixturesWithRequiredDistribution() {
        XCTAssertEqual(VoicePolishFixtureCatalog.all.count, 100)
        XCTAssertEqual(Set(VoicePolishFixtureCatalog.all.map(\.id)).count, 100)
        for category in VoicePolishFixtureCategory.allCases {
            XCTAssertEqual(
                VoicePolishFixtureCatalog.all.filter { $0.category == category }.count,
                category.expectedCount,
                category.rawValue
            )
        }
    }

}
