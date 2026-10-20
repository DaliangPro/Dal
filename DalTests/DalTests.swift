import XCTest
@testable import Dal

final class DalTests: XCTestCase {
    func testRecognitionTranscriptDisplayTextPrefersAuthoritativeText() {
        let transcript = RecognitionTranscript(
            confirmedSegments: ["第一段", "第二段"],
            partialText: "草稿",
            authoritativeText: "最终文本",
            isFinal: true
        )

        XCTAssertEqual(transcript.composedText, "第一段第二段草稿")
        XCTAssertEqual(transcript.displayText, "最终文本")
    }
}
