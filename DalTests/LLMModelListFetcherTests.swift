import XCTest
@testable import Dal

/// 获取模型列表：地址规范化与响应解析
final class LLMModelListFetcherTests: XCTestCase {

    func testNormalizedAppendsV1WhenMissing() {
        XCTAssertEqual(LLMModelListFetcher.normalized("https://api.deepseek.com"), "https://api.deepseek.com/v1")
        XCTAssertEqual(LLMModelListFetcher.normalized("https://api.deepseek.com/"), "https://api.deepseek.com/v1")
    }

    func testNormalizedKeepsExistingVersionSegments() {
        XCTAssertEqual(LLMModelListFetcher.normalized("https://api.openai.com/v1"), "https://api.openai.com/v1")
        XCTAssertEqual(LLMModelListFetcher.normalized("https://ark.cn-beijing.volces.com/api/v3"), "https://ark.cn-beijing.volces.com/api/v3")
        XCTAssertEqual(LLMModelListFetcher.normalized("https://open.bigmodel.cn/api/paas/v4"), "https://open.bigmodel.cn/api/paas/v4")
        XCTAssertEqual(LLMModelListFetcher.normalized("https://generativelanguage.googleapis.com/v1beta/openai"), "https://generativelanguage.googleapis.com/v1beta/openai")
        XCTAssertEqual(LLMModelListFetcher.normalized("https://dashscope.aliyuncs.com/compatible-mode/v1"), "https://dashscope.aliyuncs.com/compatible-mode/v1")
    }

    func testParseOpenAIStyleResponse() {
        let json = #"{"object":"list","data":[{"id":"deepseek-chat"},{"id":"deepseek-reasoner"}]}"#
        XCTAssertEqual(
            LLMModelListFetcher.parseModelIDs(from: Data(json.utf8)),
            ["deepseek-chat", "deepseek-reasoner"]
        )
    }

    func testParseModelsKeyAndNameFallback() {
        let json = #"{"models":[{"name":"qwen3.5:14b"},{"id":"llama4"}]}"#
        XCTAssertEqual(
            LLMModelListFetcher.parseModelIDs(from: Data(json.utf8)),
            ["llama4", "qwen3.5:14b"]
        )
    }

    func testParseGarbageReturnsEmpty() {
        XCTAssertTrue(LLMModelListFetcher.parseModelIDs(from: Data("not json".utf8)).isEmpty)
    }
}
