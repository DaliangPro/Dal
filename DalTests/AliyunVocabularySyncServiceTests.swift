import XCTest
@testable import Dal

final class AliyunVocabularySyncServiceTests: XCTestCase {
    func testEntriesUseMaximumWeightAndRejectUnsupportedLengths() {
        let entries = AliyunVocabularySyncService.entries(from: [
            " Dal ",
            "dal",
            "语音实验室",
            "一二三四五六七八九十一二三四五六",
            "one two three four five six seven",
            "one two three four five six seven eight",
            "   ",
        ])

        XCTAssertEqual(entries, [
            AliyunVocabularyEntry(text: "Dal", weight: 5),
            AliyunVocabularyEntry(text: "语音实验室", weight: 5),
            AliyunVocabularyEntry(text: "one two three four five six seven", weight: 5),
        ])
        XCTAssertTrue(entries.allSatisfy { $0.weight == AliyunVocabularySyncService.defaultWeight })
        XCTAssertEqual(AliyunVocabularySyncService.defaultWeight, 5)
    }

    func testCreateVocabularyUsesFunASRDefaultModelAndPersistsReturnedID() async throws {
        let transport = AliyunVocabularyTransportStub(responses: [
            .json(200, ["output": ["vocabulary_id": "vocab-created"]]),
        ])
        let service = AliyunVocabularySyncService { request in
            try await transport.send(request)
        }
        let config = try XCTUnwrap(AliyunASRConfig(credentials: ["apiKey": "sk-test"]))

        let outcome = try await service.synchronize(
            config: config,
            words: ["Dal", "大梁老师"]
        )

        XCTAssertEqual(outcome.operation, .created)
        XCTAssertEqual(outcome.vocabularyID, "vocab-created")
        XCTAssertEqual(outcome.wordCount, 2)

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(
            requests[0].url,
            AliyunASRConfig.compatibilityVocabularyEndpoint
        )
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let input = try requestInput(requests[0])
        XCTAssertEqual(input["action"] as? String, "create_vocabulary")
        XCTAssertEqual(input["target_model"] as? String, "fun-asr-realtime")
        XCTAssertEqual(input["prefix"] as? String, "dal")
        let vocabulary = try XCTUnwrap(input["vocabulary"] as? [[String: Any]])
        XCTAssertEqual(vocabulary.compactMap { $0["weight"] as? Int }, [5, 5])
    }

    func testExistingMatchingVocabularyIsQueriedThenUpdated() async throws {
        let transport = AliyunVocabularyTransportStub(responses: [
            .json(200, ["output": [
                "status": "OK",
                "target_model": "paraformer-realtime-v2",
            ]]),
            .json(200, ["output": [:] as [String: Any]]),
        ])
        let service = AliyunVocabularySyncService { request in
            try await transport.send(request)
        }
        let config = try XCTUnwrap(AliyunASRConfig(credentials: [
            "apiKey": "sk-test",
            "model": "paraformer-realtime-v2",
            "vocabularyId": "vocab-existing",
        ]))

        let outcome = try await service.synchronize(config: config, words: ["Dal"])

        XCTAssertEqual(outcome.operation, .updated)
        XCTAssertEqual(outcome.vocabularyID, "vocab-existing")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(try requestInput(requests[0])["action"] as? String, "query_vocabulary")
        XCTAssertEqual(try requestInput(requests[1])["action"] as? String, "update_vocabulary")
        XCTAssertEqual(
            try requestInput(requests[1])["vocabulary_id"] as? String,
            "vocab-existing"
        )
    }

    func testMismatchedVocabularyCreatesDedicatedParaformerVocabulary() async throws {
        let transport = AliyunVocabularyTransportStub(responses: [
            .json(200, ["output": [
                "status": "OK",
                "target_model": "fun-asr-realtime",
            ]]),
            .json(200, ["output": ["vocabulary_id": "vocab-paraformer"]]),
        ])
        let service = AliyunVocabularySyncService { request in
            try await transport.send(request)
        }
        let config = try XCTUnwrap(AliyunASRConfig(credentials: [
            "apiKey": "sk-test",
            "model": "paraformer-realtime-v2",
            "vocabularyId": "vocab-wrong-model",
        ]))

        let outcome = try await service.synchronize(config: config, words: ["Dal"])

        XCTAssertEqual(outcome.operation, .created)
        XCTAssertEqual(outcome.vocabularyID, "vocab-paraformer")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(try requestInput(requests[0])["action"] as? String, "query_vocabulary")
        XCTAssertEqual(try requestInput(requests[1])["action"] as? String, "create_vocabulary")
    }

    func testInvalidExistingVocabularyFallsBackToCreate() async throws {
        let transport = AliyunVocabularyTransportStub(responses: [
            .json(400, ["code": "InvalidVocabularyId", "message": "not found"]),
            .json(200, ["output": ["vocabulary_id": "vocab-replaced"]]),
        ])
        let service = AliyunVocabularySyncService { request in
            try await transport.send(request)
        }
        let config = try XCTUnwrap(AliyunASRConfig(credentials: [
            "apiKey": "sk-test",
            "model": "paraformer-realtime-v2",
            "vocabularyId": "vocab-missing",
        ]))

        let outcome = try await service.synchronize(config: config, words: ["Dal"])

        XCTAssertEqual(outcome.operation, .created)
        XCTAssertEqual(outcome.vocabularyID, "vocab-replaced")
    }

    func testAuthenticationFailureDoesNotCreateAnotherVocabulary() async throws {
        let transport = AliyunVocabularyTransportStub(responses: [
            .json(401, ["code": "InvalidApiKey", "message": "invalid key"]),
        ])
        let service = AliyunVocabularySyncService { request in
            try await transport.send(request)
        }
        let config = try XCTUnwrap(AliyunASRConfig(credentials: [
            "apiKey": "sk-test",
            "model": "paraformer-realtime-v2",
            "vocabularyId": "vocab-existing",
        ]))

        do {
            _ = try await service.synchronize(config: config, words: ["Dal"])
            XCTFail("鉴权失败必须抛错")
        } catch let error as AliyunVocabularySyncError {
            XCTAssertEqual(
                error,
                .server(statusCode: 401, code: "InvalidApiKey", message: "invalid key")
            )
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    private func requestInput(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(root["model"] as? String, "speech-biasing")
        return try XCTUnwrap(root["input"] as? [String: Any])
    }
}

private actor AliyunVocabularyTransportStub {
    private var responses: [AliyunVocabularyHTTPResult]
    private(set) var requests: [URLRequest] = []

    init(responses: [AliyunVocabularyHTTPResult]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) throws -> AliyunVocabularyHTTPResult {
        requests.append(request)
        guard !responses.isEmpty else {
            throw AliyunVocabularySyncError.invalidResponse
        }
        return responses.removeFirst()
    }
}

private extension AliyunVocabularyHTTPResult {
    static func json(_ statusCode: Int, _ object: [String: Any]) -> Self {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return AliyunVocabularyHTTPResult(data: data, statusCode: statusCode)
    }
}
