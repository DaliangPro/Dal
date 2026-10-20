import Foundation

enum LLMProviderRegistry {

    static let all: [LLMProvider: any LLMProviderConfig.Type] = [
        .doubao:      OpenAICompatibleLLMConfig<DoubaoLLMTag>.self,
        .minimaxCN:   OpenAICompatibleLLMConfig<MinimaxCNLLMTag>.self,
        .minimaxIntl: OpenAICompatibleLLMConfig<MinimaxIntlLLMTag>.self,
        .bailian:     OpenAICompatibleLLMConfig<BailianLLMTag>.self,
        .kimi:        OpenAICompatibleLLMConfig<KimiLLMTag>.self,
        .openrouter:  OpenAICompatibleLLMConfig<OpenRouterLLMTag>.self,
        .openai:      OpenAICompatibleLLMConfig<OpenAILLMTag>.self,
        .gemini:      OpenAICompatibleLLMConfig<GeminiLLMTag>.self,
        .deepseek:    OpenAICompatibleLLMConfig<DeepSeekLLMTag>.self,
        .zhipu:       OpenAICompatibleLLMConfig<ZhipuLLMTag>.self,
        .claude:      ClaudeLLMConfig.self,
        .ollama:      OpenAICompatibleLLMConfig<OllamaLLMTag>.self,
        .localQwen:   LocalQwenLLMConfig.self,
    ]

    static func configType(for provider: LLMProvider) -> (any LLMProviderConfig.Type)? {
        all[provider]
    }

    /// 按 provider 返回合适的 LLM 客户端：Claude 用独立客户端，其余走 OpenAI 兼容的 DoubaoChatClient。
    static func makeClient(for provider: LLMProvider) -> any LLMClient {
        provider == .claude ? ClaudeChatClient() : DoubaoChatClient(provider: provider)
    }
}
