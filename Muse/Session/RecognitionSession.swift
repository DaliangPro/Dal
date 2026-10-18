import AppKit
import os

private struct ASRTeardownResult: Sendable {
    let providerIsStreaming: Bool
    let endAudioSucceeded: Bool
    let eventStreamDrained: Bool

    var clean: Bool {
        endAudioSucceeded && eventStreamDrained
    }
}

private struct BatchFallbackTimeoutError: Error {}

private enum VoicePolishUserChoice: Sendable {
    case retry
    case cancel
}

private enum TranscriptRecoveryResult: Sendable, Equatable {
    case notNeeded
    case succeeded
    case failed
}

private enum ASRRecoveryError: Error, LocalizedError {
    case partialTextPreserved(provider: String)
    case noTranscript(provider: String)

    var errorDescription: String? {
        switch self {
        case .partialTextPreserved(let provider):
            return L(
                "\(provider) 全文重识别失败，已保留现有文字，内容可能不完整",
                "\(provider) full re-recognition failed. Existing text was preserved and may be incomplete."
            )
        case .noTranscript(let provider):
            return L(
                "\(provider) 未返回识别结果，请重试或暂时切换到豆包",
                "\(provider) returned no transcript. Try again or temporarily switch to Doubao."
            )
        }
    }
}

struct RecognitionSessionID: Hashable, Sendable {
    let rawValue: UInt64
}

/// REPAIR_PLAN K4：ASR 连接的会话级超时（底层 URLSession 默认 60s 过长）
struct ASRConnectTimeoutError: Error, LocalizedError {
    var errorDescription: String? {
        L("识别服务连接超时，请检查网络后重试",
          "ASR connection timed out. Check your network and try again.")
    }
}

private struct LLMPostProcessingResult: Sendable {
    var finalText: String
    var processedText: String?
    var llmFailed: Bool
    var voicePolishHistoryStatus: String?
    var voicePolishPerformance: VoicePolishPerformanceMeasurement?
    var voicePolishVocabularyContext: VocabularyStorageContext?
}

actor RecognitionSession {

    // MARK: - State

    enum SessionState: Equatable, Sendable {
        case idle
        case starting
        case recording
        case finishing
        case injecting
        case postProcessing  // Phase 3
    }

    private(set) var state: SessionState = .idle

    var canStartRecording: Bool { state == .idle }

    /// Exposed for testing; production code should use startRecording / stopRecording.
    func setState(_ newState: SessionState) {
        state = newState
    }

    /// Exposed for testing; production code should resolve modes through startRecording / switchMode.
    func currentModeForTesting() -> ProcessingMode {
        currentMode
    }

    // MARK: - Dependencies

    private let audioEngine: any AudioCaptureControlling
    private let injectionEngine: any TextInjecting
    let historyStore: HistoryStore
    private let asrClientFactory: @Sendable (ASRProvider) -> (any SpeechRecognizer)?
    private let selectedASRProvider: @Sendable () -> ASRProvider
    private let asrConfigLoader: (@Sendable (ASRProvider) async -> (any ASRProviderConfig)?)?
    private let microphonePermission: (@Sendable () async -> Bool)?
    private let promptContextCapture: @Sendable () async -> PromptContext
    private let writingContextCapture: @Sendable (WritingContextLevel) async -> WritingContext
    private let frontmostApplicationBundleIdentifier: @Sendable () async -> String?
    private let requestOptionsProvider: (@Sendable (ProcessingMode) -> (
        options: ASRRequestOptions,
        hotwordCount: Int
    ))?
    private let llmClientFactory: (@Sendable () -> any LLMClient)?
    private let llmConfigLoader: (@Sendable () async -> LLMConfig?)?
    private let voicePolishRecentInputStore: VoicePolishRecentInputContextStore
    private let aliyunReplaySleep: @Sendable (Duration) async throws -> Void
    private let editLearningMonitor: PostInjectionEditLearningMonitor
    private let editLearningFieldCapture: @Sendable () async -> PostInjectionLearningFieldCapture
    private let sessionVocabularyContext: VocabularyStorageContext
    private var asrClient: (any SpeechRecognizer)?
    private var asrClientSessionID: RecognitionSessionID?

    init(
        audioEngine: any AudioCaptureControlling = AudioCaptureEngine(),
        injectionEngine: any TextInjecting = TextInjectionEngine(),
        historyStore: HistoryStore = HistoryStore(),
        asrClientFactory: @escaping @Sendable (ASRProvider) -> (any SpeechRecognizer)? = {
            ASRProviderRegistry.createClient(for: $0)
        },
        selectedASRProvider: @escaping @Sendable () -> ASRProvider = {
            KeychainService.selectedASRProvider
        },
        asrConfigLoader: (@Sendable (ASRProvider) async -> (any ASRProviderConfig)?)? = nil,
        microphonePermission: (@Sendable () async -> Bool)? = nil,
        promptContextCapture: @escaping @Sendable () async -> PromptContext = {
            PromptContext.capture()
        },
        writingContextCapture: @escaping @Sendable (WritingContextLevel) async -> WritingContext = {
            await WritingContextCapture.capture(level: $0)
        },
        frontmostApplicationBundleIdentifier: @escaping @Sendable () async -> String? = {
            await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            }
        },
        requestOptionsProvider: (@Sendable (ProcessingMode) -> (
            options: ASRRequestOptions,
            hotwordCount: Int
        ))? = nil,
        llmClientFactory: (@Sendable () -> any LLMClient)? = nil,
        llmConfigLoader: (@Sendable () async -> LLMConfig?)? = nil,
        voicePolishRecentInputStore: VoicePolishRecentInputContextStore = .shared,
        aliyunReplaySleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        editLearningMonitor: PostInjectionEditLearningMonitor = .shared,
        editLearningFieldCapture: @escaping @Sendable () async -> PostInjectionLearningFieldCapture = {
            await PostInjectionEditLearningMonitor.focusedField()
        },
        vocabularyContext: VocabularyStorageContext = .production
    ) {
        self.audioEngine = audioEngine
        self.injectionEngine = injectionEngine
        self.historyStore = historyStore
        self.asrClientFactory = asrClientFactory
        self.selectedASRProvider = selectedASRProvider
        self.asrConfigLoader = asrConfigLoader
        self.microphonePermission = microphonePermission
        self.promptContextCapture = promptContextCapture
        self.writingContextCapture = writingContextCapture
        self.frontmostApplicationBundleIdentifier = frontmostApplicationBundleIdentifier
        self.requestOptionsProvider = requestOptionsProvider
        self.llmClientFactory = llmClientFactory
        self.llmConfigLoader = llmConfigLoader
        self.voicePolishRecentInputStore = voicePolishRecentInputStore
        self.aliyunReplaySleep = aliyunReplaySleep
        self.editLearningMonitor = editLearningMonitor
        self.editLearningFieldCapture = editLearningFieldCapture
        self.sessionVocabularyContext = vocabularyContext
    }

    private let logger = Logger(
        subsystem: "pro.daliang.muse.session",
        category: "RecognitionSession"
    )

    /// REPAIR_PLAN J12：LLM 后处理的会话级硬超时。底层 request timeout(30s) 是
    /// 「无数据间隔」语义，流式慢速涓流可无限拖延；45s 高于底层正常超时（不抢跑），
    /// 超时按 LLM 失败处理回退原文，HUD 不再卡死在 postProcessing。
    static let llmPostProcessTimeout: Duration = .seconds(45)

    /// REPAIR_PLAN K4：ASR 连接会话级超时。实测正常握手 <1s；网络异常时
    /// URLSession 默认 60s 会让用户对着无字幕的 HUD 干等，10s 即判失败走报错路径。
    static let asrConnectTimeout: Duration = .seconds(10)

    /// Return the appropriate LLM client for the currently selected provider.
    private func currentLLMClient() -> any LLMClient {
        if let llmClientFactory { return llmClientFactory() }
        return LLMProviderRegistry.makeClient(for: KeychainService.selectedPolishProvider(
            for: .resolve(currentMode.voicePolishQualityMode)
        ))
    }

    private func loadASRConfigOffActor(for provider: ASRProvider) async -> (any ASRProviderConfig)? {
        DebugFileLogger.log("ASR config load start provider=\(provider.rawValue)")
        let result: TimedValue<any ASRProviderConfig> = await AsyncTimeout.value(.milliseconds(900)) {
            KeychainService.loadASRConfig(for: provider)
        }
        if result.timedOut {
            DebugFileLogger.log("ASR config load timeout provider=\(provider.rawValue)")
        } else {
            DebugFileLogger.log("ASR config load done provider=\(provider.rawValue) hasConfig=\(result.value != nil)")
        }
        return result.value
    }

    private func loadLLMConfigOffActor() async -> LLMConfig? {
        if let llmConfigLoader {
            return await llmConfigLoader()
        }
        let role = PolishModelRole.resolve(currentMode.voicePolishQualityMode)
        let provider = KeychainService.selectedPolishProvider(for: role)
        DebugFileLogger.log("LLM config load start provider=\(provider.rawValue)")
        let result: TimedValue<LLMConfig> = await AsyncTimeout.value(.milliseconds(900)) {
            KeychainService.loadPolishConfig(for: role)
        }
        if result.timedOut {
            DebugFileLogger.log("LLM config load timeout provider=\(provider.rawValue)")
        } else {
            DebugFileLogger.log("LLM config load done provider=\(provider.rawValue) hasConfig=\(result.value != nil)")
        }
        return result.value
    }

    /// Pre-initialize audio subsystem so the first recording starts instantly.
    func warmUp() { audioEngine.warmUp() }

    // MARK: - Mode & Timing

    private var currentMode: ProcessingMode = .direct
    private var recordingStartTime: Date?
    private var recordingStartSessionID: RecognitionSessionID?
    private var currentConfig: (any ASRProviderConfig)?
    private var currentConfigSessionID: RecognitionSessionID?
    /// The ASR provider for the current session, captured at start time.
    /// stopRecording reads this, not the global setting.
    private var activeProvider: ASRProvider = .volcano

    // MARK: - UI Callback

    /// Called on every ASR event so the UI layer can update.
    /// Set by AppDelegate to bridge actor → @MainActor.
    private var onASREvent: (@Sendable (RecognitionEvent) -> Void)?

    func setOnASREvent(_ handler: @escaping @Sendable (RecognitionEvent) -> Void) {
        onASREvent = handler
    }

    /// Called with normalized audio level (0..1) for UI visualization.
    private var onAudioLevel: (@Sendable (Float) -> Void)?

    func setOnAudioLevel(_ handler: @escaping @Sendable (Float) -> Void) {
        onAudioLevel = handler
    }

    // MARK: - Session identity (prevents zombie tasks after reset/restart)

    private var nextSessionIDRawValue: UInt64 = 0
    private var currentSessionID: RecognitionSessionID?

    private func makeSessionID() -> RecognitionSessionID {
        nextSessionIDRawValue &+= 1
        return RecognitionSessionID(rawValue: nextSessionIDRawValue)
    }

    private func isCurrent(_ sessionID: RecognitionSessionID) -> Bool {
        currentSessionID == sessionID
    }

    private func ownsASRClient(
        _ client: any SpeechRecognizer,
        sessionID: RecognitionSessionID
    ) -> Bool {
        guard currentSessionID == sessionID,
              asrClientSessionID == sessionID,
              let activeClient = asrClient else {
            return false
        }
        return ObjectIdentifier(activeClient) == ObjectIdentifier(client)
    }

    private func clearASRClientIfOwned(
        _ client: any SpeechRecognizer,
        sessionID: RecognitionSessionID
    ) {
        guard ownsASRClient(client, sessionID: sessionID) else { return }
        asrClient = nil
        asrClientSessionID = nil
    }

    // MARK: - Accumulated text

    private var currentTranscript: RecognitionTranscript = .empty
    private var eventConsumptionTask: Task<Void, Never>?
    private var eventConsumptionTaskSessionID: RecognitionSessionID?
    private var eventConsumptionTaskToken: UUID?
    private var hasEmittedReadyForCurrentSession = false
    private var audioChunkPipeline: AudioChunkUploadPipeline?
    private var audioChunkPipelineSessionID: RecognitionSessionID?
    private var audioCaptureSessionID: RecognitionSessionID?
    /// REPAIR_PLAN B7b：本次会话流式是否降级（断流/重连过），停止时强制批量复核
    private var streamingDegraded = false

    // MARK: - Prompt context (selected text + clipboard captured at recording start)

    private var promptContext: PromptContext = PromptContext(selectedText: "", clipboardText: "")

    // MARK: - Voice Polish writing context（录音启动时并行，400ms 超时）

    private var writingContextTask: Task<WritingContext, Never>?
    private var writingContextTaskSessionID: RecognitionSessionID?
    /// 录音开始时冻结目标应用，避免停止或 HUD 切换焦点后把应用级术语套到错误应用。
    private var targetApplicationBundleIdentifier: String?
    private var targetApplicationBundleIdentifierSessionID: RecognitionSessionID?

    // MARK: - Active Voice Polish task

    private var voicePolishTask: Task<VoicePolishResult, Never>?
    private var voicePolishTaskSessionID: RecognitionSessionID?
    private var voicePolishProcessingSessionID: RecognitionSessionID?
    private var voicePolishChoiceSessionID: RecognitionSessionID?
    private var voicePolishChoiceContinuation: CheckedContinuation<VoicePolishUserChoice, Never>?

    // MARK: - Speculative LLM (fire during recording pauses)

    private let polishPrefetch = PolishPrefetch()
    private var speculativeLLMTask: Task<String?, Never>?
    private var speculativeLLMSessionID: RecognitionSessionID?
    private var speculativeLLMText: String = ""
    private var speculativeDebounceTask: Task<Void, Never>?
    private var speculativeDebounceSessionID: RecognitionSessionID?
    private var speculativeDebounceTaskToken: UUID?
    /// Stores the last LLM error from the early/fresh LLM task, consumed once by stopRecording().
    private var pendingLLMError: Error?

    // MARK: - Toggle

    func toggleRecording() async {
        switch state {
        case .idle:
            await startRecording()
        case .recording:
            await stopRecording()
        default:
            logger.warning("toggleRecording ignored in state: \(String(describing: self.state))")
        }
    }

    /// 只接受当前明确停在 unavailable 状态的会话。每次重试仍沿用同一份
    /// canonical 输入、上下文与有界 Pipeline，不会把 rejected draft 当事实来源。
    @discardableResult
    func retryVoicePolishResult() -> Bool {
        guard currentMode.kind == .voicePolish,
              state == .postProcessing,
              let sessionID = currentSessionID,
              voicePolishChoiceSessionID == sessionID else { return false }
        resolveVoicePolishChoice(.retry, sessionID: sessionID)
        DebugFileLogger.log(
            "voice polish unavailable retry accepted session=\(sessionID.rawValue)"
        )
        return true
    }

    // MARK: - Start

    func startRecording(mode: ProcessingMode = .direct) async {
        if state != .idle {
            AppLogger.log("[Session] startRecording: forcing reset from state=\(String(describing: state))")
            DebugFileLogger.log("session forcing reset from state=\(state)")
            forceReset()
        }

        let provider = selectedASRProvider()
        let sessionID = makeSessionID()
        let effectiveMode = ASRProviderRegistry.resolvedMode(for: mode, provider: provider)
        currentSessionID = sessionID
        activeProvider = provider
        currentMode = effectiveMode
        recordingStartTime = nil
        recordingStartSessionID = nil
        hasEmittedReadyForCurrentSession = false
        pendingLLMError = nil
        streamingDegraded = false
        // 第一次 await 前必须进入 starting。否则快速松键/ESC 会把仍在捕获前台
        // App 的会话误认为 idle，待 await 返回后形成僵尸录音。
        state = .starting

        let capturedApplicationBundleIdentifier = await frontmostApplicationBundleIdentifier()
        guard isCurrent(sessionID), state == .starting else { return }
        targetApplicationBundleIdentifier = capturedApplicationBundleIdentifier
        targetApplicationBundleIdentifierSessionID = sessionID
        DebugFileLogger.log("startRecording begin mode=\(effectiveMode.name) provider=\(provider.rawValue) session=\(sessionID.rawValue)")

        if effectiveMode.kind == .voicePolish {
            let level = VoicePolishSettings.contextLevel()
            let capture = writingContextCapture
            writingContextTask = Task { await capture(level) }
            writingContextTaskSessionID = sessionID
            DebugFileLogger.log(
                "voice polish context capture scheduled level=\(level.rawValue) session=\(sessionID.rawValue)"
            )
        } else {
            writingContextTask?.cancel()
            writingContextTask = nil
            writingContextTaskSessionID = nil
        }

        // Load credentials for selected provider
        guard let config = await resolveASRConfig(provider: provider, sessionID: sessionID) else {
            return
        }
        guard isCurrent(sessionID), state == .starting else { return }
        self.currentConfig = config
        currentConfigSessionID = sessionID

        guard let client = asrClientFactory(provider) else {
            AppLogger.log("[Session] No client implementation for provider=\(provider.rawValue)")
            failStart(
                with: NSError(domain: "Muse", code: -2, userInfo: [NSLocalizedDescriptionKey: L("\(provider.displayName) 暂不支持", "\(provider.displayName) not yet supported")]),
                sessionID: sessionID
            )
            return
        }
        self.asrClient = client
        asrClientSessionID = sessionID

        // Load hotwords（用户词优先置前 + 内置词补到上限,见 loadEffectiveForASR）
        let requestSetup: (options: ASRRequestOptions, hotwordCount: Int)
        if let requestOptionsProvider {
            requestSetup = requestOptionsProvider(effectiveMode)
        } else {
            let effectiveHotwords = HotwordStorage.loadEffectiveForASR()
            let biasSettings = ASRBiasSettingsStorage.load()
            let needsLLM = effectiveMode.requiresLLM
            requestSetup = (
                ASRRequestOptions(
                    // Voice Polish V2 使用 Provider 可用的带标点终稿；其余模式
                    // 沿用旧行为：直出开标点，通用 LLM 模式关闭 ASR 标点。
                    enablePunc: effectiveMode.kind == .voicePolish || !needsLLM,
                    hotwords: effectiveHotwords.words,
                    userHotwordCount: effectiveHotwords.userCount,
                    correctionWords: SnippetStorage.userCorrectionWords(),
                    boostingTableID: biasSettings.boostingTableID,
                    contextHistoryLength: biasSettings.contextHistoryLength
                ),
                effectiveHotwords.words.count
            )
        }

        // Voice Polish 使用独立、受授权级别约束的 WritingContext，不读取旧的
        // selected/clipboard PromptContext，也不让上下文采集阻塞麦克风启动。
        if effectiveMode.kind == .voicePolish {
            promptContext = PromptContext(selectedText: "", clipboardText: "")
        } else {
            DebugFileLogger.log("prompt context capture start")
            let capturedPromptContext = await promptContextCapture()
            DebugFileLogger.log("prompt context capture done")
            guard isCurrent(sessionID), ownsASRClient(client, sessionID: sessionID) else {
                DebugFileLogger.log("startRecording: zombie detected after capture, bailing")
                return
            }
            promptContext = capturedPromptContext
        }

        // Reset text state and clean up previous pipeline
        currentTranscript = .empty
        DebugFileLogger.log("audio pipeline cleanup start")
        await finishAudioChunkPipeline(sessionID: sessionID, timeout: .milliseconds(100))
        DebugFileLogger.log("audio pipeline cleanup done")
        guard isCurrent(sessionID), ownsASRClient(client, sessionID: sessionID) else {
            DebugFileLogger.log("startRecording: zombie detected after pipeline cleanup, bailing")
            return
        }

        // ── Phase 1: Start recording immediately (before ASR connects) ──
        // Audio chunks are buffered while WebSocket handshake is in progress.
        // This eliminates the ~1s perceived latency from connect().

        let audioBuffer = AudioChunkBuffer()

        let levelHandler = self.onAudioLevel
        audioEngine.setAudioHandlers(
            onChunk: { [weak self] data in
                guard self != nil else { return }
                audioBuffer.append(data)
            },
            onLevel: { level in
                levelHandler?(level)
            }
        )

        guard await startAudioCapture(client: client, sessionID: sessionID) else { return }
        guard isCurrent(sessionID), ownsASRClient(client, sessionID: sessionID) else { return }

        state = .recording
        markReadyIfNeeded(sessionID: sessionID)
        DebugFileLogger.log("session entered recording state (buffering, ASR connecting)")

        // ── Phase 2: Connect ASR (audio is already recording) ──

        guard await connectASR(
            client: client,
            config: config,
            options: requestSetup.options,
            hotwordCount: requestSetup.hotwordCount,
            sessionID: sessionID,
            provider: provider
        ) else { return }

        // ── Phase 3: Flush buffer → switch to live pipeline ──

        guard await activateLivePipeline(
            client: client,
            audioBuffer: audioBuffer,
            sessionID: sessionID,
            provider: provider
        ) else { return }

        await prewarmLLMIfNeeded(sessionID: sessionID)
    }

    // MARK: - Start Helpers（J15：startRecording ~260 行按既有三阶段拆分，纯代码搬移）

    /// 启动失败共用收尾：错误音 + 回 idle + 通知 UI（error 后补 completed 收 HUD）
    private func failStart(
        with error: Error,
        sessionID: RecognitionSessionID,
        client expectedClient: (any SpeechRecognizer)? = nil
    ) {
        guard isCurrent(sessionID) else { return }

        let clientToDisconnect: (any SpeechRecognizer)?
        if let expectedClient {
            guard ownsASRClient(expectedClient, sessionID: sessionID) else {
                DebugFileLogger.log("start failure ignored for non-owned client session=\(sessionID.rawValue)")
                Task.detached { await expectedClient.disconnect() }
                return
            }
            clientToDisconnect = expectedClient
        } else {
            guard asrClient == nil, asrClientSessionID == nil else {
                DebugFileLogger.log("start failure without client identity refused to clear active client")
                return
            }
            clientToDisconnect = nil
        }

        // 先让 session 失效并摘除全部共享引用；后续断开只持有局部旧 client。
        currentSessionID = nil
        asrClient = nil
        asrClientSessionID = nil

        if eventConsumptionTaskSessionID == sessionID {
            eventConsumptionTask?.cancel()
            eventConsumptionTask = nil
            eventConsumptionTaskSessionID = nil
            eventConsumptionTaskToken = nil
        }
        if audioChunkPipelineSessionID == sessionID {
            audioChunkPipeline?.cancel()
            audioChunkPipeline = nil
            audioChunkPipelineSessionID = nil
        }
        if audioCaptureSessionID == sessionID {
            audioCaptureSessionID = nil
            audioEngine.stop()
            audioEngine.clearAudioHandlers()
        }
        if currentConfigSessionID == sessionID {
            currentConfig = nil
            currentConfigSessionID = nil
        }
        polishPrefetch.reset(session: sessionID)
        if speculativeLLMSessionID == sessionID || speculativeDebounceSessionID == sessionID {
            resetSpeculativeLLM(sessionID: sessionID)
        }
        if writingContextTaskSessionID == sessionID {
            writingContextTask?.cancel()
            writingContextTask = nil
            writingContextTaskSessionID = nil
        }
        if targetApplicationBundleIdentifierSessionID == sessionID {
            targetApplicationBundleIdentifier = nil
            targetApplicationBundleIdentifierSessionID = nil
        }

        SoundFeedback.playError()
        state = .idle
        currentTranscript = .empty
        hasEmittedReadyForCurrentSession = false
        if recordingStartSessionID == sessionID {
            recordingStartTime = nil
            recordingStartSessionID = nil
        }
        onASREvent?(.error(error))
        onASREvent?(.completed)

        if let clientToDisconnect {
            Task.detached { await clientToDisconnect.disconnect() }
        }
    }

    /// 凭证/配置解析：本地引擎兜底默认模型目录并校验模型就绪；云端支持 env var 开发回退。
    /// 返回 nil 表示已走 failStart 收尾（或代际失效静默退出）。
    private func resolveASRConfig(
        provider: ASRProvider,
        sessionID: RecognitionSessionID
    ) async -> (any ASRProviderConfig)? {
        let savedConfig: (any ASRProviderConfig)?
        if let asrConfigLoader {
            savedConfig = await asrConfigLoader(provider)
        } else {
            savedConfig = await loadASRConfigOffActor(for: provider)
        }
        guard isCurrent(sessionID), state == .starting else {
            DebugFileLogger.log("startRecording: cancelled during ASR config load, bailing")
            return nil
        }

        if asrConfigLoader != nil {
            guard let savedConfig else {
                failStart(
                    with: NSError(domain: "Muse", code: -1, userInfo: [NSLocalizedDescriptionKey: L("未配置 API 凭证", "API credentials not configured")]),
                    sessionID: sessionID
                )
                return nil
            }
            return savedConfig
        }

        if provider.isLocal {
            let config: any ASRProviderConfig
            // Local providers: use default model directory if no saved config
            if let savedConfig {
                config = savedConfig
                AppLogger.log("[Session] Loaded \(provider.rawValue) config from file store")
            } else if let defaultConfig = SherpaASRConfig(credentials: ["modelDir": ModelManager.defaultModelsDir]) {
                config = defaultConfig
                AppLogger.log("[Session] Using default model directory for \(provider.rawValue)")
            } else {
                AppLogger.log("[Session] Failed to create default config for \(provider.rawValue)!")
                failStart(
                    with: NSError(domain: "Muse", code: -1, userInfo: [NSLocalizedDescriptionKey: L("本地模型未配置", "Local model not configured")]),
                    sessionID: sessionID
                )
                return nil
            }
            // Verify required models are downloaded
            if !ModelManager.shared.areRequiredModelsAvailable() {
                AppLogger.log("[Session] Required local models not downloaded for \(provider.rawValue)")
                failStart(
                    with: NSError(domain: "Muse", code: -3, userInfo: [NSLocalizedDescriptionKey: L("请先下载识别模型", "Please download ASR models first")]),
                    sessionID: sessionID
                )
                return nil
            }
            return config
        }

        if let savedConfig {
            AppLogger.log("[Session] Loaded \(provider.rawValue) credentials from file store")
            return savedConfig
        }

        if provider == .volcano,
           let appKey = ProcessInfo.processInfo.environment["VOLC_APP_KEY"],
           let accessKey = ProcessInfo.processInfo.environment["VOLC_ACCESS_KEY"] {
            // Env var fallback (volcano only, for dev convenience)
            let resourceId = ProcessInfo.processInfo.environment["VOLC_RESOURCE_ID"] ?? VolcanoASRConfig.resourceIdSeedASR
            let volcConfig = VolcanoASRConfig(credentials: [
                "appKey": appKey, "accessKey": accessKey, "resourceId": resourceId,
            ])!
            try? KeychainService.saveASRCredentials(appKey: appKey, accessKey: accessKey, resourceId: resourceId)
            AppLogger.log("[Session] Loaded credentials from env vars and persisted to file")
            return volcConfig
        }

        AppLogger.log("[Session] No ASR credentials found for provider=\(provider.rawValue)!")
        failStart(
            with: NSError(domain: "Muse", code: -1, userInfo: [NSLocalizedDescriptionKey: L("未配置 API 凭证", "API credentials not configured")]),
            sessionID: sessionID
        )
        return nil
    }

    /// Phase 1 收尾：麦克风权限 + 音频引擎启动。失败时清理客户端并 failStart。
    private func startAudioCapture(
        client: any SpeechRecognizer,
        sessionID: RecognitionSessionID
    ) async -> Bool {
        DebugFileLogger.log("microphone permission check start")
        let granted: Bool
        if let microphonePermission {
            granted = await microphonePermission()
        } else if PermissionManager.hasMicrophonePermission {
            granted = true
        } else {
            granted = await PermissionManager.requestMicrophonePermission()
        }
        guard isCurrent(sessionID), ownsASRClient(client, sessionID: sessionID) else {
            DebugFileLogger.log("microphone permission returned for stale session=\(sessionID.rawValue)")
            Task.detached { await client.disconnect() }
            return false
        }
        guard granted else {
            AppLogger.log("[Session] Microphone permission denied")
            DebugFileLogger.log("microphone permission denied before audio start")
            failStart(
                with: AudioCaptureError.microphonePermissionDenied,
                sessionID: sessionID,
                client: client
            )
            return false
        }
        DebugFileLogger.log("microphone permission check done")

        audioCaptureSessionID = sessionID
        let audioStartT0 = ContinuousClock.now
        DebugFileLogger.log("audio engine start begin")
        do {
            try await audioEngine.start()
            guard isCurrent(sessionID),
                  ownsASRClient(client, sessionID: sessionID),
                  audioCaptureSessionID == sessionID,
                  state == .starting else {
                // reset/new start 已负责停旧 token；这里绝不能 stop 共享引擎，否则会拆掉新会话。
                DebugFileLogger.log("audio engine start completed after cancel/supersede; ignored")
                return false
            }
            AppLogger.log("[Session] Audio engine started OK")
            DebugFileLogger.log("audio engine started OK +\(ContinuousClock.now - audioStartT0)")
            return true
        } catch {
            guard isCurrent(sessionID),
                  ownsASRClient(client, sessionID: sessionID),
                  audioCaptureSessionID == sessionID,
                  state == .starting else {
                DebugFileLogger.log("audio engine start failed after cancel/supersede, suppressed: \(String(describing: error))")
                return false
            }
            AppLogger.log("[Session] Audio engine start FAILED: \(String(describing: error))")
            DebugFileLogger.log("audio engine start failed +\(ContinuousClock.now - audioStartT0): \(String(describing: error))")
            failStart(with: error, sessionID: sessionID, client: client)
            return false
        }
    }

    /// Phase 2：连接 ASR。失败时区分「用户已取消/被顶替」（静默清理）与真失败（报错收尾）。
    private func connectASR(
        client: any SpeechRecognizer,
        config: any ASRProviderConfig,
        options requestOptions: ASRRequestOptions,
        hotwordCount: Int,
        sessionID: RecognitionSessionID,
        provider: ASRProvider
    ) async -> Bool {
        do {
            DebugFileLogger.log("ASR connecting provider=\(provider.rawValue)")
            // REPAIR_PLAN K4：URLSession 默认握手超时 60s，网络差时字幕可空转一分钟；
            // 会话级 10s 硬超时（同 J12 的 Result 包装模式），超时走既有失败路径。
            let connectT0 = ContinuousClock.now
            let timed = await AsyncTimeout.asyncValue(Self.asrConnectTimeout) {
                () -> Result<Void, Error> in
                do {
                    try await client.connect(config: config, options: requestOptions)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            guard let outcome = timed.value else {
                throw ASRConnectTimeoutError()
            }
            try outcome.get()
            AppLogger.log("[Session] ASR connected OK (streaming, hotwords=\(hotwordCount), userHotwords=\(requestOptions.userHotwordCount), corrections=\(requestOptions.correctionWords.count), history=\(requestOptions.contextHistoryLength))")
            DebugFileLogger.log("ASR connected OK provider=\(provider.rawValue) +\(ContinuousClock.now - connectT0)")
        } catch {
            AppLogger.log("[Session] ASR connect FAILED provider=\(provider.rawValue) error=\(String(describing: error))")
            DebugFileLogger.log("ASR connect failed provider=\(provider.rawValue): \(String(describing: error))")
            // 先判会话身份。旧连接只允许断开自己，禁止停止共享音频或清空新 client。
            guard isCurrent(sessionID),
                  ownsASRClient(client, sessionID: sessionID),
                  state == .recording else {
                DebugFileLogger.log("ASR connect failed after cancel/supersede, suppressed (session=\(sessionID.rawValue) active=\(String(describing: currentSessionID?.rawValue)) state=\(state))")
                Task.detached { await client.disconnect() }
                return false
            }

            failStart(with: error, sessionID: sessionID, client: client)
            return false
        }

        // Bail out if session was superseded or user stopped while we were connecting
        guard isCurrent(sessionID),
              ownsASRClient(client, sessionID: sessionID),
              state == .recording else {
            DebugFileLogger.log("startRecording: zombie or state change after connect (session=\(sessionID.rawValue) active=\(String(describing: currentSessionID?.rawValue)) state=\(state)), bailing")
            Task.detached { await client.disconnect() }
            return false
        }
        return true
    }

    /// Phase 3：事件消费任务 + 缓冲冲刷 → 切换到实时上传管线
    private func activateLivePipeline(
        client: any SpeechRecognizer,
        audioBuffer: AudioChunkBuffer,
        sessionID: RecognitionSessionID,
        provider: ASRProvider
    ) async -> Bool {
        let events = await client.events
        guard isCurrent(sessionID), ownsASRClient(client, sessionID: sessionID) else {
            DebugFileLogger.log("event stream obtained for stale session=\(sessionID.rawValue)")
            Task.detached { await client.disconnect() }
            return false
        }

        let taskToken = UUID()
        let eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                await self.handleASREvent(event, sessionID: sessionID)
                if case .completed = event { break }
            }
            await self?.eventConsumptionDidFinish(sessionID: sessionID, token: taskToken)
        }
        eventConsumptionTask = eventTask
        eventConsumptionTaskSessionID = sessionID
        eventConsumptionTaskToken = taskToken

        guard let audioUploadPipeline = setupAudioChunkPipeline(
            client: client,
            provider: provider,
            sessionID: sessionID
        ) else {
            eventTask.cancel()
            return false
        }

        // Flush all chunks buffered during connect
        let bufferedChunks = audioBuffer.drain()
        for chunk in bufferedChunks {
            audioUploadPipeline.yield(chunk)
        }

        // Switch callback from buffer to live pipeline
        audioEngine.setAudioChunkHandler { [weak self, weak audioUploadPipeline] data in
            guard self != nil else { return }
            audioUploadPipeline?.yield(data)
        }

        // Catch any chunks that arrived between drain and callback switch
        for chunk in audioBuffer.drain() {
            audioUploadPipeline.yield(chunk)
        }

        DebugFileLogger.log("ASR pipeline live, flushed \(bufferedChunks.count) buffered chunks")
        return true
    }

    /// Pre-warm LLM connection for modes with post-processing
    private func prewarmLLMIfNeeded(sessionID: RecognitionSessionID) async {
        guard currentMode.requiresLLM else { return }
        let llmConfig = await loadLLMConfigOffActor()
        guard isCurrent(sessionID), state == .recording else {
            DebugFileLogger.log("startRecording: cancelled during LLM prewarm config load, bailing")
            return
        }
        if let llmConfig {
            let client = currentLLMClient()
            Task { await client.warmUp(baseURL: llmConfig.baseURL) }
        }
    }

    /// Switch the processing mode before stopping. Used for cross-mode hotkey stops.
    func switchMode(to mode: ProcessingMode) {
        guard state == .starting || state == .recording else { return }
        let resolvedMode = ASRProviderRegistry.resolvedMode(for: mode, provider: activeProvider)
        if resolvedMode != currentMode { polishPrefetch.invalidate() }
        currentMode = resolvedMode
    }

    // MARK: - Stop

    /// ESC means interrupt immediately: no post-processing, no clipboard write, no injection.
    /// 中断安全由会话身份守卫兜底：forceReset 使旧 ID 失效后，在途 stop 管线会退出。
    func abortCurrentSession() async {
        guard state != .idle else {
            DebugFileLogger.log("abortCurrentSession idle: emit completed for UI cleanup")
            onASREvent?(.completed)
            return
        }
        DebugFileLogger.log("abortCurrentSession: force reset from state=\(state)")
        forceReset()
        onASREvent?(.completed)
    }

    func stopRecording(expectedSessionID: RecognitionSessionID? = nil) async {
        if let expectedSessionID, !isCurrent(expectedSessionID) {
            DebugFileLogger.log(
                "stopRecording ignored for stale session=\(expectedSessionID.rawValue)"
            )
            return
        }
        if state == .starting {
            DebugFileLogger.log("stopRecording during starting: cancelling pending session")
            forceReset()
            onASREvent?(.completed)
            return
        }
        guard state == .recording, let sessionID = currentSessionID else {
            logger.warning("stopRecording called but state is \(String(describing: self.state))")
            return
        }
        let stoppingClient = asrClientSessionID == sessionID ? asrClient : nil

        // Set state BEFORE any await to prevent a second stop from
        // slipping through the guard during the suspension point.
        state = .finishing

        let stopT0 = ContinuousClock.now

        // 用户主动松开热键时保留 300ms 收声窗口，避免最后一两个字仍在麦克风/HAL
        // 缓冲区中就被截断。服务端自动停录带 expectedSessionID，不额外延迟。
        if expectedSessionID == nil, audioCaptureSessionID == sessionID {
            await audioEngine.captureReleaseTail()
            guard isStillCurrent(sessionID, stage: "release tail capture") else { return }
        }

        // Stop capture first so flushRemaining() can emit the tail audio chunk.
        if audioCaptureSessionID == sessionID {
            audioCaptureSessionID = nil
            audioEngine.stop()
            audioEngine.clearAudioHandlers()
        }
        // 停止提示音必须在麦克风真正关闭后播放，否则尾音保护会把提示音录进去。
        SoundFeedback.playStop()
        let uploadFailed = await finishAudioChunkPipeline(sessionID: sessionID)
        let recordedAudio = audioEngine.getRecordedAudio()
        let audioSummary = PCMAudioActivitySummary.analyze(recordedAudio)
        DebugFileLogger.log(
            "stop: audio summary bytes=\(audioSummary.validByteCount) frames=\(audioSummary.analyzedFrameCount) voiced=\(audioSummary.voicedFrameCount) peak=\(audioSummary.peakAmplitude) meaningful=\(audioSummary.hasMeaningfulSpeech)"
        )
        DebugFileLogger.log("stop: audio stopped +\(ContinuousClock.now - stopT0)")
        guard isStillCurrent(sessionID, stage: "audio pipeline") else {
            DebugFileLogger.log("stopRecording: zombie after audio pipeline, bailing")
            return
        }

        // Keep speculative LLM task alive — we'll compare its input text
        // against the final ASR transcript after full teardown.
        cancelSpeculativeLLM(sessionID: sessionID)
        let needsLLM = currentMode.requiresLLM
        let provider = activeProvider

        let asrTeardown = await teardownASRClient(
            provider: provider,
            client: stoppingClient,
            sessionID: sessionID,
            stopStartedAt: stopT0
        )
        guard isStillCurrent(sessionID, stage: "ASR teardown") else { return }

        let earlyLLMTask = await prepareEarlyLLMTask(
            needsLLM: needsLLM,
            canEarlyLLM: asrTeardown.providerIsStreaming,
            sessionID: sessionID,
            stopStartedAt: stopT0
        )
        guard isStillCurrent(sessionID, stage: "early LLM preparation") else {
            DebugFileLogger.log("stopRecording: zombie after ASR teardown, bailing")
            return
        }

        // Batch fallback: retry only when the audio/transcript itself may be incomplete.
        // A provider that accepted endAudio but did not close its event stream in time
        // is a lifecycle anomaly, not automatically a content failure. For Volcano,
        // preserve already-valid text instead of creating a second real-time replay.
        // REPAIR_PLAN K2：转写严重滞后时服务端可能只 final 了开头段就正常关流
        //（实测说 8s 首包 7.4s 才到、注入仅 3 字），clean 关闭不代表文本完整——
        // 长录音字数低到不合理时同样强制批量复核。
        let recordedDuration = recordingStartSessionID == sessionID
            ? recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
            : 0
        let streamingFailed = streamingNeedsRecovery(
            provider: provider,
            teardown: asrTeardown,
            uploadFailed: uploadFailed,
            audioSummary: audioSummary,
            recordedDuration: recordedDuration
        )
        let recoveryResult = await recoverTranscriptAfterStreamingFailureIfNeeded(
            streamingFailed: streamingFailed,
            audio: recordedAudio,
            sessionID: sessionID
        )
        guard isStillCurrent(sessionID, stage: "batch fallback") else { return }
        // REPAIR_PLAN K2：注入取值经守卫函数——asyncFinal 的权威文本明显短于
        // 流式累积（HUD 所见）时回退 composed，保证注入与字幕口径一致。
        let effectiveText = Self.effectiveTranscriptText(for: currentTranscript)
        if currentConfigSessionID == sessionID {
            currentConfig = nil
            currentConfigSessionID = nil
        }

        if !effectiveText.isEmpty {
            guard await deliverRecognizedText(
                effectiveText,
                needsLLM: needsLLM,
                earlyLLMTask: earlyLLMTask,
                provider: provider,
                recordedDuration: recordedDuration,
                streamingFailed: streamingFailed,
                recoveryResult: recoveryResult,
                sessionID: sessionID,
                stopStartedAt: stopT0
            ) else { return }
        } else {
            await saveEmptyHistoryIfNeeded(
                streamingFailed: streamingFailed,
                durationSeconds: recordedDuration,
                sessionID: sessionID
            )
            guard isStillCurrent(sessionID, stage: "empty completion") else { return }
            if recoveryResult == .failed, audioSummary.hasMeaningfulSpeech {
                onASREvent?(.error(ASRRecoveryError.noTranscript(
                    provider: provider.displayName
                )))
            } else {
                onASREvent?(.processingResult(text: ""))
                onASREvent?(.completed)
            }
        }

        finishSession(sessionID)
        logger.info("Session complete, injected \(effectiveText.count) chars")
    }

    private func isStillCurrent(_ sessionID: RecognitionSessionID, stage: String) -> Bool {
        guard currentSessionID == sessionID else {
            DebugFileLogger.log("stopRecording: superseded during \(stage), bailing")
            return false
        }
        return true
    }

    /// 有文本时的交付：后处理 → 注入 → 统计 → 历史。返回 false 表示会话已被取代
    /// 或用户取消，调用方不再做收尾清理。
    private func deliverRecognizedText(
        _ text: String,
        needsLLM: Bool,
        earlyLLMTask: Task<String?, Never>?,
        provider: ASRProvider,
        recordedDuration: TimeInterval,
        streamingFailed: Bool,
        recoveryResult: TranscriptRecoveryResult,
        sessionID: RecognitionSessionID,
        stopStartedAt stopT0: ContinuousClock.Instant
    ) async -> Bool {
        // 原始 ASR 终稿只作为历史审计证据保存；后续纠错与润色使用独立的
        // canonical 文本，避免为了提升正确率而覆盖 raw transcript。
        let rawText = text
        guard let llmResult = await postProcessRecognizedText(
            rawText: rawText,
            needsLLM: needsLLM,
            earlyLLMTask: earlyLLMTask,
            transcript: currentTranscript,
            provider: provider,
            durationMs: Int((recordedDuration * 1_000).rounded()),
            sessionID: sessionID,
            stopStartedAt: stopT0,
            vocabularyContext: sessionVocabularyContext,
            allowsVoicePolishUserChoice: true
        ) else { return false }
        guard isStillCurrent(sessionID, stage: "pre-injection") else { return false }

        let historyID = UUID().uuidString
        let injectionOutcome = injectFinalText(
            llmResult.finalText,
            stopStartedAt: stopT0
        )
        if let voicePolishPerformance = llmResult.voicePolishPerformance {
            let elapsed = ContinuousClock.now - stopT0
            let milliseconds = elapsed.components.seconds * 1_000
                + Int64(elapsed.components.attoseconds / 1_000_000_000_000_000)
            VoicePolishPerformanceStore.record(
                measurement: voicePolishPerformance.completing(
                    stopElapsedMilliseconds: Int(clamping: milliseconds)
                ),
                latencyMilliseconds: Int(clamping: milliseconds),
                qualityMode: currentMode.voicePolishQualityMode,
                defaults: llmResult.voicePolishVocabularyContext?.userDefaults ?? .standard
            )
        }
        guard isStillCurrent(sessionID, stage: "post-injection") else { return false }
        onASREvent?(.finalized(text: llmResult.finalText, injection: injectionOutcome))
        let shouldObserveEditLearning = PostInjectionEditLearningMonitor.shouldObserve(
            kind: currentMode.kind,
            injection: injectionOutcome,
            defaults: sessionVocabularyContext.userDefaults
        )
        guard isStillCurrent(sessionID, stage: "edit learning capture") else { return false }
        if recoveryResult == .failed {
            onASREvent?(.error(ASRRecoveryError.partialTextPreserved(
                provider: provider.displayName
            )))
        }

        await saveSuccessfulHistory(
            historyID: historyID,
            rawText: rawText,
            llmResult: llmResult,
            streamingFailed: streamingFailed,
            injection: injectionOutcome,
            durationSeconds: recordedDuration,
            sessionID: sessionID
        )
        if shouldObserveEditLearning {
            await editLearningMonitor.start(
                injectedText: llmResult.finalText, historyID: historyID,
                captureProvider: editLearningFieldCapture,
                historyStore: historyStore
            )
        }
        guard isStillCurrent(sessionID, stage: "history save") else { return false }
        return true
    }

    /// 判断停止后是否需要用整段录音复核转写：上传/结束包失败、流式降级、
    /// 字数与有声时长明显不符，或阿里云有声却零字。
    private func streamingNeedsRecovery(
        provider: ASRProvider,
        teardown asrTeardown: ASRTeardownResult,
        uploadFailed: Bool,
        audioSummary: PCMAudioActivitySummary,
        recordedDuration: TimeInterval
    ) -> Bool {
        let transcriptTextCount = Self.effectiveTranscriptText(for: currentTranscript).count
        let implausiblyShort = Self.isTranscriptImplausiblyShort(
            textCount: transcriptTextCount,
            audioSummary: audioSummary
        )
        let voicedButEmpty = provider == .aliyun
            && transcriptTextCount == 0
            && audioSummary.hasMeaningfulSpeech
        if implausiblyShort {
            DebugFileLogger.log(
                "stop: transcript implausibly short for voiced=\(String(format: "%.1f", audioSummary.voicedDurationSeconds))s wall=\(String(format: "%.1f", recordedDuration))s, forcing batch fallback"
            )
        }
        if voicedButEmpty {
            DebugFileLogger.log(
                "stop: Aliyun returned zero text for voiced audio, forcing paced full replay"
            )
        }
        let volcanoCloseTimeoutWithValidText = provider == .volcano
            && asrTeardown.endAudioSucceeded
            && !asrTeardown.eventStreamDrained
            && transcriptTextCount > 0
        if volcanoCloseTimeoutWithValidText {
            DebugFileLogger.log(
                "stop: volcano event stream close timed out with valid text (\(transcriptTextCount) chars); skipping full replay"
            )
        }
        let teardownRequiresRecovery = !asrTeardown.clean
            && !volcanoCloseTimeoutWithValidText
        return uploadFailed || teardownRequiresRecovery
            || streamingDegraded || implausiblyShort || voicedButEmpty
    }

    /// 正常结束后仅清理仍属于本会话的状态，不触碰已开始的新会话。
    private func finishSession(_ sessionID: RecognitionSessionID) {
        // Only reset to idle if this is still the active session.
        if currentSessionID == sessionID, state != .idle {
            currentSessionID = nil
            state = .idle
            hasEmittedReadyForCurrentSession = false
            currentTranscript = .empty
            recordingStartTime = nil
            recordingStartSessionID = nil
        }
        if writingContextTaskSessionID == sessionID {
            writingContextTask?.cancel()
            writingContextTask = nil
            writingContextTaskSessionID = nil
        }
        if targetApplicationBundleIdentifierSessionID == sessionID {
            targetApplicationBundleIdentifier = nil
            targetApplicationBundleIdentifierSessionID = nil
        }
        if voicePolishTaskSessionID == sessionID {
            voicePolishTask?.cancel()
            voicePolishTask = nil
            voicePolishTaskSessionID = nil
        }
        if voicePolishProcessingSessionID == sessionID {
            voicePolishProcessingSessionID = nil
        }
        if voicePolishChoiceSessionID == sessionID {
            resolveVoicePolishChoice(.cancel, sessionID: sessionID)
        }
        resetSpeculativeLLM(sessionID: sessionID)
    }

    // MARK: - Stop Helpers

    private func prepareEarlyLLMTask(
        needsLLM: Bool,
        canEarlyLLM: Bool,
        sessionID: RecognitionSessionID,
        stopStartedAt stopT0: ContinuousClock.Instant
    ) async -> Task<String?, Never>? {
        guard needsLLM && canEarlyLLM && currentMode.kind != .voicePolish else { return nil }

        let rawASRText = currentTranscript.composedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let finalASRText = canonicalText(
            for: rawASRText,
            sessionID: sessionID
        )
        DebugFileLogger.log("stop: needsLLM=true mode=\(currentMode.name) text=\(finalASRText.count)chars specMatch=\(finalASRText == speculativeLLMText)")
        guard !finalASRText.isEmpty else { return nil }

        if finalASRText == speculativeLLMText,
           speculativeLLMSessionID == sessionID,
           let specTask = speculativeLLMTask {
            // Final transcript matches speculative input — reuse (may already be done!)
            state = .postProcessing
            DebugFileLogger.log("stop: reusing speculative LLM +\(ContinuousClock.now - stopT0)")
            return specTask
        }

        guard let llmConfig = await loadLLMConfigOffActor() else { return nil }
        guard isCurrent(sessionID) else {
            DebugFileLogger.log("stopRecording: superseded during fresh llm config, bailing")
            return nil
        }

        // Final transcript differs from speculative input (tail words arrived),
        // discard stale result and fire fresh LLM with complete text.
        if speculativeLLMSessionID == sessionID {
            speculativeLLMTask?.cancel()
        }
        let mode = currentMode
        let prompt = mode.applyingLLMFormatGuard(
            to: promptContext.expandContextVariables(mode.prompt)
        )
        let client = currentLLMClient()
        state = .postProcessing
        if finalASRText != speculativeLLMText {
            DebugFileLogger.log("stop: final transcript changed (spec=\(speculativeLLMText.count)chars final=\(finalASRText.count)chars), firing fresh LLM")
        }
        DebugFileLogger.log("stop: fresh LLM firing mode=\(mode.name) model=\(llmConfig.model) with \(finalASRText.count) chars +\(ContinuousClock.now - stopT0)")

        let task: Task<String?, Never> = Task {
            do {
                let result = try await client.process(
                    text: finalASRText,
                    prompt: prompt,
                    context: .processingMode,
                    config: llmConfig
                )
                let cleanedResult = mode.applyingLLMResultCleanup(to: result)
                DebugFileLogger.log("stop: fresh LLM done \(cleanedResult.count) chars +\(ContinuousClock.now - stopT0)")
                return cleanedResult
            } catch {
                DebugFileLogger.log("stop: fresh LLM FAILED +\(ContinuousClock.now - stopT0) error=\(error)")
                self.setPendingLLMError(error, sessionID: sessionID)
                return nil
            }
        }
        speculativeLLMTask = task
        speculativeLLMSessionID = sessionID
        speculativeLLMText = finalASRText
        return task
    }

    private func postProcessRecognizedText(
        rawText: String,
        needsLLM: Bool,
        earlyLLMTask: Task<String?, Never>?,
        transcript: RecognitionTranscript,
        provider: ASRProvider,
        durationMs: Int,
        sessionID: RecognitionSessionID,
        stopStartedAt stopT0: ContinuousClock.Instant,
        vocabularyContext: VocabularyStorageContext = .production,
        allowsVoicePolishUserChoice: Bool = false
    ) async -> LLMPostProcessingResult? {
        let asrReadyAt = ContinuousClock.now
        // rawText 必须原样留给历史审计。语音润色分支会在构造 envelope 时
        // 一次性完成术语规范化；其他模式仍在这里生成 canonical。
        var finalText = rawText
        if currentMode.kind != .voicePolish {
            finalText = canonicalText(
                for: rawText,
                sessionID: sessionID,
                vocabularyContext: vocabularyContext
            )
        }
        let frozenQualityMode = currentMode.voicePolishQualityMode
        var performance = VoicePolishSessionPerformance(stoppedAt: stopT0, asrReadyAt: asrReadyAt)
        performance.prefetchScheduledCount = polishPrefetch.scheduledCount(session: sessionID)
        var returnedPolishResult = false
        func finalized(_ value: LLMPostProcessingResult) -> LLMPostProcessingResult {
            var value = value
            if let measurement = value.voicePolishPerformance {
                value.voicePolishPerformance = performance.measurement(outcome: measurement.outcome)
                returnedPolishResult = true
            }
            return value
        }
        defer {
            if frozenQualityMode != nil, !returnedPolishResult {
                // 取消也留下一条不含正文的统计；先前自动失败不能随会话退出消失。
                let measurement = performance.measurement(outcome: .cancelled)
                VoicePolishPerformanceStore.record(
                    measurement: measurement,
                    latencyMilliseconds: measurement.stopLatencyMilliseconds ?? 0,
                    qualityMode: frozenQualityMode,
                    defaults: vocabularyContext.userDefaults
                )
            }
        }

        // LLM post-processing: prefer early result (fired at stop time),
        // fall back to synchronous call for very short recordings where
        // no streaming text was available yet.
        var outcome = PostProcessingOutcome(finalText: finalText)
        let step: PostProcessingStep
        if currentMode.kind == .voicePolish {
            step = await postProcessVoicePolish(
                rawText: rawText, transcript: transcript, provider: provider,
                durationMs: durationMs, sessionID: sessionID, vocabularyContext: vocabularyContext,
                allowsVoicePolishUserChoice: allowsVoicePolishUserChoice,
                performance: &performance, outcome: &outcome
            )
        } else if let earlyTask = earlyLLMTask {
            step = await postProcessEarlyLLM(
                earlyTask, sessionID: sessionID, stopStartedAt: stopT0, outcome: &outcome
            )
        } else if needsLLM {
            step = await postProcessSyncLLM(sessionID: sessionID, outcome: &outcome)
        } else {
            step = .continue
        }
        switch step {
        case .abort:
            return nil
        case .finished(let value):
            return finalized(value)
        case .continue:
            break
        }

        let insertionCleanedText = Self.finalizeInsertionText(
            outcome.finalText,
            mode: currentMode,
            isLLMOutput: outcome.processedText != nil
        )
        if insertionCleanedText != outcome.finalText {
            DebugFileLogger.log(
                "stop: final insertion cleanup changed text len \(outcome.finalText.count)->\(insertionCleanedText.count)"
            )
            outcome.finalText = insertionCleanedText
            if outcome.processedText != nil {
                outcome.processedText = insertionCleanedText
            }
        }

        if voicePolishProcessingSessionID == sessionID {
            voicePolishProcessingSessionID = nil
        }

        return finalized(LLMPostProcessingResult(
            finalText: outcome.finalText,
            processedText: outcome.processedText,
            llmFailed: outcome.llmFailed,
            voicePolishHistoryStatus: outcome.voicePolishHistoryStatus,
            voicePolishPerformance: outcome.voicePolishPerformance,
            voicePolishVocabularyContext: outcome.voicePolishPerformance == nil
                ? nil
                : vocabularyContext
        ))
    }

    /// 各后处理分支写入的结果；`finalText` 初值为进入分支前的文本（润色为原始转写，其他模式为 canonical）。
    private struct PostProcessingOutcome {
        var finalText: String
        var processedText: String?
        var llmFailed = false
        var voicePolishHistoryStatus: String?
        var voicePolishPerformance: VoicePolishPerformanceMeasurement?
    }

    private enum PostProcessingStep {
        /// 会话已失效或用户取消：不交付。
        case abort
        /// 分支已给出完整结果，跳过统一的插入清理。
        case finished(LLMPostProcessingResult)
        /// 继续统一的插入清理与收尾。
        case `continue`
    }

    private func postProcessVoicePolish(
        rawText: String,
        transcript: RecognitionTranscript,
        provider: ASRProvider,
        durationMs: Int,
        sessionID: RecognitionSessionID,
        vocabularyContext: VocabularyStorageContext,
        allowsVoicePolishUserChoice: Bool,
        performance: inout VoicePolishSessionPerformance,
        outcome: inout PostProcessingOutcome
    ) async -> PostProcessingStep {
        state = .postProcessing
        voicePolishProcessingSessionID = sessionID
        let mode = currentMode
        guard let writingContext = await polishWritingContext(
            sessionID: sessionID, vocabularyContext: vocabularyContext
        ) else { return .abort }
        writingContextTask = nil
        writingContextTaskSessionID = nil
        DebugFileLogger.log(
            "voice polish context scene=\(writingContext.scene.rawValue) level=\(writingContext.level.rawValue) safety=\(writingContext.safety.rawValue) selected=\(writingContext.selectedText?.count ?? 0) before=\(writingContext.textBeforeCursor?.count ?? 0) after=\(writingContext.textAfterCursor?.count ?? 0) recent=\(writingContext.recentMuseInputs.count)"
        )
        VoicePolishContextDiagnostics.record(writingContext)

        var prepared = preparePolishRequest(
            rawText: rawText, transcript: transcript, mode: mode,
            writingContext: writingContext, durationMs: durationMs,
            provider: provider, sessionID: sessionID, vocabularyContext: vocabularyContext
        )
        outcome.finalText = prepared.canonicalText
        var envelope: VoiceInputEnvelope?
        repeat {
            envelope = prepared.request?.input
            guard envelope == nil, allowsVoicePolishUserChoice else { break }
            performance.recordSetupFailure()
            let waitingAt = ContinuousClock.now
            let choice = await waitForVoicePolishChoice(reason: .setupFailed, sessionID: sessionID)
            performance.decisionWait += ContinuousClock.now - waitingAt
            switch choice {
            case .retry:
                performance.userRetryCount += 1
                prepared = preparePolishRequest(
                    rawText: rawText, transcript: transcript, mode: mode,
                    writingContext: writingContext, durationMs: durationMs,
                    provider: provider, sessionID: sessionID, vocabularyContext: vocabularyContext
                )
                outcome.finalText = prepared.canonicalText
                continue
            case .cancel:
                await saveCancelledVoicePolishHistory(
                    rawText: rawText, canonicalText: outcome.finalText,
                    mode: mode, durationMs: durationMs
                )
                return .abort
            }
        } while envelope == nil

        guard let envelope else {
            performance.recordSetupFailure()
            voicePolishProcessingSessionID = nil
            outcome.llmFailed = true
            outcome.voicePolishHistoryStatus = "voice_polish_fallback"
            onASREvent?(.processingResult(text: outcome.finalText))
            return .finished(LLMPostProcessingResult(
                finalText: outcome.finalText,
                processedText: nil,
                llmFailed: true,
                voicePolishHistoryStatus: outcome.voicePolishHistoryStatus,
                voicePolishPerformance: VoicePolishPerformanceMeasurement(
                    outcome: .setupFailure
                ),
                voicePolishVocabularyContext: vocabularyContext
            ))
        }

        var loadedLLMConfig = await loadLLMConfigOffActor()
        while loadedLLMConfig == nil, allowsVoicePolishUserChoice {
            performance.recordSetupFailure()
            let waitingAt = ContinuousClock.now
            let choice = await waitForVoicePolishChoice(reason: .setupFailed, sessionID: sessionID)
            performance.decisionWait += ContinuousClock.now - waitingAt
            switch choice {
            case .retry:
                performance.userRetryCount += 1
                loadedLLMConfig = await loadLLMConfigOffActor()
            case .cancel:
                await saveCancelledVoicePolishHistory(
                    rawText: rawText, canonicalText: outcome.finalText,
                    mode: mode, durationMs: durationMs
                )
                return .abort
            }
        }
        if let llmConfig = loadedLLMConfig {
            guard isCurrent(sessionID) else {
                DebugFileLogger.log("stopRecording: superseded during voice polish config, bailing")
                return .abort
            }
            guard let request = prepared.request else { return .abort }
            let voicePolishConfig = llmConfig
            let pipeline = VoicePolishEditingPipeline(
                client: currentLLMClient(),
                config: voicePolishConfig,
                onStage: { [weak self] stage in
                    Task { [weak self] in
                        await self?.emitVoicePolishStage(stage, sessionID: sessionID)
                    }
                }
            )
            var prefetched = polishPrefetch.take(session: sessionID, key: .init(
                text: request.fallbackText, requirements: request.preferences.additionalRequirements,
                provider: KeychainService.selectedPolishProvider(for: .standard),
                config: voicePolishConfig))
            if prefetched != nil {
                performance.reusedPrefetch = true
                DebugFileLogger.log("polish prefetch: reused completed candidate")
            }
            var totalAttempts = 0
            let result: VoicePolishResult
            while true {
                let readyCandidate = prefetched
                prefetched = nil
                let task = Task {
                    if let readyCandidate {
                        // 预生成已另计调度与复用；停止后没有发起正式请求。
                        return Self.voicePolishResult(readyCandidate, replacingAttemptCount: 0)
                    }
                    return await pipeline.process(request)
                }
                voicePolishTask = task
                voicePolishTaskSessionID = sessionID
                let currentResult = await task.value
                performance.record(
                    currentResult,
                    completedAutomatically: isCurrent(sessionID)
                )
                if voicePolishTaskSessionID == sessionID {
                    voicePolishTask = nil
                    voicePolishTaskSessionID = nil
                }
                totalAttempts += currentResult.llmAttemptCount
                let accumulatedResult = Self.voicePolishResult(
                    currentResult,
                    replacingAttemptCount: totalAttempts
                )
                guard isCurrent(sessionID) else {
                    DebugFileLogger.log("stopRecording: superseded during voice polish, bailing")
                    return .abort
                }
                guard currentResult.usedFallback,
                      allowsVoicePolishUserChoice else {
                    result = accumulatedResult
                    break
                }
                let waitingAt = ContinuousClock.now
                let choice = await waitForVoicePolishChoice(
                    reason: currentResult.failureReason, sessionID: sessionID
                )
                performance.decisionWait += ContinuousClock.now - waitingAt
                switch choice {
                case .retry:
                    performance.userRetryCount += 1
                    // 用户明确重试是一轮新的有界请求：每次 process 都从调用时刻
                    // 重新计算 deadline，不继续消耗录音停止时开始的旧预算。
                    continue
                case .cancel:
                    await saveCancelledVoicePolishHistory(
                        rawText: rawText, canonicalText: outcome.finalText,
                        mode: mode, durationMs: durationMs
                    )
                    return .abort
                }
            }
            outcome.voicePolishPerformance = VoicePolishPerformanceMeasurement(result: result)
            voicePolishProcessingSessionID = nil
            outcome.finalText = result.text
            if !result.usedFallback {
                outcome.processedText = result.text
            }
            outcome.llmFailed = result.usedFallback
            outcome.voicePolishHistoryStatus = Self.voicePolishHistoryStatus(for: result)
            // 先把已完成结果同步给HUD，再执行非关键的近期输入记忆。
            onASREvent?(.processingResult(text: result.text))
            if VoicePolishSettings.recentInputContextEnabled(defaults: vocabularyContext.userDefaults), !result.usedFallback {
                await voicePolishRecentInputStore.remember(
                    result.text,
                    applicationBundleID: writingContext.applicationBundleID
                )
                guard isCurrent(sessionID) else {
                    DebugFileLogger.log("stopRecording: stale recent voice polish output ignored")
                    return .abort
                }
            }
        } else {
            performance.recordSetupFailure()
            DebugFileLogger.log("stop: no LLM credentials for voice polish, falling back")
            outcome.llmFailed = true
            outcome.voicePolishHistoryStatus = "voice_polish_fallback"
            onASREvent?(.processingResult(text: envelope.fallbackText))
            outcome.finalText = envelope.fallbackText
            outcome.voicePolishPerformance = VoicePolishPerformanceMeasurement(
                outcome: .setupFailure
            )
        }
        return .continue
    }

    private func postProcessEarlyLLM(
        _ earlyTask: Task<String?, Never>,
        sessionID: RecognitionSessionID,
        stopStartedAt stopT0: ContinuousClock.Instant,
        outcome: inout PostProcessingOutcome
    ) async -> PostProcessingStep {
        state = .postProcessing
        DebugFileLogger.log("stop: awaiting early LLM result +\(ContinuousClock.now - stopT0)")
        // REPAIR_PLAN J12：stop 链路上 LLM 是唯一无会话级硬超时的阻塞点——底层
        // 30s request timeout 是「无数据间隔」语义，流式慢速涓流可拖过；超时按
        // LLM 失败处理（下方 else 分支回退原文），HUD 不再无限卡 postProcessing。
        let timedEarly = await AsyncTimeout.asyncValue(Self.llmPostProcessTimeout) {
            await earlyTask.value
        }
        if timedEarly.timedOut {
            DebugFileLogger.log("stop: early LLM timed out at session level")
        }
        let earlyResult = timedEarly.value.flatMap { $0 }
        guard isCurrent(sessionID) else {
            DebugFileLogger.log("stopRecording: superseded during early llm, bailing")
            return .abort
        }
        if let result = earlyResult, !result.isEmpty {
            DebugFileLogger.log("stop: early LLM result received \(result.count) chars +\(ContinuousClock.now - stopT0)")
            outcome.processedText = result
            outcome.finalText = result
            onASREvent?(.processingResult(text: result))
        } else {
            let err = pendingLLMError ?? LLMError.emptyResponse(nil)
            DebugFileLogger.log("stop: early LLM failed, falling back to canonical text: \(err)")
            pendingLLMError = nil
            outcome.llmFailed = true
            onASREvent?(.processingResult(text: outcome.finalText))
        }
        return .continue
    }

    private func postProcessSyncLLM(
        sessionID: RecognitionSessionID,
        outcome: inout PostProcessingOutcome
    ) async -> PostProcessingStep {
        state = .postProcessing
        if let llmConfig = await loadLLMConfigOffActor() {
            guard isCurrent(sessionID) else {
                DebugFileLogger.log("stopRecording: superseded during sync llm config, bailing")
                return .abort
            }

            let mode = currentMode
            let prompt = mode.applyingLLMFormatGuard(
                to: promptContext.expandContextVariables(mode.prompt)
            )
            DebugFileLogger.log("stop: sync LLM firing mode=\(mode.name) model=\(llmConfig.model) with \(outcome.finalText.count) chars")
            do {
                let client = currentLLMClient()
                // REPAIR_PLAN J12：同 early 路径，包会话级硬超时防涓流拖死
                let textForLLM = outcome.finalText
                let timed = await AsyncTimeout.asyncValue(Self.llmPostProcessTimeout) {
                    () -> Result<String, Error> in
                    do {
                        return .success(try await client.process(
                            text: textForLLM,
                            prompt: prompt,
                            context: .processingMode,
                            config: llmConfig
                        ))
                    } catch {
                        return .failure(error)
                    }
                }
                guard let llmOutcome = timed.value else {
                    throw LLMError.timedOut
                }
                let result = try llmOutcome.get()
                let cleanedResult = mode.applyingLLMResultCleanup(to: result)
                guard isCurrent(sessionID) else {
                    DebugFileLogger.log("stopRecording: superseded during sync llm, bailing")
                    return .abort
                }
                if cleanedResult.isEmpty {
                    DebugFileLogger.log("stop: sync LLM empty result, falling back to canonical text")
                    outcome.llmFailed = true
                    onASREvent?(.processingResult(text: outcome.finalText))
                } else {
                    outcome.processedText = cleanedResult
                    outcome.finalText = cleanedResult
                    onASREvent?(.processingResult(text: cleanedResult))
                }
            } catch {
                guard isCurrent(sessionID) else {
                    DebugFileLogger.log("stopRecording: superseded during sync llm error, bailing")
                    return .abort
                }
                logger.error("LLM failed: \(error)")
                DebugFileLogger.log("stop: sync LLM FAILED, falling back to canonical text: \(error)")
                outcome.llmFailed = true
                onASREvent?(.processingResult(text: outcome.finalText))
            }
        } else {
            DebugFileLogger.log("stop: no LLM credentials, falling back to canonical text")
            outcome.llmFailed = true
            onASREvent?(.processingResult(text: outcome.finalText))
        }
        return .continue
    }

    private func emitVoicePolishStage(
        _ stage: VoicePolishStage,
        sessionID: RecognitionSessionID
    ) {
        guard isCurrent(sessionID),
              state == .postProcessing,
              voicePolishProcessingSessionID == sessionID,
              voicePolishChoiceSessionID == nil else { return }
        onASREvent?(.voicePolishStage(stage))
    }

    private func waitForVoicePolishChoice(
        reason: VoicePolishFailureReason?,
        sessionID: RecognitionSessionID
    ) async -> VoicePolishUserChoice {
        guard isCurrent(sessionID), state == .postProcessing else { return .cancel }
        // 同一会话同时只能存在一个选择点。若旧 continuation 尚未清理，先让
        // 它退出，避免悬挂或一次点击唤醒错误的等待者。
        if let pending = voicePolishChoiceContinuation {
            pending.resume(returning: .cancel)
            voicePolishChoiceContinuation = nil
            voicePolishChoiceSessionID = nil
        }
        return await withCheckedContinuation { continuation in
            voicePolishChoiceSessionID = sessionID
            voicePolishChoiceContinuation = continuation
            onASREvent?(.voicePolishUnavailable(reason: reason))
        }
    }

    private func resolveVoicePolishChoice(
        _ choice: VoicePolishUserChoice,
        sessionID: RecognitionSessionID
    ) {
        guard voicePolishChoiceSessionID == sessionID,
              let continuation = voicePolishChoiceContinuation else { return }
        voicePolishChoiceSessionID = nil
        voicePolishChoiceContinuation = nil
        continuation.resume(returning: choice)
    }

    private func applicationBundleIdentifier(for sessionID: RecognitionSessionID) -> String? {
        guard targetApplicationBundleIdentifierSessionID == sessionID else { return nil }
        return targetApplicationBundleIdentifier
    }

    private func terminologyApplicationBundleIdentifier(
        for sessionID: RecognitionSessionID,
        fallbackBundleIdentifier: String?
    ) -> String? {
        if targetApplicationBundleIdentifierSessionID == sessionID {
            return targetApplicationBundleIdentifier
        }
        return fallbackBundleIdentifier
    }

    private func canonicalText(
        for rawText: String,
        sessionID: RecognitionSessionID,
        vocabularyContext: VocabularyStorageContext = .production
    ) -> String {
        VoicePolishTerminologyRuntime.prepare(
            rawText: rawText,
            applicationBundleIdentifier: applicationBundleIdentifier(for: sessionID),
            context: vocabularyContext
        ).canonicalText
    }

    private static func voicePolishResult(
        _ result: VoicePolishResult,
        replacingAttemptCount attemptCount: Int
    ) -> VoicePolishResult {
        VoicePolishResult(
            text: result.text,
            detectedRoute: result.detectedRoute,
            executedRoute: result.executedRoute,
            llmAttemptCount: attemptCount,
            validationCodes: result.validationCodes,
            usedFallback: result.usedFallback,
            failureReason: result.failureReason,
            rejectedDraft: result.rejectedDraft,
            repairAttemptCount: result.repairAttemptCount
        )
    }

    private static func voicePolishHistoryStatus(for result: VoicePolishResult) -> String {
        guard result.usedFallback else { return "voice_polish_success" }
        switch result.failureReason {
        case .timeout:
            return "voice_polish_timeout"
        case .validationFailed:
            return "voice_polish_validation_failed"
        case .requestFailed, .setupFailed, .none:
            return "voice_polish_fallback"
        }
    }

    // REPAIR_PLAN K1：防泄漏清洗只作用于真 LLM 输出。直出与 LLM 失败回退的文本是
    // 用户口述原文，stripLikelyPromptLeakage 的 marker（「现在剪切板」「输入消息」等）
    // 会命中日常口语并从命中处截断到结尾（2026-07-15 实锤：113 字被截成 5 字）。
    static func finalizeInsertionText(
        _ text: String,
        mode: ProcessingMode,
        isLLMOutput: Bool
    ) -> String {
        guard isLLMOutput else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return mode.applyingFinalInsertionCleanup(to: text)
    }

    private func injectFinalText(
        _ finalText: String,
        stopStartedAt stopT0: ContinuousClock.Instant
    ) -> InjectionOutcome {
        state = .injecting
        let defaults = UserDefaults.standard
        injectionEngine.preserveClipboard = defaults.object(forKey: DefaultsKeys.preserveClipboard) != nil
            ? defaults.bool(forKey: DefaultsKeys.preserveClipboard)
            : true

        DebugFileLogger.log("stop: injecting len=\(finalText.count) +\(ContinuousClock.now - stopT0)")
        return injectionEngine.inject(finalText)
    }

    private func saveSuccessfulHistory(
        historyID: String,
        rawText: String,
        llmResult: LLMPostProcessingResult,
        streamingFailed: Bool,
        injection: InjectionOutcome,
        durationSeconds: TimeInterval,
        sessionID: RecognitionSessionID
    ) async {
        // J15：状态口径反映注入结局——仅复制到剪贴板 / 没找到输入位置时不再记 completed
        let status: String
        if llmResult.llmFailed {
            if let voicePolishStatus = llmResult.voicePolishHistoryStatus,
               case .inserted = injection {
                status = voicePolishStatus
            } else {
                status = "llm_error"
            }
        } else if streamingFailed {
            status = "stream_recovered"
        } else if let voicePolishStatus = llmResult.voicePolishHistoryStatus,
                  case .inserted = injection {
            status = voicePolishStatus
        } else {
            switch injection {
            case .inserted:
                status = "completed"
            case .copiedToClipboard, .copiedToClipboardPermissionMissing:
                status = "copied_only"
            case .noFocusedInput(let copiedToClipboard):
                status = copiedToClipboard ? "copied_only" : "no_input_target"
            }
        }

        let finalText = llmResult.finalText
        await historyStore.insert(HistoryRecord(
            id: historyID,
            createdAt: Date(),
            durationSeconds: durationSeconds,
            rawText: rawText,
            processingMode: historyProcessingModeName,
            processedText: llmResult.processedText,
            finalText: finalText,
            status: status,
            characterCount: finalText.count,
            tokenCount: EstimatedTokenCounter.count(in: finalText)
        ))
        guard isCurrent(sessionID) else { return }

        // REPAIR_PLAN C1：按保留上限裁剪（默认 1 万条，defaults 可调）
        let defaults = UserDefaults.standard
        let retentionLimit = defaults.object(forKey: DefaultsKeys.historyRetentionLimit) != nil
            ? defaults.integer(forKey: DefaultsKeys.historyRetentionLimit)
            : HistoryStore.defaultRetentionLimit
        await historyStore.prune(keepingMostRecent: retentionLimit)
    }

    private func saveEmptyHistoryIfNeeded(
        streamingFailed: Bool,
        durationSeconds: TimeInterval,
        sessionID: RecognitionSessionID
    ) async {
        // No text recognized: save to history as failed, then exit.
        guard durationSeconds > 1.0 else { return }

        // Only save if recording lasted more than 1 second (skip accidental taps)
        let status = streamingFailed ? "stream_failed" : "empty"
        await historyStore.insert(HistoryRecord(
            id: UUID().uuidString,
            createdAt: Date(),
            durationSeconds: durationSeconds,
            rawText: "",
            processingMode: historyProcessingModeName,
            processedText: nil,
            finalText: "",
            status: status,
            characterCount: 0,
            tokenCount: 0
        ))
        guard isCurrent(sessionID) else { return }
        DebugFileLogger.log("stop: no text recognized, saved to history as \(status)")
    }

    /// 新记录使用真实执行的基础模式名称。
    private var historyProcessingModeName: String {
        Self.historyProcessingModeName(for: currentMode)
    }

    private static func historyProcessingModeName(for mode: ProcessingMode) -> String {
        switch mode.id {
        case ProcessingMode.directId:
            return L("直出", "Direct")
        case ProcessingMode.lightPolishId, ProcessingMode.formalWriting.id:
            return L("润色", "Polish")
        default:
            return mode.name
        }
    }

    /// 润色失败等待中被取消（Esc 或新会话顶替）时不注入、不交付，但原转写
    /// 必须留在历史里，否则 HUD 所称「原转写已保留」会落空、整段内容丢失。
    /// 字数与 token 记 0：本次没有产生输出，不计入统计。
    private func saveCancelledVoicePolishHistory(
        rawText: String,
        canonicalText: String,
        mode: ProcessingMode,
        durationMs: Int
    ) async {
        await historyStore.insert(HistoryRecord(
            id: UUID().uuidString,
            createdAt: Date(),
            durationSeconds: Double(durationMs) / 1_000,
            rawText: rawText,
            processingMode: Self.historyProcessingModeName(for: mode),
            processedText: nil,
            finalText: canonicalText,
            status: "voice_polish_cancelled",
            characterCount: 0,
            tokenCount: 0
        ))
        DebugFileLogger.log("voice polish cancelled while awaiting choice; transcript saved to history len=\(canonicalText.count)")
    }

    private func teardownASRClient(
        provider: ASRProvider,
        client: (any SpeechRecognizer)?,
        sessionID: RecognitionSessionID,
        stopStartedAt stopT0: ContinuousClock.Instant
    ) async -> ASRTeardownResult {
        // ASR teardown: send endAudio and drain event stream with hard deadlines.
        // Uses detached tasks + continuation so a stuck client can't block stopRecording.
        let providerIsStreaming = ASRProviderRegistry.capabilities(for: provider).isStreaming
        var eventStreamDrained = true

        guard let client,
              isCurrent(sessionID),
              ownsASRClient(client, sessionID: sessionID) else {
            return ASRTeardownResult(
                providerIsStreaming: providerIsStreaming,
                endAudioSucceeded: true,
                eventStreamDrained: true
            )
        }
        let ownedEventTask: Task<Void, Never>?
        let ownedEventToken: UUID?
        if eventConsumptionTaskSessionID == sessionID {
            ownedEventTask = eventConsumptionTask
            ownedEventToken = eventConsumptionTaskToken
        } else {
            ownedEventTask = nil
            ownedEventToken = nil
        }

        let endAudioTimeout: Duration = providerIsStreaming ? .seconds(3) : .seconds(60)
        let endAudioOK = await AsyncTimeout.run(endAudioTimeout) {
            try await client.endAudio()
        }
        guard isCurrent(sessionID), ownsASRClient(client, sessionID: sessionID) else {
            DebugFileLogger.log("stop: ASR endAudio returned for stale session=\(sessionID.rawValue)")
            return ASRTeardownResult(
                providerIsStreaming: providerIsStreaming,
                endAudioSucceeded: false,
                eventStreamDrained: false
            )
        }
        if !endAudioOK {
            DebugFileLogger.log("endAudio timeout or failed")
        }

        // Always try to drain events — even if endAudio failed, the server
        // may have already queued transcript events before the connection broke.
        if let evtTask = ownedEventTask {
            let drainTimeout: Duration
            if provider == .volcano {
                drainTimeout = .milliseconds(1_200)
            } else {
                drainTimeout = providerIsStreaming ? .seconds(2) : .seconds(5)
            }
            let drained = await AsyncTimeout.run(drainTimeout) {
                await evtTask.value
            }
            guard isCurrent(sessionID), ownsASRClient(client, sessionID: sessionID) else {
                DebugFileLogger.log("stop: event drain returned for stale session=\(sessionID.rawValue)")
                return ASRTeardownResult(
                    providerIsStreaming: providerIsStreaming,
                    endAudioSucceeded: false,
                    eventStreamDrained: false
                )
            }
            if !drained {
                DebugFileLogger.log("event stream drain timeout")
                eventStreamDrained = false
            }
        }

        await client.disconnect()
        guard isCurrent(sessionID), ownsASRClient(client, sessionID: sessionID) else {
            DebugFileLogger.log("stop: disconnect returned for stale session=\(sessionID.rawValue)")
            return ASRTeardownResult(
                providerIsStreaming: providerIsStreaming,
                endAudioSucceeded: false,
                eventStreamDrained: false
            )
        }

        ownedEventTask?.cancel()
        if eventConsumptionTaskSessionID == sessionID,
           eventConsumptionTaskToken == ownedEventToken {
            eventConsumptionTask = nil
            eventConsumptionTaskSessionID = nil
            eventConsumptionTaskToken = nil
        }
        clearASRClientIfOwned(client, sessionID: sessionID)
        hasEmittedReadyForCurrentSession = false
        let result = ASRTeardownResult(
            providerIsStreaming: providerIsStreaming,
            endAudioSucceeded: endAudioOK,
            eventStreamDrained: eventStreamDrained
        )
        DebugFileLogger.log(
            "stop: ASR teardown complete (clean=\(result.clean) endAudio=\(result.endAudioSucceeded) drained=\(result.eventStreamDrained)) +\(ContinuousClock.now - stopT0)"
        )
        return result
    }

    private func recoverTranscriptAfterStreamingFailureIfNeeded(
        streamingFailed: Bool,
        audio fullAudio: Data,
        sessionID: RecognitionSessionID
    ) async -> TranscriptRecoveryResult {
        guard streamingFailed, isCurrent(sessionID) else { return .notNeeded }

        let partialText = currentTranscript.composedText
        DebugFileLogger.log("stop: streaming failed (partial=\(partialText.count) chars), attempting batch fallback")

        guard !fullAudio.isEmpty,
              currentConfigSessionID == sessionID,
              let config = currentConfig else {
            DebugFileLogger.log("stop: batch fallback unavailable (audio/config missing)")
            return .failed
        }
        let provider = activeProvider

        onASREvent?(.processingResult(text: partialText.isEmpty ? "重新识别中..." : partialText))
        guard let batchText = await attemptBatchFallback(
            audio: fullAudio,
            config: config,
            provider: provider
        ) else {
            DebugFileLogger.log("stop: batch fallback failed, using partial text")
            return .failed
        }
        guard isCurrent(sessionID) else {
            DebugFileLogger.log("stop: batch fallback result ignored for stale session")
            return .failed
        }

        // REPAIR_PLAN K2：兜底不劣化——批量结果比流式已有文本更短时保留流式，
        // 防止「兜底自身被截」反而覆盖掉更完整的字幕文本。
        let streamingText = Self.effectiveTranscriptText(for: currentTranscript)
        guard batchText.count >= streamingText.count else {
            DebugFileLogger.log(
                "stop: batch fallback shorter than streaming (\(batchText.count) < \(streamingText.count)), keeping streaming text"
            )
            return .succeeded
        }

        currentTranscript = RecognitionTranscript(
            confirmedSegments: [batchText],
            partialText: "",
            authoritativeText: batchText,
            isFinal: true
        )
        DebugFileLogger.log("stop: batch fallback succeeded, \(batchText.count) chars")
        return .succeeded
    }

    // REPAIR_PLAN K2：注入取值守卫。HUD 字幕与 LLM 路径显示/消费 composedText
    //（流式累积），而 displayText 优先 authoritativeText（火山 asyncFinal 的
    // result.text）——后者偶发只承载尾段或被服务端 DDC 重排变短。权威文本明显
    // 短于流式累积时回退 composed，使注入与用户在 HUD 所见一致。
    static func effectiveTranscriptText(for transcript: RecognitionTranscript) -> String {
        let auth = transcript.authoritativeText
        let composed = transcript.composedText
        guard !auth.isEmpty else { return composed }
        guard !composed.isEmpty else { return auth }
        if Double(auth.count) < Double(composed.count) * 0.6 {
            DebugFileLogger.log(
                "stop: authoritative text suspiciously short auth=\(auth.count) composed=\(composed.count), using composed"
            )
            return composed
        }
        return auth
    }

    // REPAIR_PLAN K10：按真实有声时长而非墙钟录音时长判断，长停顿不再把正常
    // 文本误报为丢字；活动摘要只计通过声音阈值的 20ms 帧。
    static func isTranscriptImplausiblyShort(
        textCount: Int,
        audioSummary: PCMAudioActivitySummary
    ) -> Bool {
        isTranscriptImplausiblyShort(
            textCount: textCount,
            durationSeconds: audioSummary.voicedDurationSeconds
        )
    }

    // REPAIR_PLAN K2：有声时长较长且不足每秒 0.5 字时视为疑似流层丢失。
    // 0 字交由 K7 的 PCM 活动摘要另行判断；不足 10 秒的短句不触发。
    static func isTranscriptImplausiblyShort(
        textCount: Int,
        durationSeconds: Double
    ) -> Bool {
        guard durationSeconds >= 10 else { return false }
        guard textCount > 0 else { return false }
        return Double(textCount) < durationSeconds * 0.5
    }

    // MARK: - ASR Events

    private func handleASREvent(_ event: RecognitionEvent, sessionID: RecognitionSessionID) {
        guard isCurrent(sessionID) else {
            DebugFileLogger.log(
                "ignoring stale ASR event for session=\(sessionID.rawValue), active=\(String(describing: currentSessionID?.rawValue))"
            )
            return
        }
        switch event {
        case .ready:
            // Deduplicate: ASR clients may emit .ready, but we also emit it
            // on first audio chunk via markReadyIfNeeded(). Route both through
            // the same guard to avoid double-firing the start sound.
            markReadyIfNeeded(sessionID: sessionID)
            return  // markReadyIfNeeded calls onASREvent(.ready) internally

        case .completed:
            // J15 状态回跳：流关闭只在录音中才有语义（服务端主动收播 → UI 进处理态）。
            // 用户已发起停止后的正常关流若照转发，UI 会提前复位热键 processing 标志，
            // 间隙按键可打断在途收尾管线；收尾自身的终态事件由 stop 管线直接发出。
            logger.info("ASR stream completed")
            if state == .recording {
                AppLogger.log("[Session] Server closed ASR while recording, initiating stop")
                DebugFileLogger.log("server-initiated stop from recording state")
                onASREvent?(.completed)
                Task { await self.stopRecording(expectedSessionID: sessionID) }
            } else {
                DebugFileLogger.log("ASR stream closed in state=\(state); completed not forwarded")
            }
            return

        default:
            break
        }

        switch event {
        case .ready, .completed:
            break  // handled above

        case .transcript(let transcript):
            if transcript.composedText != currentTranscript.composedText {
                polishPrefetch.invalidate()
            }
            currentTranscript = transcript
            onASREvent?(event)
            logger.info("Transcript updated chars=\(transcript.displayText.count, privacy: .public) segments=\(transcript.confirmedSegments.count, privacy: .public) final=\(transcript.isFinal, privacy: .public)")
            if state == .recording, currentMode.requiresLLM {
                scheduleSpeculativeLLM(sessionID: sessionID)
            }

        case .error(let error):
            logger.error("ASR error: \(error, privacy: .private)")
            let supportsFullPCMReplay = activeProvider == .aliyun
                || activeProvider == .volcano
            if supportsFullPCMReplay,
               state == .recording || state == .finishing {
                // 云端任务失败不再立即 forceReset 丢掉本地整段音频。录音中只给
                // 非致命断流提示，停止阶段静默标记降级，随后统一做完整重放。
                streamingDegraded = true
                DebugFileLogger.log(
                    "ASR terminal error preserved local audio state=\(state); batch fallback required"
                )
                if state == .recording {
                    onASREvent?(.streamingInterrupted)
                }
                return
            }
            onASREvent?(event)
            if state == .recording || state == .starting {
                Task { await self.failActiveSessionAfterASRError(sessionID: sessionID) }
            }

        case .streamingInterrupted:
            // REPAIR_PLAN B7b：客户端静默重连成功也会发此事件——重连期间的
            // 语音服务端没听到，标记降级让停止流程批量复核全文
            streamingDegraded = true
            onASREvent?(event)
            logger.warning("streaming degraded (interrupted/reconnected); batch fallback will verify at stop")

        case .processingResult, .voicePolishStage, .voicePolishUnavailable, .finalized:
            onASREvent?(event)
            break
        }
    }

    private func failActiveSessionAfterASRError(sessionID: RecognitionSessionID) async {
        guard isCurrent(sessionID) else { return }
        guard state == .recording || state == .starting else { return }
        DebugFileLogger.log("ASR error forced session teardown state=\(state)")
        forceReset()
        onASREvent?(.completed)
    }

    // MARK: - Internal helpers

    private func eventConsumptionDidFinish(
        sessionID: RecognitionSessionID,
        token: UUID
    ) {
        guard isCurrent(sessionID),
              eventConsumptionTaskSessionID == sessionID,
              eventConsumptionTaskToken == token else {
            return
        }
        eventConsumptionTask = nil
        eventConsumptionTaskSessionID = nil
        eventConsumptionTaskToken = nil
    }

    private func setupAudioChunkPipeline(
        client: any SpeechRecognizer,
        provider: ASRProvider,
        sessionID: RecognitionSessionID
    ) -> AudioChunkUploadPipeline? {
        guard isCurrent(sessionID), ownsASRClient(client, sessionID: sessionID) else {
            return nil
        }
        if let existingPipeline = audioChunkPipeline {
            guard audioChunkPipelineSessionID == sessionID else {
                DebugFileLogger.log("refusing to replace audio pipeline owned by another session")
                return nil
            }
            existingPipeline.cancel()
        }
        // Capture everything needed for sending so the Task body
        // does NOT hop back to the actor.  This prevents a blocking
        // WebSocket send from starving stopRecording().
        let audioInput = ASRProviderRegistry.capabilities(for: provider).audioInput
        let emitInterrupted: @Sendable (RecognitionEvent) -> Void = { [weak self] event in
            Task { await self?.handleASREvent(event, sessionID: sessionID) }
        }

        let pipeline = AudioChunkUploadPipeline(
            client: client,
            audioInput: audioInput,
            emitInterrupted: emitInterrupted
        )
        audioChunkPipeline = pipeline
        audioChunkPipelineSessionID = sessionID
        return pipeline
    }

    @discardableResult
    private func finishAudioChunkPipeline(
        sessionID: RecognitionSessionID,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        // Give the detached sender a brief window to drain remaining chunks
        // (especially the tail audio from flushRemaining). Since it's detached,
        // this wait does NOT block the actor.
        guard audioChunkPipelineSessionID == sessionID,
              let pipeline = audioChunkPipeline else { return false }
        // 先摘除共享引用；旧 finish 晚到时无法清理新会话管线。
        audioChunkPipeline = nil
        audioChunkPipelineSessionID = nil
        let failed = await pipeline.finish(timeout: timeout)
        return failed
    }

    private func markReadyIfNeeded(sessionID: RecognitionSessionID) {
        guard isCurrent(sessionID) else { return }
        guard !hasEmittedReadyForCurrentSession else { return }
        hasEmittedReadyForCurrentSession = true
        recordingStartTime = Date()
        recordingStartSessionID = sessionID
        DebugFileLogger.log("session emitting ready")
        onASREvent?(.ready)
        logger.info("Recording started")
    }

    // MARK: - Speculative LLM

    /// Debounce: after each transcript update, wait 800ms of silence before
    /// speculatively sending current text to LLM. If the user is still
    /// speaking, the timer resets.
    private func scheduleSpeculativeLLM(sessionID: RecognitionSessionID) {
        guard isCurrent(sessionID) else { return }
        // Skip speculative LLM for local models — they're fast enough (~0.5s)
        // and would compete for Metal GPU with local ASR.
        guard KeychainService.selectedPolishProvider(for: .resolve(currentMode.voicePolishQualityMode)) != .localQwen else { return }

        speculativeDebounceTask?.cancel()
        let debounceToken = UUID()
        speculativeDebounceSessionID = sessionID
        speculativeDebounceTaskToken = debounceToken
        speculativeDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled,
                  isCurrent(sessionID),
                  state == .recording,
                  speculativeDebounceSessionID == sessionID,
                  speculativeDebounceTaskToken == debounceToken else { return }
            speculativeDebounceTask = nil
            speculativeDebounceSessionID = nil
            speculativeDebounceTaskToken = nil
            await fireSpeculativeLLM(sessionID: sessionID)
        }
    }

    private func fireSpeculativeLLM(sessionID: RecognitionSessionID) async {
        guard isCurrent(sessionID), state == .recording else { return }
        if currentMode.kind == .voicePolish {
            await firePolishPrefetch(sessionID: sessionID)
            return
        }
        let rawText = currentTranscript.composedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = canonicalText(for: rawText, sessionID: sessionID)
        guard !text.isEmpty, text != speculativeLLMText else { return }
        guard let llmConfig = await loadLLMConfigOffActor() else { return }
        guard isCurrent(sessionID), state == .recording else { return }

        // Cancel previous speculative call if text changed
        if speculativeLLMSessionID == sessionID {
            speculativeLLMTask?.cancel()
        }
        speculativeLLMText = text
        let mode = currentMode
        let prompt = mode.applyingLLMFormatGuard(
            to: promptContext.expandContextVariables(mode.prompt)
        )

        let client = currentLLMClient()
        DebugFileLogger.log("speculative LLM: firing mode=\(mode.name) model=\(llmConfig.model) with \(text.count) chars")
        let task: Task<String?, Never> = Task {
            do {
                let result = try await client.process(
                    text: text,
                    prompt: prompt,
                    context: .processingMode,
                    config: llmConfig
                )
                let cleanedResult = mode.applyingLLMResultCleanup(to: result)
                DebugFileLogger.log("speculative LLM: done \(cleanedResult.count) chars")
                return cleanedResult
            } catch {
                DebugFileLogger.log("speculative LLM: failed \(error)")
                self.setPendingLLMError(error, sessionID: sessionID)
                return nil
            }
        }
        speculativeLLMTask = task
        speculativeLLMSessionID = sessionID
    }

    private func firePolishPrefetch(
        sessionID: RecognitionSessionID,
        vocabularyContext: VocabularyStorageContext = .production
    ) async {
        let transcript = currentTranscript
        let raw = transcript.composedText
        let mode = currentMode
        let provider = KeychainService.selectedPolishProvider(for: .standard)
        // 仅云端预生成；与正式路径共享上下文纠错及完整正文构造。
        guard mode.kind == .voicePolish, !provider.isLocal,
              let writingContext = await polishWritingContext(
                sessionID: sessionID, vocabularyContext: vocabularyContext
              ),
              let config = await loadLLMConfigOffActor(),
              isCurrent(sessionID), state == .recording,
              currentMode == mode, currentTranscript == transcript,
              KeychainService.selectedPolishProvider(for: .standard) == provider else { return }
        let prepared = preparePolishRequest(
            rawText: raw, transcript: transcript, mode: mode, writingContext: writingContext,
            durationMs: 0, provider: activeProvider, sessionID: sessionID,
            vocabularyContext: vocabularyContext
        )
        guard let request = prepared.request else { return }
        let pipeline = VoicePolishEditingPipeline(client: currentLLMClient(), config: config)
        polishPrefetch.start(session: sessionID, key: .init(
            text: request.fallbackText, requirements: request.preferences.additionalRequirements,
            provider: provider, config: config
        )) {
            await pipeline.process(request)
        }
    }

    /// 预生成保留录音开始时捕获的上下文，正式交付再次读取当前近期输入并精确比对正文。
    private func polishWritingContext(
        sessionID: RecognitionSessionID, vocabularyContext: VocabularyStorageContext
    ) async -> WritingContext? {
        var context: WritingContext
        if writingContextTaskSessionID == sessionID, let task = writingContextTask {
            context = await task.value
        } else {
            context = WritingContext(
                level: VoicePolishSettings.contextLevel(defaults: vocabularyContext.userDefaults),
                safety: .unknown
            )
        }
        guard isCurrent(sessionID) else { return nil }
        if VoicePolishSettings.recentInputContextEnabled(defaults: vocabularyContext.userDefaults) {
            let recent = await voicePolishRecentInputStore.recentInputs(
                applicationBundleID: context.applicationBundleID
            )
            guard isCurrent(sessionID) else { return nil }
            context = context.includingRecentMuseInputs(recent)
        }
        return context
    }

    /// 一处构造最终送给模型的正文，确保词库、分段与授权上下文在预生成和交付间一致。
    private func preparePolishRequest(
        rawText: String, transcript: RecognitionTranscript, mode: ProcessingMode,
        writingContext: WritingContext, durationMs: Int, provider: ASRProvider,
        sessionID: RecognitionSessionID, vocabularyContext: VocabularyStorageContext
    ) -> (request: VoicePolishRequest?, canonicalText: String) {
        let terminology = VoicePolishTerminologyRuntime.prepare(
            rawText: rawText,
            applicationBundleIdentifier: terminologyApplicationBundleIdentifier(
                for: sessionID, fallbackBundleIdentifier: writingContext.applicationBundleID
            ), context: vocabularyContext
        )
        let segments = transcript.confirmedSegments.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map { VoicePolishTerminologyRuntime.canonicalText(for: $0, reusing: terminology) }
        guard let envelope = VoiceInputEnvelope.fromFinalTranscript(
            transcript, rawFinalText: rawText, canonicalText: terminology.canonicalText,
            preferredCanonicalSegmentTexts: segments,
            deterministicCorrections: terminology.projection.corrections,
            durationMs: durationMs, provider: provider
        ) else { return (nil, terminology.canonicalText) }
        let entities = EntityResolver.resolve(
            segments: envelope.segments, lexicon: terminology.projection.personalLexicon,
            snippets: terminology.fixedSnippets, hotwords: [], context: writingContext
        )
        let request = VoicePolishRequest(
            input: envelope, context: writingContext,
            preferences: UserPolishPreferences(additionalRequirements: mode.prompt),
            qualityMode: .standard, resolvedEntities: entities
        )
        return (request, terminology.canonicalText)
    }

    private func cancelSpeculativeLLM(sessionID: RecognitionSessionID) {
        if speculativeDebounceSessionID == sessionID {
            speculativeDebounceTask?.cancel()
            speculativeDebounceTask = nil
            speculativeDebounceSessionID = nil
            speculativeDebounceTaskToken = nil
        }
        // Don't cancel speculativeLLMTask here — stopRecording may reuse it
    }

    private func setPendingLLMError(_ error: Error, sessionID: RecognitionSessionID) {
        guard isCurrent(sessionID), speculativeLLMSessionID == sessionID else { return }
        pendingLLMError = error
    }

    private func resetSpeculativeLLM(sessionID: RecognitionSessionID? = nil) {
        polishPrefetch.reset(session: sessionID)
        if sessionID == nil || speculativeDebounceSessionID == sessionID {
            speculativeDebounceTask?.cancel()
            speculativeDebounceTask = nil
            speculativeDebounceSessionID = nil
            speculativeDebounceTaskToken = nil
        }
        if sessionID == nil || speculativeLLMSessionID == sessionID {
            speculativeLLMTask?.cancel()
            speculativeLLMTask = nil
            speculativeLLMSessionID = nil
            speculativeLLMText = ""
        }
    }

    // MARK: - Batch Fallback

    /// Try to transcribe full audio via the same provider in a fresh connection.
    private func attemptBatchFallback(
        audio: Data,
        config: any ASRProviderConfig,
        provider: ASRProvider
    ) async -> String? {
        let timeout = Self.batchFallbackTimeout(
            provider: provider,
            audioByteCount: audio.count
        )
        let clientFactory = asrClientFactory
        let replaySleep = aliyunReplaySleep
        do {
            return try await AsyncTimeout.throwingValue(
                timeout,
                timeoutError: BatchFallbackTimeoutError()
            ) {
                guard let client = clientFactory(provider) else { return nil }
                do {
                    let options = ASRRequestOptions(enablePunc: true, contextHistoryLength: 0)
                    try await client.connect(config: config, options: options)
                    if provider == .aliyun {
                        try await AliyunAudioReplay.send(
                            audio: audio,
                            to: client,
                            sleep: replaySleep
                        )
                    } else if provider == .volcano {
                        try await VolcanoAudioReplay.send(
                            audio: audio,
                            to: client
                        )
                    } else {
                        try await client.sendAudio(audio)
                    }
                    try await client.endAudio()

                    // Wait for final transcript
                    let events = await client.events
                    var latestNonEmptyText: String?
                    for await event in events {
                        switch event {
                        case .transcript(let transcript):
                            // REPAIR_PLAN K2：批量结果同样可能 auth 短于 composed，取长。
                            let text = RecognitionSession.effectiveTranscriptText(for: transcript)
                            if !text.isEmpty {
                                latestNonEmptyText = text
                            }
                            guard transcript.isFinal else { continue }
                            let result = latestNonEmptyText
                            await client.disconnect()
                            return result
                        case .error(let error):
                            DebugFileLogger.log(
                                "batch fallback provider=\(provider.rawValue) server error: \(error)"
                            )
                            await client.disconnect()
                            return nil
                        case .completed:
                            let result = latestNonEmptyText
                            if let result {
                                DebugFileLogger.log(
                                    "batch fallback provider=\(provider.rawValue) completed without final; using latest \(result.count) chars"
                                )
                            }
                            await client.disconnect()
                            return result
                        default:
                            continue
                        }
                    }
                    let result = latestNonEmptyText
                    if let result {
                        DebugFileLogger.log(
                            "batch fallback provider=\(provider.rawValue) event stream ended without final; using latest \(result.count) chars"
                        )
                    }
                    await client.disconnect()
                    return result
                } catch {
                    DebugFileLogger.log("batch fallback error: \(error)")
                    await client.disconnect()
                    return nil
                }
            }
        } catch is BatchFallbackTimeoutError {
            DebugFileLogger.log("batch fallback timeout after \(timeout)")
            return nil
        } catch {
            DebugFileLogger.log("batch fallback cancelled: \(error)")
            return nil
        }
    }

    /// 阿里云与火山重放都按实时节奏发送，超时必须覆盖音频本身时长；其他厂商
    /// 保持原 30 秒上限。极长会话最多等待 5 分钟，避免停止流程无限占用。
    static func batchFallbackTimeout(
        provider: ASRProvider,
        audioByteCount: Int
    ) -> Duration {
        guard provider == .aliyun || provider == .volcano else { return .seconds(30) }
        let bytesPerSecond = Int(AudioCaptureEngine.sampleRate)
            * MemoryLayout<Int16>.size
        let audioSeconds = Double(max(0, audioByteCount)) / Double(bytesPerSecond)
        return .seconds(min(300, max(30, audioSeconds.rounded(.up) + 15)))
    }

    // MARK: - Force Reset

    /// Aggressively tear down all resources and return to idle.
    /// Used when a new recording is requested but the session is stuck
    /// (e.g. stopRecording hung on a WebSocket timeout).
    private func forceReset() {
        AppLogger.log("[Session] forceReset from state=\(String(describing: state))")
        DebugFileLogger.log("forceReset from state=\(state)")

        // 会话 ID 是本函数的第一项状态修改。此后所有旧回调都会被身份守卫拒绝；
        // 剩余清理均同步摘除共享引用，唯一可能挂起的 disconnect 完全使用局部对象。
        let resetSessionID = currentSessionID
        polishPrefetch.reset()
        if let resetSessionID, voicePolishChoiceSessionID == resetSessionID {
            resolveVoicePolishChoice(.cancel, sessionID: resetSessionID)
        }
        currentSessionID = nil

        let client = asrClient
        let eventTask = eventConsumptionTask
        let pipeline = audioChunkPipeline
        let debounceTask = speculativeDebounceTask
        let llmTask = speculativeLLMTask
        let activeVoicePolishTask = voicePolishTask
        let shouldStopAudio = resetSessionID != nil && audioCaptureSessionID == resetSessionID

        asrClient = nil
        asrClientSessionID = nil
        eventConsumptionTask = nil
        eventConsumptionTaskSessionID = nil
        eventConsumptionTaskToken = nil
        audioChunkPipeline = nil
        audioChunkPipelineSessionID = nil
        audioCaptureSessionID = nil
        speculativeDebounceTask = nil
        speculativeDebounceSessionID = nil
        speculativeDebounceTaskToken = nil
        speculativeLLMTask = nil
        speculativeLLMSessionID = nil
        speculativeLLMText = ""
        writingContextTask?.cancel()
        writingContextTask = nil
        writingContextTaskSessionID = nil
        targetApplicationBundleIdentifier = nil
        targetApplicationBundleIdentifierSessionID = nil
        voicePolishTask = nil
        voicePolishTaskSessionID = nil
        voicePolishProcessingSessionID = nil
        voicePolishChoiceSessionID = nil
        voicePolishChoiceContinuation = nil
        currentConfig = nil
        currentConfigSessionID = nil
        recordingStartTime = nil
        recordingStartSessionID = nil
        pendingLLMError = nil
        state = .idle
        currentTranscript = .empty
        hasEmittedReadyForCurrentSession = false
        streamingDegraded = false

        eventTask?.cancel()
        pipeline?.cancel()
        debounceTask?.cancel()
        llmTask?.cancel()
        activeVoicePolishTask?.cancel()
        if shouldStopAudio {
            audioEngine.clearAudioHandlers()
            audioEngine.stop()
        }

        if let client {
            Task.detached { await client.disconnect() }
        }
    }

}

#if DEBUG
extension RecognitionSession {
    func handleASREventForTesting(
        _ event: RecognitionEvent,
        expectedSessionID: RecognitionSessionID? = nil
    ) {
        let sessionID: RecognitionSessionID
        if let expectedSessionID {
            sessionID = expectedSessionID
        } else if let currentSessionID {
            sessionID = currentSessionID
        } else {
            sessionID = makeSessionID()
            currentSessionID = sessionID
        }
        handleASREvent(event, sessionID: sessionID)
    }

    /// 测试用：同步使当前会话失效，异步断连仅持有旧客户端局部引用。
    func forceResetForTesting() {
        forceReset()
    }

    var currentSessionIDForTesting: RecognitionSessionID? {
        currentSessionID
    }

    func isActiveClientForTesting(_ client: any SpeechRecognizer) -> Bool {
        guard let currentSessionID else { return false }
        return ownsASRClient(client, sessionID: currentSessionID)
    }

    var activeClientCountForTesting: Int {
        guard let currentSessionID,
              let client = asrClient,
              ownsASRClient(client, sessionID: currentSessionID) else { return 0 }
        return 1
    }

    var transcriptForTesting: RecognitionTranscript {
        currentTranscript
    }

    var hasEmittedReadyForTesting: Bool {
        hasEmittedReadyForCurrentSession
    }

    func postProcessVoicePolishForTesting(
        rawText: String,
        transcript: RecognitionTranscript,
        provider: ASRProvider = .volcano,
        durationMs: Int = 1_000,
        writingContext: WritingContext? = nil,
        vocabularyContext: VocabularyStorageContext = .production,
        allowsUserChoice: Bool = false
    ) async -> (
        finalText: String,
        processedText: String?,
        llmFailed: Bool,
        historyStatus: String?,
        performance: VoicePolishPerformanceMeasurement?
    )? {
        await postProcessForTesting(
            rawText: rawText,
            transcript: transcript,
            mode: .formalWriting,
            provider: provider,
            durationMs: durationMs,
            writingContext: writingContext,
            vocabularyContext: vocabularyContext,
            allowsVoicePolishUserChoice: allowsUserChoice
        )
    }

    /// 使用真实预生成入口，仅绕过麦克风采集和停顿计时。
    func prefetchPolishForTesting(
        text: String, vocabularyContext: VocabularyStorageContext,
        writingContext: WritingContext? = nil
    ) async {
        if currentSessionID == nil { currentSessionID = makeSessionID() }
        guard let sessionID = currentSessionID else { return }
        state = .recording
        currentMode = .formalWriting
        if let writingContext {
            writingContextTask = Task { writingContext }
            writingContextTaskSessionID = sessionID
        }
        currentTranscript = RecognitionTranscript(confirmedSegments: [text], partialText: "",
                                                  authoritativeText: text, isFinal: false)
        await firePolishPrefetch(sessionID: sessionID, vocabularyContext: vocabularyContext)
    }

    func postProcessForTesting(
        rawText: String,
        transcript: RecognitionTranscript,
        mode: ProcessingMode,
        needsLLM: Bool? = nil,
        provider: ASRProvider = .volcano,
        durationMs: Int = 1_000,
        writingContext: WritingContext? = nil,
        applicationBundleIdentifier: String? = nil,
        applicationBundleIdentifierWasCaptured: Bool = false,
        vocabularyContext: VocabularyStorageContext = .production,
        allowsVoicePolishUserChoice: Bool = false
    ) async -> (
        finalText: String,
        processedText: String?,
        llmFailed: Bool,
        historyStatus: String?,
        performance: VoicePolishPerformanceMeasurement?
    )? {
        let sessionID: RecognitionSessionID
        if let currentSessionID {
            sessionID = currentSessionID
        } else {
            sessionID = makeSessionID()
            currentSessionID = sessionID
        }
        currentMode = mode
        if applicationBundleIdentifierWasCaptured || applicationBundleIdentifier != nil {
            targetApplicationBundleIdentifier = applicationBundleIdentifier
            targetApplicationBundleIdentifierSessionID = sessionID
        } else {
            targetApplicationBundleIdentifier = nil
            targetApplicationBundleIdentifierSessionID = nil
        }
        if let writingContext {
            writingContextTask = Task { writingContext }
            writingContextTaskSessionID = sessionID
        }
        let result = await postProcessRecognizedText(
            rawText: rawText,
            needsLLM: needsLLM ?? mode.requiresLLM,
            earlyLLMTask: nil,
            transcript: transcript,
            provider: provider,
            durationMs: durationMs,
            sessionID: sessionID,
            stopStartedAt: .now,
            vocabularyContext: vocabularyContext,
            allowsVoicePolishUserChoice: allowsVoicePolishUserChoice
        )
        return result.map {
            (
                finalText: $0.finalText,
                processedText: $0.processedText,
                llmFailed: $0.llmFailed,
                historyStatus: $0.voicePolishHistoryStatus,
                performance: $0.voicePolishPerformance
            )
        }
    }
}
#endif
