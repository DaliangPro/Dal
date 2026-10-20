import Security
import XCTest
@testable import Dal

final class VoicePolishQualityAuthorizationTests: XCTestCase {
    private let flag = VoicePolishQualityAuthorization.argument

    func test授权入口在生产App构造之前分流且不会进入质量跑测() throws {
        let arguments = ["Dal", flag, "--provider", "deepseek"]
        XCTAssertTrue(VoicePolishQualityRunner.isRequested(arguments: arguments))
        XCTAssertEqual(try VoicePolishQualityAuthorization.requestedProvider(arguments: arguments), .deepseek)
        XCTAssertNil(try VoicePolishQualityRunner.parseInvocation(arguments: arguments))
        XCTAssertNil(try VoicePolishQualityAuthorization.requestedProvider(arguments: ["Dal"]))
    }

    func test拒绝同时授权与调用模型() {
        let arguments = ["Dal", flag, "--provider", "deepseek", "--voice-polish-quality-run"]
        XCTAssertThrowsError(try VoicePolishQualityAuthorization.requestedProvider(arguments: arguments))
        XCTAssertThrowsError(try VoicePolishQualityRunner.parseInvocation(arguments: arguments))
    }

    func test必须明确有效云端授权对象() {
        for suffix in [[], ["--provider"], ["--provider", "unknown"], ["--provider", "localQwen"]] {
            XCTAssertThrowsError(try VoicePolishQualityAuthorization.requestedProvider(arguments: ["Dal", flag] + suffix))
        }
    }

    func test授权测试使用隔离后端且只返回状态码() throws {
        XCTAssertTrue(KeychainService.isUsingIsolatedTestStorage)
        let provider = LLMProvider.deepseek
        let original = KeychainService.loadLLMCredentials(for: provider)
        defer {
            if let original {
                try? KeychainService.saveLLMCredentials(for: provider, values: original)
            } else {
                KeychainService.delete(key: "tf_llm_deepseek")
            }
        }
        KeychainService.delete(key: "tf_llm_deepseek")
        XCTAssertEqual(KeychainService.authorizeLLMCredentialAccess(for: provider), errSecItemNotFound)
        try KeychainService.saveLLMCredentials(for: provider, values: ["apiKey": "仅用于隔离测试", "model": "test-model"])
        XCTAssertEqual(KeychainService.authorizeLLMCredentialAccess(for: provider), errSecSuccess)
        XCTAssertEqual(KeychainService.authorizeLLMCredentialAccess(for: .localQwen), errSecParam)
    }
}
