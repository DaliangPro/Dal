import Foundation
import XCTest
@testable import Dal

final class LLMEndpointPolicyTests: XCTestCase {
    func testCloudProviderRejectsHTTP() {
        for value in ["http://api.deepseek.com/v1", "http://127.0.0.1:8080/v1"] {
            XCTAssertThrowsError(
                try LLMEndpointPolicy.normalizedBaseURL(
                    rawValue: value,
                    provider: .deepseek
                ),
                value
            )
        }
    }

    func testCloudProviderAcceptsHTTPSAndNormalizesRepeatedSlashes() throws {
        let url = try LLMEndpointPolicy.normalizedBaseURL(
            rawValue: " https://api.deepseek.com//v1/// ",
            provider: .deepseek
        )

        XCTAssertEqual(url.absoluteString, "https://api.deepseek.com/v1")
    }

    func testOllamaAllowsOnlyExactLoopbackHostsForHTTP() throws {
        for value in [
            "http://localhost:11434/v1",
            "http://127.0.0.1:11434/v1",
            "http://[::1]:11434/v1",
        ] {
            XCTAssertNoThrow(
                try LLMEndpointPolicy.normalizedBaseURL(rawValue: value, provider: .ollama),
                value
            )
        }

        for value in [
            "http://0.0.0.0:11434/v1",
            "http://127.0.0.2:11434/v1",
            "http://192.168.1.8:11434/v1",
            "http://ollama.local:11434/v1",
        ] {
            XCTAssertThrowsError(
                try LLMEndpointPolicy.normalizedBaseURL(rawValue: value, provider: .ollama),
                value
            )
        }
    }

    func testOllamaMayUseHTTPSForRemoteEndpoint() throws {
        let url = try LLMEndpointPolicy.normalizedBaseURL(
            rawValue: "https://ollama.example.com/v1",
            provider: .ollama
        )
        XCTAssertEqual(url.absoluteString, "https://ollama.example.com/v1")
    }

    func testLocalQwenRequiresCurrentPortAndExactBasePath() throws {
        let valid = try LLMEndpointPolicy.normalizedBaseURL(
            rawValue: "http://127.0.0.1:52123/v1/",
            provider: .localQwen,
            localQwenPort: 52_123
        )
        XCTAssertEqual(valid.absoluteString, "http://127.0.0.1:52123/v1")

        for value in [
            "http://localhost:52123/v1",
            "http://127.0.0.1:52124/v1",
            "http://127.0.0.1:52123",
            "http://127.0.0.1:52123/v1/extra",
            "https://127.0.0.1:52123/v1",
        ] {
            XCTAssertThrowsError(
                try LLMEndpointPolicy.normalizedBaseURL(
                    rawValue: value,
                    provider: .localQwen,
                    localQwenPort: 52_123
                ),
                value
            )
        }
    }

    func testURLCredentialsFragmentEmptyHostAndInvalidPortAreRejected() {
        for value in [
            "https://user:pass@api.example.com/v1",
            "https://api.example.com/v1#secret",
            "https:///v1",
            "https://api.example.com:/v1",
            "https://api.example.com:70000/v1",
            "https://api.example.com:999999999999999999999999/v1",
        ] {
            XCTAssertThrowsError(
                try LLMEndpointPolicy.normalizedBaseURL(rawValue: value, provider: .openai),
                value
            )
        }
    }

    func testEndpointIsBuiltWithURLPathComponents() throws {
        let base = try LLMEndpointPolicy.normalizedBaseURL(
            rawValue: "https://api.example.com//api/v1//",
            provider: .openai
        )
        let endpoint = try LLMEndpointPolicy.endpoint(
            baseURL: base,
            pathComponents: ["chat", "completions"]
        )

        XCTAssertEqual(endpoint.absoluteString, "https://api.example.com/api/v1/chat/completions")
    }

    func testCredentialsAreValidatedAndNormalizedBeforeStorage() throws {
        let normalized = try KeychainService.normalizedLLMCredentialsForStorage(
            provider: .deepseek,
            values: [
                "apiKey": " secret ",
                "model": " model ",
                "baseURL": " https://api.deepseek.com//v1/ ",
            ]
        )

        XCTAssertEqual(normalized["apiKey"], "secret")
        XCTAssertEqual(normalized["model"], "model")
        XCTAssertEqual(normalized["baseURL"], "https://api.deepseek.com/v1")

        XCTAssertThrowsError(
            try KeychainService.normalizedLLMCredentialsForStorage(
                provider: .deepseek,
                values: ["apiKey": "secret", "model": "model", "baseURL": "http://example.com/v1"]
            )
        )
    }

    func testDedicatedSessionIsEphemeralAndDoesNotPersistCookiesOrCache() {
        let configuration = LLMNetworkSession.makeConfiguration()

        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertGreaterThan(configuration.timeoutIntervalForRequest, 0)
        XCTAssertGreaterThanOrEqual(
            configuration.timeoutIntervalForResource,
            configuration.timeoutIntervalForRequest
        )
    }

    func testLocalQwenAuthorizationHeaderIsPresent() throws {
        let url = try LLMEndpointPolicy.endpoint(
            baseURL: LLMEndpointPolicy.normalizedBaseURL(
                rawValue: "http://127.0.0.1:52123/v1",
                provider: .localQwen,
                localQwenPort: 52_123
            ),
            pathComponents: ["chat", "completions"]
        )
        var request = URLRequest(url: url)

        DoubaoChatClient.authorizeLocalServiceRequest(&request, provider: .localQwen)

        XCTAssertEqual(
            request.value(forHTTPHeaderField: LocalServiceAuth.headerName),
            LocalServiceAuth.token
        )
    }

    func testAPIErrorBodyIsBoundedAndRedactsJSONHeaderAndQuerySecrets() {
        let source = #"{"api_key":"sk-json-secret","token":"local-secret","message":"Authorization: Bearer header-secret https://example.com/fail?access_key=query-secret&safe=ok"}"#
            + String(repeating: "x", count: 1_000)

        let sanitized = LLMNetworkSession.sanitizedErrorBody(Data(source.utf8), limit: 512)

        XCTAssertLessThanOrEqual(sanitized.utf8.count, 512)
        XCTAssertFalse(sanitized.contains("sk-json-secret"))
        XCTAssertFalse(sanitized.contains("local-secret"))
        XCTAssertFalse(sanitized.contains("header-secret"))
        XCTAssertFalse(sanitized.contains("query-secret"))
    }

    func testErrorBodyRedactionHandlesTruncatedJSONAndSecretAliases() {
        let source = #"{"access_token":"access-secret","client_secret":"client-secret","password":"password-secret","message":"ok"}"#
        let truncatedInsideFirstSecret = Data(source.utf8).prefix(30)

        let partial = LLMNetworkSession.sanitizedErrorBody(
            Data(truncatedInsideFirstSecret),
            limit: 30
        )
        let complete = LLMNetworkSession.sanitizedErrorBody(Data(source.utf8), limit: 512)

        XCTAssertFalse(partial.contains("access-sec"))
        XCTAssertFalse(complete.contains("access-secret"))
        XCTAssertFalse(complete.contains("client-secret"))
        XCTAssertFalse(complete.contains("password-secret"))
    }

    func testNetworkReadersRetainOnlyBoundedResponseBytes() async throws {
        let prefix = try await LLMNetworkSession.readPrefix(
            byteStream("abcdef"),
            limit: 3
        )
        XCTAssertEqual(String(decoding: prefix, as: UTF8.self), "abc")

        do {
            _ = try await LLMNetworkSession.readCapped(byteStream("abcd"), limit: 3)
            XCTFail("expected responseTooLarge")
        } catch LLMError.responseTooLarge(let maximum) {
            XCTAssertEqual(maximum, 3)
        }
    }

    func testSSEByteDecoderRejectsOversizedLineAndTotalWireBytes() throws {
        var lineDecoder = SSEByteStreamDecoder(maximumTotalBytes: 100, maximumLineBytes: 4)
        XCTAssertThrowsError(
            try "12345".utf8.forEach { byte in
                _ = try lineDecoder.consume(byte: byte)
            }
        ) { error in
            guard case LLMError.responseTooLarge = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        var totalDecoder = SSEByteStreamDecoder(maximumTotalBytes: 5, maximumLineBytes: 20)
        XCTAssertThrowsError(
            try "a\nb\ncd".utf8.forEach { byte in
                _ = try totalDecoder.consume(byte: byte)
            }
        ) { error in
            guard case LLMError.responseTooLarge = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testDedicatedSessionBlocksHTTPRedirects() {
        let session = LLMNetworkSession.makeSession()
        XCTAssertTrue(session.delegate is LLMRedirectBlockingDelegate)
        session.invalidateAndCancel()
    }

    func testDefaultSecureSessionIsSharedSoWarmupConnectionCanBeReused() {
        XCTAssertTrue(LLMNetworkSession.shared === LLMNetworkSession.shared)
        XCTAssertTrue(LLMNetworkSession.shared.delegate is LLMRedirectBlockingDelegate)
    }

    private func byteStream(_ text: String) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for byte in text.utf8 {
                continuation.yield(byte)
            }
            continuation.finish()
        }
    }
}
