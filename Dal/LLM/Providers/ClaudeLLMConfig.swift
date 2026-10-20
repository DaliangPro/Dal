import Foundation

struct ClaudeLLMConfig: LLMProviderConfig, Sendable {

    static let provider = LLMProvider.claude

    static var credentialFields: [CredentialField] {[
        CredentialField(
            key: "apiKey", label: "API Key",
            placeholder: "sk-ant-...",
            isSecure: true, isOptional: false, defaultValue: ""
        ),
        CredentialField(
            key: "model", label: L("模型", "Model"),
            placeholder: "claude-sonnet-4-5-20250514",
            isSecure: false, isOptional: false, defaultValue: ""
        ),
        CredentialField(
            key: "baseURL", label: "Base URL",
            placeholder: "https://api.anthropic.com/v1",
            isSecure: false, isOptional: true, defaultValue: "https://api.anthropic.com/v1"
        ),
    ]}

    let apiKey: String
    let model: String
    let baseURL: String

    init?(credentials: [String: String]) {
        let key = (credentials["apiKey"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (credentials["model"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !model.isEmpty else { return nil }
        self.apiKey = key
        self.model = model
        let rawURL = (credentials["baseURL"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = LLMBaseURLValidator.normalizedURL(
            rawValue: rawURL,
            defaultValue: LLMProvider.claude.defaultBaseURL,
            provider: .claude
        ) else { return nil }
        self.baseURL = baseURL
    }

    func toCredentials() -> [String: String] {
        ["apiKey": apiKey, "model": model, "baseURL": baseURL]
    }

    func toLLMConfig() -> LLMConfig {
        LLMConfig(apiKey: apiKey, model: model, baseURL: baseURL)
    }
}
