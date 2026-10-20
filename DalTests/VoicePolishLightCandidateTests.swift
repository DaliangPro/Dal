import XCTest
@testable import Dal

/// 固定响应验证单次轻度调用和原样交付，不替代真实模型的语义质量验收。
/// 仍保留独立 TextEditor 与历史响应 decoder 的边界回归，轻度管线不再调用这些协议。
final class VoicePolishLightCandidateTests: XCTestCase {
    func testThousandCharacterBoundedUnchangedAndPunctuationOutputsStayOneCall() async {
        let source = String(repeating: "先核对原始资料再记录原因和限制", count: 50)
        let punctuated = String(repeating: "先核对原始资料，再记录原因和限制。", count: 50)
        XCTAssertLessThanOrEqual(max(source.count, punctuated.count), 1_000)
        for target in [source, punctuated] {
            let (result, calls) = await run(source, [target])
            XCTAssertFalse(result.usedFallback)
            XCTAssertTrue(result.text.utf8.elementsEqual(target.utf8))
            XCTAssertEqual(result.llmAttemptCount, 1)
            XCTAssertEqual(result.repairAttemptCount, 0)
            XCTAssertEqual(calls.map(\.task), [.voicePolishStructured])
            XCTAssertEqual(calls.first?.options.maxOutputTokens, 2048)
        }
    }

    func testBoundedLongWordCorrectionAndFillerDeletionDoNotRequireReview() async {
        let prefix = String(repeating: "先核对原始资料，再记录原因和限制。", count: 45)
        let source = prefix + "嗯，请按装软件。"
        let target = prefix + "请安装软件。"
        XCTAssertLessThanOrEqual(source.count, 1_000)
        let (result, calls) = await run(source, [target])
        XCTAssertFalse(result.usedFallback)
        XCTAssertTrue(result.text.utf8.elementsEqual(target.utf8))
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
        XCTAssertEqual(calls.count, 1)
    }

    func testStutterWordAndSelfCorrectionOutputsAreNotLocallyRejected() async {
        for (source, target) in [
            ("我我明天到", "我明天到。"),
            ("请先核对发票的抬投和税号。", "请先核对发票的抬头和税号。"),
            ("这份方案的优缺点需要再权横一下。", "这份方案的优缺点需要再权衡一下。"),
            ("人数三十，不对，二十四。预算八百，不对，六百。", "人数二十四，预算六百。"),
            ("很重要，很重要，先别承诺日期。", "很重要，先别承诺日期。")
        ] {
            let (result, calls) = await run(source, [target])
            XCTAssertFalse(result.usedFallback, source)
            XCTAssertEqual(result.text, target)
            XCTAssertTrue(result.validationCodes.isEmpty)
            XCTAssertEqual(result.llmAttemptCount, 1)
            XCTAssertEqual(result.repairAttemptCount, 0)
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testExistingRiskPhrasesDoNotTriggerAnotherCallForUnchangedText() async {
        for source in ["不对，日期还待确认。", "请同事不要改由阿宁。", "我补一句，先保留原因。"] {
            let (result, calls) = await run(source, [source, "不应读取第二条响应"])
            XCTAssertFalse(result.usedFallback, source)
            XCTAssertEqual(result.text, source)
            XCTAssertEqual(result.llmAttemptCount, 1)
            XCTAssertEqual(result.repairAttemptCount, 0)
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testOutputPreservesLeadingTrailingSpacesLineEndingsAndUnicodeBytes() async {
        let source = "👍🏽先看资料。가再确认。"
        let target = "  👍🏽先看资料。\r\n\r\n\t\u{1100}\u{1161}再确认。  \n"
        let (result, calls) = await run(source, [target])
        XCTAssertFalse(result.usedFallback)
        XCTAssertTrue(result.text.utf8.elementsEqual(target.utf8))
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(calls.count, 1)
    }

    func testCanonicalEquivalentUnicodeIsDeliveredWithoutNormalization() async {
        let source = "가先保留。"
        let target = "\u{1100}\u{1161}先保留。"
        XCTAssertEqual(source, target)
        XCTAssertFalse(source.utf8.elementsEqual(target.utf8))
        let (result, calls) = await run(source, [target])
        XCTAssertFalse(result.usedFallback)
        XCTAssertTrue(result.text.utf8.elementsEqual(target.utf8))
        XCTAssertEqual(result.repairAttemptCount, 0)
        XCTAssertEqual(calls.count, 1)
    }

    func testLiteralPrefixMarkupAndRepeatedParagraphsAreNotCleanedAfterGeneration() async {
        let paragraph = "这一段是需要保留的完整正文，说明先核对资料，再确认时间，同时保留具体原因和相关限制，不要提前发布。"
        for target in ["润色后：这是用户实际需要的标题。", "```text\n请保留这段示例。\n```",
                       paragraph + "\n\n" + paragraph] {
            let (result, calls) = await run("请保留正文格式。", [target])
            XCTAssertFalse(result.usedFallback)
            XCTAssertTrue(result.text.utf8.elementsEqual(target.utf8))
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testEmptyOrWhitespaceResponseFallsBackWithoutRetry() async {
        let source = "完整原文必须保留。还有第二项任务。"
        for target in ["", " ", "\r\n\t  ", "\u{0085}", "\u{200B}"] {
            let (result, calls) = await run(source, [target, "不应读取第二条响应"])
            assertFailure(result, source: source, calls: calls, count: 1, repairs: 0, code: .emptyOutput)
            XCTAssertEqual(result.validationCodes, [.emptyOutput])
            XCTAssertEqual(result.failureReason, .validationFailed)
            XCTAssertEqual(result.rejectedDraft, target)
        }
    }

    func testUnsafeResponseFallsBackWithoutDeliveringPartialText() async {
        let source = "完整原文必须保留。还有第二项任务。"
        for target in ["第一项。\u{0000}第二项。", "第一项。\u{001B}[31m第二项。", "正文\u{FFFF}", "\u{001C}"] {
            let (result, calls) = await run(source, [target, "不应重试"])
            assertFailure(result, source: source, calls: calls, count: 1, repairs: 0, code: .unsafeCharacters)
            XCTAssertEqual(result.validationCodes, [.unsafeCharacters])
            XCTAssertEqual(result.rejectedDraft, target)
        }
    }

    private func assertFailure(_ result: VoicePolishResult, source: String, calls: [LLMRequest], count: Int,
                               repairs: Int, code: VoicePolishValidationCode,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(result.usedFallback, file: file, line: line)
        XCTAssertTrue(result.text.utf8.elementsEqual(source.utf8), file: file, line: line)
        XCTAssertEqual(result.llmAttemptCount, count, file: file, line: line)
        XCTAssertEqual(calls.count, count, file: file, line: line)
        XCTAssertEqual(result.repairAttemptCount, repairs, file: file, line: line)
        XCTAssertTrue(result.validationCodes.contains(code), "\(result.validationCodes)", file: file, line: line)
    }

    private func candidate(_ text: String) -> String { json(["text": text]) }
    private func json(_ value: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    private func run(_ source: String, _ responses: [String]) async -> (VoicePolishResult, [LLMRequest]) {
        let client = LightCandidateClient(responses)
        let request = VoicePolishRequest(input: VoiceInputEnvelope(providerFinalText: source,
            segments: [.init(id: "s1", text: source, startTimeMs: nil, endTimeMs: nil, confidence: nil, isFinal: true)],
            durationMs: 1_000, provider: .volcano), context: WritingContext(scene: .workChat),
            preferences: UserPolishPreferences(additionalRequirements: ""), qualityMode: .light)
        let config = LLMConfig(apiKey: "test-only", model: "configured-model", baseURL: "https://example.invalid")
        let result = await VoicePolishEditingPipeline(client: client, config: config).process(request)
        return (result, await client.requests)
    }
}

private actor LightCandidateClient: LLMClient {
    private var responses: [String]
    private(set) var requests: [LLMRequest] = []
    init(_ responses: [String]) { self.responses = responses }
    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw LLMError.emptyResponse(nil) }
        return LLMResponse(text: responses.removeFirst(), model: config.model)
    }
    func process(text: String, prompt: String, context: LLMRequestContext, config: LLMConfig) async throws -> String {
        throw LLMError.emptyResponse(nil)
    }
    func warmUp(baseURL: String) async {}
}
