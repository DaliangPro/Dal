import AppKit
import CommonCrypto
import Foundation
import Security

/// 仅由显式质量跑测入口写入调用方指定的报告，用来区分模型初稿、修复与
/// 本地处理造成的变化；生产历史和诊断日志不采集正文，也不记录配置或凭据。
struct VoicePolishQualityStageResponse: Codable, Sendable, Equatable {
    let task: String
    let requestPayload: String
    let responseText: String
    // 可选字段保持旧报告可解码；新报告按真实尝试记录失败与耗时。
    var attemptOrdinal: Int? = nil
    var status: String? = nil
    var startedAt: Date? = nil
    var finishedAt: Date? = nil
    var latencyMilliseconds: Int64? = nil
    var failureReason: String? = nil
}

actor VoicePolishProviderAuditSuccessCounter {
    private var count = 0
    private var responses: [VoicePolishQualityStageResponse] = []
    private var runningStarts: [Int: ContinuousClock.Instant] = [:]

    func recordStarted(request: LLMRequest, at startedAt: Date) -> Int {
        let ordinal = responses.count + 1
        runningStarts[ordinal] = .now
        responses.append(VoicePolishQualityStageResponse(
            task: request.task.rawValue,
            requestPayload: request.user,
            responseText: "",
            attemptOrdinal: ordinal,
            status: "running",
            startedAt: startedAt
        ))
        return ordinal
    }

    func recordFinished(
        ordinal: Int,
        response: LLMResponse?,
        error: Error?,
        at finishedAt: Date,
        elapsed: Duration
    ) {
        guard responses.indices.contains(ordinal - 1) else { return }
        guard responses[ordinal - 1].status == "running" else { return }
        let started = responses[ordinal - 1]
        runningStarts.removeValue(forKey: ordinal)
        if response != nil { count += 1 }
        responses[ordinal - 1] = VoicePolishQualityStageResponse(
            task: started.task,
            requestPayload: started.requestPayload,
            responseText: response?.text ?? "",
            attemptOrdinal: ordinal,
            status: response == nil ? "failed" : "succeeded",
            startedAt: started.startedAt,
            finishedAt: finishedAt,
            latencyMilliseconds: VoicePolishQualityRunner.milliseconds(elapsed),
            failureReason: error.map { LogRedactor.redact($0.localizedDescription) }
        )
    }

    func currentCount() -> Int {
        count
    }

    func stageResponses() -> [VoicePolishQualityStageResponse] {
        responses.map { stage in
            guard let ordinal = stage.attemptOrdinal,
                  let startedAt = runningStarts[ordinal] else { return stage }
            // 外层预算可能已经结束，而底层取消尚未返回。保留 running 与空
            // finishedAt，同时给出截至取证时的耗时，不伪造已完成的 Provider 回执。
            var pending = stage
            pending.latencyMilliseconds = VoicePolishQualityRunner.milliseconds(ContinuousClock.now - startedAt)
            return pending
        }
    }
}

/// `AsyncTimeout` 会在 detached task 内执行模型调用，外层 TaskLocal 不会自动继承。
/// 质量 Runner 因此用每条样本独立的客户端包装器，在真正进入 `generate` 时重新
/// 绑定审计上下文，避免请求成功但网络层看不到 nonce、样本 ID 或回执路径。
struct VoicePolishProviderAuditedLLMClient: LLMClient {
    let base: any LLMClient
    let context: VoicePolishProviderAudit.Context
    let successCounter: VoicePolishProviderAuditSuccessCounter
    let requestProbeBodyPath: String?

    init(
        base: any LLMClient,
        runNonce: String,
        testInputID: String,
        receiptPath: String,
        successCounter: VoicePolishProviderAuditSuccessCounter = .init(),
        requestProbeBodyPath: String? = nil
    ) {
        self.base = base
        self.successCounter = successCounter
        self.requestProbeBodyPath = requestProbeBodyPath
        context = VoicePolishProviderAudit.Context(
            runNonce: runNonce,
            testInputID: testInputID,
            receiptPath: receiptPath
        )
    }

    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        let startedAt = ContinuousClock.now
        let ordinal = await successCounter.recordStarted(request: request, at: Date())
        do {
            let response = try await VoicePolishProviderAudit.withContext(
                runNonce: context.runNonce,
                testInputID: context.testInputID,
                receiptPath: context.receiptPath
            ) {
                if let requestProbeBodyPath {
                    return try await VoicePolishProviderAudit.withRequestProbe(bodyPath: requestProbeBodyPath) {
                        try await base.generate(request, config: config)
                    }
                }
                // 未指定路径时保留调用方已在当前任务设置的实验上下文。
                return try await base.generate(request, config: config)
            }
            // 网络层只有在 HTTP 200 响应解析成功且回执已经 fsync 后才返回。
            await successCounter.recordFinished(
                ordinal: ordinal, response: response, error: nil,
                at: Date(), elapsed: ContinuousClock.now - startedAt
            )
            return response
        } catch {
            await successCounter.recordFinished(
                ordinal: ordinal, response: nil, error: error,
                at: Date(), elapsed: ContinuousClock.now - startedAt
            )
            throw error
        }
    }

    func process(
        text: String,
        prompt: String,
        context: LLMRequestContext,
        config: LLMConfig
    ) async throws -> String {
        try await base.process(text: text, prompt: prompt, context: context, config: config)
    }

    func probeThinkingMode(config: LLMConfig) async throws -> LLMThinkingProbeEvidence {
        try await base.probeThinkingMode(config: config)
    }

    func warmUp(baseURL: String) async {
        await base.warmUp(baseURL: baseURL)
    }
}

/// 由签名后的 Dal.app 显式执行的语音润色质量跑测入口。
///
/// XCTest 必须继续使用隔离凭据；该入口只在传入专用参数时运行，复用正式应用
/// 的 Provider 配置，但不会把 API Key 写入参数、日志或报告。
enum VoicePolishQualityRunner {
    private static let reportSchemaVersion = 5

    /// 计时范围和执行分支共用一个判定，兼容旧环境变量但优先使用当前名称。
    static func prefetchBenchmarkPlan(
        for mode: Mode, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard mode == .standard || mode == .light else { return nil }
        return environment["DAL_POLISH_PREFETCH_BENCHMARK_PLAN"]
            ?? environment["DAL_LIGHT_PREFETCH_BENCHMARK_PLAN"]
    }

    enum Mode: String, CaseIterable {
        case direct
        case light
        case standard

        var qualityMode: VoicePolishQualityMode? {
            switch self {
            case .direct: return nil
            case .light: return .standard
            case .standard: return .standard
            }
        }
    }

    struct Invocation: Equatable {
        let runInputPath: String
        let reportPath: String
        let providerAuditPath: String
        let runNonce: String
        let limit: Int?
        let mode: Mode
    }

    private struct QualityRunInputDocument: Decodable {
        let schemaVersion: Int
        let name: String
        let inputs: [QualityInput]
    }

    struct QualityContextFixture: Codable, Equatable {
        let type: String
        let level: WritingContextLevel
        let safety: ContextSafety
        let selectedText: String?
        let textBeforeCursor: String?
        let textAfterCursor: String?
        let recentDalInputs: [String]

        private enum CodingKeys: String, CodingKey {
            case type
            case level
            case safety
            case selectedText
            case textBeforeCursor
            case textAfterCursor
            case recentDalInputs = "recentMuseInputs"
        }

        /// 质量报告必须保留完整夹具，包括显式的 `null` 字段，便于独立评审者
        /// 区分“数据集没有提供”与“Runner 在编码时漏掉了该字段”。
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encode(level, forKey: .level)
            try container.encode(safety, forKey: .safety)
            if let selectedText {
                try container.encode(selectedText, forKey: .selectedText)
            } else {
                try container.encodeNil(forKey: .selectedText)
            }
            if let textBeforeCursor {
                try container.encode(textBeforeCursor, forKey: .textBeforeCursor)
            } else {
                try container.encodeNil(forKey: .textBeforeCursor)
            }
            if let textAfterCursor {
                try container.encode(textAfterCursor, forKey: .textAfterCursor)
            } else {
                try container.encodeNil(forKey: .textAfterCursor)
            }
            try container.encode(recentDalInputs, forKey: .recentDalInputs)
        }
    }

    struct QualityArtifactEvidence: Codable, Equatable {
        let runInputSHA256: String
        let executableSHA256: String
        let sourceCommit: String
    }

    struct QualityReportInputEvidence: Codable, Equatable {
        let segmentTexts: [String]
        let contextFixture: QualityContextFixture
    }

    struct QualityValidationEvidence: Equatable {
        let hardValidationCodes: [String]
        let diagnosticCodes: [String]
    }

    /// 单独定义审计字段拼写，避免 sourceSegmentIDs 的缩写自动编码产生歧义。
    struct QualityResolvedEntityEvidence: Codable, Equatable {
        let surfaceText: String
        let canonical: String
        let sourceSegmentIds: [String]
        let candidateSource: EntityCandidateSource
        let confidence: Double
    }

    static func resolvedEntitiesForReport(_ entities: [ResolvedEntity]) -> [QualityResolvedEntityEvidence] {
        entities.map {
            QualityResolvedEntityEvidence(
                surfaceText: $0.surfaceText, canonical: $0.canonical,
                sourceSegmentIds: $0.sourceSegmentIDs,
                candidateSource: $0.candidateSource, confidence: $0.confidence
            )
        }
    }

    private struct QualityInput: Decodable {
        let testInputId: String
        let baseCaseId: String
        let inputKind: String
        let writingScene: WritingScene
        let spokenInput: String
        let preconditions: [String]
        let contextType: String
        let segmentTexts: [String]
        let contextFixture: QualityContextFixture?
    }

    private struct QualityCaseReport: Codable {
        let testInputID: String
        let baseCaseID: String
        let inputKind: String
        let writingScene: String
        let spokenInput: String
        let canonicalInput: String
        let segmentCount: Int
        let segmentTexts: [String]
        let contextFixture: QualityContextFixture
        let modelOutput: String
        let rejectedModelOutput: String?
        let stageResponses: [VoicePolishQualityStageResponse]
        let detectedRoute: String
        let executedRoute: String
        let internalChunkCount: Int
        let llmCallCount: Int
        let llmAttemptCount: Int
        let latencyMilliseconds: Int64
        let fallbackUsed: Bool
        let hardValidationCodes: [String]
        let diagnosticCodes: [String]
        let failureReason: String?
        var mode: String? = nil
        var startedAt: Date? = nil
        var finishedAt: Date? = nil
        var preResolutionCanonicalInput: String? = nil
        var canonicalSegments: [RecognitionSegment]? = nil
        var resolvedEntities: [QualityResolvedEntityEvidence]? = nil
        var repairAttemptCount: Int? = nil
    }

    private struct QualityRunReport: Codable {
        let schemaVersion: Int
        let status: String
        let error: String?
        let runAt: Date
        let runNonce: String
        let processID: Int32
        let runInputName: String?
        let runInputSchemaVersion: Int?
        let runInputSHA256: String?
        let executableSHA256: String?
        let provider: String
        let model: String?
        let endpointURL: String?
        let promptVersion: Int
        let qualityMode: String
        let commit: String
        let requestedInputCount: Int
        let completedInputCount: Int
        let cases: [QualityCaseReport]
        var mode: String? = nil
        var finishedAt: Date? = nil
        var editingPromptVersion: Int? = nil
        var latencyMeasurementScope: String? = nil
    }

    private enum RunnerError: LocalizedError {
        case missingArgument(String)
        case invalidLimit(String)
        case invalidMode(String)
        case inputTooLong(testID: String, field: String, count: Int)
        case invalidSegments(String)
        case invalidRunNonce(String)
        case duplicateCaseID(String)
        case invalidRunInput
        case forbiddenRunInputField(String)
        case missingLLMConfig
        case noninteractiveKeychainUnavailable(OSStatus)
        case missingExecutableURL
        case missingSourceCommit
        case invalidSourceCommit(String)
        case evidenceFileReadFailed(String)
        case invalidProviderAuditPath(String)
        case providerAuditWasNotEmpty(String)
        case providerAuditUnreadable(String)
        case providerAuditCountMismatch(testID: String, expected: Int, actual: Int)

        var errorDescription: String? {
            switch self {
            case .missingArgument(let argument):
                return "缺少参数 \(argument)"
            case .invalidLimit(let value):
                return "limit 必须是正整数，当前为 \(value)"
            case .invalidMode(let value):
                return "mode 必须是 direct、light 或 standard，当前为 \(value)"
            case .inputTooLong(let testID, let field, let count):
                return "\(testID) 的 \(field) 共 \(count) 字，超过本轮 1,000 字上限；输入未截断"
            case .invalidSegments(let testID):
                return "\(testID) 的源分段必须为非空字符串数组"
            case .invalidRunNonce(let value):
                return "run nonce 必须是 64 位小写十六进制，当前为 \(value)"
            case .duplicateCaseID(let id):
                return "运行输入存在重复 ID：\(id)"
            case .invalidRunInput:
                return "运行输入必须是由 evaluator 生成的无答案 inputs 清单"
            case .forbiddenRunInputField(let field):
                return "运行输入包含禁止交给 Runner 的答案字段：\(field)"
            case .missingLLMConfig:
                return "当前 LLM Provider 没有可用配置"
            case .noninteractiveKeychainUnavailable(let status):
                return "无法禁用质量跑测进程的钥匙串交互，状态码：\(status)"
            case .missingExecutableURL:
                return "无法确定当前运行二进制路径"
            case .missingSourceCommit:
                return "候选应用没有写入 DalSourceCommit，不能作为质量验收制品"
            case .invalidSourceCommit(let value):
                return "候选应用的 DalSourceCommit 无效：\(value)"
            case .evidenceFileReadFailed(let path):
                return "无法读取质量验收证据文件：\(path)"
            case .invalidProviderAuditPath(let path):
                return "Provider 审计路径必须是 Evaluator 预建的绝对常规文件：\(path)"
            case .providerAuditWasNotEmpty(let path):
                return "Provider 审计文件在 Runner 启动前不是空文件：\(path)"
            case .providerAuditUnreadable(let path):
                return "Provider 审计文件无法完整读取：\(path)"
            case .providerAuditCountMismatch(let testID, let expected, let actual):
                return "\(testID) 完成后 Provider 回执累计 \(actual) 条，应为 \(expected) 条"
            }
        }
    }

    @MainActor
    static func startIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        do {
            try VoicePolishRequestProbe.validateOperations(arguments: arguments)
        } catch {
            // 混合入口不能进入授权或配置读取，也不使用可能含凭据的参数写启动报告。
            print("VOICE_POLISH_HEADLESS_FAILED mixed_operations")
            NSApp.terminate(nil)
            return true
        }
        if VoicePolishRequestProbe.startIfRequested(arguments: arguments) { return true }
        if VoicePolishQualityAuthorization.startIfRequested(arguments: arguments) {
            return true
        }
        let invocation: Invocation
        do {
            guard let parsed = try parseInvocation(arguments: arguments) else { return false }
            invocation = parsed
        } catch {
            writeStartupFailure(error, arguments: arguments)
            NSApp.terminate(nil)
            return true
        }

        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await run(invocation)
            NSApp.terminate(nil)
        }
        return true
    }

    static func isRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains("--voice-polish-quality-run")
            || arguments.contains(VoicePolishQualityAuthorization.argument)
            || arguments.contains(VoicePolishRequestProbe.argument)
    }

    static func parseInvocation(arguments: [String]) throws -> Invocation? {
        guard arguments.contains("--voice-polish-quality-run") else { return nil }
        guard !arguments.contains(VoicePolishQualityAuthorization.argument),
              !arguments.contains(VoicePolishRequestProbe.argument) else {
            throw VoicePolishQualityAuthorization.InvocationError.mixedOperations
        }

        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }

        guard let runInputPath = value(after: "--run-input") else {
            throw RunnerError.missingArgument("--run-input")
        }
        guard let reportPath = value(after: "--report") else {
            throw RunnerError.missingArgument("--report")
        }
        guard let providerAuditPath = value(after: "--provider-audit") else {
            throw RunnerError.missingArgument("--provider-audit")
        }
        guard let runNonce = value(after: "--run-nonce") else {
            throw RunnerError.missingArgument("--run-nonce")
        }
        guard runNonce.count == 64,
              runNonce.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...102).contains($0.value)
              }) else {
            throw RunnerError.invalidRunNonce(runNonce)
        }
        let limit: Int?
        if let rawLimit = value(after: "--limit") {
            guard let parsed = Int(rawLimit), parsed > 0 else {
                throw RunnerError.invalidLimit(rawLimit)
            }
            limit = parsed
        } else {
            limit = nil
        }
        // 旧自动编排已删除，必须显式指定 direct 或 standard（light 为 standard 别名）。
        guard arguments.filter({ $0 == "--mode" }).count == 1,
              let rawMode = value(after: "--mode"),
              let parsed = Mode(rawValue: rawMode) else {
            throw RunnerError.invalidMode(value(after: "--mode") ?? "缺失")
        }
        let mode: Mode = parsed == .light ? .standard : parsed
        return Invocation(
            runInputPath: runInputPath,
            reportPath: reportPath,
            providerAuditPath: providerAuditPath,
            runNonce: runNonce,
            limit: limit,
            mode: mode
        )
    }

    /// 默认仅供旧数据集的静态兼容回归；实际 run 始终传入 1,000 字上限。
    static func validatedInputCount(
        at runInputPath: String,
        maximumInputCharacters: Int? = nil
    ) throws -> Int {
        try validatedInputs(
            from: loadRunInput(at: runInputPath),
            maximumInputCharacters: maximumInputCharacters
        ).count
    }

    /// 直出必须在取得任何 Provider 选择、配置、凭据之前分流。
    static func configuration(
        for mode: Mode,
        load: () throws -> (provider: LLMProvider, config: LLMConfig)
    ) rethrows -> (provider: LLMProvider, config: LLMConfig)? {
        guard mode != .direct else { return nil }
        return try load()
    }

    @MainActor
    private static func run(_ invocation: Invocation) async {
        var report = QualityRunReport(
            schemaVersion: reportSchemaVersion,
            status: "running",
            error: nil,
            runAt: Date(),
            runNonce: invocation.runNonce,
            processID: ProcessInfo.processInfo.processIdentifier,
            runInputName: nil,
            runInputSchemaVersion: nil,
            runInputSHA256: nil,
            executableSHA256: nil,
            provider: invocation.mode == .direct ? "none" : "unresolved",
            model: nil,
            endpointURL: nil,
            promptVersion: VoicePolishEditingPrompts.version,
            qualityMode: invocation.mode.qualityMode?.rawValue ?? "direct",
            commit: "unverified",
            requestedInputCount: 0,
            completedInputCount: 0,
            cases: [],
            mode: invocation.mode.rawValue,
            editingPromptVersion: [.light, .standard].contains(invocation.mode)
                ? VoicePolishEditingPrompts.version : nil,
            latencyMeasurementScope: prefetchBenchmarkPlan(for: invocation.mode) == nil
                ? "asr_final_fixture_to_output" : "real_model_simulated_transcript_stop_to_output"
        )

        do {
            let providerAuditURL = try validatedEmptyProviderAuditURL(
                at: invocation.providerAuditPath
            )
            let artifactEvidence = try runtimeArtifactEvidence(
                runInputPath: invocation.runInputPath
            )
            let runInput = try loadRunInput(at: invocation.runInputPath)
            // 先核对全部输入，再应用 limit；缺省兼容调用也不能绕过本轮上限。
            var inputs = try validatedInputs(from: runInput, maximumInputCharacters: 1_000)
            if let limit = invocation.limit {
                inputs = Array(inputs.prefix(limit))
            }
            let configured = try configuration(for: invocation.mode) {
                // 仅润色质量进程关闭本进程的钥匙串交互，不修改存储和安装版。
                let keychainStatus = SecKeychainSetUserInteractionAllowed(false)
                guard keychainStatus == errSecSuccess else {
                    throw RunnerError.noninteractiveKeychainUnavailable(keychainStatus)
                }
                let role = PolishModelRole.resolve(invocation.mode.qualityMode)
                let provider = KeychainService.selectedPolishProvider(for: role)
                guard let loadedConfig = KeychainService.loadPolishConfig(for: role) else {
                    throw RunnerError.missingLLMConfig
                }
                let config = loadedConfig
                return (provider, config)
            }
            let providerClient = configured.map { LLMProviderRegistry.makeClient(for: $0.provider) }
            report = QualityRunReport(
                schemaVersion: report.schemaVersion,
                status: report.status,
                error: nil,
                runAt: report.runAt,
                runNonce: report.runNonce,
                processID: report.processID,
                runInputName: runInput.name,
                runInputSchemaVersion: runInput.schemaVersion,
                runInputSHA256: artifactEvidence.runInputSHA256,
                executableSHA256: artifactEvidence.executableSHA256,
                provider: configured?.provider.rawValue ?? "none",
                model: configured?.config.model,
                endpointURL: try configured.map {
                    try endpointIdentity(rawBaseURL: $0.config.baseURL, provider: $0.provider)
                },
                promptVersion: report.promptVersion,
                qualityMode: report.qualityMode,
                commit: artifactEvidence.sourceCommit,
                requestedInputCount: inputs.count,
                completedInputCount: 0,
                cases: [],
                mode: invocation.mode.rawValue,
                editingPromptVersion: report.editingPromptVersion,
                latencyMeasurementScope: report.latencyMeasurementScope
            )
            try write(report, to: invocation.reportPath)

            var caseReports: [QualityCaseReport] = []
            var expectedProviderReceiptCount = 0
            for (index, input) in inputs.enumerated() {
                if invocation.mode == .direct {
                    caseReports.append(makeDirectCaseReport(for: input))
                    let receiptCount = try providerAuditReceiptCount(at: providerAuditURL)
                    guard receiptCount == 0 else {
                        throw RunnerError.providerAuditCountMismatch(
                            testID: input.testInputId, expected: 0, actual: receiptCount
                        )
                    }
                    report = replacing(
                        report, status: "running", error: nil,
                        completedInputCount: index + 1, cases: caseReports
                    )
                    try write(report, to: invocation.reportPath)
                    print("VOICE_POLISH_QUALITY_PROGRESS \(index + 1)/\(inputs.count) \(input.testInputId)")
                    continue
                }
                guard let configured, let providerClient,
                      let qualityMode = invocation.mode.qualityMode else {
                    throw RunnerError.missingLLMConfig
                }
                let startedAt = ContinuousClock.now
                let wallStartedAt = Date()
                let terminology = terminologyRules(from: input.preconditions)
                let envelope = try makeEnvelope(for: input, terminology: terminology)
                let writingContext = makeWritingContext(for: input)
                let inputEvidence = reportInputEvidence(
                    segmentTexts: input.segmentTexts,
                    contextFixture: input.contextFixture,
                    contextType: input.contextType,
                    appliedContext: writingContext
                )
                // 与正式 RecognitionSession 保持同一条链路：安全上下文先参与
                // 高置信实体解析，再随 payload 交给模型。否则质量跑测只测到了
                // Prompt 是否偶然看懂上下文，不能代表安装版的真实行为。
                let resolvedEntities = EntityResolver.resolve(
                    segments: envelope.segments,
                    lexicon: .empty,
                    snippets: [],
                    hotwords: [],
                    context: writingContext
                )
                let request = VoicePolishRequest(
                    input: envelope,
                    context: writingContext,
                    preferences: UserPolishPreferences(additionalRequirements: ""),
                    qualityMode: qualityMode,
                    resolvedEntities: resolvedEntities
                )
                let canonicalInput = request.fallbackText
                let successCounter = VoicePolishProviderAuditSuccessCounter()
                let requestProbeBodyPath: String?
                if invocation.mode == .standard,
                   ProcessInfo.processInfo.environment["DAL_QUALITY_CAPTURE_LIGHT_REQUEST_BODY"] == "1" {
                    // 路径随客户端进入真正的 generate，跨越管线内部的 detached 超时任务。
                    requestProbeBodyPath = URL(fileURLWithPath: invocation.reportPath).deletingLastPathComponent()
                        .appendingPathComponent("light-request-\(index + 1).json").path
                } else {
                    requestProbeBodyPath = nil
                }
                let auditedClient = VoicePolishProviderAuditedLLMClient(
                    base: providerClient,
                    runNonce: invocation.runNonce,
                    testInputID: input.testInputId,
                    receiptPath: providerAuditURL.path,
                    successCounter: successCounter,
                    requestProbeBodyPath: requestProbeBodyPath
                )
                let pipeline = VoicePolishEditingPipeline(client: auditedClient, config: configured.config)
                let result: VoicePolishResult
                let elapsed: Duration
                if let planPath = prefetchBenchmarkPlan(for: invocation.mode) {
                    let measured = try await PolishPrefetchBenchmark.run(
                        planPath: planPath, caseID: input.testInputId, request: request,
                        client: auditedClient, provider: configured.provider, config: configured.config,
                        outputPath: invocation.reportPath + ".prefetch.jsonl")
                    result = measured.result
                    elapsed = measured.elapsed
                    // 计时已冻结；等待被取消请求的审计收尾，不算入出稿耗时。
                    for _ in 0..<100 {
                        if !(await successCounter.stageResponses()).contains(where: { $0.status == "running" }) { break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                } else {
                    result = await pipeline.process(request)
                    elapsed = ContinuousClock.now - startedAt
                }
                let successfulProviderCallCount = await successCounter.currentCount()
                expectedProviderReceiptCount += successfulProviderCallCount
                let actualProviderReceiptCount = try providerAuditReceiptCount(
                    at: providerAuditURL
                )
                guard actualProviderReceiptCount == expectedProviderReceiptCount else {
                    throw RunnerError.providerAuditCountMismatch(
                        testID: input.testInputId,
                        expected: expectedProviderReceiptCount,
                        actual: actualProviderReceiptCount
                    )
                }
                let validationEvidence = validationEvidence(for: result.validationCodes)
                caseReports.append(QualityCaseReport(
                    testInputID: input.testInputId,
                    baseCaseID: input.baseCaseId,
                    inputKind: input.inputKind,
                    writingScene: input.writingScene.rawValue,
                    spokenInput: input.spokenInput,
                    canonicalInput: canonicalInput,
                    segmentCount: inputEvidence.segmentTexts.count,
                    segmentTexts: inputEvidence.segmentTexts,
                    contextFixture: inputEvidence.contextFixture,
                    modelOutput: result.text,
                    rejectedModelOutput: result.rejectedDraft,
                    stageResponses: await successCounter.stageResponses(),
                    detectedRoute: result.detectedRoute.rawValue,
                    executedRoute: result.executedRoute.rawValue,
                    // 润色整段单次编辑，不再分片。
                    internalChunkCount: 1,
                    llmCallCount: successfulProviderCallCount,
                    llmAttemptCount: result.llmAttemptCount,
                    latencyMilliseconds: milliseconds(elapsed),
                    fallbackUsed: result.usedFallback,
                    hardValidationCodes: validationEvidence.hardValidationCodes,
                    diagnosticCodes: validationEvidence.diagnosticCodes,
                    failureReason: result.failureReason?.rawValue,
                    mode: invocation.mode.rawValue,
                    startedAt: wallStartedAt,
                    finishedAt: Date(),
                    preResolutionCanonicalInput: envelope.fallbackText,
                    canonicalSegments: envelope.segments,
                    resolvedEntities: resolvedEntitiesForReport(resolvedEntities),
                    repairAttemptCount: result.repairAttemptCount
                ))
                report = replacing(
                    report,
                    status: "running",
                    error: nil,
                    completedInputCount: index + 1,
                    cases: caseReports
                )
                try write(report, to: invocation.reportPath)
                print("VOICE_POLISH_QUALITY_PROGRESS \(index + 1)/\(inputs.count) \(input.testInputId)")
            }

            report = replacing(
                report,
                status: "complete",
                error: nil,
                completedInputCount: caseReports.count,
                cases: caseReports
            )
            try write(report, to: invocation.reportPath)
            print("VOICE_POLISH_QUALITY_COMPLETE \(caseReports.count)")
        } catch {
            report = replacing(
                report,
                status: "failed",
                error: LogRedactor.redact(error.localizedDescription),
                completedInputCount: report.cases.count,
                cases: report.cases
            )
            try? write(report, to: invocation.reportPath)
            print("VOICE_POLISH_QUALITY_FAILED \(LogRedactor.redact(error.localizedDescription))")
        }
    }

    private static let forbiddenRunInputFields: Set<String> = [
        "automatic_checks",
        "factor_assertions",
        "must_not_invent",
        "must_preserve",
        "must_remove",
        "quality_dimensions",
        "reference_output",
        "requires_transformation",
    ]

    /// Runner 只接受 evaluator 派生的无答案输入清单。先检查原始 JSON 键，避免
    /// `JSONDecoder` 静默忽略答案字段后，让完整母集看起来也像合法运行输入。
    private static func loadRunInput(at path: String) throws -> QualityRunInputDocument {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawInputs = object["inputs"] as? [[String: Any]] else {
            throw RunnerError.invalidRunInput
        }
        for rawInput in rawInputs {
            if let forbidden = forbiddenRunInputFields.first(where: rawInput.keys.contains) {
                throw RunnerError.forbiddenRunInputField(forbidden)
            }
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(QualityRunInputDocument.self, from: data)
    }

    private static func validatedInputs(
        from document: QualityRunInputDocument,
        maximumInputCharacters: Int? = nil
    ) throws -> [QualityInput] {
        var seenIDs = Set<String>()
        for item in document.inputs {
            guard seenIDs.insert(item.testInputId).inserted else {
                throw RunnerError.duplicateCaseID(item.testInputId)
            }
            if let maximumInputCharacters {
                let segmentText = item.segmentTexts.joined()
                for (field, text) in [("spoken_input", item.spokenInput), ("segment_texts", segmentText)] {
                    // 与 Python 验收脚本的 len 一致，组合字符不能绕过原始输入上限。
                    let characterCount = text.unicodeScalars.count
                    guard characterCount <= maximumInputCharacters else {
                        throw RunnerError.inputTooLong(
                            testID: item.testInputId, field: field, count: characterCount
                        )
                    }
                }
                guard !item.segmentTexts.isEmpty,
                      item.segmentTexts.allSatisfy({ !$0.isEmpty }) else {
                    throw RunnerError.invalidSegments(item.testInputId)
                }
            }
        }
        return document.inputs
    }

    /// 固定为空个人词库和空片段；只应用测试夹具明确给定的已确认术语。
    /// 与正式直出共用纠词、插入前清理纯函数，不读取配置、上下文或凭据。
    static func directOutput(_ spokenInput: String, terminology: [String: String] = [:]) -> String {
        let canonical = EntityResolver.applyingKnownCorrections(terminology, to: spokenInput)
        let mode = ProcessingMode(
            id: ProcessingMode.directId,
            name: "直出",
            prompt: "",
            isBuiltin: true,
            processingLabel: "直出",
            hotkeyStyle: .toggle
        )
        return RecognitionSession.finalizeInsertionText(canonical, mode: mode, isLLMOutput: false)
    }

    private static func makeDirectCaseReport(for input: QualityInput) -> QualityCaseReport {
        let startedAt = ContinuousClock.now
        let wallStartedAt = Date()
        let terminology = terminologyRules(from: input.preconditions)
        let canonical = EntityResolver.applyingKnownCorrections(terminology, to: input.spokenInput)
        let output = directOutput(input.spokenInput, terminology: terminology)
        let inputEvidence = reportInputEvidence(
            segmentTexts: input.segmentTexts,
            contextFixture: input.contextFixture,
            contextType: input.contextType,
            appliedContext: makeWritingContext(for: input)
        )
        return QualityCaseReport(
            testInputID: input.testInputId,
            baseCaseID: input.baseCaseId,
            inputKind: input.inputKind,
            writingScene: input.writingScene.rawValue,
            spokenInput: input.spokenInput,
            canonicalInput: canonical,
            segmentCount: inputEvidence.segmentTexts.count,
            segmentTexts: inputEvidence.segmentTexts,
            contextFixture: inputEvidence.contextFixture,
            modelOutput: output,
            rejectedModelOutput: nil,
            stageResponses: [],
            detectedRoute: "direct",
            executedRoute: "direct",
            internalChunkCount: 0,
            llmCallCount: 0,
            llmAttemptCount: 0,
            latencyMilliseconds: milliseconds(ContinuousClock.now - startedAt),
            fallbackUsed: false,
            hardValidationCodes: [],
            diagnosticCodes: [],
            failureReason: nil,
            mode: Mode.direct.rawValue,
            startedAt: wallStartedAt,
            finishedAt: Date(),
            preResolutionCanonicalInput: canonical,
            canonicalSegments: [],
            resolvedEntities: [],
            repairAttemptCount: 0
        )
    }

    /// 只读隔离夹具并执行正式直出报告构造器，不启动应用或访问真实用户设置。
    static func directCaseReportsForTesting(at path: String) throws -> Data {
        let inputs = try validatedInputs(from: loadRunInput(at: path), maximumInputCharacters: 1_000)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(inputs.map(makeDirectCaseReport))
    }

    private static func makeEnvelope(
        for input: QualityInput,
        terminology: [String: String]
    ) throws -> VoiceInputEnvelope {
        // 完整终稿是唯一编辑来源。ASR 原始分段可能没有终稿新增的段落；
        // 共用生产构造器的保守回退，不能用拼段结果覆盖全文。
        let canonical = EntityResolver.applyingKnownCorrections(terminology, to: input.spokenInput)
        let transcript = RecognitionTranscript(
            confirmedSegments: input.segmentTexts,
            partialText: "",
            authoritativeText: input.spokenInput,
            isFinal: true
        )
        guard let envelope = VoiceInputEnvelope.fromFinalTranscript(
            transcript,
            rawFinalText: input.spokenInput,
            canonicalText: canonical,
            preferredCanonicalSegmentTexts: input.segmentTexts.map {
                EntityResolver.applyingKnownCorrections(terminology, to: $0)
            },
            deterministicCorrections: terminology,
            durationMs: 0,
            // 固定文本夹具没有真实 ASR 调用，不读取用户 ASR 设置冒充本次来源。
            provider: .volcano
        ) else {
            throw RunnerError.invalidRunInput
        }
        return envelope
    }

    static func envelopesForTesting(at path: String) throws -> [VoiceInputEnvelope] {
        try validatedInputs(from: loadRunInput(at: path), maximumInputCharacters: 1_000).map {
            try makeEnvelope(for: $0, terminology: terminologyRules(from: $0.preconditions))
        }
    }

    private static func makeWritingContext(for input: QualityInput) -> WritingContext {
        guard let fixture = input.contextFixture else {
            return WritingContext(
                scene: input.writingScene,
                level: .metadataOnly,
                safety: .unknown
            )
        }
        return WritingContext(
            scene: input.writingScene,
            level: fixture.level,
            safety: fixture.safety,
            selectedText: fixture.selectedText,
            textBeforeCursor: fixture.textBeforeCursor,
            textAfterCursor: fixture.textAfterCursor,
            recentDalInputs: fixture.recentDalInputs
        )
    }

    /// 报告记录 Runner 实际用于构造请求的分段，同时完整保留数据集上下文夹具。
    /// 没有显式夹具时也写出真实采用的默认上下文，而不是省略字段。
    static func reportInputEvidence(
        segmentTexts: [String],
        contextFixture: QualityContextFixture?,
        contextType: String,
        appliedContext: WritingContext
    ) -> QualityReportInputEvidence {
        let completeFixture = contextFixture ?? QualityContextFixture(
            type: contextType,
            level: appliedContext.level,
            safety: appliedContext.safety,
            selectedText: appliedContext.selectedText,
            textBeforeCursor: appliedContext.textBeforeCursor,
            textAfterCursor: appliedContext.textAfterCursor,
            recentDalInputs: appliedContext.recentDalInputs
        )
        return QualityReportInputEvidence(
            segmentTexts: segmentTexts,
            contextFixture: completeFixture
        )
    }

    private static func terminologyRules(from preconditions: [String]) -> [String: String] {
        var rules: [String: String] = [:]
        for precondition in preconditions {
            guard let arrow = precondition.range(of: "→") else { continue }
            var alias = String(precondition[..<arrow.lowerBound])
            if let marker = alias.range(of: "已确认 ", options: .backwards) {
                alias = String(alias[marker.upperBound...])
            }
            let canonical = String(precondition[arrow.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            if !alias.isEmpty, !canonical.isEmpty {
                rules[alias] = canonical
            }
        }
        return rules
    }

    /// 报告的是客户端最终请求地址，而不是设置里保存的 base URL。
    static func endpointIdentity(
        rawBaseURL: String,
        provider: LLMProvider,
        localQwenPort: Int? = nil
    ) throws -> String {
        let baseURL = try LLMEndpointPolicy.normalizedBaseURL(
            rawValue: rawBaseURL,
            provider: provider,
            localQwenPort: provider == .localQwen
                ? (localQwenPort ?? LLMEndpointPolicy.currentLocalQwenPort)
                : nil
        )
        let endpoint = try LLMEndpointPolicy.endpoint(
            baseURL: baseURL,
            pathComponents: provider == .claude ? ["messages"] : ["chat", "completions"]
        )
        guard let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              let host = components.host else {
            throw LLMEndpointPolicyError.invalidURL
        }
        let port = components.port.map { ":\($0)" } ?? ""
        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return "\(scheme.lowercased())://\(host.lowercased())\(port)\(path)"
    }

    static func validationEvidence(
        for codes: [VoicePolishValidationCode]
    ) -> QualityValidationEvidence {
        QualityValidationEvidence(
            hardValidationCodes: codes.filter(\.isHardFailure).map(\.rawValue),
            diagnosticCodes: codes.filter { !$0.isHardFailure }.map(\.rawValue)
        )
    }

    /// 测试可显式注入伪二进制；生产路径不接受 CLI 或调用方传入的二进制地址，
    /// 始终从 `Bundle.main.executableURL` 读取当前进程制品。
    static func artifactEvidenceForTesting(
        runInputURL: URL,
        executableURL: URL,
        sourceCommit: String = String(repeating: "0", count: 40)
    ) throws -> QualityArtifactEvidence {
        try makeArtifactEvidence(
            runInputURL: runInputURL,
            executableURL: executableURL,
            sourceCommit: sourceCommit
        )
    }

    private static func makeArtifactEvidence(
        runInputURL: URL,
        executableURL: URL,
        sourceCommit: String
    ) throws -> QualityArtifactEvidence {
        let normalizedCommit = try validatedSourceCommit(sourceCommit)
        let runInputSHA256 = try sha256(fileAt: runInputURL)
        let executableSHA256 = try sha256(fileAt: executableURL)
        return QualityArtifactEvidence(
            runInputSHA256: runInputSHA256,
            executableSHA256: executableSHA256,
            sourceCommit: normalizedCommit
        )
    }

    private static func validatedSourceCommit(_ rawValue: String?) throws -> String {
        guard let rawValue else { throw RunnerError.missingSourceCommit }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 40,
              value.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...102).contains($0.value)
              }) else {
            throw RunnerError.invalidSourceCommit(value)
        }
        return value
    }

    private static func runtimeArtifactEvidence(
        runInputPath: String
    ) throws -> QualityArtifactEvidence {
        guard let executableURL = Bundle.main.executableURL else {
            throw RunnerError.missingExecutableURL
        }
        let sourceCommit = try validatedSourceCommit(
            Bundle.main.object(forInfoDictionaryKey: "DalSourceCommit") as? String
        )
        return try makeArtifactEvidence(
            runInputURL: URL(fileURLWithPath: runInputPath),
            executableURL: executableURL,
            sourceCommit: sourceCommit
        )
    }

    private static func sha256(fileAt url: URL) throws -> String {
        guard let stream = InputStream(url: url) else {
            throw RunnerError.evidenceFileReadFailed(url.path)
        }
        stream.open()
        defer { stream.close() }

        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)

        let bufferSize = 1024 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while true {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count > 0 {
                CC_SHA256_Update(&context, buffer, CC_LONG(count))
            } else if count == 0 {
                break
            } else {
                throw stream.streamError
                    ?? RunnerError.evidenceFileReadFailed(url.path)
            }
        }

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func validatedEmptyProviderAuditURL(at path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard path.hasPrefix("/"), url.path == path,
              let values = try? url.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw RunnerError.invalidProviderAuditPath(path)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard (attributes[.size] as? NSNumber)?.intValue == 0 else {
            throw RunnerError.providerAuditWasNotEmpty(path)
        }
        return url
    }

    private static func providerAuditReceiptCount(at url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return 0 }
        guard data.last == 0x0A else {
            throw RunnerError.providerAuditUnreadable(url.path)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        do {
            for line in lines {
                _ = try decoder.decode(
                    VoicePolishProviderAuditReceipt.self,
                    from: Data(line)
                )
            }
        } catch {
            throw RunnerError.providerAuditUnreadable(url.path)
        }
        return lines.count
    }

    static func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1_000
            + Int64(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func replacing(
        _ report: QualityRunReport,
        status: String,
        error: String?,
        completedInputCount: Int,
        cases: [QualityCaseReport]
    ) -> QualityRunReport {
        QualityRunReport(
            schemaVersion: report.schemaVersion,
            status: status,
            error: error,
            runAt: report.runAt,
            runNonce: report.runNonce,
            processID: report.processID,
            runInputName: report.runInputName,
            runInputSchemaVersion: report.runInputSchemaVersion,
            runInputSHA256: report.runInputSHA256,
            executableSHA256: report.executableSHA256,
            provider: report.provider,
            model: report.model,
            endpointURL: report.endpointURL,
            promptVersion: report.promptVersion,
            qualityMode: report.qualityMode,
            commit: report.commit,
            requestedInputCount: report.requestedInputCount,
            completedInputCount: completedInputCount,
            cases: cases,
            mode: report.mode,
            finishedAt: status == "running" ? nil : Date(),
            editingPromptVersion: report.editingPromptVersion,
            latencyMeasurementScope: report.latencyMeasurementScope
        )
    }

    private static func write(_ report: QualityRunReport, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    @MainActor
    private static func writeStartupFailure(_ error: Error, arguments: [String]) {
        guard let reportIndex = arguments.firstIndex(of: "--report"),
              arguments.indices.contains(reportIndex + 1) else { return }
        let runNonce: String
        if let nonceIndex = arguments.firstIndex(of: "--run-nonce"),
           arguments.indices.contains(nonceIndex + 1) {
            runNonce = arguments[nonceIndex + 1]
        } else {
            runNonce = "invalid"
        }
        var artifactEvidence: QualityArtifactEvidence?
        if let runInputIndex = arguments.firstIndex(of: "--run-input"),
           arguments.indices.contains(runInputIndex + 1) {
            artifactEvidence = try? runtimeArtifactEvidence(
                runInputPath: arguments[runInputIndex + 1]
            )
        }
        let report = QualityRunReport(
            schemaVersion: reportSchemaVersion,
            status: "failed",
            error: LogRedactor.redact(error.localizedDescription),
            runAt: Date(),
            runNonce: runNonce,
            processID: ProcessInfo.processInfo.processIdentifier,
            runInputName: nil,
            runInputSchemaVersion: nil,
            runInputSHA256: artifactEvidence?.runInputSHA256,
            executableSHA256: artifactEvidence?.executableSHA256,
            provider: "unknown",
            model: nil,
            endpointURL: nil,
            promptVersion: VoicePolishEditingPrompts.version,
            qualityMode: startupMode(arguments: arguments),
            commit: artifactEvidence?.sourceCommit ?? "unknown",
            requestedInputCount: 0,
            completedInputCount: 0,
            cases: [],
            mode: startupMode(arguments: arguments),
            finishedAt: Date(),
            editingPromptVersion: [Mode.light.rawValue, Mode.standard.rawValue].contains(
                startupMode(arguments: arguments)
            ) ? VoicePolishEditingPrompts.version : nil,
            latencyMeasurementScope: "asr_final_fixture_to_output"
        )
        try? write(report, to: arguments[reportIndex + 1])
    }

    private static func startupMode(arguments: [String]) -> String {
        guard let index = arguments.firstIndex(of: "--mode"),
              arguments.indices.contains(index + 1),
              let mode = Mode(rawValue: arguments[index + 1]) else {
            return "invalid"
        }
        return (mode == .light ? Mode.standard : mode).rawValue
    }
}
