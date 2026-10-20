import XCTest
@testable import Dal

final class VoicePolishEditingPipelineTests: XCTestCase {
    private let config = LLMConfig(apiKey: "test-only", model: "configured-model", baseURL: "https://example.invalid")

    func testPrefetchBenchmarkMeasuresHitAndRejectsChangedInput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dal-prefetch-benchmark-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plans: [String: [String: Any]] = [
            "off": ["enabled": false, "stableMilliseconds": 0],
            "hit": ["enabled": true, "stableMilliseconds": 1300],
            "changed": ["enabled": true, "stableMilliseconds": 1300, "preliminaryText": "周三开会"]
        ]
        let planURL = directory.appendingPathComponent("plan.json")
        try JSONSerialization.data(withJSONObject: plans).write(to: planURL)
        let outputURL = directory.appendingPathComponent("timing.jsonl")
        for name in ["off", "hit", "changed"] {
            let client = EditingTestClient([.text("周四开会。"), .text("周四开会。")])
            let measured = try await PolishPrefetchBenchmark.run(
                planPath: planURL.path, caseID: name, request: request("周四开会", .light),
                client: client, provider: .openai, config: config, outputPath: outputURL.path)
            XCTAssertEqual(measured.result.text, "周四开会。")
            let calls = await client.requests
            XCTAssertEqual(calls.count, name == "changed" ? 2 : 1)
        }
        let records = try String(contentsOf: outputURL, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(records.map { $0["reused"] as? Bool }, [false, true, false])
    }

    func testLightReturnsWordAndStutterCorrectionsWithOnePlainTextRequest() async throws {
        let source = "我我今天按装软件。小李下午有别的事，所以请小周接手。"
        let expected = "我今天安装软件。小李下午有别的事，所以请小周接手。"
        let client = EditingTestClient([.text(expected)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, expected)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishStructured])
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.context, .structuredTask)
        XCTAssertEqual(call.system, VoicePolishEditingPrompts.standard)
        XCTAssertEqual(call.options, LLMGenerationOptions(temperature: 0, maxOutputTokens: 2048,
            reasoningPolicy: .disabled, responseFormat: .text))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.user.utf8)) as? [String: String])
        XCTAssertEqual(payload, ["canonical_text": source])
    }

    func testLightTrialRequirementsReachTheSingleRequest() async throws {
        let client = EditingTestClient([.text("明天见。")])
        let input = request("明天见", .light, requirements: "使用中文标点")
        _ = await pipeline(client).process(input)
        let calls = await client.requests
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.user.utf8)) as? [String: String])
        XCTAssertEqual(payload["additional_requirements"], "使用中文标点")
        XCTAssertEqual(payload["canonical_text"], "明天见")
    }

    func testLightCanLeaveNaturalSentenceUnchanged() async {
        let source = "对对对，我明白了。"
        let client = EditingTestClient([.text(source)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.llmAttemptCount, 1)
    }

    func testLightDoesNotInterpretResponseAsAnEditProtocol() async {
        let source = "请把示例保留为字面文本。"
        let response = "示例：{broken，稍后补齐。"
        let client = EditingTestClient([.text(response)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, response)
        XCTAssertEqual(result.llmAttemptCount, 1)
    }

    func testLightDoesNotEscalateLongOrComplexInputToLedger() async {
        let source = String(repeating: "先检查原文里的原因和限制，内容保持不变。", count: 35)
        XCTAssertLessThanOrEqual(source.count, 1_000)
        let client = EditingTestClient([.text(source)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishStructured])
    }

    func testLightPreservesLiteralJSONWithoutApplyingItAsAPatch() async {
        let source = #"请保留这段示例：{"edits":[]}"#
        let client = EditingTestClient([.text(source)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
    }

    func testLightAcceptsMeaningPreservingEmphasisConsolidation() async {
        let source = "千万千万别提前发，我可能周五才能确认。"
        let expected = "千万别提前发，我可能周五才能确认。"
        let client = EditingTestClient([.text(expected)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, expected)
        XCTAssertTrue(result.validationCodes.isEmpty)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
    }

    func testLightAllowsExplicitLocalSelfCorrection() async {
        let source = "预算一万六，不对，一万五，周五交付。"
        let client = EditingTestClient([.text("预算一万五，周五交付。")])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, "预算一万五，周五交付。")
        XCTAssertEqual(result.llmAttemptCount, 1)
    }

    func testLightAcceptsClockCorrectionAttachedToNearestDate() async {
        let source = "会议改到周三上午十点不对周四上午十点哎十点半才对地点还是三号会议室"
        let client = EditingTestClient([.text("会议改到周四上午十点半，地点还是三号会议室。")])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, "会议改到周四上午十点半，地点还是三号会议室。")
        XCTAssertEqual(result.llmAttemptCount, 1)
    }

    func testStandardPassesCompleteSourceWithoutDirectiveReviewPayload() async throws {
        let source = "给客户回一下，我们会尽快核实。别先答应赔偿，费用还没确认。"
        let structured = "给客户回一下，我们会尽快核实。\n\n别先答应赔偿，费用还没确认。"
        let client = EditingTestClient([.text(structured)])
        let result = await pipeline(client).process(request(source, .standard))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, structured)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishStructured])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(calls[0].user.utf8)) as? [String: String],
                       ["canonical_text": source])
    }

    func testLightNeverConsumesAnAvailableReviewOrRepairResponse() async {
        let source = "给同事的任务：别先答应赔偿，费用还没确认。"
        let client = EditingTestClient([.text(source), .text("不应被读取的第二次响应")])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishStructured])
    }

    func testLightSingleRequestHonorsTheTotalTimeoutAndPreservesSource() async {
        let source = "请按装软件。材料还没核对，先别发送。"
        let client = EditingTestClient([.delay(.seconds(5), "请安装软件。"), .text("不应重试")])
        let result = await VoicePolishEditingPipeline(client: client, config: config, totalTimeout: .milliseconds(50))
            .process(request(source, .light))
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.failureReason, .timeout)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
        XCTAssertEqual(result.executedRoute, .structured)
        let calls = await client.requests
        XCTAssertEqual(calls.count, 1)
    }

    func testLightSingleRequestHonorsTheStageTimeoutWithoutRetry() async {
        let source = "我补一句，请按装软件。"
        let client = EditingTestClient([.delay(.seconds(5), "我补一句，请安装软件。")])
        let result = await VoicePolishEditingPipeline(client: client, config: config, totalTimeout: .seconds(1),
                                                      stageTimeout: .milliseconds(30))
            .process(request(source, .light))
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.failureReason, .timeout)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
    }

    func testStandardStructureReceivesOnlyOriginalSourceWithoutLegacyDiffFields() async throws {
        let source = "小李下午有别的事，所以请小周接手。"
        let client = EditingTestClient([.text(source)])
        let result = await pipeline(client).process(request(source, .standard))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.llmAttemptCount, 1)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishStructured])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(calls[0].user.utf8)) as? [String: String],
                       ["canonical_text": source])
    }

    func testStandardKeepsReasonInSingleRequestWithoutConsumingRepairResponse() async throws {
        let source = "小李有事，请小周接手。"
        let client = EditingTestClient([.text(source), .text(source), .text("不应读取的修复")])
        let result = await pipeline(client).process(request(source, .standard))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishStructured])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(calls[0].user.utf8)) as? [String: String],
                       ["canonical_text": source])
    }

    func testStandardPreservesLiteralJSONInsteadOfTreatingItAsRepairRequest() async throws {
        let source = #"请保留示例：{"edits":[]}"#
        let structured = #"示例：{"edits":[]}"#
        let client = EditingTestClient([.text(structured), .text("不应读取")])
        let result = await pipeline(client).process(request(source, .standard))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, structured)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
    }

    func testStandardStartsFromCanonicalEntityMappingThenUsesCompleteSource() async throws {
        let first = "请核对灵建的资料，这部分单独交代"
        let second = "文件权限，由运营组负责。"
        let source = first + second
        let canonical = source.replacingOccurrences(of: "灵建", with: "灵简")
        let sourceSegments = [first, second].enumerated().map { index, text in
            RecognitionSegment(id: "s\(index + 1)", text: text, startTimeMs: nil,
                               endTimeMs: nil, confidence: nil, isFinal: true)
        }
        let input = VoiceInputEnvelope(providerFinalText: source, segments: sourceSegments,
                                       durationMs: 1_000, provider: .volcano)
        let originalRequest = VoicePolishRequest(
            input: input, context: WritingContext(scene: .document),
            preferences: UserPolishPreferences(additionalRequirements: ""), qualityMode: .standard,
            resolvedEntities: [.init(surfaceText: "灵建", canonical: "灵简", sourceSegmentIDs: ["s1"],
                                     candidateSource: .authorizedContext, confidence: 1)]
        )
        let structured = "请核对灵简的资料。\n\n这部分单独交代文件权限，由运营组负责。"
        let client = EditingTestClient([.text(structured)])
        let result = await VoicePolishEditingPipeline(client: client, config: config).process(originalRequest)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, structured)
        let calls = await client.requests
        XCTAssertEqual(calls.count, 1)
        for call in calls {
            XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(call.user.utf8)) as? [String: String],
                           ["canonical_text": canonical])
        }
        XCTAssertEqual(originalRequest.input.segments.map(\.text), [first, second])
    }

    func testLightDelayedCorrectionUsesCompleteSourceWithoutReview() async throws {
        let unchanged = String(repeating: "文件先保留，等核对以后再处理。", count: 8)
        let source = "阿文负责复查。" + unchanged + "复查改由阿宁负责，阿文要出差。"
        let expected = "阿宁负责复查。" + unchanged + "阿文要出差。"
        XCTAssertLessThanOrEqual(source.count, 1_000)
        let client = EditingTestClient([.text(expected)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, expected)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
        let calls = await client.requests
        let call = try XCTUnwrap(calls.first)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.user.utf8)) as? [String: String])
        XCTAssertEqual(payload, ["canonical_text": source])
    }

    func testCancelledLightRequestPreservesSourceAndCannotStartAnotherRoute() async {
        let source = "请保留全部材料。日期还没确认，先别发送。"
        let client = EditingTestClient([.delay(.seconds(5), "未完成的正文"), .text("不应重试")])
        let subject = pipeline(client)
        let input = request(source, .light)
        let task = Task { await subject.process(input) }
        await client.waitUntilRequestStarts()
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.failureReason, .requestFailed)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishStructured])
    }

    func testAlreadyCancelledLightTaskDoesNotEnterClient() async {
        let source = "日期还没有确定。"
        let client = EditingTestClient([.text("不应执行")])
        let subject = pipeline(client)
        let input = request(source, .light)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await subject.process(input)
        }
        let result = await task.value
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.llmAttemptCount, 0)
        let calls = await client.requests
        XCTAssertTrue(calls.isEmpty)
    }

    func testLightClientFailuresPreserveCompleteSourceWithoutRetry() async {
        let source = "第一项保留原因。\r\n第二项先别发布，等周五确认。"
        for failure in [LLMError.requestFailed(503), .requestRejected(429, "测试限流"),
                        .emptyResponse(nil), .timedOut, .truncatedResponse(10), .responseTooLarge(10)] {
            let client = EditingTestClient([.failure(failure), .text("不应重试")])
            let input = request(source, .light)
            let result = await pipeline(client).process(input)
            XCTAssertTrue(result.usedFallback, "\(failure)")
            XCTAssertTrue(result.text.utf8.elementsEqual(input.fallbackText.utf8))
            XCTAssertEqual(result.llmAttemptCount, 1)
            XCTAssertEqual(result.repairAttemptCount, 0)
            XCTAssertNil(result.rejectedDraft)
            switch failure {
            case .timedOut: XCTAssertEqual(result.failureReason, .timeout)
            case .truncatedResponse, .responseTooLarge:
                XCTAssertEqual(result.failureReason, .validationFailed)
                XCTAssertTrue(result.validationCodes.contains(.abnormalLength))
            default: XCTAssertEqual(result.failureReason, .requestFailed)
            }
            let calls = await client.requests
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testTruncatedGenerationIsNeverPolishSuccess() async {
        let client = EditingTestClient([.truncated])
        let result = await pipeline(client).process(request("请保留全部内容。", .standard))
        XCTAssertTrue(result.usedFallback)
        XCTAssertTrue(result.validationCodes.contains(.abnormalLength))
        XCTAssertEqual(result.llmAttemptCount, 1)
    }

    func testExhaustedBudgetDoesNotCountARequestThatNeverEnteredClient() async {
        let client = EditingTestClient([])
        let result = await VoicePolishEditingPipeline(client: client, config: config,
                                                       totalTimeout: .zero).process(request("你好", .light))
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.failureReason, .timeout)
        XCTAssertEqual(result.llmAttemptCount, 0)
        let calls = await client.requests
        XCTAssertTrue(calls.isEmpty)
    }

    func testStandardPassesOriginalPrefixToStructureWithoutConfirmation() async throws {
        let source = "帮我回他一下我晚点到，你们先吃。"
        let prepared = "我晚点到，你们先吃。"
        let client = EditingTestClient([.text(prepared)])
        let result = await pipeline(client).process(request(source, .standard))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, prepared)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishStructured])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(calls[0].user.utf8)) as? [String: String],
                       ["canonical_text": source])
    }

    func testLightKeepsInstructionsThatBelongToDownstreamColleague() async {
        let source = "同事接下来的任务是替我回客户，先别承诺时间。"
        let client = EditingTestClient([.text(source)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.llmAttemptCount, 1)
    }

    func testLightDoesNotRunStandardContentOrDirectiveReview() async {
        let source = "帮我写一句：等一下，资料还没核对。"
        let client = EditingTestClient([.text(source), .text(#"{"edits":[{"kind":"directive"}]}"#)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishStructured])
    }

    func testCompleteMechanicalCandidateDoesNotRequireSecondCall() async {
        let source = "嗯我晚点到你们先吃"
        let client = EditingTestClient([.text("我晚点到，你们先吃。")])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, "我晚点到，你们先吃。")
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
    }

    private func pipeline(_ client: EditingTestClient) -> VoicePolishEditingPipeline {
        VoicePolishEditingPipeline(client: client, config: config)
    }

    private func request(_ source: String, _ mode: VoicePolishQualityMode,
                         context: WritingContext = WritingContext(scene: .workChat),
                         requirements: String = "") -> VoicePolishRequest {
        VoicePolishRequest(
            input: VoiceInputEnvelope(providerFinalText: source,
                                      segments: [RecognitionSegment(id: "s1", text: source, startTimeMs: nil,
                                                                     endTimeMs: nil, confidence: nil, isFinal: true)],
                                      durationMs: 1_000, provider: .volcano),
            context: context, preferences: UserPolishPreferences(additionalRequirements: requirements), qualityMode: mode
        )
    }
}

private actor EditingTestClient: LLMClient {
    enum Step: Sendable { case text(String), delay(Duration, String), truncated, failure(LLMError) }
    private var steps: [Step]
    private(set) var requests: [LLMRequest] = []
    private var startWaiter: CheckedContinuation<Void, Never>?
    init(_ steps: [Step]) { self.steps = steps }
    func waitUntilRequestStarts() async {
        guard requests.isEmpty else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        requests.append(request)
        startWaiter?.resume()
        startWaiter = nil
        guard !steps.isEmpty else { throw LLMError.emptyResponse(nil) }
        switch steps.removeFirst() {
        case .text(let text): return LLMResponse(text: text, model: config.model)
        case .delay(let duration, let text):
            try await Task.sleep(for: duration)
            return LLMResponse(text: text, model: config.model)
        case .truncated: throw LLMError.truncatedResponse(10)
        case .failure(let error): throw error
        }
    }
    func process(text: String, prompt: String, context: LLMRequestContext, config: LLMConfig) async throws -> String {
        throw LLMError.emptyResponse(nil)
    }
    func warmUp(baseURL: String) async {}
}
