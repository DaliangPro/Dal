import XCTest
@testable import Dal

final class AliyunASRProtocolTests: XCTestCase {
    func testRunTaskMessageUsesPCMParaformerAndOptionalVocabulary() throws {
        let config = try XCTUnwrap(AliyunASRConfig(credentials: [
            "apiKey": "sk-test",
            "model": "paraformer-realtime-v2",
            "vocabularyId": "vocab-test",
        ]))

        let text = try AliyunASRProtocol.makeRunTaskMessage(
            taskID: "task-1",
            config: config,
            options: ASRRequestOptions(enablePunc: false)
        )
        let root = try jsonObject(text)
        let header = try XCTUnwrap(root["header"] as? [String: Any])
        let payload = try XCTUnwrap(root["payload"] as? [String: Any])
        let parameters = try XCTUnwrap(payload["parameters"] as? [String: Any])

        XCTAssertEqual(header["action"] as? String, "run-task")
        XCTAssertEqual(header["task_id"] as? String, "task-1")
        XCTAssertEqual(header["streaming"] as? String, "duplex")
        XCTAssertEqual(payload["model"] as? String, "paraformer-realtime-v2")
        XCTAssertEqual(parameters["format"] as? String, "pcm")
        XCTAssertEqual(parameters["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(parameters["punctuation_prediction_enabled"] as? Bool, false)
        XCTAssertEqual(parameters["heartbeat"] as? Bool, true)
        XCTAssertEqual(parameters["vocabulary_id"] as? String, "vocab-test")
    }

    func testRunTaskMessageUsesFunASRByDefaultAndItsDedicatedVocabulary() throws {
        let config = try XCTUnwrap(AliyunASRConfig(credentials: [
            "apiKey": "sk-test",
            "funVocabularyId": "vocab-fun",
            "vocabularyId": "vocab-paraformer",
        ]))

        let text = try AliyunASRProtocol.makeRunTaskMessage(
            taskID: "task-fun",
            config: config,
            options: ASRRequestOptions(enablePunc: true)
        )
        let root = try jsonObject(text)
        let payload = try XCTUnwrap(root["payload"] as? [String: Any])
        let parameters = try XCTUnwrap(payload["parameters"] as? [String: Any])

        XCTAssertEqual(payload["model"] as? String, "fun-asr-realtime")
        XCTAssertEqual(parameters["vocabulary_id"] as? String, "vocab-fun")
        XCTAssertNil(parameters["punctuation_prediction_enabled"])
        XCTAssertEqual(parameters["heartbeat"] as? Bool, true)
    }

    func testFinishTaskMessageKeepsTaskID() throws {
        let text = try AliyunASRProtocol.makeFinishTaskMessage(taskID: "task-1")
        let root = try jsonObject(text)
        let header = try XCTUnwrap(root["header"] as? [String: Any])

        XCTAssertEqual(header["action"] as? String, "finish-task")
        XCTAssertEqual(header["task_id"] as? String, "task-1")
        XCTAssertEqual(header["streaming"] as? String, "duplex")
    }

    func testParsesResultAndTaskFailureEvents() throws {
        let result = try AliyunASRProtocol.parseServerMessage("""
        {
          "header": {"task_id": "task-1", "event": "result-generated"},
          "payload": {"output": {"sentence": {
            "text": "你好，世界。", "sentence_end": true, "heartbeat": false
          }}}
        }
        """)
        XCTAssertEqual(
            result,
            .result(
                taskID: "task-1",
                sentence: AliyunSentence(text: "你好，世界。", isFinal: true, isHeartbeat: false)
            )
        )

        let failure = try AliyunASRProtocol.parseServerMessage("""
        {
          "header": {
            "task_id": "task-1", "event": "task-failed",
            "error_code": "CLIENT_ERROR", "error_message": "invalid request"
          },
          "payload": {}
        }
        """)
        XCTAssertEqual(
            failure,
            .taskFailed(taskID: "task-1", code: "CLIENT_ERROR", message: "invalid request")
        )
    }

    func testTranscriptAccumulatorReplacesPartialAndConfirmsSentences() {
        var accumulator = AliyunTranscriptAccumulator()

        let firstPartial = accumulator.apply(
            AliyunSentence(text: "你好", isFinal: false, isHeartbeat: false)
        )
        let replacedPartial = accumulator.apply(
            AliyunSentence(text: "你好世界", isFinal: false, isHeartbeat: false)
        )
        let firstFinal = accumulator.apply(
            AliyunSentence(text: "你好，世界。", isFinal: true, isHeartbeat: false)
        )
        let secondPartial = accumulator.apply(
            AliyunSentence(text: "下一句", isFinal: false, isHeartbeat: false)
        )

        XCTAssertEqual(firstPartial?.composedText, "你好")
        XCTAssertEqual(replacedPartial?.composedText, "你好世界")
        XCTAssertEqual(firstFinal?.confirmedSegments, ["你好，世界。"])
        XCTAssertEqual(firstFinal?.partialText, "")
        XCTAssertEqual(secondPartial?.composedText, "你好，世界。下一句")
    }

    func testTranscriptAccumulatorSkipsHeartbeat() {
        var accumulator = AliyunTranscriptAccumulator()
        XCTAssertNil(
            accumulator.apply(
                AliyunSentence(text: "", isFinal: false, isHeartbeat: true)
            )
        )
    }

    func testTranscriptAccumulatorFreezesPartialBeforeReconnect() {
        var accumulator = AliyunTranscriptAccumulator()
        _ = accumulator.apply(
            AliyunSentence(text: "断流前半句", isFinal: false, isHeartbeat: false)
        )

        accumulator.freezePartialAsConfirmed()
        let afterReconnect = accumulator.apply(
            AliyunSentence(text: "重连后半句", isFinal: true, isHeartbeat: false)
        )

        XCTAssertEqual(
            afterReconnect?.confirmedSegments,
            ["断流前半句", "重连后半句"]
        )
        XCTAssertEqual(afterReconnect?.composedText, "断流前半句重连后半句")
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
