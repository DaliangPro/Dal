import Foundation
import XCTest
@testable import Dal

final class LocalServiceAuthTests: XCTestCase {
    func testAuthorizeWritesLocalTokenHeaderWithoutChangingOtherHeaders() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:8765/health")))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        LocalServiceAuth.authorize(&request)

        XCTAssertEqual(
            request.value(forHTTPHeaderField: LocalServiceAuth.headerName),
            LocalServiceAuth.token
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testProcessTokenContainsAtLeastThirtyTwoRandomBytesAsBase64URL() throws {
        let token = LocalServiceAuth.token
        XCTAssertFalse(token.isEmpty)
        XCTAssertNil(token.firstMatch(of: /[^A-Za-z0-9_-]/))
        XCTAssertFalse(token.contains("="))

        var base64 = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let decoded = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertGreaterThanOrEqual(decoded.count, 32)
    }

    func testServerEnvironmentPreservesExistingValuesAndAddsToken() {
        let environment = LocalServiceAuth.serverEnvironment(
            inheriting: [
                "PATH": "/usr/bin",
                "EXISTING": "kept",
                "OPENAI_API_KEY": "must-not-cross-process-boundary",
                "AWS_SECRET_ACCESS_KEY": "must-not-cross-process-boundary",
                LocalServiceAuth.environmentName: "stale-parent-token",
            ]
        )

        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertNil(environment["EXISTING"])
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertNil(environment["AWS_SECRET_ACCESS_KEY"])
        XCTAssertEqual(
            environment[LocalServiceAuth.environmentName],
            LocalServiceAuth.token
        )
    }

    func testOnlyLocalQwenReceivesDalToken() throws {
        let url = try XCTUnwrap(URL(string: "http://localhost:11434/v1/chat/completions"))
        var localQwenRequest = URLRequest(url: url)
        var ollamaRequest = URLRequest(url: url)

        DoubaoChatClient.authorizeLocalServiceRequest(
            &localQwenRequest,
            provider: .localQwen
        )
        DoubaoChatClient.authorizeLocalServiceRequest(
            &ollamaRequest,
            provider: .ollama
        )

        XCTAssertEqual(
            localQwenRequest.value(forHTTPHeaderField: LocalServiceAuth.headerName),
            LocalServiceAuth.token
        )
        XCTAssertNil(ollamaRequest.value(forHTTPHeaderField: LocalServiceAuth.headerName))
    }

    func testSenseVoiceWebSocketHandshakeCarriesTokenHeader() async throws {
        let capture = LocalRequestCapture()
        let socket = AuthTestWebSocketTask()
        let client = SenseVoiceWSClient(
            connectionPlanProvider: {
                SenseVoiceConnectionPlan(
                    webSocketURL: URL(string: "ws://127.0.0.1:8765/ws")!,
                    qwenPort: nil
                )
            },
            dialFactory: { request in
                capture.store(request)
                return SenseVoiceDialResources(
                    task: socket,
                    invalidateSession: {}
                )
            },
            qwenFinalEnabledProvider: { false }
        )
        let config = try XCTUnwrap(
            SherpaASRConfig(credentials: ["modelDir": "/tmp/test-model"])
        )

        try await client.connect(config: config, options: ASRRequestOptions())
        let request = try XCTUnwrap(capture.request)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: LocalServiceAuth.headerName),
            LocalServiceAuth.token
        )
        await client.disconnect()
    }
}

private final class LocalRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    var request: URLRequest? {
        lock.withLock { storedRequest }
    }

    func store(_ request: URLRequest) {
        lock.withLock { storedRequest = request }
    }
}

private final class AuthTestWebSocketTask: SenseVoiceWebSocketTasking, @unchecked Sendable {
    func resume() {}

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        _ = message
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        throw CancellationError()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        _ = closeCode
        _ = reason
    }
}
