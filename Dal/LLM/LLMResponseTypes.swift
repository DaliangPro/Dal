import Foundation

// 请求、响应及错误类型集中管理，客户端只保留传输与调用策略。
struct ThinkingConfig: Encodable, Sendable {
    let type: String
}

struct ReasoningConfig: Encodable, Sendable {
    let effort: String
}

struct ChatResponseFormat: Encodable, Sendable {
    let type: String
}

struct ChatRequest: Encodable, Sendable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
    let max_tokens: Int?
    let temperature: Double?
    let response_format: ChatResponseFormat?
    let thinking: ThinkingConfig?
    let enable_thinking: Bool?
    let reasoning_effort: String?
    let reasoning: ReasoningConfig?
    let think: Bool?
    let reasoning_split: Bool?
}

struct ChatMessage: Encodable, Sendable {
    let role: String
    let content: String
}

// Non-streaming response
struct ChatCompletionResponse: Decodable, Sendable {
    let id: String?
    let model: String?
    let choices: [CompletionChoice]
    let usage: ChatUsage?
    let muse_thinking_mode: String?

    var thinkingEvidence: LLMThinkingProbeEvidence {
        let message = choices.first?.message
        let reportedMode = muse_thinking_mode.flatMap(LLMThinkingMode.init(rawValue:))
        let observed: Bool?
        if message?.reasoningObserved == true
            || (usage?.completion_tokens_details?.reasoning_tokens ?? 0) > 0 {
            observed = true
        } else if usage?.completion_tokens_details?.reasoning_tokens == 0 {
            observed = false
        } else {
            observed = nil
        }
        return LLMThinkingProbeEvidence(
            reportedMode: reportedMode,
            reasoningObserved: observed
        )
    }

    var hitOutputTokenLimit: Bool {
        choices.contains {
            LLMCompletionTermination.hitOutputTokenLimit($0.finish_reason)
        }
    }
}

struct CompletionChoice: Decodable, Sendable {
    let message: CompletionMessage
    let finish_reason: String?
}

struct CompletionMessage: Decodable, Sendable {
    let content: String?
    let reasoningContent: String?
    let reasoningDetailsPresent: Bool

    var reasoningObserved: Bool {
        !(reasoningContent ?? "").isEmpty
            || reasoningDetailsPresent
            || (content?.contains("<think>") ?? false)
    }

    private enum CodingKeys: String, CodingKey {
        case content
        case reasoning
        case thinking
        case reasoningContent = "reasoning_content"
        case reasoningDetails = "reasoning_details"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        let primaryReasoning = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        // 不同兼容端点可能把这些字段返回成字符串、数组或对象。
        // 非字符串结构不应让正常的 content 一并解码失败。
        let fallbackReasoning = try? container.decodeIfPresent(String.self, forKey: .reasoning)
        let thinking = try? container.decodeIfPresent(String.self, forKey: .thinking)
        reasoningContent = primaryReasoning ?? fallbackReasoning ?? thinking
        let reasoningDetails = try? container.decodeIfPresent(
            [ReasoningDetailMarker].self,
            forKey: .reasoningDetails
        )
        reasoningDetailsPresent = !(reasoningDetails ?? []).isEmpty
    }
}

struct ChatUsage: Decodable, Sendable {
    let completion_tokens_details: CompletionTokenDetails?

    private enum CodingKeys: String, CodingKey { case completionTokensDetails = "completion_tokens_details" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        completion_tokens_details = try? container.decodeIfPresent(
            CompletionTokenDetails.self, forKey: .completionTokensDetails
        )
    }
}

struct CompletionTokenDetails: Decodable, Sendable {
    let reasoning_tokens: Int?
}

// Streaming response (SSE chunks)
struct ChatStreamChunk: Decodable, Sendable {
    let id: String?
    let model: String?
    let choices: [ChunkChoice]
    let usage: ChatUsage?
}

struct ChunkChoice: Decodable, Sendable {
    let delta: ChunkDelta?
    let finish_reason: String?
}

struct ChunkDelta: Decodable, Sendable {
    let content: String?
    let reasoning_content: String?
    let reasoning: String?
    let thinking: String?
    let reasoning_details: [ReasoningDetailMarker]?

    private enum CodingKeys: String, CodingKey {
        case content, reasoning, thinking
        case reasoningContent = "reasoning_content"
        case reasoningDetails = "reasoning_details"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 正文结构异常必须报错；服务商自定义的推理元数据不能连带丢掉正文。
        content = try container.decodeIfPresent(String.self, forKey: .content)
        reasoning_content = try? container.decodeIfPresent(String.self, forKey: .reasoningContent)
        reasoning = try? container.decodeIfPresent(String.self, forKey: .reasoning)
        thinking = try? container.decodeIfPresent(String.self, forKey: .thinking)
        reasoning_details = try? container.decodeIfPresent([ReasoningDetailMarker].self, forKey: .reasoningDetails)
    }

    var reasoningObserved: Bool {
        !(reasoning_content ?? "").isEmpty
            || !(reasoning ?? "").isEmpty
            || !(thinking ?? "").isEmpty
            || !(reasoning_details ?? []).isEmpty
    }
}

struct ReasoningDetailMarker: Decodable, Sendable {
    init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer()
    }
}

enum LLMError: Error, LocalizedError {
    case invalidURL
    case requestFailed(Int)
    case requestRejected(Int, String)
    case malformedResponse
    case emptyResponse(String?)
    case truncatedResponse(Int)
    case responseTooLarge(Int)
    /// REPAIR_PLAN J12：会话级硬超时（底层 30s 是无数据间隔语义，慢速涓流可绕过）
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return L("LLM 地址无效", "Invalid LLM URL")
        case .timedOut:
            return L("LLM 处理超时", "LLM processing timed out")
        case .requestFailed(let code):
            return Self.requestFailureDescription(code: code)
        case .requestRejected(let code, _):
            return Self.requestFailureDescription(code: code)
        case .malformedResponse:
            return L("LLM 返回了无法解析的流式响应", "LLM returned a malformed streaming response")
        case .emptyResponse(let raw):
            _ = raw
            return L("LLM 未返回内容", "LLM returned no content")
        case .truncatedResponse:
            return L("LLM 流式响应提前中断，请重试", "LLM streaming response was truncated; retry")
        case .responseTooLarge:
            return L("LLM 响应超过安全上限", "LLM response exceeded the safety limit")
        }
    }

    var isThinkingModeRejection: Bool {
        guard case .requestRejected(let code, let message) = self,
              code == 400 || code == 422
        else { return false }
        let normalized = message.lowercased()
        let markers = [
            "thinking",
            "reasoning",
            "enable_thinking",
            "reasoning_effort",
            "\"think\"",
            "'think'",
        ]
        let rejectionMarkers = [
            "unsupported",
            "not supported",
            "does not support",
            "invalid",
            "unknown parameter",
            "unrecognized",
            "not allowed",
            "not permitted",
            "cannot",
            "can't",
            "always enabled",
            "only supports",
            "expected",
            "should be",
            "must be",
        ]
        return markers.contains { normalized.contains($0) }
            && rejectionMarkers.contains { normalized.contains($0) }
    }

    private static func requestFailureDescription(code: Int) -> String {
        switch code {
        case 401:
            return L("LLM 鉴权失败，请检查 API Key", "LLM auth failed, check API Key")
        case 429:
            return L("LLM 请求超限或余额不足", "LLM rate limit or insufficient balance")
        case 500, 502, 503:
            return L("LLM 服务异常 (\(code))", "LLM service error (\(code))")
        default:
            return L("LLM 请求失败 (\(code))", "LLM request failed (\(code))")
        }
    }
}
