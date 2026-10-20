import Foundation
import XCTest
@testable import Dal

final class VoicePolishRequestProbeTests: XCTestCase {
    private let flag = VoicePolishRequestProbe.argument
    private let config = LLMConfig(apiKey: "unit-test-credential-never-record", model: "deepseek-flash", baseURL: "https://api.deepseek.com")

    func testExplicitEntryIsHeadlessAndDisablesUserFileLog() throws {
        let args = ["Dal", flag, "--probe-input", "/workspace/input.json", "--probe-output", "/workspace/new-output"]
        XCTAssertEqual(try VoicePolishRequestProbe.parseInvocation(arguments: args),
                       .init(inputPath: "/workspace/input.json", outputPath: "/workspace/new-output"))
        XCTAssertTrue(VoicePolishQualityRunner.isRequested(arguments: args))
        XCTAssertTrue(DebugFileLogger.shouldDisableFileLogging(arguments: args, isRunningTests: false))
        XCTAssertNil(try VoicePolishQualityRunner.parseInvocation(arguments: args))
        XCTAssertNil(try VoicePolishQualityAuthorization.requestedProvider(arguments: args))
        XCTAssertNil(try VoicePolishRequestProbe.parseInvocation(arguments: ["Dal"]))
        XCTAssertFalse(DebugFileLogger.shouldDisableFileLogging(arguments: ["Dal"], isRunningTests: false))
    }

    func testAllHeadlessOperationsAreMutuallyExclusiveBeforeConfiguration() {
        let operations = [flag, "--voice-polish-quality-run", VoicePolishQualityAuthorization.argument]
        for first in operations {
            for second in operations {
                let args = ["Dal", first, second]
                XCTAssertThrowsError(try VoicePolishRequestProbe.validateOperations(arguments: args))
                XCTAssertThrowsError(try VoicePolishRequestProbe.parseInvocation(arguments: args))
            }
        }
        XCTAssertThrowsError(try VoicePolishQualityRunner.parseInvocation(arguments: ["Dal", flag, "--voice-polish-quality-run"]))
        XCTAssertThrowsError(try VoicePolishQualityAuthorization.requestedProvider(arguments: ["Dal", flag, VoicePolishQualityAuthorization.argument, "--provider", "deepseek"]))
    }

    func testFlagsRejectMissingDuplicateUnknownRelativeAndCredentialArguments() {
        let bad: [[String]] = [
            ["Dal", flag],
            ["Dal", flag, "--probe-input", "/in", "--probe-input", "/out"],
            ["Dal", flag, "--probe-input", "relative.json", "--probe-output", "/out"],
            ["Dal", flag, "--probe-input", "/in", "--probe-output", "/out/../other"],
            ["Dal", flag, "--probe-input", "/in", "--probe-output", "--provider"],
            ["Dal", flag, "--probe-input", "/in", "--api-key", "credential"],
            ["Dal", flag, "--probe-input", "/in", "--probe-output", "/out", "--provider", "deepseek"],
            ["Dal", flag, "--probe-input", "/in\u{0}suffix", "--probe-output", "/out"]
        ]
        for args in bad { XCTAssertThrowsError(try VoicePolishRequestProbe.parseInvocation(arguments: args)) }
    }

    func testInputHasExactSchemaAndBindsCanonicalUTF8WithoutNormalizing() throws {
        let source = " e\u{301}👩🏽‍💻\r\n内容。 "
        let input = try VoicePolishRequestProbe.decodeInput(data(source: source))
        XCTAssertTrue(input.canonicalText.utf8.elementsEqual(source.utf8))
        var bad = try object(source: source)
        bad["user"] = #"{"canonical_text":" é👩🏽‍💻\r\n内容。 "}"#
        XCTAssertThrowsError(try VoicePolishRequestProbe.decodeInput(json(bad)))
        bad = try object(); bad["answer"] = "不可输入答案字段"
        XCTAssertThrowsError(try VoicePolishRequestProbe.decodeInput(json(bad)))
        bad = try object(); bad.removeValue(forKey: "system")
        XCTAssertThrowsError(try VoicePolishRequestProbe.decodeInput(json(bad)))
    }

    func testIntegerAndEnumFieldsDoNotAcceptBooleanStringsOrFractions() throws {
        for invalid in [true, "1", 1.5, 0, 2] as [Any] {
            var value = try object(); value["schema_version"] = invalid
            XCTAssertThrowsError(try VoicePolishRequestProbe.decodeInput(json(value)), "\(invalid)")
        }
        for invalid in [true, "4096", 1.5, 0, 8193] as [Any] {
            var value = try object(); value["max_output_tokens"] = invalid
            XCTAssertThrowsError(try VoicePolishRequestProbe.decodeInput(json(value)), "\(invalid)")
        }
        for invalid in ["json", "JSON_OBJECT", "", 1] as [Any] {
            var value = try object(); value["response_format"] = invalid
            XCTAssertThrowsError(try VoicePolishRequestProbe.decodeInput(json(value)))
        }
        for valid in [1, 8192] {
            var value = try object(); value["max_output_tokens"] = valid
            XCTAssertEqual(try VoicePolishRequestProbe.decodeInput(json(value)).maxOutputTokens, valid)
        }
    }

    func testInputCharacterAndByteLimitsAreSeparateAndNeverTruncate() throws {
        let thousand = String(repeating: "👩🏽‍💻", count: 1000)
        XCTAssertEqual(try VoicePolishRequestProbe.decodeInput(data(source: thousand)).canonicalText.count, 1000)
        XCTAssertThrowsError(try VoicePolishRequestProbe.decodeInput(data(source: thousand + "甲")))
        XCTAssertThrowsError(try VoicePolishRequestProbe.decodeInput(data(source: " \r\n ")))
        var value = try object(); value["system"] = String(repeating: "甲", count: 11_000)
        XCTAssertThrowsError(try VoicePolishRequestProbe.decodeInput(json(value)))
        value = try object(); value["system"] = " \n "
        XCTAssertThrowsError(try VoicePolishRequestProbe.decodeInput(json(value)))
        value = try object(); value["user"] = String(repeating: " ", count: 128 * 1024 + 1)
        XCTAssertThrowsError(try VoicePolishRequestProbe.decodeInput(json(value)))
        XCTAssertThrowsError(try VoicePolishRequestProbe.decodeInput(Data(repeating: 32, count: VoicePolishRequestProbe.maximumInputBytes + 1)))
    }

    func testDuplicateJSONKeysAndNestedCredentialsAreRejected() throws {
        let raw = String(decoding: try data(), as: UTF8.self)
        let duplicate = raw.replacingOccurrences(of: "\"case_id\":\"x01\"", with: "\"case_id\":\"x01\",\"case_\\u0069d\":\"x01\"")
        XCTAssertNotEqual(raw, duplicate)
        XCTAssertThrowsError(try VoicePolishRequestProbe.decodeInput(Data(duplicate.utf8)))
        for user in [#"{"canonical_text":"资料已备齐。","canonical_text":"资料已备齐。"}"#,
                     #"{"canonical_text":"资料已备齐。","options":{"headers":{"Authorization":"secret"}}}"#,
                     #"{"canonical_text":"资料已备齐。","api_key":"secret"}"#] {
            var value = try object(); value["user"] = user
            XCTAssertThrowsError(try VoicePolishRequestProbe.decodeInput(json(value)))
        }
    }

    func testSharedDuplicateScannerKeepsOriginalDepthLimit() throws {
        func raw(_ depth: Int) -> Data {
            Data((String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)).utf8)
        }
        var accepted = VoicePolishJSONUniqueKeys(data: raw(64))
        XCTAssertNoThrow(try accepted.check())
        var rejected = VoicePolishJSONUniqueKeys(data: raw(65))
        XCTAssertThrowsError(try rejected.check())
    }

    func testSharedDuplicateScannerPreservesProbeInvalidInputClassification() throws {
        var value = try object()
        value["user"] = #"{"canonical_text":"资料已备齐。","metadata":{"key":1,"k\u0065y":2}}"#
        XCTAssertThrowsError(try VoicePolishRequestProbe.decodeInput(json(value))) {
            XCTAssertEqual($0 as? VoicePolishRequestProbe.ProbeError, .invalidInput)
        }
        let input = try VoicePolishRequestProbe.decodeInput(data())
        XCTAssertEqual(input.canonicalText, "资料已备齐。")
    }

    func testRequestOptionsAreFixedExceptTwoExplicitExperimentFields() throws {
        for format in ["text", "json_object"] {
            var value = try object(); value["response_format"] = format
            let input = try VoicePolishRequestProbe.decodeInput(json(value))
            let request = VoicePolishRequestProbe.makeRequest(input)
            XCTAssertEqual(request.context, .structuredTask)
            XCTAssertEqual(request.task, .voicePolishRender)
            XCTAssertEqual(request.system, input.system)
            XCTAssertEqual(request.user, input.user)
            XCTAssertEqual(request.options.temperature, 0)
            XCTAssertEqual(request.options.reasoningPolicy, .disabled)
            XCTAssertEqual(request.options.maxOutputTokens, 4096)
            XCTAssertEqual(request.options.responseFormat, format == "text" ? .text : .jsonObject)
        }
    }

    func testConfigurationCannotChangeProviderModelOrActualEndpoint() throws {
        XCTAssertEqual(try VoicePolishRequestProbe.validateConfiguration(provider: .deepseek, config: config), VoicePolishRequestProbe.expectedEndpoint)
        for provider in [LLMProvider.openai, .doubao, .localQwen] {
            XCTAssertThrowsError(try VoicePolishRequestProbe.validateConfiguration(provider: provider, config: config))
        }
        for candidate in [
            LLMConfig(apiKey: "test", model: "deepseek-pro", baseURL: "https://api.deepseek.com"),
            LLMConfig(apiKey: "test", model: "deepseek-flash", baseURL: "https://example.invalid"),
            LLMConfig(apiKey: "test", model: "deepseek-flash", baseURL: "https://api.deepseek.com/v1"),
            LLMConfig(apiKey: "test", model: "deepseek-flash", baseURL: "https://api.deepseek.com:443"),
            LLMConfig(apiKey: "test", model: "deepseek-flash", baseURL: "https://api.deepseek.com?key=secret"),
            LLMConfig(apiKey: "", model: "deepseek-flash", baseURL: "https://api.deepseek.com")
        ] { XCTAssertThrowsError(try VoicePolishRequestProbe.validateConfiguration(provider: .deepseek, config: candidate)) }
    }

    func testOneSimulatedCallPreservesRawInputAndCompleteEvidenceWithoutCredential() async throws {
        let root = try workspace(), bytes = try data()
        let inputURL = root.appendingPathComponent("input.json"); try bytes.write(to: inputURL)
        let output = root.appendingPathComponent("run")
        let client = ProbeClient(.success)
        let result = try await execute(input: inputURL, output: output, root: root, client: client)
        XCTAssertEqual(result.status, "succeeded")
        XCTAssertEqual(result.attemptCount, 1); XCTAssertEqual(result.receiptCount, 1)
        XCTAssertEqual(result.response?.text, "资料已备齐。")
        XCTAssertNotNil(result.stageResponses.first?.startedAt)
        XCTAssertNotNil(result.stageResponses.first?.finishedAt)
        XCTAssertNotNil(result.stageResponses.first?.latencyMilliseconds)
        XCTAssertGreaterThanOrEqual(result.elapsedMilliseconds, 0)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("input.raw.json")), bytes)
        let calls = await client.requests
        XCTAssertEqual(calls.count, 1); XCTAssertEqual(calls.first?.context, .structuredTask)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("probe-report.json"))) as? [String: Any])
        XCTAssertEqual(report["evidence_kind"] as? String, "controlled_request_probe")
        XCTAssertEqual(report["is_production_quality_result"] as? Bool, false)
        let request = try XCTUnwrap(report["request"] as? [String: Any])
        XCTAssertEqual(request["timeout_milliseconds"] as? Int, 30_000)
        XCTAssertEqual(request["temperature"] as? Int, 0)
        for url in try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil) {
            let contents = try Data(contentsOf: url)
            XCTAssertFalse(String(decoding: contents, as: UTF8.self).contains(config.apiKey), url.lastPathComponent)
        }
    }

    func testInvalidInputFailsBeforeIdentityConfigurationOrClientCreation() async throws {
        let root = try workspace(), input = root.appendingPathComponent("invalid.json"), output = root.appendingPathComponent("run")
        try Data(#"{"schema_version":1,"api_key":"must-not-copy"}"#.utf8).write(to: input)
        let report = try await VoicePolishRequestProbe.execute(invocation: .init(inputPath: input.path, outputPath: output.path), workspaceRoot: root,
            loadIdentity: { XCTFail("无效输入不能读取制品"); throw VoicePolishRequestProbe.ProbeError.runtimeIdentityUnavailable },
            loadConfiguration: { XCTFail("无效输入不能读取配置"); throw VoicePolishRequestProbe.ProbeError.configurationUnavailable },
            clientFactory: { _ in XCTFail("无效输入不能创建客户端"); return ProbeClient(.success) })
        XCTAssertEqual(report.failureCode, "invalid_input"); XCTAssertEqual(report.attemptCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("input.raw.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("probe-report.json").path))
    }

    func testUnavailableOrWrongConfigurationLeavesZeroAttemptFailure() async throws {
        for mismatch in [false, true] {
            let root = try workspace(), input = root.appendingPathComponent("input.json"), output = root.appendingPathComponent("run")
            try data().write(to: input)
            let report = try await VoicePolishRequestProbe.execute(invocation: .init(inputPath: input.path, outputPath: output.path), workspaceRoot: root,
                loadIdentity: identity,
                loadConfiguration: {
                    if mismatch { return (.openai, self.config) }
                    throw VoicePolishRequestProbe.ProbeError.configurationUnavailable
                }, clientFactory: { _ in XCTFail("配置失败不能创建客户端"); return ProbeClient(.success) })
            XCTAssertEqual(report.status, "failed"); XCTAssertEqual(report.attemptCount, 0)
            XCTAssertEqual(report.failureCode, mismatch ? "configuration_mismatch" : "configuration_unavailable")
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("input.raw.json").path))
        }
    }

    func testClientFailureIsRecordedOnceWithoutSensitiveErrorDetail() async throws {
        let root = try workspace(), input = root.appendingPathComponent("input.json"), output = root.appendingPathComponent("run")
        try data().write(to: input)
        let client = ProbeClient(.failure)
        let result = try await execute(input: input, output: output, root: root, client: client)
        XCTAssertEqual(result.status, "failed"); XCTAssertEqual(result.attemptCount, 1)
        XCTAssertEqual(result.receiptCount, 0); XCTAssertEqual(result.stageResponses.first?.status, "failed")
        XCTAssertNotNil(result.stageResponses.first?.finishedAt)
        XCTAssertNotNil(result.stageResponses.first?.latencyMilliseconds)
        let count = await client.requests.count; XCTAssertEqual(count, 1)
        let report = try String(contentsOf: output.appendingPathComponent("probe-report.json"), encoding: .utf8)
        XCTAssertFalse(report.contains("sensitive-error-value"))
    }

    func testMissingDuplicatedOrWrongModelReceiptCannotClaimSuccess() async throws {
        for mode in [ProbeClient.Mode.missingReceipt, .duplicateReceipt, .wrongModel] {
            let root = try workspace(), input = root.appendingPathComponent("input.json"), output = root.appendingPathComponent("run")
            try data().write(to: input)
            let client = ProbeClient(mode)
            let result = try await execute(input: input, output: output, root: root, client: client)
            XCTAssertEqual(result.status, "failed"); XCTAssertEqual(result.attemptCount, 1)
            XCTAssertNotNil(result.response)
            let count = await client.requests.count; XCTAssertEqual(count, 1)
        }
    }

    func testExistingOutputAndSymlinkAncestorsNeverOverwriteOrCallClient() async throws {
        let root = try workspace(), input = root.appendingPathComponent("input.json")
        try data().write(to: input)
        let existing = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let sentinel = existing.appendingPathComponent("sentinel"); try Data("keep".utf8).write(to: sentinel)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: existing)
        let client = ProbeClient(.success)
        for output in [existing, alias, alias.appendingPathComponent("new"), root.appendingPathComponent("missing/new")] {
            do { _ = try await execute(input: input, output: output, root: root, client: client); XCTFail("必须拒绝输出路径") }
            catch { }
        }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
        let count = await client.requests.count; XCTAssertEqual(count, 0)
    }

    func testInputMustBeRegularWorkspaceFileWithoutSymlink() async throws {
        let root = try workspace(), real = root.appendingPathComponent("input.json"), alias = root.appendingPathComponent("alias.json")
        try data().write(to: real)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let client = ProbeClient(.success)
        for (index, input) in [alias, root, root.appendingPathComponent("missing.json")].enumerated() {
            let result = try await execute(input: input, output: root.appendingPathComponent("run\(index)"), root: root, client: client)
            XCTAssertEqual(result.status, "failed"); XCTAssertEqual(result.attemptCount, 0)
        }
        let count = await client.requests.count; XCTAssertEqual(count, 0)
    }

    private func workspace() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/2026-09-10-three-mode-implementation/request-probe-unit-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }
    private func object(source: String = "资料已备齐。") throws -> [String: Any] {
        ["schema_version": 1, "experiment_id": "unit-only", "case_id": "x01", "canonical_text": source,
         "system": "仅整理本次内容。", "user": String(decoding: try json(["canonical_text": source]), as: UTF8.self),
         "max_output_tokens": 4096, "response_format": "text"]
    }
    private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
    private func data(source: String = "资料已备齐。") throws -> Data { try json(object(source: source)) }
    private func identity() -> VoicePolishRequestProbe.RuntimeIdentity {
        .init(commit: String(repeating: "a", count: 40), executableSHA256: String(repeating: "b", count: 64), processID: ProcessInfo.processInfo.processIdentifier)
    }
    private func execute(input: URL, output: URL, root: URL, client: ProbeClient) async throws -> VoicePolishRequestProbe.Evidence {
        try await VoicePolishRequestProbe.execute(invocation: .init(inputPath: input.path, outputPath: output.path), workspaceRoot: root,
            loadIdentity: identity, loadConfiguration: { (.deepseek, self.config) }, clientFactory: { _ in client })
    }
}

/// 仅测试使用的单次请求替身；回执明确使用 unit-test-simulated 身份，不访问网络或 Keychain。
private actor ProbeClient: LLMClient {
    enum Mode: Sendable { case success, failure, missingReceipt, duplicateReceipt, wrongModel }
    let mode: Mode
    private(set) var requests: [LLMRequest] = []
    init(_ mode: Mode) { self.mode = mode }
    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        requests.append(request)
        guard let audit = VoicePolishProviderAudit.currentContext else { throw LLMError.emptyResponse(nil) }
        let messages = LLMRequestBuilder.messages(for: request)
        let body = try JSONSerialization.data(withJSONObject: ["model": config.model, "stream": true,
            "messages": [["role": "system", "content": messages.system ?? ""], ["role": "user", "content": messages.user]]])
        let captured = try VoicePolishRequestProbeEvidence.captureIfRequested(body: body, task: request.task)
        if mode == .failure {
            try captured?.recordResponse(status: "unit_test_failure")
            throw LLMError.requestRejected(400, "sensitive-error-value")
        }
        let response = LLMResponse(text: "资料已备齐。", model: "deepseek-flash")
        try captured?.recordResponse(status: "unit_test_simulated", text: response.text, httpStatus: 200,
                                     responseModel: response.model, transport: "unit_test")
        if mode != .missingReceipt {
            let bodyHash = VoicePolishProviderAudit.sha256Hex(body)
            let receipt = VoicePolishProviderAuditReceipt(schemaVersion: 2, runNonce: audit.runNonce,
                testInputID: audit.testInputID, requestOrdinal: 1, llmTask: request.task.rawValue,
                provider: "deepseek", endpointURL: VoicePolishRequestProbe.expectedEndpoint,
                configuredModel: config.model, responseModel: mode == .wrongModel ? "wrong-model" : response.model,
                transport: "unit_test", httpStatus: 200, requestBodySHA256: bodyHash,
                requestBindingSHA256: VoicePolishProviderAudit.requestBindingSHA256(runNonce: audit.runNonce,
                    testInputID: audit.testInputID, requestOrdinal: 1, requestBodySHA256: bodyHash),
                responseTextSHA256: VoicePolishProviderAudit.sha256Hex(Data(response.text.utf8)),
                providerResponseID: "unit-test-simulated", recordedAt: Date())
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            var line = try encoder.encode(receipt); line.append(0x0A)
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: audit.receiptPath)); defer { try? handle.close() }
            try handle.write(contentsOf: line)
            if mode == .duplicateReceipt { try handle.write(contentsOf: line) }
            try handle.synchronize()
        }
        return response
    }
    func process(text: String, prompt: String, context: LLMRequestContext, config: LLMConfig) async throws -> String { throw LLMError.emptyResponse(nil) }
    func warmUp(baseURL: String) async {}
}
