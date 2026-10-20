import Foundation

enum LLMBaseURLValidator {
    static func normalizedURL(
        rawValue: String,
        defaultValue: String,
        provider: LLMProvider
    ) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = value.isEmpty ? defaultValue : value
        return try? LLMEndpointPolicy.normalizedBaseURL(
            rawValue: candidate,
            provider: provider
        ).absoluteString
    }
}
