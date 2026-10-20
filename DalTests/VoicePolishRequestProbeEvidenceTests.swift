import Darwin
import os
import XCTest
@testable import Dal

private final class RequestProbeEvidenceURLProtocol: URLProtocol {
    struct State {
        var bodies: [Data] = []
        var evidencePath: String?
        var observedSavedBodyBeforeTransport = false
        var status = 200
    }
    static let state = OSAllocatedUnfairLock(initialState: State())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
        }
        let receivedBody = body
        let status = Self.state.withLock { state in
            state.bodies.append(receivedBody)
            if let path = state.evidencePath {
                state.observedSavedBodyBeforeTransport = (try? Data(contentsOf: URL(fileURLWithPath: path))) == receivedBody
                    && FileManager.default.fileExists(atPath: path + ".metadata.json")
                    && FileManager.default.fileExists(atPath: path + ".response.json")
            }
            return state.status
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/event-stream"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let payload = status == 200 ? """
        data: {"id":"request-probe-test-only","model":"deepseek-flash","choices":[{"delta":{"content":"{\\"edits\\":[]}"},"finish_reason":"stop"}],"usage":{"completion_tokens":5}}


        """ : "模拟网络错误"
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class VoicePolishRequestProbeEvidenceTests: XCTestCase {
    private func directory() throws -> URL {
        // Foundation 会保留 macOS 的 /var 别名；这里需要真实无符号链接路径测试逐级打开。
        let resolved = try XCTUnwrap(Darwin.realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(resolved) }
        let result = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("DalRequestProbeEvidenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        RequestProbeEvidenceURLProtocol.state.withLock { $0 = .init() }
        return result
    }

    private func invoke(directory: URL, bodyPath: String?, audited: Bool = true) async throws -> LLMResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestProbeEvidenceURLProtocol.self]
        let base = DoubaoChatClient(provider: .deepseek, session: URLSession(configuration: configuration))
        let receipt = directory.appendingPathComponent("provider-audit.jsonl")
        if !FileManager.default.fileExists(atPath: receipt.path) {
            XCTAssertTrue(FileManager.default.createFile(atPath: receipt.path, contents: Data()))
        }
        let client: any LLMClient = audited ? VoicePolishProviderAuditedLLMClient(
            base: base, runNonce: String(repeating: "a", count: 64), testInputID: "probe-fixture",
            receiptPath: receipt.path
        ) : base
        let request = LLMRequest(context: .structuredTask, task: .voicePolishRender,
            system: "只修正这份冻结的合成文本。", user: "{\"canonical_text\":\"周三不对周四开会。\"}",
            options: LLMGenerationOptions(temperature: 0, maxOutputTokens: 4096,
                reasoningPolicy: .disabled, responseFormat: .jsonObject))
        let config = LLMConfig(apiKey: "unit-test-secret-must-not-be-in-evidence", model: "deepseek-flash",
            baseURL: "https://api.deepseek.com", thinkingMode: .enabled)
        if let bodyPath {
            return try await VoicePolishProviderAudit.withRequestProbe(bodyPath: bodyPath) {
                try await client.generate(request, config: config)
            }
        }
        return try await client.generate(request, config: config)
    }

    private func object(_ path: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
    }

    func testActualEncodedBodyIsSavedBeforeTransportAndMatchesExistingReceipt() async throws {
        let folder = try directory()
        defer { try? FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
        let path = folder.appendingPathComponent("request-body.json").path
        RequestProbeEvidenceURLProtocol.state.withLock { $0.evidencePath = path }
        let response = try await invoke(directory: folder, bodyPath: path)
        XCTAssertEqual(response.text, "{\"edits\":[]}")
        let actual = try Data(contentsOf: URL(fileURLWithPath: path))
        let state = RequestProbeEvidenceURLProtocol.state.withLock { $0 }
        XCTAssertEqual(state.bodies, [actual])
        XCTAssertTrue(state.observedSavedBodyBeforeTransport)
        let decoded = try object(path)
        let messages = try XCTUnwrap(decoded["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(messages[0]["content"], "只修正这份冻结的合成文本。\n\n仅返回有效的 JSON 对象。")
        XCTAssertEqual(messages[1]["content"], "{\"canonical_text\":\"周三不对周四开会。\"}")
        XCTAssertEqual(decoded["model"] as? String, "deepseek-flash")
        XCTAssertEqual(decoded["temperature"] as? Int, 0)
        XCTAssertEqual(decoded["max_tokens"] as? Int, 4096)
        XCTAssertEqual(decoded["stream"] as? Bool, true)
        XCTAssertEqual((decoded["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertEqual((decoded["response_format"] as? [String: String])?["type"], "json_object")
        let metadata = try object(path + ".metadata.json")
        let digest = VoicePolishProviderAudit.sha256Hex(actual)
        XCTAssertEqual(metadata["evidence_kind"] as? String, "actual_encoded_http_body_before_send")
        XCTAssertEqual(metadata["request_body_sha256"] as? String, digest)
        XCTAssertEqual(metadata["run_nonce"] as? String, String(repeating: "a", count: 64))
        XCTAssertEqual(metadata["test_input_id"] as? String, "probe-fixture")
        XCTAssertEqual(metadata["llm_task"] as? String, "voicePolishRender")
        let messageEvidence = try XCTUnwrap(metadata["messages"] as? [[String: Any]])
        XCTAssertEqual(messageEvidence[0]["content_sha256"] as? String,
            VoicePolishProviderAudit.sha256Hex(Data(try XCTUnwrap(messages[0]["content"]).utf8)))
        let receipt = try object(folder.appendingPathComponent("provider-audit.jsonl").path)
        XCTAssertEqual(receipt["schema_version"] as? Int, 2)
        XCTAssertEqual(receipt["request_body_sha256"] as? String, digest)
        let completion = try object(path + ".response.json")
        XCTAssertEqual(completion["status"] as? String, "response_parsed")
        XCTAssertEqual(completion["http_status"] as? Int, 200)
        XCTAssertEqual(completion["finish_reason"] as? String, "unknown")
        XCTAssertEqual(completion["usage"] as? String, "unknown")
        XCTAssertEqual(completion["response_text_sha256"] as? String, receipt["response_text_sha256"] as? String)
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            let contents = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(contents.contains("unit-test-secret-must-not-be-in-evidence"))
            XCTAssertFalse(contents.contains("Authorization"))
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testOrdinaryAuditedRequestDoesNotCreateProbeEvidence() async throws {
        let folder = try directory()
        defer { try? FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
        _ = try await invoke(directory: folder, bodyPath: nil)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["provider-audit.jsonl"])
        XCTAssertEqual(RequestProbeEvidenceURLProtocol.state.withLock { $0.bodies.count }, 1)
    }

    func testProbeRequiresExistingAuditContextBeforeSending() async throws {
        let folder = try directory()
        defer { try? FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
        let path = folder.appendingPathComponent("request-body.json").path
        do {
            _ = try await invoke(directory: folder, bodyPath: path, audited: false)
            XCTFail("缺少审计上下文却发出了请求")
        } catch {}
        XCTAssertEqual(RequestProbeEvidenceURLProtocol.state.withLock { $0.bodies.count }, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testAnyExistingEvidenceFileBlocksSendWithoutOverwriting() async throws {
        for suffix in ["", ".metadata.json", ".response.json"] {
            let folder = try directory()
            defer { try? FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
            let path = folder.appendingPathComponent("request-body.json").path
            let existing = URL(fileURLWithPath: path + suffix)
            let sentinel = Data("原有证据不能覆盖".utf8)
            try sentinel.write(to: existing)
            do {
                _ = try await invoke(directory: folder, bodyPath: path)
                XCTFail("已有证据仍触发网络")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: existing), sentinel)
            XCTAssertEqual(RequestProbeEvidenceURLProtocol.state.withLock { $0.bodies.count }, 0)
        }
    }

    func testSymlinkFileAndAncestorAreRejectedBeforeSending() async throws {
        for parentLink in [false, true] {
            let folder = try directory()
            defer { try? FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
            let target = folder.appendingPathComponent("target", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let sentinel = target.appendingPathComponent("request-body.json")
            try Data("不能覆盖".utf8).write(to: sentinel)
            let link = folder.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: parentLink ? target : sentinel)
            let path = parentLink ? link.appendingPathComponent("request-body.json").path : link.path
            do {
                _ = try await invoke(directory: folder, bodyPath: path)
                XCTFail("符号链接路径仍触发网络")
            } catch {}
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "不能覆盖")
            XCTAssertEqual(RequestProbeEvidenceURLProtocol.state.withLock { $0.bodies.count }, 0)
        }
    }

    func testFailedTransportPreservesRequestAndMarksUnknownResponseDetails() async throws {
        let folder = try directory()
        defer { try? FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
        let path = folder.appendingPathComponent("request-body.json").path
        RequestProbeEvidenceURLProtocol.state.withLock { $0.status = 500; $0.evidencePath = path }
        do {
            _ = try await invoke(directory: folder, bodyPath: path)
            XCTFail("模拟 HTTP 500 不应成功")
        } catch {}
        XCTAssertTrue(RequestProbeEvidenceURLProtocol.state.withLock { $0.observedSavedBodyBeforeTransport })
        XCTAssertEqual(try object(path + ".response.json")["status"] as? String, "request_or_response_failed")
        XCTAssertEqual(try object(path + ".response.json")["finish_reason"] as? String, "unknown")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("provider-audit.jsonl")).count, 0)
    }
}
