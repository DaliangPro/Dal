import Foundation

// MARK: - Provider Enum

enum LLMProvider: String, CaseIterable, Codable, Sendable {
    case doubao
    case minimaxCN
    case minimaxIntl
    case bailian
    case kimi
    case openrouter
    case openai
    case gemini
    case deepseek
    case zhipu
    case claude
    case ollama
    case localQwen

    var displayName: String {
        switch self {
        case .doubao:      return L("豆包 (ByteDance ARK)", "Doubao (ByteDance ARK)")
        case .minimaxCN:   return L("MiniMax 国内", "MiniMax China")
        case .minimaxIntl: return L("MiniMax 海外", "MiniMax Global")
        case .bailian:     return L("百炼 (阿里云)", "Bailian (Alibaba Cloud)")
        case .kimi:        return L("Kimi (月之暗面)", "Kimi (Moonshot)")
        case .openrouter:  return "OpenRouter"
        case .openai:      return "OpenAI"
        case .gemini:      return "Gemini (Google)"
        case .deepseek:    return L("DeepSeek (深度求索)", "DeepSeek")
        case .zhipu:       return L("智谱 (GLM)", "Zhipu (GLM)")
        case .claude:      return "Claude (Anthropic)"
        case .ollama:      return L("Ollama (本地模型)", "Ollama (Local)")
        case .localQwen:   return L("本地 Qwen (离线)", "Local Qwen (Offline)")
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .doubao:      return "https://ark.cn-beijing.volces.com/api/v3"
        case .minimaxCN:   return "https://api.minimaxi.com/v1"
        case .minimaxIntl: return "https://api.minimax.io/v1"
        case .bailian:     return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .kimi:        return "https://api.moonshot.ai/v1"
        case .openrouter:  return "https://openrouter.ai/api/v1"
        case .openai:      return "https://api.openai.com/v1"
        case .gemini:      return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .deepseek:    return "https://api.deepseek.com"
        case .zhipu:       return "https://open.bigmodel.cn/api/paas/v4"
        case .claude:      return "https://api.anthropic.com/v1"
        case .ollama:      return "http://localhost:11434/v1"
        case .localQwen:   return "http://127.0.0.1:0/v1"  // Dynamic port from SenseVoiceServerManager
        }
    }

    /// Whether this is a local provider bundled with the app (no external service).
    var isLocal: Bool {
        self == .localQwen || self == .ollama
    }

    /// Whether this provider requires an API key for authentication.
    var requiresAPIKey: Bool {
        self != .ollama && self != .localQwen
    }

    /// 各服务商表达深度思考开关的字段不同，统一在请求层按此策略编码。
    func thinkingRequestField(for model: String) -> LLMThinkingRequestField {
        if self == .kimi, isKimiAlwaysThinkingModel(model) {
            // Kimi K3 / K2.7 Code 固定思考且会拒绝 thinking 参数，直接走模型默认行为。
            return .none
        }

        switch self {
        case .doubao, .kimi, .deepseek, .zhipu:
            // thinking: { type: "enabled" | "disabled" }
            return .thinking
        case .bailian:
            // enable_thinking: true | false
            return .enableThinking
        case .openai, .gemini, .ollama:
            // reasoning_effort: "medium" | "none"
            return .reasoningEffort
        case .openrouter:
            // reasoning: { effort: "medium" | "none" }
            return .reasoningObject
        case .localQwen:
            // Dal 内置 Qwen 服务使用自定义 think 布尔字段
            return .think
        case .claude:
            // Anthropic Messages API 的 thinking 配置由独立客户端编码
            return .claudeThinking
        default:
            // MiniMax M2+ 强制推理，不能通过请求字段关闭
            return .none
        }
    }

    /// 未保存过新开关的老配置沿用此前实际行为，避免升级后静默改变输出。
    func defaultThinkingMode(for model: String) -> LLMThinkingMode {
        fixedThinkingMode(for: model) ?? .disabled
    }

    /// 已知只能固定在某个状态的服务商；仍会在“测试连接”中真实请求一次后才判定通过。
    func fixedThinkingMode(for model: String) -> LLMThinkingMode? {
        if needsReasoningSplit
            || (self == .kimi && isKimiAlwaysThinkingModel(model))
            || (self == .gemini && isGeminiAlwaysThinkingModel(model)) {
            return .enabled
        }
        return nil
    }

    /// MiniMax M2+ models always reason and can't be turned off.
    /// reasoning_split=true separates thinking into reasoning_details field,
    /// keeping it out of delta.content so our SSE parser won't pick it up.
    var needsReasoningSplit: Bool {
        self == .minimaxCN || self == .minimaxIntl
    }

    private func isKimiAlwaysThinkingModel(_ model: String) -> Bool {
        let normalized = normalizedModelName(model)
        return normalized.hasPrefix("kimi-k3")
            || normalized.hasPrefix("kimi-k2.7-code")
    }

    private func isGeminiAlwaysThinkingModel(_ model: String) -> Bool {
        let normalized = normalizedModelName(model)
        return normalized.hasPrefix("gemini-3")
            || normalized.hasPrefix("gemini-2.5-pro")
    }

    private func normalizedModelName(_ model: String) -> String {
        model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

// MARK: - Thinking Disable Strategy

enum LLMThinkingRequestField: Equatable, Sendable {
    /// `thinking: { type: "enabled" | "disabled" }` — Doubao, Kimi, DeepSeek, Zhipu
    case thinking
    /// `enable_thinking: Bool` — Bailian (Qwen)
    case enableThinking
    /// `reasoning_effort: "medium" | "none"` — OpenAI compatible reasoning models
    case reasoningEffort
    /// `reasoning: { effort: ... }` — OpenRouter unified reasoning API
    case reasoningObject
    /// `think: Bool` — Dal bundled Qwen service
    case think
    /// Anthropic Messages API extended thinking
    case claudeThinking
    /// No switch field; provider/model is fixed or unverifiable
    case none

    var isExplicitlyControllable: Bool {
        self != .none
    }
}

// MARK: - Provider Config Protocol

protocol LLMProviderConfig: Sendable {
    static var provider: LLMProvider { get }
    static var credentialFields: [CredentialField] { get }

    init?(credentials: [String: String])
    func toCredentials() -> [String: String]
    func toLLMConfig() -> LLMConfig
}
