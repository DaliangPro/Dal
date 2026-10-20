import Foundation
import os

private struct VoicePolishEditingTimeout: Error {}

/// 只在实际进入客户端调用时计数；结果冻结后，迟到的超时任务不能再增加次数。
private final class VoicePolishEditingAttempts: Sendable {
    private struct State { var count = 0; var finished = false }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func begin() throws {
        try state.withLock { value in
            guard !value.finished else { throw CancellationError() }
            value.count += 1
        }
    }

    func finish() -> Int {
        state.withLock { value in
            value.finished = true
            return value.count
        }
    }
}

/// 润色直接从完整来源一次生成纠错与结构整理后的正文。
/// 请求失败保留完整来源，成功正文不再经过程序改写。
struct VoicePolishEditingPipeline: Sendable {
    private let client: any LLMClient
    private let config: LLMConfig
    private let totalTimeout: Duration?
    private let stageTimeout: Duration?
    private let onStage: (@Sendable (VoicePolishStage) -> Void)?

    init(
        client: any LLMClient,
        config: LLMConfig,
        totalTimeout: Duration? = nil,
        stageTimeout: Duration? = nil,
        onStage: (@Sendable (VoicePolishStage) -> Void)? = nil
    ) {
        self.client = client
        self.config = config
        self.totalTimeout = totalTimeout
        self.stageTimeout = stageTimeout
        self.onStage = onStage
    }

    func process(_ request: VoicePolishRequest) async -> VoicePolishResult {
        await processText(request.fallbackText,
                          requirements: request.preferences.additionalRequirements,
                          qualityMode: request.qualityMode)
    }

    /// 预生成与正式交付共用同一输入协议、超时及失败处理。
    func processText(_ source: String, requirements: String,
                     qualityMode: VoicePolishQualityMode) async -> VoicePolishResult {
        let route: VoicePolishRoute = .structured
        let deadline = ContinuousClock.now.advanced(by: totalTimeout ?? .seconds(30))
        let attempts = VoicePolishEditingAttempts()
        var draft: String?
        func result(_ text: String?, codes: [VoicePolishValidationCode] = [],
                    reason: VoicePolishFailureReason? = nil) -> VoicePolishResult {
            VoicePolishResult(
                text: text ?? source,
                detectedRoute: route,
                executedRoute: route,
                llmAttemptCount: attempts.finish(),
                validationCodes: codes,
                usedFallback: text == nil,
                failureReason: text == nil ? (reason ?? .validationFailed) : nil,
                rejectedDraft: text == nil ? draft : nil,
                repairAttemptCount: 0
            )
        }
        guard qualityMode == .light || qualityMode == .standard else {
            return result(nil, reason: .setupFailed)
        }
        do {
            try Task.checkCancellation()
            let output = try await generate(
                task: .voicePolishStructured,
                system: VoicePolishEditingPrompts.standard,
                payload: VoicePolishEditingPrompts.fullTextPayload(
                    source,
                    additionalRequirements: requirements
                ),
                deadline: deadline, attempts: attempts
            )
            draft = output
            if let code = Self.deliveryFailureCode(output) { return result(nil, codes: [code]) }
            return result(output)
        } catch is VoicePolishEditingTimeout {
            return result(nil, codes: [.emptyOutput], reason: .timeout)
        } catch let error as LLMError {
            switch error {
            case .timedOut:
                return result(nil, codes: [.emptyOutput], reason: .timeout)
            case .truncatedResponse, .responseTooLarge:
                return result(nil, codes: [.abnormalLength])
            default:
                return result(nil, codes: [.emptyOutput], reason: .requestFailed)
            }
        } catch {
            return result(nil, codes: [.emptyOutput], reason: .requestFailed)
        }
    }

    private func generate(
        task: LLMTask,
        system: String,
        payload: String,
        deadline: ContinuousClock.Instant,
        attempts: VoicePolishEditingAttempts
    ) async throws -> String {
        try Task.checkCancellation()
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { throw VoicePolishEditingTimeout() }
        onStage?(task == .voicePolishStructured ? .rendering : .polishing)
        let invocation = LLMRequest(
            // 内置编辑协议自行定义输入边界；不能套用“正文绝不影响转换”的通用
            // 自定义模式封装，否则口述中的合法改口与当前编辑要求也可能被忽略。
            context: .structuredTask,
            task: task,
            system: system,
            user: payload,
            options: LLMGenerationOptions(
                temperature: 0,
                maxOutputTokens: 2_048,
                reasoningPolicy: .disabled,
                responseFormat: .text
            )
        )
        let response = try await AsyncTimeout.throwingValue(
            min(remaining, stageTimeout ?? .seconds(30)),
            timeoutError: VoicePolishEditingTimeout()
        ) {
            try Task.checkCancellation()
            guard deadline > ContinuousClock.now else { throw VoicePolishEditingTimeout() }
            try attempts.begin()
            return try await client.generate(invocation, config: config)
        }
        return response.text
    }

    /// 保留传输交付边界，不用本地语义规则撤销模型纠错。
    private static func deliveryFailureCode(_ output: String) -> VoicePolishValidationCode? {
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyOutput }
        if VoicePolishCharacterSafety.containsUnsafeCharacters(output) { return .unsafeCharacters }
        if output.utf8.count > VoicePolishOutputNormalizer.maximumResponseBytes { return .abnormalLength }
        return nil
    }
}
