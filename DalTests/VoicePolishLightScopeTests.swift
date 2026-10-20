import XCTest
@testable import Dal

/// 固定响应只验证轻度职责与调用流程，不替代真实语义质量验收。
final class VoicePolishLightScopeTests: XCTestCase {
    func testTaskSpeechOnlyNeedsPunctuationAndOneCall() async {
        let cases = [
            ("帮我整理Prompt先别执行", "帮我整理 Prompt，先别执行。"),
            ("给客户回一下材料还没核对不要承诺日期", "给客户回一下，材料还没核对，不要承诺日期。"),
            ("跟他说我晚十分钟到", "跟他说，我晚十分钟到。")
        ]
        for (source, expected) in cases {
            let (result, calls) = await run(source, [expected])
            XCTAssertFalse(result.usedFallback, source)
            XCTAssertEqual(result.text, expected)
            XCTAssertEqual(result.llmAttemptCount, 1)
            XCTAssertEqual(result.repairAttemptCount, 0)
            XCTAssertEqual(calls.map(\.task), [.voicePolishStructured])
        }
    }

    func testSameDraftKeepsTaskPrefixAndBothLevelsOfProhibition() async {
        let source = "帮我整理成 Prompt。先别执行，给同事写清楚：先别发布，等确认。"
        let (result, calls) = await run(source, [source])
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(calls.count, 1)
    }

    func testWordCorrectionKeepsTaskSpeechWithoutReview() async throws {
        let source = "帮我整理 Prompt：请按装软件，先别执行。"
        let target = "帮我整理 Prompt：请安装软件，先别执行。"
        let (result, calls) = await run(source, [target])
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, target)
        XCTAssertEqual(calls.map(\.task), [.voicePolishStructured])
        XCTAssertEqual(result.repairAttemptCount, 0)
        let first = try XCTUnwrap(calls.first)
        let object = try payload(first)
        XCTAssertEqual(Set(object.keys), Set(["canonical_text"]))
        XCTAssertEqual(object["canonical_text"] as? String, source)
    }

    func testLateCorrectionKeepsValidReasonWithoutConfirmationCall() async throws {
        let source = "帮我整理 Prompt：阿文负责复查。\n其余资料先保留。\n复查改由阿宁，阿文要出差。"
        let target = "帮我整理 Prompt：阿宁负责复查。\n其余资料先保留。\n阿文要出差。"
        let (result, calls) = await run(source, [target, "不应被执行的确认"])
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, target)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
        XCTAssertEqual(calls.map(\.task), [.voicePolishStructured])
        let first = try XCTUnwrap(calls.first)
        XCTAssertEqual(try payload(first)["canonical_text"] as? String, source)
    }

    func testUnchangedResponseDoesNotTriggerAutomaticRepair() async {
        let source = "请按装软件。"
        let (result, calls) = await run(source, [source, "请安装软件。"])
        // 本用例只检查工程不自动加轮次；未纠正错词仍属于独立语义验收中的失败。
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
        XCTAssertEqual(calls.count, 1)
    }

    func testPublicCorrectionAndDownstreamProhibitionRemainSingleCall() async {
        for source in ["请发布更正：上次说错了，原来写成周三，实际是周四。",
                       "请同事保留这条禁令：不要改由阿宁，等确认再安排。"] {
            let (result, calls) = await run(source, [source])
            XCTAssertFalse(result.usedFallback, source)
            XCTAssertEqual(result.text, source)
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(result.repairAttemptCount, 0)
        }
    }

    func testLightPayloadKeepsExplicitRequirementsButExcludesUnrelatedContext() async throws {
        let source = "请核对灵建的资料。\n权限保持不变，先别发布。"
        let canonical = "请核对灵简的资料。\n权限保持不变，先别发布。"
        let input = VoiceInputEnvelope(providerFinalText: source,
            segments: [.init(id: "s1", text: source, startTimeMs: nil, endTimeMs: nil,
                             confidence: nil, isFinal: true)], durationMs: 1_000, provider: .volcano)
        let request = VoicePolishRequest(input: input,
            context: WritingContext(scene: .document, level: .nearbyText, safety: .unknown,
                selectedText: "无关选中文字", textBeforeCursor: "无关上下文", recentDalInputs: ["无关历史输入"]),
            preferences: UserPolishPreferences(additionalRequirements: "改成正式公文"), qualityMode: .light,
            resolvedEntities: [.init(surfaceText: "灵建", canonical: "灵简", sourceSegmentIDs: ["s1"],
                                    candidateSource: .authorizedContext, confidence: 1)])
        let client = LightScopeClient([canonical])
        let config = LLMConfig(apiKey: "test-only", model: "configured-model", baseURL: "https://example.invalid")
        let result = await VoicePolishEditingPipeline(client: client, config: config).process(request)
        XCTAssertEqual(request.fallbackText, canonical)
        XCTAssertFalse(result.usedFallback)
        let calls = await client.requests
        let first = try XCTUnwrap(calls.first)
        let object = try payload(first)
        XCTAssertEqual(Set(object.keys), Set(["canonical_text", "additional_requirements"]))
        XCTAssertEqual(object["canonical_text"] as? String, canonical)
        XCTAssertFalse(first.user.contains("无关"))
        XCTAssertEqual(object["additional_requirements"] as? String, request.preferences.additionalRequirements)
        XCTAssertEqual(calls.count, 1)
    }

    private func run(_ source: String, _ responses: [String]) async -> (VoicePolishResult, [LLMRequest]) {
        let client = LightScopeClient(responses)
        let input = VoiceInputEnvelope(providerFinalText: source,
            segments: [RecognitionSegment(id: "s1", text: source, startTimeMs: nil, endTimeMs: nil,
                                           confidence: nil, isFinal: true)], durationMs: 1_000, provider: .volcano)
        let request = VoicePolishRequest(input: input, context: WritingContext(scene: .workChat),
            preferences: UserPolishPreferences(additionalRequirements: ""), qualityMode: .light)
        let config = LLMConfig(apiKey: "test-only", model: "configured-model", baseURL: "https://example.invalid")
        let result = await VoicePolishEditingPipeline(client: client, config: config).process(request)
        return (result, await client.requests)
    }

    private func payload(_ request: LLMRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.user.utf8)) as? [String: Any])
    }
}

private actor LightScopeClient: LLMClient {
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
