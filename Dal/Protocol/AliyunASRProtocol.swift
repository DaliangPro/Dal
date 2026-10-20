import Foundation

enum AliyunASRProtocolError: Error, LocalizedError, Equatable {
    case invalidMessage
    case unexpectedEvent(String)
    case taskIDMismatch

    var errorDescription: String? {
        switch self {
        case .invalidMessage:
            return L("阿里云返回了无法解析的数据", "Alibaba Cloud returned an invalid response")
        case .unexpectedEvent(let event):
            return L("阿里云返回了非预期事件：\(event)", "Unexpected Alibaba Cloud event: \(event)")
        case .taskIDMismatch:
            return L("阿里云任务标识不匹配", "Alibaba Cloud task ID mismatch")
        }
    }
}

struct AliyunSentence: Sendable, Equatable {
    let text: String
    let isFinal: Bool
    let isHeartbeat: Bool
}

enum AliyunServerEvent: Sendable, Equatable {
    case taskStarted(taskID: String)
    case result(taskID: String, sentence: AliyunSentence)
    case taskFinished(taskID: String)
    case taskFailed(taskID: String, code: String?, message: String?)
    case unknown(taskID: String?, name: String)
}

enum AliyunASRProtocol {
    static let maximumServerMessageBytes = 1_048_576

    static func makeRunTaskMessage(
        taskID: String,
        config: AliyunASRConfig,
        options: ASRRequestOptions
    ) throws -> String {
        var parameters: [String: Any] = [
            "format": "pcm",
            "sample_rate": 16_000,
            "heartbeat": true,
        ]
        if config.model == .paraformerRealtimeV2 {
            parameters["punctuation_prediction_enabled"] = options.enablePunc
        }
        if let vocabularyId = config.vocabularyId {
            parameters["vocabulary_id"] = vocabularyId
        }

        let body: [String: Any] = [
            "header": [
                "action": "run-task",
                "task_id": taskID,
                "streaming": "duplex",
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": config.model.rawValue,
                "parameters": parameters,
                "input": [:] as [String: Any],
            ],
        ]
        return try encode(body)
    }

    static func makeFinishTaskMessage(taskID: String) throws -> String {
        try encode([
            "header": [
                "action": "finish-task",
                "task_id": taskID,
                "streaming": "duplex",
            ],
            "payload": ["input": [:] as [String: Any]],
        ])
    }

    static func parseServerMessage(_ text: String) throws -> AliyunServerEvent {
        guard text.utf8.count <= maximumServerMessageBytes,
              let data = text.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = root["header"] as? [String: Any],
              let event = header["event"] as? String
        else { throw AliyunASRProtocolError.invalidMessage }

        let taskID = header["task_id"] as? String
        switch event {
        case "task-started":
            guard let taskID else { throw AliyunASRProtocolError.invalidMessage }
            return .taskStarted(taskID: taskID)

        case "result-generated":
            guard let taskID,
                  let payload = root["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let rawSentence = output["sentence"] as? [String: Any],
                  let text = rawSentence["text"] as? String,
                  let sentenceEnd = rawSentence["sentence_end"] as? Bool
            else { throw AliyunASRProtocolError.invalidMessage }
            return .result(
                taskID: taskID,
                sentence: AliyunSentence(
                    text: text,
                    isFinal: sentenceEnd,
                    isHeartbeat: rawSentence["heartbeat"] as? Bool ?? false
                )
            )

        case "task-finished":
            guard let taskID else { throw AliyunASRProtocolError.invalidMessage }
            return .taskFinished(taskID: taskID)

        case "task-failed":
            guard let taskID else { throw AliyunASRProtocolError.invalidMessage }
            return .taskFailed(
                taskID: taskID,
                code: header["error_code"] as? String,
                message: header["error_message"] as? String
            )

        default:
            return .unknown(taskID: taskID, name: event)
        }
    }

    private static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw AliyunASRProtocolError.invalidMessage
        }
        return text
    }
}

struct AliyunTranscriptAccumulator: Sendable {
    private(set) var confirmedSegments: [String] = []
    private(set) var partialText = ""

    /// 连接中断前把当前临时字幕冻结为已确认前缀。新连接只会返回重连后的音频，
    /// 若直接覆盖 partialText，用户已经看到的半句会从字幕与最终兜底前文本中消失。
    mutating func freezePartialAsConfirmed() {
        guard !partialText.isEmpty else { return }
        confirmedSegments.append(partialText)
        partialText = ""
    }

    mutating func apply(_ sentence: AliyunSentence) -> RecognitionTranscript? {
        guard !sentence.isHeartbeat else { return nil }
        let text = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if sentence.isFinal {
            if !text.isEmpty {
                confirmedSegments.append(text)
            }
            partialText = ""
        } else {
            partialText = text
        }
        return transcript(isFinal: false)
    }

    func transcript(isFinal: Bool) -> RecognitionTranscript {
        let pieces = confirmedSegments + (partialText.isEmpty ? [] : [partialText])
        let text = pieces.joined()
        return RecognitionTranscript(
            confirmedSegments: confirmedSegments,
            partialText: partialText,
            authoritativeText: text,
            isFinal: isFinal
        )
    }
}
