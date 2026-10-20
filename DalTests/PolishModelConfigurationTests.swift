import XCTest
@testable import Dal

final class PolishModelConfigurationTests: XCTestCase {
    func testLegacyConfigurationIsInheritedWithoutMutatingIt() throws {
        try KeychainService.withIsolatedPolishSettingsForTesting(legacyOverride: "old-polish") {
            KeychainService.selectedLLMProvider = .bailian
            try KeychainService.saveLLMCredentials(for: .bailian, values: credentials("old-text", "old-key"))
            for role in PolishModelRole.allCases {
                XCTAssertEqual(KeychainService.selectedPolishProvider(for: role), .bailian)
                let config = try XCTUnwrap(KeychainService.loadPolishConfig(for: role))
                XCTAssertEqual(config.model, "old-polish")
                XCTAssertEqual(config.apiKey, "old-key")
                XCTAssertEqual(config.thinkingMode, .disabled)
            }
            XCTAssertEqual(KeychainService.loadLLMCredentials(for: .bailian)?["model"], "old-text")
        }
    }

    func testSameProviderCredentialsAndModelsRemainIndependent() throws {
        try KeychainService.withIsolatedPolishSettingsForTesting(legacyOverride: "old-polish") {
            KeychainService.selectedLLMProvider = .bailian
            try KeychainService.saveLLMCredentials(for: .bailian, values: credentials("old-text", "old-key"))
            try KeychainService.savePolishCredentials(for: .bailian, role: .light, values: credentials("fast-model", "fast-key"))
            XCTAssertEqual(KeychainService.loadPolishConfig(for: .light)?.model, "fast-model")
            XCTAssertEqual(KeychainService.loadPolishConfig(for: .standard)?.model, "old-polish")
            try KeychainService.savePolishCredentials(for: .bailian, role: .standard, values: credentials("quality-model", "quality-key"))
            XCTAssertEqual(KeychainService.loadPolishConfig(for: .light)?.apiKey, "fast-key")
            XCTAssertEqual(KeychainService.loadPolishConfig(for: .standard)?.apiKey, "quality-key")
            XCTAssertEqual(KeychainService.loadPolishConfig(for: .standard)?.model, "quality-model")
            XCTAssertEqual(KeychainService.loadLLMCredentials(for: .bailian)?["apiKey"], "old-key")
        }
    }

    func testProviderSelectionsAndModeRoutesAreIndependent() throws {
        try KeychainService.withIsolatedPolishSettingsForTesting {
            KeychainService.selectedLLMProvider = .bailian
            KeychainService.setSelectedPolishProvider(.deepseek, for: .light)
            KeychainService.setSelectedPolishProvider(.bailian, for: .standard)
            try KeychainService.savePolishCredentials(for: .deepseek, role: .light, values: credentials("fast", "key-a"))
            try KeychainService.savePolishCredentials(for: .bailian, role: .standard, values: credentials("standard", "key-b"))
            XCTAssertEqual(KeychainService.selectedPolishProvider(for: .resolve(.light)), .bailian)
            XCTAssertEqual(KeychainService.selectedPolishProvider(for: .resolve(.standard)), .bailian)
            XCTAssertEqual(KeychainService.loadPolishConfig(for: .resolve(.light))?.model, "standard")
            XCTAssertEqual(KeychainService.loadPolishConfig(for: .resolve(.standard))?.model, "standard")
            XCTAssertEqual(PolishModelRole.resolve(nil), .standard)
        }
    }

    func testUnavailableSavedCredentialsCannotSilentlyFallbackToLegacy() throws {
        try KeychainService.withIsolatedPolishSettingsForTesting {
            KeychainService.selectedLLMProvider = .bailian
            try KeychainService.saveLLMCredentials(for: .bailian, values: credentials("legacy", "legacy-key"))
            try KeychainService.savePolishCredentials(for: .bailian, role: .light, values: credentials("chosen", "chosen-key"))
            KeychainService.delete(key: KeychainService.polishStorageKey(role: .light, provider: .bailian))
            XCTAssertNil(KeychainService.loadPolishConfig(for: .light))
            XCTAssertEqual(KeychainService.loadPolishConfig(for: .standard)?.model, "legacy")
        }
    }

    func testConnectionTestUsesOneActualGenerationWithThinkingDisabled() async throws {
        for role in PolishModelRole.allCases {
            let client = PolishConnectionSpy()
            try await PolishModelConnectionTester.test(role: role, config: LLMConfig(apiKey: "test", model: "test-model", thinkingMode: .enabled), client: client)
            let requests = await client.requests
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.0.options.reasoningPolicy, .disabled)
            XCTAssertEqual(requests.first?.0.task, role == .light ? .voicePolishRender : .voicePolishStructured)
            XCTAssertEqual(requests.first?.1.thinkingMode, .disabled)
        }
    }

    @MainActor
    func testConnectionStatesDoNotOverwriteOtherRole() {
        let old = ModelConnectivityCache.polish
        defer { ModelConnectivityCache.polish = old }
        let signature = LLMConnectivitySignature(provider: .bailian, config: LLMConfig(apiKey: "test", model: "test"))
        ModelConnectivityCache.polish[.light] = LLMConnectivityCacheEntry(signature: signature, status: .success)
        ModelConnectivityCache.polish[.standard] = LLMConnectivityCacheEntry(signature: signature, status: .failed("test error"))
        XCTAssertEqual(ModelConnectivityCache.polish[.light]?.status, .success)
        XCTAssertEqual(ModelConnectivityCache.polish[.standard]?.status, .failed("test error"))
    }

    private func credentials(_ model: String, _ key: String) -> [String: String] {
        ["model": model, "apiKey": key, "baseURL": "https://example.com/v1"]
    }
}

private actor PolishConnectionSpy: LLMClient {
    var requests: [(LLMRequest, LLMConfig)] = []
    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        requests.append((request, config))
        return LLMResponse(text: "连接正常", model: config.model)
    }
    func process(text: String, prompt: String, context: LLMRequestContext, config: LLMConfig) async throws -> String {
        XCTFail("连接测试不应走额外处理路径")
        return ""
    }
    func warmUp(baseURL: String) async {}
}
