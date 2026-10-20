import Foundation
import os

/// 模型深度思考的用户期望状态。
///
/// 该状态只控制模型是否在生成最终答案前进行推理；推理过程本身不会写入最终文本。
enum LLMThinkingMode: String, CaseIterable, Codable, Hashable, Sendable {
    case disabled
    case enabled

    var isEnabled: Bool {
        self == .enabled
    }

    var displayName: String {
        switch self {
        case .disabled:
            return L("关闭", "Off")
        case .enabled:
            return L("开启", "On")
        }
    }

    var opposite: LLMThinkingMode {
        self == .enabled ? .disabled : .enabled
    }
}

/// 深度思考偏好按使用场景分开保存；存储键包含场景名，新增场景不会与既有偏好串用。
enum LLMConfigurationRole: String, Codable, Sendable {
    case textProcessing
}

/// 连通性缓存必须绑定完整模型执行配置；只按服务商缓存会在模型或思考状态改变后
/// 错误复用旧的绿色状态。
struct LLMConnectivitySignature: Hashable, Sendable {
    let provider: LLMProvider
    let baseURL: String
    let model: String
    let thinkingMode: LLMThinkingMode
    /// 只保存进程内随机种子的哈希结果，既能在凭证改变后作废缓存，也不延长明文密钥生命周期。
    private let apiKeyFingerprint: Int

    init(provider: LLMProvider, config: LLMConfig) {
        var hasher = Hasher()
        hasher.combine(config.apiKey)
        self.provider = provider
        self.baseURL = config.baseURL
        self.model = config.model
        self.thinkingMode = config.thinkingMode
        self.apiKeyFingerprint = hasher.finalize()
    }
}

/// 正常调用与“测试连接”对兼容缓存的使用方式不同：
/// 正常调用优先复用已知可用的静默回退，测试连接始终重新验证显式开关。
enum LLMThinkingRequestPurpose: Sendable {
    case runtime
    case probe
}

enum LLMThinkingRuntimeRequestPreference: Equatable, Sendable {
    case standard
    case claudeManual
    case omitControl
}

extension Notification.Name {
    /// 仅通知设置页刷新连通状态，不在输入、润色或模型调用流程中显示提示。
    static let llmThinkingValidationInvalidated = Notification.Name(
        "Dal.llmThinkingValidationInvalidated"
    )
}

/// 记录当前进程中已经证实的请求兼容方式。
///
/// 若某模型在真实调用时开始拒绝深度思考字段，客户端会静默重试基础请求，并把该配置
/// 先前的“连接正常”状态作废。后续调用直接复用基础请求，直到用户再次执行测试连接；
/// 整个过程不向正在输入的用户弹窗或插入错误提示。
enum LLMThinkingRuntimeState {
    private struct State {
        var preferences: [LLMConnectivitySignature: LLMThinkingRuntimeRequestPreference] = [:]
        var validationGenerations: [LLMConnectivitySignature: UInt64] = [:]
        var invalidatedSignatures: Set<LLMConnectivitySignature> = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func preference(
        for signature: LLMConnectivitySignature
    ) -> LLMThinkingRuntimeRequestPreference {
        state.withLock { state in
            state.preferences[signature] ?? .standard
        }
    }

    static func validationGeneration(
        for signature: LLMConnectivitySignature
    ) -> UInt64 {
        state.withLock { state in
            state.validationGenerations[signature] ?? 0
        }
    }

    static func rememberClaudeManual(
        for signature: LLMConnectivitySignature
    ) {
        state.withLock { state in
            state.preferences[signature] = .claudeManual
        }
    }

    static func rememberOmittedControl(
        for signature: LLMConnectivitySignature
    ) {
        let didInvalidate = state.withLock { state -> Bool in
            state.preferences[signature] = .omitControl
            guard state.invalidatedSignatures.insert(signature).inserted else {
                return false
            }
            state.validationGenerations[signature, default: 0] &+= 1
            return true
        }
        postInvalidationIfNeeded(didInvalidate)
    }

    /// 正常响应若明确暴露了与用户选择相反的状态，只作废旧验证结果；
    /// 文本仍正常返回，绝不在输入链路里展示功能错误。
    static func recordRuntimeEvidence(
        _ evidence: LLMThinkingProbeEvidence,
        provider: LLMProvider,
        config: LLMConfig
    ) {
        guard let observedMode = evidence.observedMode,
              observedMode != config.thinkingMode
        else { return }
        invalidateValidation(
            for: LLMConnectivitySignature(provider: provider, config: config)
        )
    }

    static func markValidated(
        _ signature: LLMConnectivitySignature
    ) {
        state.withLock { state in
            _ = state.invalidatedSignatures.remove(signature)
        }
    }

    /// 测试连接成功发送显式控制字段后，恢复标准请求；代际不回退，
    /// 新测试结果会以当前代际写入连通缓存。
    static func clearPreference(
        for signature: LLMConnectivitySignature
    ) {
        state.withLock { state in
            _ = state.preferences.removeValue(forKey: signature)
        }
    }

    private static func invalidateValidation(
        for signature: LLMConnectivitySignature
    ) {
        let didInvalidate = state.withLock { state -> Bool in
            guard state.invalidatedSignatures.insert(signature).inserted else {
                return false
            }
            state.validationGenerations[signature, default: 0] &+= 1
            return true
        }
        postInvalidationIfNeeded(didInvalidate)
    }

    private static func postInvalidationIfNeeded(_ isNeeded: Bool) {
        guard isNeeded else { return }
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .llmThinkingValidationInvalidated,
                object: nil
            )
        }
    }
}

/// 测试请求只保留是否观察到推理的证据，不保存、记录或向 UI 暴露思考内容。
struct LLMThinkingProbeEvidence: Equatable, Sendable {
    let reportedMode: LLMThinkingMode?
    let reasoningObserved: Bool?
    let controlAccepted: Bool

    init(
        reportedMode: LLMThinkingMode?,
        reasoningObserved: Bool?,
        controlAccepted: Bool = false
    ) {
        self.reportedMode = reportedMode
        self.reasoningObserved = reasoningObserved
        self.controlAccepted = controlAccepted
    }

    static let unknown = LLMThinkingProbeEvidence(
        reportedMode: nil,
        reasoningObserved: nil,
        controlAccepted: false
    )

    var observedMode: LLMThinkingMode? {
        if let reportedMode {
            return reportedMode
        }
        guard let reasoningObserved else { return nil }
        return reasoningObserved ? .enabled : .disabled
    }

    func withControlAccepted(_ accepted: Bool) -> LLMThinkingProbeEvidence {
        LLMThinkingProbeEvidence(
            reportedMode: reportedMode,
            reasoningObserved: reasoningObserved,
            controlAccepted: accepted
        )
    }
}
