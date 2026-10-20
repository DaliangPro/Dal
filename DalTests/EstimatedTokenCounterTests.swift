import XCTest
@testable import Dal

final class EstimatedTokenCounterTests: XCTestCase {
    func testEmptyAndWhitespaceTextReturnsZero() {
        XCTAssertEqual(EstimatedTokenCounter.count(in: ""), 0)
        XCTAssertEqual(EstimatedTokenCounter.count(in: " \n\t"), 0)
    }

    func testCountsCJKTextPerScalar() {
        XCTAssertEqual(EstimatedTokenCounter.count(in: "你好世界"), 4)
    }

    func testCountsLatinRunsByApproximateByteChunks() {
        XCTAssertEqual(EstimatedTokenCounter.count(in: "Hello world"), 3)
    }

    func testCountsMixedTextDeterministically() {
        XCTAssertEqual(EstimatedTokenCounter.count(in: "你好 AI!"), 4)
    }
}
