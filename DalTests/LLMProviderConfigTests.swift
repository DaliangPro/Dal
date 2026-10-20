import XCTest
@testable import Dal

final class LLMProviderConfigTests: XCTestCase {

    func testOpenAICompatibleConfigTrimsCredentialWhitespace() throws {
        let config = try XCTUnwrap(OpenAICompatibleLLMConfig<DeepSeekLLMTag>(credentials: [
            "apiKey": " sk-test ",
            "model": " deepseek-v4-flash ",
            "baseURL": " https://api.deepseek.com ",
        ]))

        XCTAssertEqual(config.apiKey, "sk-test")
        XCTAssertEqual(config.model, "deepseek-v4-flash")
        XCTAssertEqual(config.baseURL, "https://api.deepseek.com")
    }

    func testClaudeConfigTrimsCredentialWhitespace() throws {
        let config = try XCTUnwrap(ClaudeLLMConfig(credentials: [
            "apiKey": " sk-ant-test ",
            "model": " claude-sonnet-4-5-20250514 ",
            "baseURL": " https://api.anthropic.com/v1 ",
        ]))

        XCTAssertEqual(config.apiKey, "sk-ant-test")
        XCTAssertEqual(config.model, "claude-sonnet-4-5-20250514")
        XCTAssertEqual(config.baseURL, "https://api.anthropic.com/v1")
    }

    func testOpenAICompatibleConfigRejectsRemoteHTTPBaseURL() {
        let config = OpenAICompatibleLLMConfig<DeepSeekLLMTag>(credentials: [
            "apiKey": "sk-test",
            "model": "deepseek-v4-flash",
            "baseURL": "http://api.deepseek.com",
        ])

        XCTAssertNil(config)
    }

    func testOllamaConfigAllowsLoopbackHTTPBaseURL() throws {
        let config = try XCTUnwrap(OpenAICompatibleLLMConfig<OllamaLLMTag>(credentials: [
            "apiKey": "",
            "model": "llama3.2",
            "baseURL": "http://127.0.0.1:11434/v1",
        ]))

        XCTAssertEqual(config.baseURL, "http://127.0.0.1:11434/v1")
    }

    func testClaudeConfigRejectsURLCredentials() {
        let config = ClaudeLLMConfig(credentials: [
            "apiKey": "sk-ant-test",
            "model": "claude-sonnet-4-5-20250514",
            "baseURL": "https://user:pass@api.anthropic.com/v1",
        ])

        XCTAssertNil(config)
    }
}
