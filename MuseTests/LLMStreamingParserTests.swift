import XCTest
@testable import Muse

final class LLMStreamingParserTests: XCTestCase {
    func testMalformedOpenAICompatibleChunkRaisesExplicitError() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: "data: {not-json}")

        XCTAssertThrowsError(try parser.consume(line: "")) { error in
            guard case LLMError.malformedResponse = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testMalformedClaudeEventRaisesExplicitError() throws {
        var parser = ClaudeStreamingParser()
        try parser.consume(line: "data: {not-json}")

        XCTAssertThrowsError(try parser.consume(line: "")) { error in
            guard case LLMError.malformedResponse = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testThinkingProbeAcceptsTokenLimitOnlyWithReasoningAndTerminalEvent() throws {
        for content in ["", "尚未完成的答案"] {
            var parser = LLMStreamingParser()
            let chunk: [String: Any] = ["choices": [["delta": ["reasoning_content": "推理测试", "content": content], "finish_reason": "length"]]]
            let data = try JSONSerialization.data(withJSONObject: chunk)
            try parser.consume(line: "data: " + String(decoding: data, as: UTF8.self))
            try parser.consume(line: "")
            XCTAssertEqual(try parser.finish(allowIncompleteProbeAnswer: true), content)
            XCTAssertTrue(parser.reasoningObserved)
            XCTAssertTrue(parser.isComplete)
            XCTAssertTrue(parser.hitOutputTokenLimit)
            // 同一响应绝不能通过正常正文交付校验。
            XCTAssertThrowsError(try parser.finish())
        }
    }

    func testThinkingProbeStillRejectsInterruptedReasoningStream() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: #"data: {"choices":[{"delta":{"reasoning_content":"推理测试"},"finish_reason":null}]}"#)
        try parser.consume(line: "")
        XCTAssertTrue(parser.reasoningObserved)
        XCTAssertThrowsError(try parser.finish(allowIncompleteProbeAnswer: true))
    }

    func testThinkingProbeAcceptsLimitedAnswerWithoutInventingReasoningEvidence() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: #"data: {"choices":[{"delta":{"content":"不完整正文"},"finish_reason":"length"}]}"#)
        try parser.consume(line: "")
        XCTAssertEqual(try parser.finish(allowIncompleteProbeAnswer: true), "不完整正文")
        XCTAssertFalse(parser.reasoningObserved)
        XCTAssertThrowsError(try parser.finish())
    }

    func testThinkingProbeRejectsEmptyTokenLimitResponse() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: #"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#)
        try parser.consume(line: "")
        XCTAssertThrowsError(try parser.finish(allowIncompleteProbeAnswer: true))
    }

    func testThinkingProbeAllowsCompleteReasoningWithoutFinalAnswer() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: #"data: {"choices":[{"delta":{"reasoning_content":"推理测试"},"finish_reason":"stop"}]}"#)
        try parser.consume(line: "")
        XCTAssertEqual(try parser.finish(allowIncompleteProbeAnswer: true), "")
        XCTAssertThrowsError(try parser.finish())
    }

    func testDataWithoutSpaceAndDoneAreParsed() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: #"data:{"choices":[{"delta":{"content":"你好"},"finish_reason":null}]}"#)
        try parser.consume(line: "")
        try parser.consume(line: "data:[DONE]")

        XCTAssertEqual(try parser.finish(), "你好")
        XCTAssertTrue(parser.isComplete)
    }

    func testDataWithSpaceAndCRLFAreParsed() throws {
        var parser = LLMStreamingParser()
        try parser.consume(
            line: #"data: {"choices":[{"delta":{"content":"hello"},"finish_reason":null}]}"# + "\r"
        )
        try parser.consume(line: "\r")
        try parser.consume(line: "data: [DONE]" + "\r")

        XCTAssertEqual(try parser.finish(), "hello")
    }

    func testMultilineDataEventIsJoinedBeforeDecoding() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: #"data: {"choices":[{"delta":"#)
        try parser.consume(line: #"data: {"content":"joined"},"finish_reason":"stop"}]}"#)
        try parser.consume(line: "")

        XCTAssertEqual(try parser.finish(), "joined")
        XCTAssertTrue(parser.isComplete)
    }

    func testNonEmptyFinishReasonCompletesWithoutDone() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: #"data: {"choices":[{"delta":{"content":"finished"},"finish_reason":"stop"}]}"#)
        try parser.consume(line: "")

        XCTAssertEqual(try parser.finish(), "finished")
        XCTAssertTrue(parser.isComplete)
    }

    func testLengthFinishReasonIsReportedAsTruncated() throws {
        var parser = LLMStreamingParser()
        try parser.consume(
            line: #"data: {"choices":[{"delta":{"content":"partial"},"finish_reason":"length"}]}"#
        )
        try parser.consume(line: "")

        XCTAssertThrowsError(try parser.finish()) { error in
            guard case LLMError.truncatedResponse(let count) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(count, 7)
        }
    }

    func testFinishReasonWithoutDeltaStillCompletes() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: #"data: {"choices":[{"delta":{"content":"body"},"finish_reason":null}]}"#)
        try parser.consume(line: "")
        try parser.consume(line: #"data: {"choices":[{"finish_reason":"stop"}]}"#)
        try parser.consume(line: "")

        XCTAssertEqual(try parser.finish(), "body")
        XCTAssertTrue(parser.isComplete)
    }

    func testEmptyFinishReasonDoesNotComplete() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: #"data: {"choices":[{"delta":{"content":"partial"},"finish_reason":""}]}"#)
        try parser.consume(line: "")

        XCTAssertThrowsError(try parser.finish()) { error in
            guard case LLMError.truncatedResponse = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testConnectionCloseAfterPartialTextIsTruncated() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: #"data: {"choices":[{"delta":{"content":"partial"},"finish_reason":null}]}"#)
        try parser.consume(line: "")

        XCTAssertThrowsError(try parser.finish()) { error in
            guard case LLMError.truncatedResponse = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testTransportFailureAfterPartialTextBecomesRetryableTruncatedError() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: #"data: {"choices":[{"delta":{"content":"partial"},"finish_reason":null}]}"#)

        let error = parser.errorForStreamFailure(URLError(.networkConnectionLost))
        guard case LLMError.truncatedResponse = error else {
            return XCTFail("unexpected error: \(error)")
        }
    }

    func testParserErrorAfterPartialTextIsNotReclassifiedAsTruncated() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: #"data: {"choices":[{"delta":{"content":"partial"},"finish_reason":null}]}"#)
        try parser.consume(line: "")

        let error = parser.errorForStreamFailure(LLMError.responseTooLarge(5))
        guard case LLMError.responseTooLarge(let maximum) = error else {
            return XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(maximum, 5)
    }

    func testCancellationAfterPartialTextPropagatesUnchanged() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: #"data: {"choices":[{"delta":{"content":"partial"},"finish_reason":null}]}"#)
        try parser.consume(line: "")

        let error = parser.errorForStreamFailure(CancellationError())
        XCTAssertTrue(error is CancellationError)
    }

    func testResponseLargerThanLimitIsRejectedBeforeAppend() throws {
        var parser = LLMStreamingParser(maxResponseBytes: 5)

        XCTAssertThrowsError(
            try {
                try parser.consume(
                    line: #"data: {"choices":[{"delta":{"content":"123456"},"finish_reason":"stop"}]}"#
                )
                try parser.consume(line: "")
            }()
        ) { error in
            guard case LLMError.responseTooLarge = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testMultilineEventEnvelopeHasIndependentHardLimit() throws {
        var parser = LLMStreamingParser(maxResponseBytes: 100, maxEventBytes: 5)
        try parser.consume(line: "data: 123")

        XCTAssertThrowsError(try parser.consume(line: "data: 456")) { error in
            guard case LLMError.responseTooLarge = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testCommentsAndUnknownFieldsAreIgnored() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: ": keep-alive")
        try parser.consume(line: "event: message")
        try parser.consume(line: #"data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#)
        try parser.consume(line: "")

        XCTAssertEqual(try parser.finish(), "ok")
    }

    func testReasoningContentIsObservedButNotIncludedInFinalText() throws {
        var parser = LLMStreamingParser()
        try parser.consume(
            line: #"data: {"choices":[{"delta":{"reasoning_content":"内部推理"},"finish_reason":null}]}"#
        )
        try parser.consume(line: "")
        try parser.consume(
            line: #"data: {"choices":[{"delta":{"content":"703"},"finish_reason":"stop"}]}"#
        )
        try parser.consume(line: "")

        XCTAssertEqual(try parser.finish(), "703")
        XCTAssertTrue(parser.reasoningObserved)
    }

    func testThinkingFieldIsObservedButNotIncludedInFinalText() throws {
        var parser = LLMStreamingParser()
        try parser.consume(
            line: #"data: {"choices":[{"delta":{"thinking":"内部推理"},"finish_reason":null}]}"#
        )
        try parser.consume(line: "")
        try parser.consume(
            line: #"data: {"choices":[{"delta":{"content":"703"},"finish_reason":"stop"}]}"#
        )
        try parser.consume(line: "")

        XCTAssertEqual(try parser.finish(), "703")
        XCTAssertTrue(parser.reasoningObserved)
    }

    func testReasoningTokenUsageIsObserved() throws {
        var parser = LLMStreamingParser()
        try parser.consume(
            line: #"data: {"choices":[],"usage":{"completion_tokens_details":{"reasoning_tokens":12}}}"#
        )
        try parser.consume(line: "")
        try parser.consume(
            line: #"data: {"choices":[{"delta":{"content":"703"},"finish_reason":"stop"}]}"#
        )
        try parser.consume(line: "")

        XCTAssertEqual(try parser.finish(), "703")
        XCTAssertTrue(parser.reasoningObserved)
    }

    func testNonStreamingReasoningDetailsRequireAtLeastOneEntry() throws {
        let emptyData = Data(
            #"{"choices":[{"message":{"content":"703","reasoning_details":[]}}]}"#.utf8
        )
        let populatedData = Data(
            #"{"choices":[{"message":{"content":"703","reasoning_details":[{"type":"text"}]}}]}"#.utf8
        )

        let empty = try JSONDecoder().decode(ChatCompletionResponse.self, from: emptyData)
        let populated = try JSONDecoder().decode(ChatCompletionResponse.self, from: populatedData)

        XCTAssertNil(empty.thinkingEvidence.reasoningObserved)
        XCTAssertEqual(populated.thinkingEvidence.reasoningObserved, true)
    }

    func testNonStreamingLengthFinishReasonIsMarkedAsTruncated() throws {
        let data = Data(
            #"{"choices":[{"message":{"content":"partial"},"finish_reason":"length"}]}"#.utf8
        )

        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)

        XCTAssertTrue(response.hitOutputTokenLimit)
    }
}

extension LLMStreamingParserTests {
    func testNonCoreMetadataCannotDiscardValidBody() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: "data: " + """
        {"choices":[{"delta":{"content":"正文","thinking":{},"reasoning_details":{}},"finish_reason":"stop"}],
        "usage":{"completion_tokens_details":"custom"}}
        """)
        try parser.consume(line: "")
        XCTAssertEqual(try parser.finish(), "正文")
    }

    func testMalformedBodyAfterPrefixCannotReturnSuccessfulPrefix() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: #"data: {"choices":[{"delta":{"content":"前缀"}}]}"#)
        try parser.consume(line: "")
        try parser.consume(line: #"data: {"choices":[{"delta":{"content":{}}}]}"#)
        XCTAssertThrowsError(try parser.consume(line: ""))
    }

}
