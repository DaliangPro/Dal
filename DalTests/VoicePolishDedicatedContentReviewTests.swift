import XCTest
@testable import Dal

final class VoicePolishDedicatedContentReviewTests: XCTestCase {
    func testRiskySourceStillUsesOnlyOneFullTextRequest() async throws {
        let source = "先别发送，等我确认。材料已经备齐。"
        let structured = "先别发送，等我确认。\n\n材料已经备齐。"
        let (result, calls) = await run(source, [structured])
        assertSuccess(result, calls: calls, text: structured, attempts: 1, repairs: 0)
        guard calls.count == 1 else { return }
        XCTAssertEqual(calls.map(\.task), [.voicePolishStructured])
        XCTAssertEqual(calls[0].system, VoicePolishEditingPrompts.standard)
        XCTAssertEqual(try payload(calls[0]) as? [String: String], ["canonical_text": source])
    }

    func testDistantOwnerCorrectionAndReasonArePassedToStructureTogether() async throws {
        let source = "阿文负责复查。共享材料使用带日期的文件。访问范围保持为项目成员，外部链接暂时不开放。设备报错先记录原话，尚未确认的原因不要自行补充。检查名单时先标记重复记录，再等我确认。阿文要出差，复查改由阿宁。"
        let structured = "阿宁负责复查。阿文要出差。\n\n共享材料使用带日期的文件。访问范围保持为项目成员，外部链接暂时不开放。设备报错先记录原话，尚未确认的原因不要自行补充。检查名单时先标记重复记录，再等我确认。"
        let (result, calls) = await run(source, [structured])
        assertSuccess(result, calls: calls, text: structured, attempts: 1, repairs: 0)
        guard calls.count == 1 else { return }
        XCTAssertEqual(try payload(calls[0]) as? [String: String], ["canonical_text": source])
    }

    func testSourcePrefixUsesStandardPrompt() async throws {
        let source = "帮我整理一下：资料已备齐。"
        let prepared = "资料已备齐。"
        let (result, calls) = await run(source, [prepared])
        assertSuccess(result, calls: calls, text: prepared, attempts: 1, repairs: 0)
        guard calls.count == 1 else { return }
        XCTAssertEqual(try payload(calls[0]) as? [String: String], ["canonical_text": source])
    }

    func testStructureReceivesOriginalSentenceBoundaries() async throws {
        let source = "帮我整理一下：先检查，再发送。"
        let structured = "1. 先检查。\n\n2. 再发送。"
        let (result, calls) = await run(source, [structured])
        assertSuccess(result, calls: calls, text: structured, attempts: 1, repairs: 0)
        guard calls.count == 1 else { return }
        XCTAssertEqual(try payload(calls[0]) as? [String: String], ["canonical_text": source])
    }

    func testSingleRequestNeverConsumesAdditionalReviewOrRepairResponses() async {
        let source = "先别发送，等我确认。"
        let (result, calls) = await run(source, [source, source, "不应读取的复核", "不应读取的修复"])
        assertSuccess(result, calls: calls, text: source, attempts: 1, repairs: 0)
        XCTAssertEqual(calls.map(\.task), [.voicePolishStructured])
    }

    func testPublicCorrectionExplanationIsPassedThroughSingleRequest() async {
        let source = "公开更正：原通知时间说错了，请以本通知为准。"
        let (result, calls) = await run(source, [source])
        assertSuccess(result, calls: calls, text: source, attempts: 1, repairs: 0)
    }

    func testDownstreamProhibitionIsPassedThroughWithoutEditorDeletionProtocol() async {
        let source = "请转告同事：先别按旧安排发送，等我确认后再发。"
        let (result, calls) = await run(source, [source])
        assertSuccess(result, calls: calls, text: source, attempts: 1, repairs: 0)
    }

    func testOrdinaryShortSentenceKeepsSingleCallStandardRoute() async throws {
        let source = "材料已经备齐。"
        let (result, calls) = await run(source, [source])
        assertSuccess(result, calls: calls, text: source, attempts: 1, repairs: 0)
        guard calls.count == 1 else { return }
        XCTAssertEqual(try payload(calls[0]) as? [String: String], ["canonical_text": source])
        XCTAssertEqual(calls[0].system, VoicePolishEditingPrompts.standard)
    }

    func testOrdinaryWordCorrectionDoesNotAddDedicatedCall() async throws {
        let source = "请按装软件。"
        let prepared = "请安装软件。"
        let (result, calls) = await run(source, [prepared])
        assertSuccess(result, calls: calls, text: prepared, attempts: 1, repairs: 0)
        guard calls.count == 1 else { return }
        XCTAssertEqual(try payload(calls[0]) as? [String: String], ["canonical_text": source])
    }

    func testUnsafeResponseStopsWithoutRetryAndKeepsOriginalSource() async {
        let source = "帮我整理一下：资料还没核对。"
        let (result, calls) = await run(source, ["资料\u{0000}还没核对。", "不应调用结构整理"])
        assertFallback(result, calls: calls, source: source, attempts: 1, repairs: 0, code: .unsafeCharacters)
    }

    func testLightPreservesProhibitionWithoutRoleReviewOrLayout() async throws {
        let source = "先别发送，等我确认。"
        let (result, calls) = await run(source, [source], mode: .light)
        assertSuccess(result, calls: calls, text: source, attempts: 1, repairs: 0)
        XCTAssertEqual(calls.map(\.task), [.voicePolishStructured])
        for call in calls { XCTAssertNil(try payload(call)["layout_segments"]) }
    }

    private func run(_ source: String, _ responses: [String],
                     mode: VoicePolishQualityMode = .standard) async -> (VoicePolishResult, [LLMRequest]) {
        let client = DedicatedContentReviewClient(responses)
        let input = VoiceInputEnvelope(providerFinalText: source,
            segments: [RecognitionSegment(id: "s1", text: source, startTimeMs: nil, endTimeMs: nil,
                                           confidence: nil, isFinal: true)], durationMs: 1_000, provider: .volcano)
        let request = VoicePolishRequest(input: input, context: WritingContext(scene: .workChat),
            preferences: UserPolishPreferences(additionalRequirements: ""), qualityMode: mode)
        let config = LLMConfig(apiKey: "test-only", model: "configured-model", baseURL: "https://example.invalid")
        let result = await VoicePolishEditingPipeline(client: client, config: config).process(request)
        return (result, await client.requests)
    }

    private func payload(_ request: LLMRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.user.utf8)) as? [String: Any])
    }

    private func assertSuccess(_ result: VoicePolishResult, calls: [LLMRequest], text: String,
                               attempts: Int, repairs: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.usedFallback, file: file, line: line)
        XCTAssertNil(result.failureReason, file: file, line: line)
        XCTAssertTrue(result.validationCodes.isEmpty, "\(result.validationCodes)", file: file, line: line)
        XCTAssertEqual(result.text, text, file: file, line: line)
        XCTAssertEqual(result.llmAttemptCount, attempts, file: file, line: line)
        XCTAssertEqual(calls.count, attempts, file: file, line: line)
        XCTAssertEqual(result.repairAttemptCount, repairs, file: file, line: line)
    }

    private func assertFallback(_ result: VoicePolishResult, calls: [LLMRequest], source: String,
                                attempts: Int, repairs: Int, code: VoicePolishValidationCode,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(result.usedFallback, file: file, line: line)
        XCTAssertEqual(result.failureReason, .validationFailed, file: file, line: line)
        XCTAssertEqual(result.text, source, file: file, line: line)
        XCTAssertEqual(result.llmAttemptCount, attempts, file: file, line: line)
        XCTAssertEqual(calls.count, attempts, file: file, line: line)
        XCTAssertEqual(result.repairAttemptCount, repairs, file: file, line: line)
        XCTAssertTrue(result.validationCodes.contains(code), "\(result.validationCodes)", file: file, line: line)
    }
}

/// 固定脚本只按次序返回字面响应，不根据请求生成补丁、布局或通过答案。
private actor DedicatedContentReviewClient: LLMClient {
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
