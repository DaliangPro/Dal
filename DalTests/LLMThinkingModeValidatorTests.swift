import XCTest
@testable import Dal

final class LLMThinkingModeValidatorTests: XCTestCase {

    private actor ScriptedProbe {
        enum Step: Sendable {
            case evidence(LLMThinkingProbeEvidence)
            case modeRejected
            case networkFailed
        }

        private var steps: [Step]
        private var modes: [LLMThinkingMode] = []

        init(_ steps: [Step]) {
            self.steps = steps
        }

        func run(_ config: LLMConfig) throws -> LLMThinkingProbeEvidence {
            modes.append(config.thinkingMode)
            guard !steps.isEmpty else {
                throw LLMError.emptyResponse(nil)
            }
            switch steps.removeFirst() {
            case .evidence(let evidence):
                return evidence
            case .modeRejected:
                throw LLMError.requestRejected(
                    400,
                    #"{"error":{"message":"reasoning mode is not supported"}}"#
                )
            case .networkFailed:
                throw URLError(.notConnectedToInternet)
            }
        }

        func recordedModes() -> [LLMThinkingMode] {
            modes
        }
    }

    private func config(_ mode: LLMThinkingMode) -> LLMConfig {
        LLMConfig(
            apiKey: "test",
            model: "test-model",
            baseURL: "https://example.com/v1",
            thinkingMode: mode
        )
    }

    func testDisabledModeUsesDifferentialEvidenceInsteadOfHTTPAcceptance() async {
        let probe = ScriptedProbe([
            .evidence(LLMThinkingProbeEvidence(
                reportedMode: nil,
                reasoningObserved: nil,
                controlAccepted: true
            )),
            .evidence(LLMThinkingProbeEvidence(
                reportedMode: nil,
                reasoningObserved: true,
                controlAccepted: true
            )),
        ])

        let result = await LLMThinkingModeValidator.validate(
            provider: .deepseek,
            config: config(.disabled)
        ) { try await probe.run($0) }

        XCTAssertEqual(result, .valid)
        let recordedModes = await probe.recordedModes()
        XCTAssertEqual(recordedModes, [.disabled, .enabled])
    }

    func testSuccessfulControlsWithoutStateEvidenceFailValidation() async {
        let probe = ScriptedProbe([
            .evidence(LLMThinkingProbeEvidence(
                reportedMode: nil,
                reasoningObserved: nil,
                controlAccepted: true
            )),
            .evidence(LLMThinkingProbeEvidence(
                reportedMode: nil,
                reasoningObserved: nil,
                controlAccepted: true
            )),
        ])

        let result = await LLMThinkingModeValidator.validate(
            provider: .gemini,
            config: config(.enabled)
        ) { try await probe.run($0) }

        guard case .failed(let message) = result else {
            return XCTFail("只有 HTTP 成功、没有状态证据时不得通过")
        }
        XCTAssertTrue(message.contains(L("没有返回足够证据", "did not provide enough evidence")))
        let recordedModes = await probe.recordedModes()
        XCTAssertEqual(recordedModes, [.enabled, .disabled])
    }

    func testEnabledModePassesWithObservedReasoning() async {
        let probe = ScriptedProbe([
            .evidence(LLMThinkingProbeEvidence(
                reportedMode: nil,
                reasoningObserved: true,
                controlAccepted: true
            )),
        ])

        let result = await LLMThinkingModeValidator.validate(
            provider: .deepseek,
            config: config(.enabled)
        ) { try await probe.run($0) }

        XCTAssertEqual(result, .valid)
        let recordedModes = await probe.recordedModes()
        XCTAssertEqual(recordedModes, [.enabled])
    }

    func testExplicitZeroReasoningCorrectsEnabledModeToDisabled() async {
        let probe = ScriptedProbe([
            .evidence(LLMThinkingProbeEvidence(
                reportedMode: nil,
                reasoningObserved: false,
                controlAccepted: true
            )),
            .evidence(LLMThinkingProbeEvidence(
                reportedMode: nil,
                reasoningObserved: false,
                controlAccepted: true
            )),
        ])

        let result = await LLMThinkingModeValidator.validate(
            provider: .openai,
            config: config(.enabled)
        ) { try await probe.run($0) }

        guard case .adjusted(let mode, _) = result else {
            return XCTFail("明确返回零推理证据时应纠正为关闭")
        }
        XCTAssertEqual(mode, .disabled)
        let recordedModes = await probe.recordedModes()
        XCTAssertEqual(recordedModes, [.enabled, .disabled])
    }

    func testRejectedDisabledModeIsCorrectedOnlyAfterEnabledModeIsVerified() async {
        let probe = ScriptedProbe([
            .modeRejected,
            .evidence(LLMThinkingProbeEvidence(reportedMode: nil, reasoningObserved: true)),
        ])

        let result = await LLMThinkingModeValidator.validate(
            provider: .deepseek,
            config: config(.disabled)
        ) { try await probe.run($0) }

        guard case .adjusted(let mode, let message) = result else {
            return XCTFail("预期自动纠正，实际为 \(result)")
        }
        XCTAssertEqual(mode, .enabled)
        XCTAssertTrue(message.contains(L("自动调整为开启", "changed to On")))
        let recordedModes = await probe.recordedModes()
        XCTAssertEqual(recordedModes, [.disabled, .enabled])
    }

    func testRejectedEnabledModeIsCorrectedToDisabled() async {
        let probe = ScriptedProbe([
            .modeRejected,
            .evidence(LLMThinkingProbeEvidence(
                reportedMode: nil,
                reasoningObserved: false,
                controlAccepted: true
            )),
        ])

        let result = await LLMThinkingModeValidator.validate(
            provider: .bailian,
            config: config(.enabled)
        ) { try await probe.run($0) }

        guard case .adjusted(let mode, _) = result else {
            return XCTFail("预期自动纠正，实际为 \(result)")
        }
        XCTAssertEqual(mode, .disabled)
        let recordedModes = await probe.recordedModes()
        XCTAssertEqual(recordedModes, [.enabled, .disabled])
    }

    func testRejectedEnabledModeWithoutStateEvidenceFails() async {
        let probe = ScriptedProbe([
            .modeRejected,
            .evidence(.unknown),
        ])

        let result = await LLMThinkingModeValidator.validate(
            provider: .deepseek,
            config: config(.enabled)
        ) { try await probe.run($0) }

        guard case .failed(let message) = result else {
            return XCTFail("没有关闭状态证据时不得自动纠正")
        }
        XCTAssertTrue(message.contains(L("没有返回足够证据", "did not provide enough evidence")))
        let recordedModes = await probe.recordedModes()
        XCTAssertEqual(recordedModes, [.enabled, .disabled])
    }

    func testBothRejectedControlsWithoutStateEvidenceFail() async {
        let probe = ScriptedProbe([
            .evidence(.unknown),
            .evidence(.unknown),
        ])

        let result = await LLMThinkingModeValidator.validate(
            provider: .openai,
            config: config(.enabled)
        ) { try await probe.run($0) }

        guard case .failed(let message) = result else {
            return XCTFail("两种状态都无法观察时不得假通过")
        }
        XCTAssertTrue(message.contains(L("没有返回足够证据", "did not provide enough evidence")))
        let recordedModes = await probe.recordedModes()
        XCTAssertEqual(recordedModes, [.enabled, .disabled])
    }

    func testUnverifiedEnabledModeIsCorrectedWhenDisabledModeIsVerified() async {
        let probe = ScriptedProbe([
            .evidence(.unknown),
            .evidence(LLMThinkingProbeEvidence(
                reportedMode: nil,
                reasoningObserved: false,
                controlAccepted: true
            )),
        ])

        let result = await LLMThinkingModeValidator.validate(
            provider: .openai,
            config: config(.enabled)
        ) { try await probe.run($0) }

        guard case .adjusted(let mode, let message) = result else {
            return XCTFail("仅关闭状态可验证时应自动纠正")
        }
        XCTAssertEqual(mode, .disabled)
        XCTAssertTrue(message.contains(L("关闭", "Off")))
        let recordedModes = await probe.recordedModes()
        XCTAssertEqual(recordedModes, [.enabled, .disabled])
    }

    func testGenericNetworkFailureDoesNotFlipThinkingMode() async {
        let probe = ScriptedProbe([.networkFailed])

        let result = await LLMThinkingModeValidator.validate(
            provider: .deepseek,
            config: config(.disabled)
        ) { try await probe.run($0) }

        guard case .failed = result else {
            return XCTFail("网络失败不应触发自动纠正")
        }
        let recordedModes = await probe.recordedModes()
        XCTAssertEqual(recordedModes, [.disabled])
    }

    func testDisabledBaselineWithoutStateEvidenceDoesNotPass() async {
        let probe = ScriptedProbe([
            .evidence(.unknown),
            .modeRejected,
        ])

        let result = await LLMThinkingModeValidator.validate(
            provider: .deepseek,
            config: config(.disabled)
        ) { try await probe.run($0) }

        guard case .failed = result else {
            return XCTFail("基线成功但状态不可观察时不得通过")
        }
        let recordedModes = await probe.recordedModes()
        XCTAssertEqual(recordedModes, [.disabled, .enabled])
    }

    func testOppositeModeContradictionConfirmsRequestedMode() async {
        let probe = ScriptedProbe([
            .evidence(.unknown),
            .evidence(LLMThinkingProbeEvidence(
                reportedMode: nil,
                reasoningObserved: true,
                controlAccepted: false
            )),
        ])

        let result = await LLMThinkingModeValidator.validate(
            provider: .deepseek,
            config: config(.enabled)
        ) { try await probe.run($0) }

        XCTAssertEqual(result, .valid)
        let recordedModes = await probe.recordedModes()
        XCTAssertEqual(recordedModes, [.enabled, .disabled])
    }

    func testForcedThinkingProviderProbesEnabledModeAndCorrectsSwitch() async {
        let probe = ScriptedProbe([.evidence(.unknown)])

        let result = await LLMThinkingModeValidator.validate(
            provider: .minimaxCN,
            config: config(.disabled)
        ) { try await probe.run($0) }

        guard case .adjusted(let mode, _) = result else {
            return XCTFail("MiniMax 固定思考模式应自动纠正")
        }
        XCTAssertEqual(mode, .enabled)
        let recordedModes = await probe.recordedModes()
        XCTAssertEqual(recordedModes, [.enabled])
    }

    func testKnownFixedModeFailsWhenResponseExplicitlyContradictsCapability() async {
        let probe = ScriptedProbe([
            .evidence(LLMThinkingProbeEvidence(
                reportedMode: nil,
                reasoningObserved: false
            )),
        ])

        let result = await LLMThinkingModeValidator.validate(
            provider: .minimaxCN,
            config: config(.enabled)
        ) { try await probe.run($0) }

        guard case .failed = result else {
            return XCTFail("明确状态与已知固定能力冲突时不得通过")
        }
        let recordedModes = await probe.recordedModes()
        XCTAssertEqual(recordedModes, [.enabled])
    }

    func testKimiAlwaysThinkingModelUsesBaselineAndCorrectsSwitch() async {
        let probe = ScriptedProbe([.evidence(.unknown)])
        let config = LLMConfig(
            apiKey: "test",
            model: "kimi-k3",
            baseURL: LLMProvider.kimi.defaultBaseURL,
            thinkingMode: .disabled
        )

        let result = await LLMThinkingModeValidator.validate(
            provider: .kimi,
            config: config
        ) { try await probe.run($0) }

        guard case .adjusted(let mode, _) = result else {
            return XCTFail("Kimi K3 固定思考，应自动纠正为开启")
        }
        XCTAssertEqual(mode, .enabled)
        let recordedModes = await probe.recordedModes()
        XCTAssertEqual(recordedModes, [.enabled])
    }

    func testGeminiAlwaysThinkingModelCorrectsDisabledSelection() async {
        let probe = ScriptedProbe([.evidence(.unknown)])
        let config = LLMConfig(
            apiKey: "test",
            model: "gemini-3.6-flash",
            baseURL: LLMProvider.gemini.defaultBaseURL,
            thinkingMode: .disabled
        )

        let result = await LLMThinkingModeValidator.validate(
            provider: .gemini,
            config: config
        ) { try await probe.run($0) }

        guard case .adjusted(let mode, _) = result else {
            return XCTFail("Gemini 3 固定思考，应自动纠正为开启")
        }
        XCTAssertEqual(mode, .enabled)
        let recordedModes = await probe.recordedModes()
        XCTAssertEqual(recordedModes, [.enabled])
    }

    func testReportedModeContradictionTriggersVerifiedCorrection() async {
        let probe = ScriptedProbe([
            .evidence(LLMThinkingProbeEvidence(reportedMode: .enabled, reasoningObserved: true)),
            .evidence(LLMThinkingProbeEvidence(reportedMode: .enabled, reasoningObserved: true)),
        ])

        let result = await LLMThinkingModeValidator.validate(
            provider: .localQwen,
            config: config(.disabled)
        ) { try await probe.run($0) }

        guard case .adjusted(let mode, _) = result else {
            return XCTFail("服务端报告状态冲突时应纠正")
        }
        XCTAssertEqual(mode, .enabled)
        let recordedModes = await probe.recordedModes()
        XCTAssertEqual(recordedModes, [.disabled, .enabled])
    }
}

final class LLMThinkingRequestEncodingTests: XCTestCase {

    private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func openAICompatibleBody(
        provider: LLMProvider,
        mode: LLMThinkingMode
    ) throws -> [String: Any] {
        let config = LLMConfig(
            apiKey: "test",
            model: "test-model",
            baseURL: provider.defaultBaseURL,
            thinkingMode: mode
        )
        let request = DoubaoChatClient.makeChatRequest(
            provider: provider,
            config: config,
            messages: [ChatMessage(role: "user", content: "test")],
            stream: false,
            maxTokens: 128
        )
        return try encodedObject(request)
    }

    func testThinkingTypeFieldEncodesBothDirections() throws {
        for provider in [LLMProvider.deepseek, .zhipu] {
            let disabled = try openAICompatibleBody(provider: provider, mode: .disabled)
            let enabled = try openAICompatibleBody(provider: provider, mode: .enabled)

            XCTAssertEqual(
                (disabled["thinking"] as? [String: Any])?["type"] as? String,
                "disabled"
            )
            XCTAssertEqual(
                (enabled["thinking"] as? [String: Any])?["type"] as? String,
                "enabled"
            )
        }
    }

    func testBailianEncodesEnableThinkingBoolean() throws {
        let disabled = try openAICompatibleBody(provider: .bailian, mode: .disabled)
        let enabled = try openAICompatibleBody(provider: .bailian, mode: .enabled)

        XCTAssertEqual(disabled["enable_thinking"] as? Bool, false)
        XCTAssertEqual(enabled["enable_thinking"] as? Bool, true)
    }

    func testBailianProbeUsesRequiredStreamingMode() {
        XCTAssertTrue(
            DoubaoChatClient.usesStreamingForThinkingProbe(
                provider: .bailian
            )
        )
        XCTAssertFalse(
            DoubaoChatClient.usesStreamingForThinkingProbe(
                provider: .openai
            )
        )
    }

    func testOpenAIProbeOmitsLegacyMaxTokens() {
        XCTAssertNil(
            DoubaoChatClient.maximumTokensForThinkingProbe(provider: .openai)
        )
        XCTAssertEqual(
            DoubaoChatClient.maximumTokensForThinkingProbe(provider: .deepseek),
            1_024
        )
    }

    func testReasoningEffortEncodesBothDirections() throws {
        let disabled = try openAICompatibleBody(provider: .openai, mode: .disabled)
        let enabled = try openAICompatibleBody(provider: .openai, mode: .enabled)

        XCTAssertEqual(disabled["reasoning_effort"] as? String, "none")
        XCTAssertEqual(enabled["reasoning_effort"] as? String, "medium")
    }

    func testOpenRouterEncodesReasoningObject() throws {
        let disabled = try openAICompatibleBody(provider: .openrouter, mode: .disabled)
        let enabled = try openAICompatibleBody(provider: .openrouter, mode: .enabled)

        XCTAssertEqual(
            (disabled["reasoning"] as? [String: Any])?["effort"] as? String,
            "none"
        )
        XCTAssertEqual(
            (enabled["reasoning"] as? [String: Any])?["effort"] as? String,
            "medium"
        )
        XCTAssertNil(disabled["reasoning_effort"])
        XCTAssertNil(enabled["reasoning_effort"])
    }

    func testOllamaEncodesOpenAICompatibleReasoningEffort() throws {
        let disabled = try openAICompatibleBody(provider: .ollama, mode: .disabled)
        let enabled = try openAICompatibleBody(provider: .ollama, mode: .enabled)

        XCTAssertEqual(disabled["reasoning_effort"] as? String, "none")
        XCTAssertEqual(enabled["reasoning_effort"] as? String, "medium")
        XCTAssertNil(disabled["think"])
        XCTAssertNil(enabled["think"])
    }

    func testBundledQwenEncodesThinkBoolean() throws {
        let disabled = try openAICompatibleBody(provider: .localQwen, mode: .disabled)
        let enabled = try openAICompatibleBody(provider: .localQwen, mode: .enabled)

        XCTAssertEqual(disabled["think"] as? Bool, false)
        XCTAssertEqual(enabled["think"] as? Bool, true)
    }

    func testMiniMaxKeepsReasoningSplitAndDoesNotInventToggleField() throws {
        let body = try openAICompatibleBody(provider: .minimaxCN, mode: .enabled)

        XCTAssertEqual(body["reasoning_split"] as? Bool, true)
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["enable_thinking"])
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertNil(body["think"])
    }

    func testKimiAlwaysThinkingModelOmitsUnsupportedThinkingField() throws {
        let config = LLMConfig(
            apiKey: "test",
            model: "kimi-k3",
            baseURL: LLMProvider.kimi.defaultBaseURL,
            thinkingMode: .enabled
        )
        let request = DoubaoChatClient.makeChatRequest(
            provider: .kimi,
            config: config,
            messages: [ChatMessage(role: "user", content: "test")],
            stream: false,
            maxTokens: 128
        )
        let body = try encodedObject(request)

        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["reasoning_effort"])
    }

    func testClaudeEncodesExplicitDisabledAndAdaptiveEnabledModes() throws {
        let disabledConfig = LLMConfig(
            apiKey: "test",
            model: "claude-test",
            baseURL: LLMProvider.claude.defaultBaseURL,
            thinkingMode: .disabled
        )
        let enabledConfig = disabledConfig.withThinkingMode(.enabled)

        let disabled = try encodedObject(ClaudeChatClient.makeRequestBody(
            config: disabledConfig,
            maxTokens: 2_048,
            system: nil,
            user: "test",
            stream: false
        ))
        let enabled = try encodedObject(ClaudeChatClient.makeRequestBody(
            config: enabledConfig,
            maxTokens: 2_048,
            system: nil,
            user: "test",
            stream: false
        ))

        let disabledThinking = try XCTUnwrap(disabled["thinking"] as? [String: Any])
        XCTAssertEqual(disabledThinking["type"] as? String, "disabled")
        XCTAssertNil(disabledThinking["budget_tokens"])

        let enabledThinking = try XCTUnwrap(enabled["thinking"] as? [String: Any])
        XCTAssertEqual(enabledThinking["type"] as? String, "adaptive")
        XCTAssertNil(enabledThinking["budget_tokens"])
    }

    func testClaudeManualFallbackEncodesThinkingBudget() throws {
        let config = LLMConfig(
            apiKey: "test",
            model: "claude-test",
            baseURL: LLMProvider.claude.defaultBaseURL,
            thinkingMode: .enabled
        )
        let body = try encodedObject(ClaudeChatClient.makeRequestBody(
            config: config,
            maxTokens: 2_048,
            system: nil,
            user: "test",
            stream: false,
            thinkingStyle: .manual
        ))

        let thinking = try XCTUnwrap(body["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "enabled")
        XCTAssertEqual(thinking["budget_tokens"] as? Int, 1_024)
    }

    func testClaudeBaselineFallbackOmitsThinkingControl() throws {
        let config = LLMConfig(
            apiKey: "test",
            model: "claude-legacy",
            baseURL: LLMProvider.claude.defaultBaseURL,
            thinkingMode: .disabled
        )
        let body = try encodedObject(ClaudeChatClient.makeRequestBody(
            config: config,
            maxTokens: 2_048,
            system: nil,
            user: "test",
            stream: false,
            thinkingStyle: .omitted
        ))

        XCTAssertNil(body["thinking"])
    }

    func testOnlyReasoningRelated400ErrorsTriggerAutomaticModeFallback() {
        XCTAssertTrue(
            LLMError.requestRejected(400, "reasoning_effort is unsupported")
                .isThinkingModeRejection
        )
        XCTAssertFalse(
            LLMError.requestRejected(401, "reasoning_effort is unsupported")
                .isThinkingModeRejection
        )
        XCTAssertFalse(
            LLMError.requestRejected(400, "model not found")
                .isThinkingModeRejection
        )
        XCTAssertFalse(
            LLMError.requestRejected(400, "reasoning model not found")
                .isThinkingModeRejection
        )
        XCTAssertTrue(
            LLMError.requestRejected(400, "thinking is always enabled for this model")
                .isThinkingModeRejection
        )
    }
}

final class LLMThinkingRuntimeStateTests: XCTestCase {

    private func signature(
        model: String,
        mode: LLMThinkingMode = .enabled
    ) -> LLMConnectivitySignature {
        LLMConnectivitySignature(
            provider: .openai,
            config: LLMConfig(
                apiKey: "runtime-state-test",
                model: model,
                baseURL: LLMProvider.openai.defaultBaseURL,
                thinkingMode: mode
            )
        )
    }

    func testOmittedControlInvalidatesOnlyMatchingConfigurationOnce() {
        let affected = signature(model: "runtime-omit-affected")
        let untouched = signature(model: "runtime-omit-untouched")
        let initialAffectedGeneration = LLMThinkingRuntimeState.validationGeneration(
            for: affected
        )
        let initialUntouchedGeneration = LLMThinkingRuntimeState.validationGeneration(
            for: untouched
        )

        LLMThinkingRuntimeState.rememberOmittedControl(for: affected)

        XCTAssertEqual(
            LLMThinkingRuntimeState.preference(for: affected),
            .omitControl
        )
        XCTAssertEqual(
            LLMThinkingRuntimeState.validationGeneration(for: affected),
            initialAffectedGeneration + 1
        )
        XCTAssertEqual(
            LLMThinkingRuntimeState.validationGeneration(for: untouched),
            initialUntouchedGeneration
        )

        LLMThinkingRuntimeState.rememberOmittedControl(for: affected)
        XCTAssertEqual(
            LLMThinkingRuntimeState.validationGeneration(for: affected),
            initialAffectedGeneration + 1,
            "重复复用同一静默回退时不应反复作废状态"
        )
    }

    func testConnectivityEntryBecomesStaleAfterRuntimeFallback() {
        let target = signature(model: "runtime-entry-stale")
        let entry = LLMConnectivityCacheEntry(
            signature: target,
            status: .success
        )
        XCTAssertTrue(entry.isCurrent)

        LLMThinkingRuntimeState.rememberOmittedControl(for: target)

        XCTAssertFalse(entry.isCurrent)
        XCTAssertTrue(LLMConnectivityCacheEntry(
            signature: target,
            status: .success
        ).isCurrent)
    }

    func testClaudeManualFallbackPreservesValidationGeneration() {
        let target = LLMConnectivitySignature(
            provider: .claude,
            config: LLMConfig(
                apiKey: "runtime-state-test",
                model: "runtime-claude-manual",
                baseURL: LLMProvider.claude.defaultBaseURL,
                thinkingMode: .enabled
            )
        )
        let initialGeneration = LLMThinkingRuntimeState.validationGeneration(
            for: target
        )

        LLMThinkingRuntimeState.rememberClaudeManual(for: target)

        XCTAssertEqual(
            LLMThinkingRuntimeState.preference(for: target),
            .claudeManual
        )
        XCTAssertEqual(
            LLMThinkingRuntimeState.validationGeneration(for: target),
            initialGeneration,
            "手动预算仍是明确的开启控制，不应作废验证"
        )
        LLMThinkingRuntimeState.clearPreference(for: target)
        XCTAssertEqual(
            LLMThinkingRuntimeState.preference(for: target),
            .standard
        )
    }

    func testContradictoryRuntimeEvidenceSilentlyInvalidatesCachedSuccess() {
        let config = LLMConfig(
            apiKey: "runtime-state-test",
            model: "runtime-observed-contradiction",
            baseURL: LLMProvider.openai.defaultBaseURL,
            thinkingMode: .disabled
        )
        let target = LLMConnectivitySignature(provider: .openai, config: config)
        let entry = LLMConnectivityCacheEntry(
            signature: target,
            status: .success
        )

        LLMThinkingRuntimeState.recordRuntimeEvidence(
            LLMThinkingProbeEvidence(
                reportedMode: nil,
                reasoningObserved: true,
                controlAccepted: true
            ),
            provider: .openai,
            config: config
        )

        XCTAssertFalse(entry.isCurrent)
        let invalidatedGeneration = LLMThinkingRuntimeState.validationGeneration(
            for: target
        )
        LLMThinkingRuntimeState.recordRuntimeEvidence(
            LLMThinkingProbeEvidence(
                reportedMode: .enabled,
                reasoningObserved: true,
                controlAccepted: true
            ),
            provider: .openai,
            config: config
        )
        XCTAssertEqual(
            LLMThinkingRuntimeState.validationGeneration(for: target),
            invalidatedGeneration,
            "同一异常状态不应在每次输入后重复刷新设置页"
        )

        XCTAssertTrue(LLMConnectivityCacheEntry(
            signature: target,
            status: .success
        ).isCurrent)
    }

    func testMatchingOrUnknownRuntimeEvidenceKeepsValidationCurrent() {
        let config = LLMConfig(
            apiKey: "runtime-state-test",
            model: "runtime-observed-match",
            baseURL: LLMProvider.openai.defaultBaseURL,
            thinkingMode: .enabled
        )
        let target = LLMConnectivitySignature(provider: .openai, config: config)
        let entry = LLMConnectivityCacheEntry(
            signature: target,
            status: .success
        )

        LLMThinkingRuntimeState.recordRuntimeEvidence(
            .unknown,
            provider: .openai,
            config: config
        )
        LLMThinkingRuntimeState.recordRuntimeEvidence(
            LLMThinkingProbeEvidence(
                reportedMode: nil,
                reasoningObserved: true,
                controlAccepted: true
            ),
            provider: .openai,
            config: config
        )

        XCTAssertTrue(entry.isCurrent)
    }
}
