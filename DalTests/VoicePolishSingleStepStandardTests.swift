import Foundation
import XCTest
import os
@testable import Dal

final class VoicePolishSingleStepStandardTests: XCTestCase {
    private let config = LLMConfig(apiKey: "test", model: "mock", baseURL: "https://example.com/v1")

    func testStandardReadsCanonicalSourceOnceAndPreservesExactOutput() async throws {
        let source = "请用 Cloud Code 复查，小李负责。小李请假了，改成小王负责。"
        let output = " \r\n请用 Claude Code 复查。\n小王负责，小李请假了。Cafe\u{301} 👩🏽‍💻\t "
        let input = request(source, correctsCloudCode: true)
        let client = SingleStepStandardClient([.text(output), .text("不应复核")])
        let stages = OSAllocatedUnfairLock(initialState: [VoicePolishStage]())
        let subject = VoicePolishEditingPipeline(client: client, config: config) { stage in
            stages.withLock { $0.append(stage) }
        }
        let result = await subject.process(input)
        let calls = await client.requests
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.task, .voicePolishStructured)
        XCTAssertEqual(try payload(call), ["canonical_text": input.fallbackText])
        XCTAssertEqual(call.system, VoicePolishEditingPrompts.standard)
        XCTAssertEqual(call.context, .structuredTask)
        XCTAssertEqual(call.options, LLMGenerationOptions(
            temperature: 0, maxOutputTokens: 2_048, reasoningPolicy: .disabled, responseFormat: .text
        ))
        XCTAssertEqual(stages.withLock { $0 }, [.rendering])
        XCTAssertTrue(result.text.utf8.elementsEqual(output.utf8))
        XCTAssertFalse(result.usedFallback)
        XCTAssertNil(result.failureReason)
        XCTAssertNil(result.rejectedDraft)
        XCTAssertTrue(result.validationCodes.isEmpty)
        XCTAssertEqual(result.detectedRoute, .structured)
        XCTAssertEqual(result.executedRoute, .structured)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
    }

    func testNumberedOutputKeepsRealNewlinesThroughFinalInsertion() async throws {
        let source = "今天要做三件事。第一写稿，第二剪头发，第三准备视频内容。"
        let output = "今天要做三件事：\n\n1. 写稿；\n2. 剪头发；\n3. 准备视频内容。"
        let client = SingleStepStandardClient([.text(output)])
        let result = await pipeline(client).process(request(source))
        let inserted = RecognitionSession.finalizeInsertionText(
            result.text, mode: .formalWriting, isLLMOutput: true
        )
        XCTAssertTrue(inserted.utf8.elementsEqual(output.utf8))
        let calls = await client.requests
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(result.usedFallback)
    }

    func testExplicitRequirementsReachEachModeWithoutAnIntermediateDraft() async throws {
        let source = "本周先整理客户反馈，再发测试报告。"
        let requirements = "请用简短段落。\n  保留英文术语 Cafe\u{301}。"
        let input = request(source, additionalRequirements: requirements)
        let client = SingleStepStandardClient([.text(source)])
        let lightClient = SingleStepStandardClient([.text(source)])
        _ = await pipeline(lightClient).process(request(source, mode: .light, additionalRequirements: requirements))
        let result = await pipeline(client).process(input)
        let calls = await client.requests
        let lightCalls = await lightClient.requests
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(lightCalls.count, 1)
        XCTAssertEqual(lightCalls.first?.task, .voicePolishStructured)
        XCTAssertEqual(lightCalls.first?.system, VoicePolishEditingPrompts.standard)
        XCTAssertEqual(try payload(XCTUnwrap(lightCalls.first)), [
            "canonical_text": source, "additional_requirements": input.preferences.additionalRequirements
        ])
        let body = try payload(XCTUnwrap(calls.first))
        XCTAssertEqual(Set(body.keys), Set(["canonical_text", "additional_requirements"]))
        XCTAssertEqual(body["canonical_text"], source)
        let actual = try XCTUnwrap(body["additional_requirements"])
        XCTAssertTrue(actual.utf8.elementsEqual(input.preferences.additionalRequirements.utf8))
        XCTAssertEqual(calls.first?.system, VoicePolishEditingPrompts.standard)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
    }

    func testFullTextPayloadOmitsWhitespaceOnlyRequirementsAndPreservesNonemptyValue() throws {
        let empty = try JSONSerialization.jsonObject(with: Data(VoicePolishEditingPrompts.fullTextPayload(
            "正文", additionalRequirements: " \t\r\n"
        ).utf8)) as? [String: String]
        XCTAssertEqual(empty, ["canonical_text": "正文"])
        let original = " \r\n请保留英文 Cafe\u{301}。\n  用自然段。\t "
        let nonempty = try JSONSerialization.jsonObject(with: Data(VoicePolishEditingPrompts.fullTextPayload(
            "正文", additionalRequirements: original
        ).utf8)) as? [String: String]
        let actual = try XCTUnwrap(nonempty?["additional_requirements"])
        XCTAssertTrue(actual.utf8.elementsEqual(original.utf8))
    }

    func testInvalidResponsePreservesCanonicalWithoutRetry() async {
        let input = request("请用 Cloud Code 复查。", correctsCloudCode: true)
        for (response, code) in invalidResponses {
            let client = SingleStepStandardClient([.text(response), .text("不应进入第二步")])
            let result = await pipeline(client).process(input)
            assertFallback(result, source: input.fallbackText, attempts: 1, reason: .validationFailed)
            XCTAssertEqual(result.validationCodes, [code])
            XCTAssertEqual(result.rejectedDraft, response)
            let calls = await client.requests
            XCTAssertEqual(calls.map(\.task), [.voicePolishStructured])
        }
    }

    func testClientFailureNeverStartsAnotherRequest() async {
        let input = request("请用 Cloud Code 复查，先别发送。", correctsCloudCode: true)
        for error in clientFailures {
            let client = SingleStepStandardClient([.failure(error), .text("不应重试")])
            let result = await pipeline(client).process(input)
            assertFallback(result, source: input.fallbackText, attempts: 1, reason: expectedReason(error))
            XCTAssertNil(result.rejectedDraft)
            let calls = await client.requests
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testRequestHonorsStageTimeout() async {
        let source = "有两件事。先校对，再整理。"
        let client = SingleStepStandardClient([.delay(.seconds(1), "迟到的稿")])
        let subject = VoicePolishEditingPipeline(
            client: client, config: config, totalTimeout: .seconds(2), stageTimeout: .milliseconds(30)
        )
        let result = await subject.process(request(source))
        assertFallback(result, source: source, attempts: 1, reason: .timeout)
        let calls = await client.requests
        XCTAssertEqual(calls.count, 1)
    }

    func testRequestHonorsTotalDeadline() async {
        let source = "先校对，再整理。"
        let client = SingleStepStandardClient([.delay(.seconds(1), "迟到的稿")])
        let subject = VoicePolishEditingPipeline(
            client: client, config: config, totalTimeout: .milliseconds(80), stageTimeout: .seconds(2)
        )
        let result = await subject.process(request(source))
        assertFallback(result, source: source, attempts: 1, reason: .timeout)
        let calls = await client.requests
        XCTAssertEqual(calls.count, 1)
    }

    func testExpiredBudgetDoesNotCountAnUnstartedClientCall() async {
        let source = "保留原文。"
        let client = SingleStepStandardClient([.text("不应请求")])
        let subject = VoicePolishEditingPipeline(client: client, config: config, totalTimeout: .zero)
        let result = await subject.process(request(source))
        assertFallback(result, source: source, attempts: 0, reason: .timeout)
        let calls = await client.requests
        XCTAssertTrue(calls.isEmpty)
    }

    func testCancellationDoesNotStartAnotherRequest() async {
        let source = "先确认，再发送。"
        let client = SingleStepStandardClient([.delay(.seconds(5), "迟到的稿"), .text("不应整理")])
        let subject = pipeline(client)
        let input = request(source)
        let task = Task { await subject.process(input) }
        await client.waitUntilRequestCount(1)
        task.cancel()
        let result = await task.value
        assertFallback(result, source: source, attempts: 1, reason: .requestFailed)
        let calls = await client.requests
        XCTAssertEqual(calls.count, 1)
    }

    private var invalidResponses: [(String, VoicePolishValidationCode)] {
        [(" \r\n\t", .emptyOutput), ("正文\u{0001}", .unsafeCharacters),
         (String(repeating: "x", count: VoicePolishOutputNormalizer.maximumResponseBytes + 1), .abnormalLength)]
    }

    private var clientFailures: [LLMError] {
        [.requestFailed(503), .requestRejected(429, "测试限流"), .emptyResponse(nil), .timedOut,
         .truncatedResponse(10), .responseTooLarge(10)]
    }

    private func expectedReason(_ error: LLMError) -> VoicePolishFailureReason {
        switch error {
        case .timedOut: return .timeout
        case .truncatedResponse, .responseTooLarge: return .validationFailed
        default: return .requestFailed
        }
    }

    private func assertFallback(
        _ result: VoicePolishResult, source: String, attempts: Int, reason: VoicePolishFailureReason,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(result.usedFallback, file: file, line: line)
        XCTAssertTrue(result.text.utf8.elementsEqual(source.utf8), file: file, line: line)
        XCTAssertEqual(result.llmAttemptCount, attempts, file: file, line: line)
        XCTAssertEqual(result.repairAttemptCount, 0, file: file, line: line)
        XCTAssertEqual(result.failureReason, reason, file: file, line: line)
    }

    private func payload(_ request: LLMRequest) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.user.utf8)) as? [String: String])
    }

    private func pipeline(_ client: SingleStepStandardClient) -> VoicePolishEditingPipeline {
        VoicePolishEditingPipeline(client: client, config: config)
    }

    private func request(
        _ source: String, mode: VoicePolishQualityMode = .standard, correctsCloudCode: Bool = false,
        additionalRequirements: String = ""
    ) -> VoicePolishRequest {
        VoicePolishRequest(
            input: VoiceInputEnvelope(providerFinalText: source, segments: [
                RecognitionSegment(id: "s1", text: source, startTimeMs: nil, endTimeMs: nil,
                                   confidence: nil, isFinal: true)
            ], durationMs: 1_000, provider: .volcano),
            context: WritingContext(scene: .workChat),
            preferences: UserPolishPreferences(additionalRequirements: additionalRequirements),
            qualityMode: mode,
            resolvedEntities: correctsCloudCode ? [ResolvedEntity(
                surfaceText: "Cloud Code", canonical: "Claude Code", sourceSegmentIDs: ["s1"],
                candidateSource: .snippet, confidence: 1
            )] : []
        )
    }
}

private actor SingleStepStandardClient: LLMClient {
    enum Step: Sendable { case text(String), failure(LLMError), delay(Duration, String) }
    private var steps: [Step]
    private(set) var requests: [LLMRequest] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(_ steps: [Step]) { self.steps = steps }

    func waitUntilRequestCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        requests.append(request)
        let ready = waiters.filter { $0.count <= requests.count }
        waiters.removeAll { $0.count <= requests.count }
        ready.forEach { $0.continuation.resume() }
        guard !steps.isEmpty else { throw LLMError.emptyResponse(nil) }
        switch steps.removeFirst() {
        case .text(let text): return LLMResponse(text: text, model: config.model)
        case .failure(let error): throw error
        case .delay(let duration, let text):
            try await Task.sleep(for: duration)
            return LLMResponse(text: text, model: config.model)
        }
    }

    func process(text: String, prompt: String, context: LLMRequestContext, config: LLMConfig) async throws -> String {
        throw LLMError.emptyResponse(nil)
    }

    func warmUp(baseURL: String) async {}
}
