import Foundation

struct LLMCapabilityKey: Hashable, Sendable {
    let provider: LLMProvider
    let model: String
    let normalizedBaseURL: String
}

struct LLMProviderCapabilities: Sendable, Equatable {
    let supportsTemperature: Bool
    let supportsJSONMode: Bool
    let supportsReasoningControl: Bool
    let supportsDynamicMaxTokens: Bool
}

enum LLMProviderCapabilityResolver {

    static func key(provider: LLMProvider, config: LLMConfig) -> LLMCapabilityKey {
        let normalizedBaseURL = config.baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        return LLMCapabilityKey(
            provider: provider,
            model: config.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            normalizedBaseURL: normalizedBaseURL
        )
    }

    static func capabilities(
        provider: LLMProvider,
        config: LLMConfig
    ) -> LLMProviderCapabilities {
        let capabilityKey = key(provider: provider, config: config)
        let model = capabilityKey.model
        let isFirstParty = isFirstPartyEndpoint(
            provider: provider,
            normalizedBaseURL: capabilityKey.normalizedBaseURL
        )
        let supportsJSONMode: Bool
        switch provider {
        case .openai:
            supportsJSONMode = isFirstParty
                && hasAnyPrefix(model, ["gpt-4", "gpt-5", "o1", "o3", "o4"])
        case .bailian:
            supportsJSONMode = isFirstParty && model.hasPrefix("qwen")
        case .gemini:
            supportsJSONMode = isFirstParty && model.hasPrefix("gemini-")
        case .deepseek:
            supportsJSONMode = isFirstParty && model.hasPrefix("deepseek-")
        case .zhipu:
            supportsJSONMode = isFirstParty && model.hasPrefix("glm-")
        default:
            // OpenAI 兼容并不代表具体端点/模型接受 response_format。
            // 未被第一方文档确认的组合继续依赖 Prompt + 本地解码校验。
            supportsJSONMode = false
        }

        let reasoningModel = model.contains("reasoner")
            || model.contains("thinking")
            || hasAnyPrefix(model, ["o1", "o3", "o4", "gpt-5"])
        let supportsSampling = isFirstParty
            && !reasoningModel
            && provider != .claude
            && provider != .minimaxCN
            && provider != .minimaxIntl

        let supportsDynamicMaxTokens: Bool
        switch provider {
        case .doubao, .bailian, .kimi, .gemini, .deepseek, .zhipu:
            supportsDynamicMaxTokens = isFirstParty
        case .ollama, .localQwen:
            supportsDynamicMaxTokens = true
        default:
            // OpenAI 新推理模型使用 max_completion_tokens；在字段模型化前不发送
            // 旧 max_tokens，避免为了兼容而发生隐藏重试。
            supportsDynamicMaxTokens = false
        }

        return LLMProviderCapabilities(
            supportsTemperature: supportsSampling,
            supportsJSONMode: supportsJSONMode,
            supportsReasoningControl: provider.thinkingRequestField(for: config.model)
                .isExplicitlyControllable,
            supportsDynamicMaxTokens: supportsDynamicMaxTokens
        )
    }

    private static func hasAnyPrefix(_ value: String, _ prefixes: [String]) -> Bool {
        prefixes.contains(where: value.hasPrefix)
    }

    private static func isFirstPartyEndpoint(
        provider: LLMProvider,
        normalizedBaseURL: String
    ) -> Bool {
        let expectedHost: String?
        switch provider {
        case .doubao: expectedHost = "ark.cn-beijing.volces.com"
        case .minimaxCN: expectedHost = "api.minimaxi.com"
        case .minimaxIntl: expectedHost = "api.minimax.io"
        case .bailian: expectedHost = "dashscope.aliyuncs.com"
        case .kimi: expectedHost = "api.moonshot.ai"
        case .openrouter: expectedHost = "openrouter.ai"
        case .openai: expectedHost = "api.openai.com"
        case .gemini: expectedHost = "generativelanguage.googleapis.com"
        case .deepseek: expectedHost = "api.deepseek.com"
        case .zhipu: expectedHost = "open.bigmodel.cn"
        case .claude: expectedHost = "api.anthropic.com"
        case .ollama, .localQwen: expectedHost = nil
        }
        guard let expectedHost,
              let host = URL(string: normalizedBaseURL)?.host?.lowercased()
        else { return false }
        return host == expectedHost
    }
}
