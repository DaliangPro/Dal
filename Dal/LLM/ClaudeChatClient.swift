import Foundation
import os

actor ClaudeChatClient: LLMClient {

    private let logger = Logger(subsystem: "pro.daliang.muse.llm", category: "ClaudeChatClient")
    private let session: URLSession

    init(session: URLSession = LLMNetworkSession.shared) {
        self.session = session
    }

    /// Pre-establish TCP+TLS connection so the first real request skips handshake.
    func warmUp(baseURL: String) async {
        guard let url = try? LLMEndpointPolicy.normalizedBaseURL(
            rawValue: baseURL,
            provider: .claude
        ) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        if let response = try? await session.bytes(for: request) {
            _ = try? await LLMNetworkSession.readPrefix(response.0, limit: 1)
        }
        logger.info("Claude connection pre-warmed")
    }

    /// Process text through Anthropic Messages API (streaming).
    func process(
        text: String,
        prompt: String,
        context: LLMRequestContext,
        config: LLMConfig
    ) async throws -> String {
        let result = try await execute(
            text: text,
            prompt: prompt,
            context: context,
            config: config,
            stream: true,
            maxTokens: 4_096,
            purpose: .runtime
        )
        LLMThinkingRuntimeState.recordRuntimeEvidence(
            result.evidence,
            provider: .claude,
            config: config
        )
        return result.text.strippingThinkTags()
    }

    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        let trimmedUser = request.user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty else {
            return LLMResponse(text: request.user, model: config.model)
        }

        let promptParts = LLMRequestBuilder.messages(for: request)
        let baseURL = try LLMEndpointPolicy.normalizedBaseURL(
            rawValue: config.baseURL,
            provider: .claude
        )
        let url = try LLMEndpointPolicy.endpoint(
            baseURL: baseURL,
            pathComponents: ["messages"]
        )
        let requestConfig: LLMConfig
        let thinkingStyle: ClaudeThinkingRequestStyle
        switch request.options.reasoningPolicy {
        case .disabled:
            requestConfig = config.withThinkingMode(.disabled)
            thinkingStyle = .adaptive
        case .low:
            requestConfig = config.withThinkingMode(.enabled)
            thinkingStyle = .adaptive
        case .providerDefault:
            requestConfig = config
            thinkingStyle = .omitted
        }

        // 与 OpenAI-compatible 客户端一致：不做 adaptive/manual/baseline 隐式
        // 重试，一次 generate 只发出一次请求。
        let result = try await send(
            url: url,
            textLength: request.user.count,
            config: requestConfig,
            maxTokens: request.options.maxOutputTokens ?? 4_096,
            system: promptParts.system,
            user: promptParts.user,
            stream: true,
            thinkingStyle: thinkingStyle
        )
        return LLMResponse(text: result.text, model: config.model)
    }

    func probeThinkingMode(config: LLMConfig) async throws -> LLMThinkingProbeEvidence {
        let result = try await execute(
            text: LLMThinkingModeValidator.probeText,
            prompt: "{text}",
            context: .connectivityProbe,
            config: config,
            stream: false,
            maxTokens: 2_048,
            purpose: .probe
        )
        return result.evidence
    }

    private func execute(
        text: String,
        prompt: String,
        context: LLMRequestContext,
        config: LLMConfig,
        stream: Bool,
        maxTokens: Int,
        purpose: LLMThinkingRequestPurpose
    ) async throws -> ClaudeExecutionResult {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return ClaudeExecutionResult(text: text, evidence: .unknown)
        }
        let promptParts = LLMRequestBuilder.messages(
            prompt: prompt,
            text: trimmedText,
            context: context
        )

        let baseURL = try LLMEndpointPolicy.normalizedBaseURL(
            rawValue: config.baseURL,
            provider: .claude
        )
        let url = try LLMEndpointPolicy.endpoint(
            baseURL: baseURL,
            pathComponents: ["messages"]
        )
        let signature = LLMConnectivitySignature(provider: .claude, config: config)
        let cachedPreference = purpose == .runtime
            ? LLMThinkingRuntimeState.preference(for: signature)
            : .standard

        if cachedPreference == .omitControl {
            return try await send(
                url: url,
                textLength: text.count,
                config: config,
                maxTokens: maxTokens,
                system: promptParts.system,
                user: promptParts.user,
                stream: stream,
                thinkingStyle: .omitted
            )
        }

        if cachedPreference == .claudeManual, config.thinkingMode == .enabled {
            do {
                return try await send(
                    url: url,
                    textLength: text.count,
                    config: config,
                    maxTokens: maxTokens,
                    system: promptParts.system,
                    user: promptParts.user,
                    stream: stream,
                    thinkingStyle: .manual
                )
            } catch let error as LLMError where error.isThinkingModeRejection {
                logger.info("Claude manual thinking rejected; retrying baseline request")
                let result = try await send(
                    url: url,
                    textLength: text.count,
                    config: config,
                    maxTokens: maxTokens,
                    system: promptParts.system,
                    user: promptParts.user,
                    stream: stream,
                    thinkingStyle: .omitted
                )
                LLMThinkingRuntimeState.rememberOmittedControl(for: signature)
                return result
            }
        }

        if config.thinkingMode == .enabled {
            do {
                let result = try await send(
                    url: url,
                    textLength: text.count,
                    config: config,
                    maxTokens: maxTokens,
                    system: promptParts.system,
                    user: promptParts.user,
                    stream: stream,
                    thinkingStyle: .adaptive
                )
                if purpose == .probe {
                    LLMThinkingRuntimeState.clearPreference(for: signature)
                }
                return result
            } catch let error as LLMError where error.isThinkingModeRejection {
                // 新版 Claude 要求 adaptive，旧版模型仍可能只接受手动 thinking budget。
                // 两次请求表达的是同一个“开启”状态，因此该兼容回退不会改变用户选择。
                logger.info("Claude adaptive thinking rejected; retrying with manual budget")
                do {
                    let result = try await send(
                        url: url,
                        textLength: text.count,
                        config: config,
                        maxTokens: maxTokens,
                        system: promptParts.system,
                        user: promptParts.user,
                        stream: stream,
                        thinkingStyle: .manual
                    )
                    LLMThinkingRuntimeState.rememberClaudeManual(for: signature)
                    return result
                } catch let manualError as LLMError where manualError.isThinkingModeRejection {
                    logger.info("Claude thinking controls rejected; retrying baseline request")
                    let result = try await send(
                        url: url,
                        textLength: text.count,
                        config: config,
                        maxTokens: maxTokens,
                        system: promptParts.system,
                        user: promptParts.user,
                        stream: stream,
                        thinkingStyle: .omitted
                    )
                    LLMThinkingRuntimeState.rememberOmittedControl(for: signature)
                    return result
                }
            }
        }

        do {
            let result = try await send(
                url: url,
                textLength: text.count,
                config: config,
                maxTokens: maxTokens,
                system: promptParts.system,
                user: promptParts.user,
                stream: stream,
                thinkingStyle: .adaptive
            )
            if purpose == .probe {
                LLMThinkingRuntimeState.clearPreference(for: signature)
            }
            return result
        } catch let error as LLMError where error.isThinkingModeRejection {
            logger.info("Claude disabled-thinking control rejected; retrying baseline request")
            let result = try await send(
                url: url,
                textLength: text.count,
                config: config,
                maxTokens: maxTokens,
                system: promptParts.system,
                user: promptParts.user,
                stream: stream,
                thinkingStyle: .omitted
            )
            LLMThinkingRuntimeState.rememberOmittedControl(for: signature)
            return result
        }
    }

    private func send(
        url: URL,
        textLength: Int,
        config: LLMConfig,
        maxTokens: Int,
        system: String?,
        user: String,
        stream: Bool,
        thinkingStyle: ClaudeThinkingRequestStyle
    ) async throws -> ClaudeExecutionResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body = Self.makeRequestBody(
            config: config,
            maxTokens: maxTokens,
            system: system,
            user: user,
            stream: stream,
            thinkingStyle: thinkingStyle
        )
        request.httpBody = try JSONEncoder().encode(body)

        logger.info(
            "Claude request: \(textLength) chars, model=\(config.model), stream=\(stream), thinking=\(config.thinkingMode.rawValue)"
        )

        let result = stream
            ? try await processStreaming(request: request, model: config.model)
            : try await processNonStreaming(request: request, model: config.model)

        logger.info("Claude result: \(result.text.count) chars")
        return ClaudeExecutionResult(
            text: result.text,
            evidence: result.evidence.withControlAccepted(thinkingStyle.appliesControl)
        )
    }

    static func makeRequestBody(
        config: LLMConfig,
        maxTokens: Int,
        system: String?,
        user: String,
        stream: Bool,
        thinkingStyle: ClaudeThinkingRequestStyle = .adaptive
    ) -> ClaudeRequest {
        let thinking: ClaudeThinkingConfig?
        switch (config.thinkingMode, thinkingStyle) {
        case (_, .omitted):
            thinking = nil
        case (.disabled, _):
            thinking = ClaudeThinkingConfig(type: "disabled", budget_tokens: nil)
        case (.enabled, .adaptive):
            thinking = ClaudeThinkingConfig(type: "adaptive", budget_tokens: nil)
        case (.enabled, .manual):
            thinking = ClaudeThinkingConfig(type: "enabled", budget_tokens: 1_024)
        }

        return ClaudeRequest(
            model: config.model,
            max_tokens: maxTokens,
            system: system,
            messages: [ClaudeMessage(role: "user", content: user)],
            stream: stream,
            thinking: thinking
        )
    }

    private func processStreaming(
        request: URLRequest,
        model: String
    ) async throws -> ClaudeExecutionResult {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.requestFailed(0)
        }
        guard http.statusCode == 200 else {
            let errorData = try await LLMNetworkSession.readPrefix(bytes, limit: 512)
            let errorBody = LLMNetworkSession.sanitizedErrorBody(errorData, limit: 512)
            logger.error("Claude HTTP \(http.statusCode)")
            DebugFileLogger.log(
                "Claude[\(model)]: HTTP \(http.statusCode), retained error bytes=\(errorBody.utf8.count)"
            )
            throw LLMError.requestRejected(http.statusCode, errorBody)
        }

        var parser = ClaudeStreamingParser()
        var decoder = SSEByteStreamDecoder()
        do {
            for try await byte in bytes {
                if let line = try decoder.consume(byte: byte) {
                    try parser.consume(line: line)
                    if parser.isComplete { break }
                }
            }
            if !parser.isComplete, let line = try decoder.finish() {
                try parser.consume(line: line)
            }
        } catch {
            if Self.shouldFlushPendingLine(after: error) {
                do {
                    if let line = try decoder.finish() {
                        try parser.consume(line: line)
                    }
                } catch {
                    throw parser.errorForStreamFailure(error)
                }
            }
            throw parser.errorForStreamFailure(error)
        }
        let text = try parser.finish()
        return ClaudeExecutionResult(
            text: text,
            evidence: LLMThinkingProbeEvidence(
                reportedMode: nil,
                reasoningObserved: parser.reasoningObserved ? true : nil
            )
        )
    }

    private func processNonStreaming(
        request: URLRequest,
        model: String
    ) async throws -> ClaudeExecutionResult {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.requestFailed(0)
        }
        guard http.statusCode == 200 else {
            let errorData = try await LLMNetworkSession.readPrefix(bytes, limit: 512)
            let errorBody = LLMNetworkSession.sanitizedErrorBody(errorData, limit: 512)
            logger.error("Claude HTTP \(http.statusCode)")
            DebugFileLogger.log(
                "Claude[\(model)]: HTTP \(http.statusCode), retained error bytes=\(errorBody.utf8.count)"
            )
            throw LLMError.requestRejected(http.statusCode, errorBody)
        }

        let data = try await LLMNetworkSession.readCapped(
            bytes,
            limit: LLMStreamingParser.defaultMaximumResponseBytes
        )
        guard let decoded = try? JSONDecoder().decode(ClaudeResponse.self, from: data),
              !decoded.text.isEmpty
        else {
            throw LLMError.emptyResponse(nil)
        }
        guard !LLMCompletionTermination.hitOutputTokenLimit(decoded.stop_reason) else {
            throw LLMError.truncatedResponse(decoded.text.count)
        }
        return ClaudeExecutionResult(
            text: decoded.text,
            evidence: LLMThinkingProbeEvidence(
                reportedMode: nil,
                reasoningObserved: decoded.reasoningObserved ? true : nil
            )
        )
    }

    private static func shouldFlushPendingLine(after error: Error) -> Bool {
        !(error is LLMError)
            && !(error is CancellationError)
            && (error as? URLError)?.code != .cancelled
    }
}

// MARK: - Request Types

struct ClaudeRequest: Encodable, Sendable {
    let model: String
    let max_tokens: Int
    let system: String?
    let messages: [ClaudeMessage]
    let stream: Bool
    let thinking: ClaudeThinkingConfig?
}

enum ClaudeThinkingRequestStyle: Equatable, Sendable {
    case adaptive
    case manual
    case omitted

    var appliesControl: Bool {
        self != .omitted
    }
}

struct ClaudeThinkingConfig: Encodable, Sendable {
    let type: String
    let budget_tokens: Int?
}

struct ClaudeMessage: Encodable, Sendable {
    let role: String
    let content: String
}

// MARK: - Stream Response Types

private struct ClaudeExecutionResult: Sendable {
    let text: String
    let evidence: LLMThinkingProbeEvidence
}

private struct ClaudeResponse: Decodable, Sendable {
    let content: [ClaudeContentBlock]
    let stop_reason: String?

    var text: String {
        content.compactMap(\.text).joined()
    }

    var reasoningObserved: Bool {
        content.contains { $0.type == "thinking" || $0.type == "redacted_thinking" }
    }
}

private struct ClaudeContentBlock: Decodable, Sendable {
    let type: String
    let text: String?
}

private struct ClaudeStreamEvent: Decodable, Sendable {
    let type: String
    let delta: ClaudeDelta?
    let content_block: ClaudeContentBlock?
}

private struct ClaudeDelta: Decodable, Sendable {
    let type: String?
    let text: String?
    let thinking: String?
    let stop_reason: String?
}

struct ClaudeStreamingParser: Sendable {
    private var events = SSEEventAccumulator()
    private var result = ""
    private var resultBytes = 0
    private(set) var isComplete = false
    private(set) var reasoningObserved = false
    private var hitOutputTokenLimit = false

    mutating func consume(line: String) throws {
        guard !isComplete else { return }
        for payload in try events.consume(line: line) {
            try consume(payload: payload)
        }
    }

    mutating func finish() throws -> String {
        if !isComplete {
            for payload in events.finish() {
                try consume(payload: payload)
            }
        }
        guard isComplete else {
            throw LLMError.truncatedResponse(result.count)
        }
        guard !hitOutputTokenLimit else {
            throw LLMError.truncatedResponse(result.count)
        }
        guard !result.isEmpty else {
            throw LLMError.emptyResponse(nil)
        }
        return result
    }

    mutating func errorForStreamFailure(_ streamError: Error) -> Error {
        if Task.isCancelled {
            return CancellationError()
        }
        if streamError is CancellationError
            || (streamError as? URLError)?.code == .cancelled
            || streamError is LLMError {
            return streamError
        }
        do {
            for payload in events.finish() {
                try consume(payload: payload)
            }
        } catch {
            return error
        }
        return result.isEmpty ? streamError : LLMError.truncatedResponse(result.count)
    }

    private mutating func consume(payload: String) throws {
        if payload == "[DONE]" {
            isComplete = true
            return
        }
        guard let data = payload.data(using: .utf8) else {
            throw LLMError.malformedResponse
        }
        let event: ClaudeStreamEvent
        do {
            event = try JSONDecoder().decode(ClaudeStreamEvent.self, from: data)
        } catch {
            DebugFileLogger.log("Claude streaming event decode failed bytes=\(data.count)")
            throw LLMError.malformedResponse
        }

        switch event.type {
        case "content_block_start":
            if event.content_block?.type == "thinking"
                || event.content_block?.type == "redacted_thinking" {
                reasoningObserved = true
            }
        case "content_block_delta":
            if event.delta?.type == "thinking_delta"
                || event.delta?.type == "signature_delta"
                || !(event.delta?.thinking ?? "").isEmpty {
                reasoningObserved = true
            }
            guard let text = event.delta?.text, !text.isEmpty else { return }
            let additionalBytes = text.utf8.count
            let maximum = LLMStreamingParser.defaultMaximumResponseBytes
            guard additionalBytes <= maximum - resultBytes else {
                throw LLMError.responseTooLarge(maximum)
            }
            result += text
            resultBytes += additionalBytes
        case "message_delta":
            if LLMCompletionTermination.hitOutputTokenLimit(event.delta?.stop_reason) {
                hitOutputTokenLimit = true
            }
        case "message_stop":
            isComplete = true
        default:
            break
        }
    }
}
