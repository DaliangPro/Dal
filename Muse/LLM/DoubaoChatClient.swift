import CommonCrypto
import Foundation
import os

/// L15 真实 Provider 验收的网络层审计上下文。Runner 只能声明本次
/// nonce、样本 ID 和由 Evaluator 预建的空回执路径；真正的回执只有在
/// `DoubaoChatClient` 收到并解析成功响应后才会写入。
enum VoicePolishProviderAudit {
    struct Context: Sendable, Equatable {
        let runNonce: String
        let testInputID: String
        let receiptPath: String
    }

    @TaskLocal static var currentContext: Context?

    static func withContext<T>(
        runNonce: String,
        testInputID: String,
        receiptPath: String,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $currentContext.withValue(
            Context(
                runNonce: runNonce,
                testInputID: testInputID,
                receiptPath: receiptPath
            ),
            operation: operation
        )
    }

    static func sha256Hex(_ data: Data) -> String {
        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)
        data.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress, !bytes.isEmpty {
                CC_SHA256_Update(&context, baseAddress, CC_LONG(bytes.count))
            }
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 用长度前缀把 Evaluator nonce、样本 ID、样本内请求序号和实际请求体摘要
    /// 绑定成一个不可歧义的摘要。Evaluator 会独立重算，避免字段被拆开替换。
    static func requestBindingSHA256(
        runNonce: String,
        testInputID: String,
        requestOrdinal: Int,
        requestBodySHA256: String
    ) -> String {
        let components = [
            runNonce,
            testInputID,
            String(requestOrdinal),
            requestBodySHA256,
        ]
        let encoded = components.map { value in
            "\(value.utf8.count):\(value)"
        }.joined(separator: "|")
        return sha256Hex(Data("muse-provider-audit-v2|\(encoded)".utf8))
    }
}

struct VoicePolishProviderAuditReceipt: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let runNonce: String
    let testInputID: String
    let requestOrdinal: Int
    let llmTask: String
    let provider: String
    let endpointURL: String
    let configuredModel: String
    let responseModel: String?
    let transport: String
    let httpStatus: Int
    let requestBodySHA256: String
    let requestBindingSHA256: String
    let responseTextSHA256: String
    let providerResponseID: String
    let recordedAt: Date

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runNonce = "run_nonce"
        case testInputID = "test_input_id"
        case requestOrdinal = "request_ordinal"
        case llmTask = "llm_task"
        case provider
        case endpointURL = "endpoint_url"
        case configuredModel = "configured_model"
        case responseModel = "response_model"
        case transport
        case httpStatus = "http_status"
        case requestBodySHA256 = "request_body_sha256"
        case requestBindingSHA256 = "request_binding_sha256"
        case responseTextSHA256 = "response_text_sha256"
        case providerResponseID = "provider_response_id"
        case recordedAt = "recorded_at"
    }
}

private enum VoicePolishProviderAuditError: LocalizedError {
    case invalidReceiptPath(String)
    case receiptWasNotEmpty(String)
    case missingRequestBody
    case missingRequestTask
    case missingResponseIdentity
    case invalidSuccessfulResponse

    var errorDescription: String? {
        switch self {
        case .invalidReceiptPath(let path):
            return "Provider 审计回执路径不是预建的常规文件：\(path)"
        case .receiptWasNotEmpty(let path):
            return "Provider 审计回执在首次请求前已包含内容：\(path)"
        case .missingRequestBody:
            return "Provider 审计无法读取实际请求体"
        case .missingRequestTask:
            return "Provider 审计缺少 Voice Polish 任务标识"
        case .missingResponseIdentity:
            return "Provider 响应没有可验证的 response ID"
        case .invalidSuccessfulResponse:
            return "Provider 审计只允许记录已解析的 HTTP 200 响应"
        }
    }
}

actor DoubaoChatClient: LLMClient {

    private let logger = Logger(subsystem: "pro.daliang.muse.llm", category: "DoubaoChatClient")
    private let provider: LLMProvider
    private let session: URLSession
    private var initializedAuditPaths = Set<String>()
    private var auditOrdinals: [String: Int] = [:]

    init(
        provider: LLMProvider = .doubao,
        session: URLSession = LLMNetworkSession.shared
    ) {
        self.provider = provider
        self.session = session
    }

    /// Pre-establish TCP+TLS connection so the first real request skips handshake.
    func warmUp(baseURL: String) async {
        guard let url = try? LLMEndpointPolicy.normalizedBaseURL(
            rawValue: baseURL,
            provider: provider,
            localQwenPort: provider == .localQwen ? LLMEndpointPolicy.currentLocalQwenPort : nil
        ) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        Self.authorizeLocalServiceRequest(&request, provider: provider)
        if let response = try? await session.bytes(for: request) {
            _ = try? await LLMNetworkSession.readPrefix(response.0, limit: 1)
        }
        logger.info("LLM connection pre-warmed")
    }

    /// Process text through Doubao ARK API (OpenAI-compatible streaming).
    /// Returns the full LLM response as a single string.
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
            useStreaming: provider != .localQwen,
            maxTokens: nil,
            purpose: .runtime
        )
        LLMThinkingRuntimeState.recordRuntimeEvidence(
            result.evidence,
            provider: provider,
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
            provider: provider,
            localQwenPort: provider == .localQwen ? LLMEndpointPolicy.currentLocalQwenPort : nil
        )
        let url = try LLMEndpointPolicy.endpoint(
            baseURL: baseURL,
            pathComponents: ["chat", "completions"]
        )
        var messages: [ChatMessage] = []
        if let system = promptParts.system {
            messages.append(ChatMessage(role: "system", content: system))
        }
        messages.append(ChatMessage(role: "user", content: promptParts.user))

        let capabilities = LLMProviderCapabilityResolver.capabilities(
            provider: provider,
            config: config
        )
        let requestConfig: LLMConfig
        switch request.options.reasoningPolicy {
        case .disabled:
            requestConfig = config.withThinkingMode(.disabled)
        case .low:
            requestConfig = config.withThinkingMode(.enabled)
        case .providerDefault:
            requestConfig = config
        }
        let appliesThinkingControl = capabilities.supportsReasoningControl
            && request.options.reasoningPolicy != .providerDefault

        // generate 的一次调用严格对应一次真实请求；能力字段被拒绝时直接把错误
        // 交还 VoicePolishPipeline，由统一预算决定下一步。
        let result = try await send(
            url: url,
            textLength: request.user.count,
            config: requestConfig,
            messages: messages,
            useStreaming: provider != .localQwen,
            maxTokens: capabilities.supportsDynamicMaxTokens
                ? request.options.maxOutputTokens
                : nil,
            appliesThinkingControl: appliesThinkingControl,
            temperature: capabilities.supportsTemperature
                ? request.options.temperature
                : nil,
            responseFormat: capabilities.supportsJSONMode
                ? request.options.responseFormat
                : .text,
            reasoningPolicy: request.options.reasoningPolicy,
            auditTask: request.task
        )
        return LLMResponse(text: result.text, model: config.model)
    }

    func probeThinkingMode(config: LLMConfig) async throws -> LLMThinkingProbeEvidence {
        let result = try await execute(
            text: LLMThinkingModeValidator.probeText,
            prompt: "{text}",
            context: .connectivityProbe,
            config: config,
            useStreaming: Self.usesStreamingForThinkingProbe(provider: provider),
            maxTokens: Self.maximumTokensForThinkingProbe(provider: provider),
            purpose: .probe
        )
        return result.evidence
    }

    static func usesStreamingForThinkingProbe(provider: LLMProvider) -> Bool {
        // 百炼部分思考模型只接受流式调用；关闭状态也走流式，才能在固定思考模型
        // 拒绝 false 后用同一传输方式完成基线探测。
        return provider == .bailian
    }

    static func maximumTokensForThinkingProbe(provider: LLMProvider) -> Int? {
        // OpenAI 的部分推理模型拒绝旧式 max_tokens，而兼容端点对
        // max_completion_tokens 的支持又不一致。探测题已要求只返回答案，
        // 因此省略上限字段兼容性最高；响应体仍受客户端硬上限保护。
        provider == .openai ? nil : 1_024
    }

    private func execute(
        text: String,
        prompt: String,
        context: LLMRequestContext,
        config: LLMConfig,
        useStreaming: Bool,
        maxTokens: Int?,
        purpose: LLMThinkingRequestPurpose
    ) async throws -> LLMExecutionResult {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return LLMExecutionResult(text: text, evidence: .unknown)
        }
        let promptParts = LLMRequestBuilder.messages(
            prompt: prompt,
            text: trimmedText,
            context: context
        )

        let baseURL = try LLMEndpointPolicy.normalizedBaseURL(
            rawValue: config.baseURL,
            provider: provider,
            localQwenPort: provider == .localQwen ? LLMEndpointPolicy.currentLocalQwenPort : nil
        )
        let url = try LLMEndpointPolicy.endpoint(
            baseURL: baseURL,
            pathComponents: ["chat", "completions"]
        )

        var messages: [ChatMessage] = []
        if let system = promptParts.system {
            messages.append(ChatMessage(role: "system", content: system))
        }
        messages.append(ChatMessage(role: "user", content: promptParts.user))
        let signature = LLMConnectivitySignature(provider: provider, config: config)
        if purpose == .runtime,
           LLMThinkingRuntimeState.preference(for: signature) == .omitControl {
            return try await send(
                url: url,
                textLength: text.count,
                config: config,
                messages: messages,
                useStreaming: useStreaming,
                maxTokens: maxTokens,
                appliesThinkingControl: false,
                isThinkingProbe: purpose == .probe
            )
        }

        do {
            let result = try await send(
                url: url,
                textLength: text.count,
                config: config,
                messages: messages,
                useStreaming: useStreaming,
                maxTokens: maxTokens,
                appliesThinkingControl: true,
                isThinkingProbe: purpose == .probe
            )
            if purpose == .probe,
               provider.thinkingRequestField(for: config.model).isExplicitlyControllable {
                LLMThinkingRuntimeState.clearPreference(for: signature)
            }
            return result
        } catch let error as LLMError where
            provider.thinkingRequestField(for: config.model).isExplicitlyControllable
                && error.isThinkingModeRejection {
            // 模型的能力可能比服务商协议更窄：例如固定思考模型会拒绝显式开关，
            // 非思考模型则可能拒绝整个控制字段。退回基础请求后由响应证据判定实际状态。
            logger.info("LLM thinking control rejected; retrying without control field")
            let result = try await send(
                url: url,
                textLength: text.count,
                config: config,
                messages: messages,
                useStreaming: useStreaming,
                maxTokens: maxTokens,
                appliesThinkingControl: false,
                isThinkingProbe: purpose == .probe
            )
            LLMThinkingRuntimeState.rememberOmittedControl(for: signature)
            return result
        }
    }

    private func send(
        url: URL,
        textLength: Int,
        config: LLMConfig,
        messages: [ChatMessage],
        useStreaming: Bool,
        maxTokens: Int?,
        appliesThinkingControl: Bool,
        temperature: Double? = nil,
        responseFormat: LLMResponseFormat = .text,
        reasoningPolicy: ReasoningPolicy = .providerDefault,
        auditTask: LLMTask? = nil,
        isThinkingProbe: Bool = false
    ) async throws -> LLMExecutionResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(Self.makeChatRequest(
            provider: provider,
            config: config,
            messages: messages,
            stream: useStreaming,
            maxTokens: maxTokens,
            appliesThinkingControl: appliesThinkingControl,
            temperature: temperature,
            responseFormat: responseFormat,
            reasoningPolicy: reasoningPolicy
        ))
        Self.authorizeLocalServiceRequest(&request, provider: provider)
        let probe = try VoicePolishRequestProbeEvidence.captureIfRequested(body: request.httpBody, task: auditTask)

        logger.info(
            "LLM request: \(textLength) chars, endpoint=\(config.model), stream=\(useStreaming), thinking=\(config.thinkingMode.rawValue), controlled=\(appliesThinkingControl)"
        )

        let requestStartedAt = ContinuousClock.now
        let result: LLMExecutionResult
        do {
            result = useStreaming
                ? try await processStreaming(
                    request: request,
                    model: config.model,
                    requestStartedAt: requestStartedAt,
                    isThinkingProbe: isThinkingProbe
                )
                : try await processNonStreaming(
                    request: request,
                    model: config.model,
                    requestStartedAt: requestStartedAt
                )
        } catch {
            try probe?.recordResponse(status: "request_or_response_failed")
            throw error
        }
        try probe?.recordResponse(
            status: "response_parsed", text: result.text, httpStatus: result.httpStatus,
            responseModel: result.responseModel, transport: result.transport
        )
        let controlAccepted = appliesThinkingControl
            && provider.thinkingRequestField(for: config.model).isExplicitlyControllable
        logger.info("LLM result: \(result.text.count) chars")
        let completedResult = LLMExecutionResult(
            text: result.text,
            evidence: result.evidence.withControlAccepted(controlAccepted),
            responseID: result.responseID,
            responseModel: result.responseModel,
            httpStatus: result.httpStatus,
            transport: result.transport
        )
        try recordProviderAuditIfRequested(
            request: request,
            config: config,
            task: auditTask,
            result: completedResult
        )
        return completedResult
    }

    private func recordProviderAuditIfRequested(
        request: URLRequest,
        config: LLMConfig,
        task: LLMTask?,
        result: LLMExecutionResult
    ) throws {
        guard let audit = VoicePolishProviderAudit.currentContext else { return }
        guard let task else { throw VoicePolishProviderAuditError.missingRequestTask }
        guard let requestBody = request.httpBody else {
            throw VoicePolishProviderAuditError.missingRequestBody
        }
        guard result.httpStatus == 200, let transport = result.transport else {
            throw VoicePolishProviderAuditError.invalidSuccessfulResponse
        }
        guard let rawResponseID = result.responseID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawResponseID.isEmpty,
              rawResponseID.utf8.count <= 512 else {
            throw VoicePolishProviderAuditError.missingResponseIdentity
        }
        guard let endpointURL = request.url?.absoluteString, !endpointURL.isEmpty else {
            throw VoicePolishProviderAuditError.invalidSuccessfulResponse
        }

        let ordinalKey = "\(audit.runNonce)\u{0}\(audit.testInputID)"
        let nextOrdinal = (auditOrdinals[ordinalKey] ?? 0) + 1
        let requestBodySHA256 = VoicePolishProviderAudit.sha256Hex(requestBody)
        let receipt = VoicePolishProviderAuditReceipt(
            schemaVersion: 2,
            runNonce: audit.runNonce,
            testInputID: audit.testInputID,
            requestOrdinal: nextOrdinal,
            llmTask: task.rawValue,
            provider: provider.rawValue,
            endpointURL: endpointURL,
            configuredModel: config.model,
            responseModel: result.responseModel,
            transport: transport,
            httpStatus: 200,
            requestBodySHA256: requestBodySHA256,
            requestBindingSHA256: VoicePolishProviderAudit.requestBindingSHA256(
                runNonce: audit.runNonce,
                testInputID: audit.testInputID,
                requestOrdinal: nextOrdinal,
                requestBodySHA256: requestBodySHA256
            ),
            responseTextSHA256: VoicePolishProviderAudit.sha256Hex(Data(result.text.utf8)),
            providerResponseID: rawResponseID,
            recordedAt: Date()
        )
        try appendAuditReceipt(receipt, to: audit.receiptPath)
        auditOrdinals[ordinalKey] = nextOrdinal
    }

    private func appendAuditReceipt(
        _ receipt: VoicePolishProviderAuditReceipt,
        to path: String
    ) throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard path.hasPrefix("/"),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw VoicePolishProviderAuditError.invalidReceiptPath(path)
        }
        if !initializedAuditPaths.contains(url.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue == 0 else {
                throw VoicePolishProviderAuditError.receiptWasNotEmpty(path)
            }
            initializedAuditPaths.insert(url.path)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(receipt)
        line.append(0x0A)

        let handle = try FileHandle(forWritingTo: url)
        do {
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: line)
            // 每条 HTTP 200 成功响应在返回上层前立即落盘；不能依赖进程退出时刷新。
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    static func makeChatRequest(
        provider: LLMProvider,
        config: LLMConfig,
        messages: [ChatMessage],
        stream: Bool,
        maxTokens: Int?,
        appliesThinkingControl: Bool = true,
        temperature: Double? = nil,
        responseFormat: LLMResponseFormat = .text,
        reasoningPolicy: ReasoningPolicy = .providerDefault
    ) -> ChatRequest {
        let thinkingField = provider.thinkingRequestField(for: config.model)
        let thinkingEnabled = config.thinkingMode.isEnabled
        let reasoningEffort: String
        if !thinkingEnabled {
            reasoningEffort = "none"
        } else if reasoningPolicy == .low {
            reasoningEffort = "low"
        } else {
            reasoningEffort = "medium"
        }
        return ChatRequest(
            model: config.model,
            messages: messages,
            stream: stream,
            max_tokens: maxTokens,
            temperature: temperature,
            response_format: responseFormat == .jsonObject
                ? ChatResponseFormat(type: "json_object")
                : nil,
            thinking: appliesThinkingControl && thinkingField == .thinking
                ? ThinkingConfig(type: thinkingEnabled ? "enabled" : "disabled")
                : nil,
            enable_thinking: appliesThinkingControl && thinkingField == .enableThinking
                ? thinkingEnabled
                : nil,
            reasoning_effort: appliesThinkingControl && thinkingField == .reasoningEffort
                ? reasoningEffort
                : nil,
            reasoning: appliesThinkingControl && thinkingField == .reasoningObject
                ? ReasoningConfig(effort: reasoningEffort)
                : nil,
            think: appliesThinkingControl && thinkingField == .think ? thinkingEnabled : nil,
            reasoning_split: provider.needsReasoningSplit ? true : nil
        )
    }

    static func authorizeLocalServiceRequest(
        _ request: inout URLRequest,
        provider: LLMProvider
    ) {
        guard provider == .localQwen else { return }
        LocalServiceAuth.authorize(&request)
    }

    // MARK: - Streaming (SSE)

    private func processStreaming(
        request: URLRequest,
        model: String,
        requestStartedAt: ContinuousClock.Instant,
        isThinkingProbe: Bool = false
    ) async throws -> LLMExecutionResult {
        let timing = LLMNetworkTiming.current()
        timing?.record("request_start")
        let (bytes, response) = try await session.bytes(for: request, delegate: timing)
        timing?.record("response_headers")
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.requestFailed(0)
        }
        guard http.statusCode == 200 else {
            let errorData = try await LLMNetworkSession.readPrefix(bytes, limit: 512)
            let errorBody = LLMNetworkSession.sanitizedErrorBody(errorData, limit: 512)
            logger.error("LLM HTTP \(http.statusCode)")
            DebugFileLogger.log(
                "LLM[\(model)]: HTTP \(http.statusCode), retained error bytes=\(errorBody.utf8.count)"
            )
            throw LLMError.requestRejected(http.statusCode, errorBody)
        }

        var lineCount = 0
        var didRecordFirstByte = false
        var didRecordFirstContent = false
        var parser = LLMStreamingParser()
        var decoder = SSEByteStreamDecoder()
        var responseID: String?
        var responseModel: String?
        do {
            for try await byte in bytes {
                if !didRecordFirstByte {
                    didRecordFirstByte = true
                    timing?.record("first_body_byte")
                    DebugFileLogger.log(
                        "LLM[\(model)]: ttft_ms=\(Self.milliseconds(ContinuousClock.now - requestStartedAt)) transport=stream"
                    )
                }
                if let line = try decoder.consume(byte: byte) {
                    lineCount += 1
                    if let identity = Self.streamResponseIdentity(from: line) {
                        responseID = responseID ?? identity.id
                        responseModel = responseModel ?? identity.model
                    }
                    try parser.consume(line: line)
                    if !didRecordFirstContent, parser.hasContent {
                        didRecordFirstContent = true
                        timing?.record("first_content")
                    }
                    if parser.isComplete { break }
                }
            }
            if !parser.isComplete, let line = try decoder.finish() {
                lineCount += 1
                if let identity = Self.streamResponseIdentity(from: line) {
                    responseID = responseID ?? identity.id
                    responseModel = responseModel ?? identity.model
                }
                try parser.consume(line: line)
                if !didRecordFirstContent, parser.hasContent {
                    didRecordFirstContent = true
                    timing?.record("first_content")
                }
            }
        } catch {
            if Self.shouldFlushPendingLine(after: error) {
                do {
                    if let line = try decoder.finish() {
                        if let identity = Self.streamResponseIdentity(from: line) {
                            responseID = responseID ?? identity.id
                            responseModel = responseModel ?? identity.model
                        }
                        try parser.consume(line: line)
                    }
                } catch {
                    throw parser.errorForStreamFailure(error)
                }
            }
            throw parser.errorForStreamFailure(error)
        }

        do {
            let text = try parser.finish(allowIncompleteProbeAnswer: isThinkingProbe)
            if isThinkingProbe, parser.hitOutputTokenLimit {
                DebugFileLogger.log("LLM[\(model)]: thinking probe reached token limit; stream_complete=\(parser.isComplete) reasoning=\(parser.reasoningObserved)")
            }
            if !didRecordFirstContent { timing?.record("first_content") }
            timing?.record("stream_finished")
            return LLMExecutionResult(
                text: text,
                evidence: LLMThinkingProbeEvidence(
                    reportedMode: nil,
                    reasoningObserved: parser.reasoningObserved ? true : nil
                ),
                responseID: responseID,
                responseModel: responseModel,
                httpStatus: 200,
                transport: "stream"
            )
        } catch {
            DebugFileLogger.log("LLM[\(model)]: stream incomplete lines=\(lineCount) terminal=\(parser.isComplete) token_limit=\(parser.hitOutputTokenLimit) reasoning=\(parser.reasoningObserved)")
            throw error
        }
    }

    private static func shouldFlushPendingLine(after error: Error) -> Bool {
        !(error is LLMError)
            && !(error is CancellationError)
            && (error as? URLError)?.code != .cancelled
    }

    private static func streamResponseIdentity(from line: String) -> (id: String?, model: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst("data:".count)
            .trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(ChatStreamChunk.self, from: data) else {
            return nil
        }
        return (chunk.id, chunk.model)
    }

    // MARK: - Non-streaming (single JSON response)

    private func processNonStreaming(
        request: URLRequest,
        model: String,
        requestStartedAt: ContinuousClock.Instant
    ) async throws -> LLMExecutionResult {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.requestFailed(0)
        }
        guard http.statusCode == 200 else {
            let errorData = try await LLMNetworkSession.readPrefix(bytes, limit: 512)
            let errorBody = LLMNetworkSession.sanitizedErrorBody(errorData, limit: 512)
            logger.error("LLM HTTP \(http.statusCode)")
            DebugFileLogger.log(
                "LLM[\(model)]: HTTP \(http.statusCode), retained error bytes=\(errorBody.utf8.count)"
            )
            throw LLMError.requestRejected(http.statusCode, errorBody)
        }
        DebugFileLogger.log(
            "LLM[\(model)]: ttft_ms=\(Self.milliseconds(ContinuousClock.now - requestStartedAt)) transport=nonstream"
        )

        let data = try await LLMNetworkSession.readCapped(
            bytes,
            limit: LLMStreamingParser.defaultMaximumResponseBytes
        )

        guard let json = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data),
              let content = json.choices.first?.message.content, !content.isEmpty else {
            DebugFileLogger.log("LLM[\(model)]: non-streaming empty; raw bytes=\(min(data.count, 300))")
            throw LLMError.emptyResponse(nil)
        }
        guard !json.hitOutputTokenLimit else {
            throw LLMError.truncatedResponse(content.count)
        }
        return LLMExecutionResult(
            text: content,
            evidence: json.thinkingEvidence,
            responseID: json.id,
            responseModel: json.model,
            httpStatus: 200,
            transport: "nonstream"
        )
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1_000
            + Int64(duration.components.attoseconds / 1_000_000_000_000_000)
    }
}

// MARK: - Request/Response Types

private struct LLMExecutionResult: Sendable {
    let text: String
    let evidence: LLMThinkingProbeEvidence
    let responseID: String?
    let responseModel: String?
    let httpStatus: Int?
    let transport: String?

    init(
        text: String,
        evidence: LLMThinkingProbeEvidence,
        responseID: String? = nil,
        responseModel: String? = nil,
        httpStatus: Int? = nil,
        transport: String? = nil
    ) {
        self.text = text
        self.evidence = evidence
        self.responseID = responseID
        self.responseModel = responseModel
        self.httpStatus = httpStatus
        self.transport = transport
    }
}
