import Foundation

enum LLMTask: String, Sendable, Equatable {
    case generic
    case voicePolishFast
    case voicePolishStructured
    case voicePolishAnalyze
    case voicePolishRender
    case voicePolishRepair
}

enum ReasoningPolicy: String, Sendable, Equatable {
    case disabled
    case low
    case providerDefault
}

enum LLMResponseFormat: Sendable, Equatable {
    case text
    case jsonObject
}

struct LLMGenerationOptions: Sendable, Equatable {
    let temperature: Double?
    let maxOutputTokens: Int?
    let reasoningPolicy: ReasoningPolicy
    let responseFormat: LLMResponseFormat

    init(
        temperature: Double? = nil,
        maxOutputTokens: Int? = nil,
        reasoningPolicy: ReasoningPolicy = .providerDefault,
        responseFormat: LLMResponseFormat = .text
    ) {
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.reasoningPolicy = reasoningPolicy
        self.responseFormat = responseFormat
    }
}

struct LLMRequest: Sendable, Equatable {
    let context: LLMRequestContext
    let task: LLMTask
    let system: String?
    let user: String
    let options: LLMGenerationOptions
}

struct LLMResponse: Sendable, Equatable {
    let text: String
    let model: String
}

/// Common interface for LLM clients (OpenAI-compatible and Claude).
protocol LLMClient: Sendable {
    /// 单次任务级生成。生产客户端一次调用只能发出一次真实请求；Voice Polish
    /// 的格式修复、能力降级和内容 Repair 均由上层统一预算决定。
    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse

    func process(
        text: String,
        prompt: String,
        context: LLMRequestContext,
        config: LLMConfig
    ) async throws -> String
    func probeThinkingMode(config: LLMConfig) async throws -> LLMThinkingProbeEvidence
    func warmUp(baseURL: String) async
}

extension LLMClient {
    /// 兼容现有测试替身。正式 Provider 客户端必须覆盖，避免 process 内部的
    /// 能力兼容重试绕过 Voice Polish 调用预算。
    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        let text = try await process(
            text: request.user,
            prompt: request.system ?? "",
            context: request.context,
            config: config
        )
        return LLMResponse(text: text, model: config.model)
    }

    /// 测试替身及不提供结构化推理信息的客户端可复用基础连通测试；
    /// 正式云端客户端会覆盖此实现并返回推理证据。
    func probeThinkingMode(config: LLMConfig) async throws -> LLMThinkingProbeEvidence {
        _ = try await process(
            text: LLMThinkingModeValidator.probeText,
            prompt: "{text}",
            context: .connectivityProbe,
            config: config
        )
        return .unknown
    }
}

extension String {
    func removingPromptTextPlaceholder() -> String {
        self
            .replacingOccurrences(of: "{{text}}", with: "")
            .replacingOccurrences(of: "{text}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func separatedLLMMessages(with text: String) -> (system: String?, user: String) {
        let system = removingPromptTextPlaceholder()
        let user = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (system.isEmpty ? nil : system, user)
    }

    /// Remove `<think>...</think>` reasoning blocks emitted by models like DeepSeek.
    /// Handles both closed tags and unclosed/truncated tags.
    func strippingThinkTags() -> String {
        self
            .replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<think>[\\s\\S]*$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
