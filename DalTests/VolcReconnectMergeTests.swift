import XCTest
@testable import Dal

/// REPAIR_PLAN B7b：重连后冻结前缀与服务端新结果的合并逻辑
final class VolcReconnectMergeTests: XCTestCase {

    func testNoCarriedSegmentsBehavesAsBefore() {
        let result = VolcASRResult(
            text: "",
            utterances: [
                VolcUtterance(text: "你好", definite: true),
                VolcUtterance(text: "世界", definite: false),
            ]
        )
        let transcript = VolcASRClient.transcript(from: result, isFinal: false, carriedSegments: [])
        XCTAssertEqual(transcript.confirmedSegments, ["你好"])
        XCTAssertEqual(transcript.partialText, "世界")
        XCTAssertEqual(transcript.composedText, "你好世界")
    }

    func testCarriedSegmentsArePrependedToConfirmed() {
        let result = VolcASRResult(
            text: "",
            utterances: [VolcUtterance(text: "继续说", definite: true)]
        )
        let transcript = VolcASRClient.transcript(
            from: result, isFinal: false,
            carriedSegments: ["断线前的话", "没说完的"]
        )
        XCTAssertEqual(transcript.confirmedSegments, ["断线前的话", "没说完的", "继续说"])
        XCTAssertEqual(transcript.composedText, "断线前的话没说完的继续说")
    }

    func testAuthoritativeTextGetsCarriedPrefix() {
        let result = VolcASRResult(
            text: "重连后的整句",
            utterances: [VolcUtterance(text: "重连后的整句", definite: true)]
        )
        let transcript = VolcASRClient.transcript(
            from: result, isFinal: true,
            carriedSegments: ["断线前的话"]
        )
        XCTAssertEqual(transcript.authoritativeText, "断线前的话重连后的整句")
        XCTAssertTrue(transcript.isFinal)
    }

    func testEmptyServerResultStillShowsCarriedText() {
        let result = VolcASRResult(text: "", utterances: [])
        let transcript = VolcASRClient.transcript(
            from: result, isFinal: false,
            carriedSegments: ["断线前的话"]
        )
        XCTAssertEqual(transcript.confirmedSegments, ["断线前的话"])
        XCTAssertEqual(transcript.composedText, "断线前的话")
    }
}
