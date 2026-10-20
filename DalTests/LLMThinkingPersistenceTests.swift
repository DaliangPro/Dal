import XCTest
@testable import Dal

final class LLMThinkingPersistenceTests: XCTestCase {

    func testThinkingPreferenceIsIsolatedByProviderAndModel() {
        let provider = LLMProvider.deepseek
        let firstModel = "thinking-pref-first"
        let secondModel = "thinking-pref-second"
        defer {
            for model in [firstModel, secondModel] {
                KeychainService.removeLLMThinkingMode(
                    role: .textProcessing,
                    provider: provider,
                    model: model
                )
            }
        }

        KeychainService.saveLLMThinkingMode(
            .enabled,
            role: .textProcessing,
            provider: provider,
            model: firstModel
        )

        XCTAssertEqual(
            KeychainService.loadLLMThinkingMode(
                role: .textProcessing,
                provider: provider,
                model: firstModel
            ),
            .enabled
        )
        XCTAssertEqual(
            KeychainService.loadLLMThinkingMode(
                role: .textProcessing,
                provider: provider,
                model: secondModel
            ),
            .disabled
        )
    }

    func testLegacyDefaultsPreservePreviousProviderBehavior() {
        XCTAssertEqual(
            KeychainService.loadLLMThinkingMode(
                role: .textProcessing,
                provider: .deepseek,
                model: "unsaved-deepseek-model"
            ),
            .disabled
        )
        XCTAssertEqual(
            KeychainService.loadLLMThinkingMode(
                role: .textProcessing,
                provider: .minimaxCN,
                model: "unsaved-minimax-model"
            ),
            .enabled
        )
        XCTAssertEqual(
            KeychainService.loadLLMThinkingMode(
                role: .textProcessing,
                provider: .kimi,
                model: "kimi-k3"
            ),
            .enabled
        )
        XCTAssertEqual(
            KeychainService.loadLLMThinkingMode(
                role: .textProcessing,
                provider: .kimi,
                model: "kimi-k2.6"
            ),
            .disabled
        )
        XCTAssertEqual(
            KeychainService.loadLLMThinkingMode(
                role: .textProcessing,
                provider: .gemini,
                model: "gemini-3.6-flash"
            ),
            .enabled
        )
        XCTAssertEqual(
            KeychainService.loadLLMThinkingMode(
                role: .textProcessing,
                provider: .gemini,
                model: "gemini-2.5-flash"
            ),
            .disabled
        )
    }

    func testLoadedLLMConfigCarriesPersistedThinkingMode() throws {
        let provider = LLMProvider.openai
        let model = "thinking-config-model"
        let originalProvider = KeychainService.selectedLLMProvider
        let originalCredentials = KeychainService.loadLLMCredentials(for: provider)
        defer {
            KeychainService.selectedLLMProvider = originalProvider
            KeychainService.removeLLMThinkingMode(
                role: .textProcessing,
                provider: provider,
                model: model
            )
            if let originalCredentials {
                try? KeychainService.saveLLMCredentials(
                    for: provider,
                    values: originalCredentials
                )
            } else {
                KeychainService.delete(key: "tf_llm_\(provider.rawValue)")
            }
        }

        try KeychainService.saveLLMCredentials(for: provider, values: [
            "apiKey": "sk-test",
            "model": model,
            "baseURL": provider.defaultBaseURL,
        ])
        KeychainService.saveLLMThinkingMode(
            .enabled,
            role: .textProcessing,
            provider: provider,
            model: model
        )
        KeychainService.selectedLLMProvider = provider

        let config = try XCTUnwrap(KeychainService.loadLLMConfig())
        XCTAssertEqual(config.model, model)
        XCTAssertEqual(config.thinkingMode, .enabled)
    }

    func testConnectivitySignatureChangesWithThinkingMode() {
        let disabled = LLMConfig(
            apiKey: "test",
            model: "model",
            baseURL: "https://example.com/v1",
            thinkingMode: .disabled
        )
        let enabled = disabled.withThinkingMode(.enabled)

        XCTAssertNotEqual(
            LLMConnectivitySignature(provider: .openai, config: disabled),
            LLMConnectivitySignature(provider: .openai, config: enabled)
        )
    }

    func testConnectivitySignatureChangesWithAPIKeyWithoutRetainingPlaintext() {
        let first = LLMConfig(
            apiKey: "first-key",
            model: "model",
            baseURL: "https://example.com/v1",
            thinkingMode: .disabled
        )
        let second = LLMConfig(
            apiKey: "second-key",
            model: "model",
            baseURL: "https://example.com/v1",
            thinkingMode: .disabled
        )

        XCTAssertNotEqual(
            LLMConnectivitySignature(provider: .openai, config: first),
            LLMConnectivitySignature(provider: .openai, config: second)
        )
    }
}
