import Foundation
import os

protocol SenseVoiceWebSocketTasking: AnyObject, Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: SenseVoiceWebSocketTasking {}

struct SenseVoiceDialResources: Sendable {
    let task: any SenseVoiceWebSocketTasking
    let invalidateSession: @Sendable () -> Void
}

struct SenseVoiceConnectionPlan: Sendable {
    let webSocketURL: URL?
    let qwenPort: Int?
}

typealias SenseVoiceConnectionPlanProvider = @Sendable () async throws -> SenseVoiceConnectionPlan
typealias SenseVoiceDialFactory = @Sendable (URLRequest) -> SenseVoiceDialResources
typealias SenseVoiceQwenTranscriber = @Sendable (
    Data,
    Int,
    TimeInterval
) async -> String?

/// ASR client that connects to the local SenseVoice Python server via WebSocket.
actor SenseVoiceWSClient: SpeechRecognizer {

    private let logger = Logger(subsystem: "pro.daliang.muse.asr", category: "SenseVoiceWS")
    private let connectionPlanProvider: SenseVoiceConnectionPlanProvider
    private let dialFactory: SenseVoiceDialFactory
    private let qwenFinalEnabledProvider: @Sendable () -> Bool
    private let qwenTranscriber: SenseVoiceQwenTranscriber

    private var sessionID: UUID?
    private var connectionID: UUID?
    private var webSocketTask: (any SenseVoiceWebSocketTasking)?
    private var invalidateURLSession: (@Sendable () -> Void)?
    private var receiveTask: Task<Void, Never>?
    private var receiveTaskConnectionID: UUID?
    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?
    private var didRequestEndAudio = false
    private var didEmitTerminalEvent = false
    private var isAwaitingQwenFinal = false
    private var staleReceiveLoopExitCount = 0

    /// Running text from the server (latest partial or final).
    private var currentText = ""
    private var confirmedSegments: [String] = []

    /// Qwen3-only mode: no SenseVoice streaming, just accumulate audio for Qwen3 final.
    private var qwen3OnlyMode = false
    private var qwenPort: Int?

    // Qwen3 incremental speculative transcription
    private var qwen3DebounceTask: Task<Void, Never>?
    private var allAudioData = Data()
    private var qwen3ConfirmedOffset = 0
    private var qwen3ConfirmedSegments: [String] = []
    private var qwen3HasPendingAudio = false

    /// REPAIR_PLAN J10：Qwen3 校准音频缓冲的内存软上限（镜像 B8 采集层的 30 分钟）。
    /// 超限即丢弃整段并停止累积——半截音频做 final 校准会产出错误的半截文本
    /// 覆盖流式结果，比不校准更糟；超长会话的文本由 SenseVoice 流式结果保证。可注入小值供测试。
    var accumulatedAudioByteLimit = 30 * 60 * 16000 * MemoryLayout<Int16>.size
    private var audioAccumulationOverflowed = false

    init(
        connectionPlanProvider: @escaping SenseVoiceConnectionPlanProvider = {
            try await SenseVoiceWSClient.resolveProductionConnectionPlan()
        },
        dialFactory: @escaping SenseVoiceDialFactory = { request in
            let session = URLSession(configuration: .default)
            let task = session.webSocketTask(with: request)
            return SenseVoiceDialResources(
                task: task,
                invalidateSession: { session.invalidateAndCancel() }
            )
        },
        qwenFinalEnabledProvider: @escaping @Sendable () -> Bool = {
            UserDefaults.standard.object(forKey: DefaultsKeys.qwen3FinalEnabled) as? Bool ?? true
        },
        qwenTranscriber: @escaping SenseVoiceQwenTranscriber = { audio, port, timeout in
            await SenseVoiceWSClient.transcribeWithQwen(
                audio: audio,
                port: port,
                timeout: timeout
            )
        }
    ) {
        self.connectionPlanProvider = connectionPlanProvider
        self.dialFactory = dialFactory
        self.qwenFinalEnabledProvider = qwenFinalEnabledProvider
        self.qwenTranscriber = qwenTranscriber
    }

    var events: AsyncStream<RecognitionEvent> {
        if let existing = _events { return existing }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream
        return stream
    }

    // MARK: - Connect

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {
        _ = config
        _ = options

        invalidateCurrentSession()

        let newSessionID = UUID()
        sessionID = newSessionID
        currentText = ""
        confirmedSegments = []
        qwen3OnlyMode = false
        qwenPort = nil
        didRequestEndAudio = false
        didEmitTerminalEvent = false
        isAwaitingQwenFinal = false
        staleReceiveLoopExitCount = 0
        resetQwen3State(for: newSessionID)

        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream

        let plan: SenseVoiceConnectionPlan
        do {
            plan = try await connectionPlanProvider()
        } catch {
            if sessionID == newSessionID {
                invalidateCurrentSession()
            }
            throw error
        }

        guard sessionID == newSessionID else { throw CancellationError() }
        qwenPort = plan.qwenPort

        if let url = plan.webSocketURL {
            var request = URLRequest(url: url)
            LocalServiceAuth.authorize(&request)
            let resources = dialFactory(request)
            let task = resources.task
            let newConnectionID = UUID()

            connectionID = newConnectionID
            webSocketTask = task
            invalidateURLSession = resources.invalidateSession
            task.resume()
            startReceiveLoop(
                sessionID: newSessionID,
                connectionID: newConnectionID,
                task: task
            )
            emitEvent(.ready, sessionID: newSessionID)
            logger.info("SenseVoiceWS connected to \(url)")
        } else if plan.qwenPort != nil {
            qwen3OnlyMode = true
            emitEvent(.ready, sessionID: newSessionID)
            logger.info("Qwen3-only mode (no SenseVoice streaming)")
            DebugFileLogger.log("Qwen3-only mode: no streaming, final via Qwen3")
        } else {
            invalidateCurrentSession()
            throw SenseVoiceWSError.serverNotRunning
        }
    }

    private static func resolveProductionConnectionPlan() async throws -> SenseVoiceConnectionPlan {
        let manager = SenseVoiceServerManager.shared

        if SenseVoiceServerManager.currentPort != nil {
            var healthy = false
            for _ in 0..<30 {
                if await manager.isHealthy() {
                    healthy = true
                    break
                }
                try await Task.sleep(for: .seconds(1))
            }
            guard healthy else { throw SenseVoiceWSError.serverNotHealthy }
            guard let url = await manager.serverWSURL else {
                throw SenseVoiceWSError.serverNotRunning
            }
            return SenseVoiceConnectionPlan(
                webSocketURL: url,
                qwenPort: SenseVoiceServerManager.currentQwen3Port
            )
        }

        if let qwenPort = SenseVoiceServerManager.currentQwen3Port {
            return SenseVoiceConnectionPlan(webSocketURL: nil, qwenPort: qwenPort)
        }

        let senseVoiceEnabled = UserDefaults.standard.object(
            forKey: DefaultsKeys.sensevoiceEnabled
        ) as? Bool ?? true
        let qwenEnabled = UserDefaults.standard.object(
            forKey: DefaultsKeys.qwen3FinalEnabled
        ) as? Bool ?? true
        guard senseVoiceEnabled || qwenEnabled else {
            throw SenseVoiceWSError.allModelsDisabled
        }

        try await manager.start()
        guard SenseVoiceServerManager.currentPort != nil
                || SenseVoiceServerManager.currentQwen3Port != nil
        else {
            throw SenseVoiceWSError.serverNotRunning
        }
        return try await resolveProductionConnectionPlan()
    }

    // MARK: - Send Audio

    func sendAudio(_ data: Data) async throws {
        guard let sendingSessionID = sessionID, !didEmitTerminalEvent else { return }

        if !qwen3OnlyMode {
            guard let task = webSocketTask,
                  let sendingConnectionID = connectionID else { return }
            try await task.send(.data(data))
            guard ownsConnection(
                task,
                sessionID: sendingSessionID,
                connectionID: sendingConnectionID
            ) else {
                throw CancellationError()
            }
        }

        guard sessionID == sendingSessionID, !didEmitTerminalEvent else { return }

        // Accumulate audio for Qwen3 (speculative or final-only)
        // REPAIR_PLAN J10：超上限丢弃整段、停止累积并放弃本会话校准（含在途投机）
        guard !audioAccumulationOverflowed else { return }
        if allAudioData.count + data.count > accumulatedAudioByteLimit {
            audioAccumulationOverflowed = true
            qwen3DebounceTask?.cancel()
            qwen3DebounceTask = nil
            allAudioData = Data()
            qwen3ConfirmedOffset = 0
            qwen3ConfirmedSegments = []
            qwen3HasPendingAudio = false
            DebugFileLogger.log("Qwen3 audio buffer over limit; calibration disabled for this session")
            return
        }
        allAudioData.append(data)
        qwen3HasPendingAudio = true
        if !qwen3OnlyMode {
            scheduleSpeculativeQwen3(sessionID: sendingSessionID)
        }
    }

    // MARK: - End Audio

    func endAudio() async throws {
        guard let endingSessionID = sessionID, !didEmitTerminalEvent else { return }
        didRequestEndAudio = true
        qwen3DebounceTask?.cancel()
        qwen3DebounceTask = nil

        let qwenEnabled = qwenFinalEnabledProvider() || qwen3OnlyMode
        let finalPort = qwenPort
        let task = webSocketTask
        let endingConnectionID = connectionID

        if qwenEnabled,
           let finalPort,
           !audioAccumulationOverflowed,
           allAudioData.count > 3200 {
            isAwaitingQwenFinal = true

            let audioSnapshot = allAudioData
            let confirmedOffset = min(qwen3ConfirmedOffset, audioSnapshot.count)
            let speculativeSegments = qwen3ConfirmedSegments
            let newAudioBytes = audioSnapshot.count - confirmedOffset
            let hasQwen3Result = !speculativeSegments.isEmpty
            let newAudioTrivial = newAudioBytes < 2 * 16000 * 2

            let finalText: String
            if hasQwen3Result && newAudioTrivial {
                var assembled = speculativeSegments.joined()
                if newAudioBytes > 3200 {
                    let tailAudio = Data(audioSnapshot.suffix(from: confirmedOffset))
                    if let tailText = await qwen3Transcribe(
                        audio: tailAudio,
                        port: finalPort,
                        timeout: 10,
                        sessionID: endingSessionID
                    ) {
                        assembled += tailText
                    }
                }
                guard sessionID == endingSessionID else { return }
                finalText = assembled
                DebugFileLogger.log(
                    "Qwen3 final: incremental (\(speculativeSegments.count) segments + tail)"
                )
            } else {
                DebugFileLogger.log("Qwen3 full final: sending \(audioSnapshot.count) bytes")
                finalText = await qwen3Transcribe(
                    audio: audioSnapshot,
                    port: finalPort,
                    timeout: 30,
                    sessionID: endingSessionID
                ) ?? ""
                guard sessionID == endingSessionID else { return }
                DebugFileLogger.log("Qwen3 full final: \(finalText.count) chars")
            }

            isAwaitingQwenFinal = false
            if let task, let endingConnectionID {
                detachConnection(
                    sessionID: endingSessionID,
                    connectionID: endingConnectionID,
                    task: task,
                    closeCode: .normalClosure
                )
            }

            if !finalText.isEmpty {
                confirmedSegments = [finalText]
                currentText = ""
                let transcript = RecognitionTranscript(
                    confirmedSegments: confirmedSegments,
                    partialText: "",
                    authoritativeText: finalText,
                    isFinal: true
                )
                emitEvent(.transcript(transcript), sessionID: endingSessionID)
                emitCompletedOnce(sessionID: endingSessionID)
            } else {
                let fallback = (
                    confirmedSegments + (currentText.isEmpty ? [] : [currentText])
                ).joined()
                DebugFileLogger.log(
                    "Qwen3 final failed, using SenseVoice fallback: \(fallback.count) chars"
                )
                let transcript = RecognitionTranscript(
                    confirmedSegments: confirmedSegments,
                    partialText: "",
                    authoritativeText: fallback,
                    isFinal: true
                )
                emitEvent(.transcript(transcript), sessionID: endingSessionID)
                emitCompletedOnce(sessionID: endingSessionID)
            }
        } else if let task, let endingConnectionID {
            try await task.send(.data(Data()))
            guard ownsConnection(
                task,
                sessionID: endingSessionID,
                connectionID: endingConnectionID
            ) else { return }
            DebugFileLogger.log("SenseVoice final (Qwen3 disabled or unavailable)")
        } else {
            DebugFileLogger.log("endAudio: no WebSocket and no usable Qwen3 audio")
            emitCompletedOnce(sessionID: endingSessionID)
        }

        resetQwen3State(for: endingSessionID)
    }

    private static func transcribeWithQwen(
        audio: Data,
        port: Int,
        timeout: TimeInterval
    ) async -> String? {
        let url = URL(string: "http://127.0.0.1:\(port)/transcribe")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = audio
        request.timeoutInterval = timeout
        LocalServiceAuth.authorize(&request)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String,
              !text.isEmpty
        else { return nil }
        return text
    }

    private func qwen3Transcribe(
        audio: Data,
        port: Int,
        timeout: TimeInterval,
        sessionID expectedSessionID: UUID
    ) async -> String? {
        guard sessionID == expectedSessionID,
              !didEmitTerminalEvent,
              !audioAccumulationOverflowed else { return nil }
        let result = await qwenTranscriber(audio, port, timeout)
        guard sessionID == expectedSessionID,
              !didEmitTerminalEvent,
              !audioAccumulationOverflowed else { return nil }
        return result
    }

    // MARK: - Qwen3 Speculative

    private func scheduleSpeculativeQwen3(sessionID speculativeSessionID: UUID) {
        qwen3DebounceTask?.cancel()
        qwen3DebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            guard await self.canRunSpeculativeQwen(sessionID: speculativeSessionID),
                  let port = await self.qwenPort(for: speculativeSessionID),
                  let snapshot = await self.snapshotQwen3Delta(sessionID: speculativeSessionID)
            else { return }

            let deltaAudio = snapshot.delta
            guard deltaAudio.count > 3200 else { return }
            DebugFileLogger.log(
                "Qwen3 speculative: sending \(deltaAudio.count) bytes (offset \(snapshot.start))"
            )

            if let text = await self.qwen3Transcribe(
                audio: deltaAudio,
                port: port,
                timeout: 30,
                sessionID: speculativeSessionID
            ), !Task.isCancelled {
                await self.confirmQwen3Segment(
                    text,
                    offset: snapshot.endOffset,
                    sessionID: speculativeSessionID
                )
            }
        }
    }

    private func canRunSpeculativeQwen(sessionID expectedSessionID: UUID) -> Bool {
        sessionID == expectedSessionID
            && !didEmitTerminalEvent
            && !audioAccumulationOverflowed
            && qwen3HasPendingAudio
    }

    private func qwenPort(for expectedSessionID: UUID) -> Int? {
        guard sessionID == expectedSessionID else { return nil }
        return qwenPort
    }

    /// Atomically snapshot the unconfirmed audio delta and the offset it ends at.
    private func snapshotQwen3Delta(
        sessionID expectedSessionID: UUID
    ) -> (delta: Data, start: Int, endOffset: Int)? {
        guard sessionID == expectedSessionID,
              !audioAccumulationOverflowed else { return nil }
        let start = min(qwen3ConfirmedOffset, allAudioData.count)
        let delta = Data(allAudioData.suffix(from: start))
        return (delta, start, start + delta.count)
    }

    private func confirmQwen3Segment(
        _ text: String,
        offset: Int,
        sessionID expectedSessionID: UUID
    ) {
        guard sessionID == expectedSessionID,
              !didEmitTerminalEvent,
              !audioAccumulationOverflowed,
              offset <= allAudioData.count else { return }
        qwen3ConfirmedSegments.append(text)
        qwen3ConfirmedOffset = offset
        qwen3HasPendingAudio = false
        DebugFileLogger.log(
            "Qwen3 speculative: confirmed segment \(qwen3ConfirmedSegments.count): \(text.count) chars"
        )
    }

    private func resetQwen3State(for expectedSessionID: UUID) {
        guard sessionID == expectedSessionID else { return }
        resetQwen3StateUnchecked()
    }

    private func resetQwen3StateUnchecked() {
        allAudioData = Data()
        qwen3ConfirmedOffset = 0
        qwen3ConfirmedSegments = []
        qwen3HasPendingAudio = false
        audioAccumulationOverflowed = false
        isAwaitingQwenFinal = false
    }

    // MARK: - Text Cleaning

    /// Keep only: Chinese (CJK Unified), English letters, digits, spaces
    private static let nonZhEnPattern = try! NSRegularExpression(
        pattern: #"[^\u4e00-\u9fff\u3400-\u4dbfa-zA-Z0-9 ]"#
    )

    /// Remove non-Chinese/English characters from streaming partials (e.g. Japanese kana, Korean).
    private static func filterNonZhEn(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return nonZhEnPattern.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: ""
        )
    }

    // MARK: - Disconnect

    func disconnect() async {
        invalidateCurrentSession()
        logger.info("SenseVoiceWS disconnected")
    }

    private func invalidateCurrentSession() {
        let oldReceiveTask = receiveTask
        let oldWebSocketTask = webSocketTask
        let oldInvalidateURLSession = invalidateURLSession
        let oldEventContinuation = eventContinuation

        // 先让会话和连接身份失效，再取消局部旧资源。
        sessionID = nil
        connectionID = nil
        receiveTask = nil
        receiveTaskConnectionID = nil
        webSocketTask = nil
        invalidateURLSession = nil
        eventContinuation = nil
        _events = nil
        qwenPort = nil
        qwen3OnlyMode = false
        didRequestEndAudio = false
        didEmitTerminalEvent = false

        qwen3DebounceTask?.cancel()
        qwen3DebounceTask = nil
        oldReceiveTask?.cancel()
        oldWebSocketTask?.cancel(with: .normalClosure, reason: nil)
        oldInvalidateURLSession?()
        oldEventContinuation?.finish()
        resetQwen3StateUnchecked()
    }

    private func detachConnection(
        sessionID expectedSessionID: UUID,
        connectionID expectedConnectionID: UUID,
        task expectedTask: any SenseVoiceWebSocketTasking,
        closeCode: URLSessionWebSocketTask.CloseCode
    ) {
        guard ownsConnection(
            expectedTask,
            sessionID: expectedSessionID,
            connectionID: expectedConnectionID
        ) else { return }

        let oldReceiveTask = receiveTaskConnectionID == expectedConnectionID
            ? receiveTask
            : nil
        let oldInvalidateURLSession = invalidateURLSession

        connectionID = nil
        receiveTask = nil
        receiveTaskConnectionID = nil
        webSocketTask = nil
        invalidateURLSession = nil

        oldReceiveTask?.cancel()
        expectedTask.cancel(with: closeCode, reason: nil)
        oldInvalidateURLSession?()
    }

    private func ownsConnection(
        _ task: any SenseVoiceWebSocketTasking,
        sessionID expectedSessionID: UUID,
        connectionID expectedConnectionID: UUID
    ) -> Bool {
        guard sessionID == expectedSessionID,
              connectionID == expectedConnectionID,
              let currentTask = webSocketTask else { return false }
        return ObjectIdentifier(currentTask) == ObjectIdentifier(task)
    }

    // MARK: - Receive Loop

    private func startReceiveLoop(
        sessionID receiveSessionID: UUID,
        connectionID receiveConnectionID: UUID,
        task: any SenseVoiceWebSocketTasking
    ) {
        let loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    await self.handleMessage(
                        message,
                        sessionID: receiveSessionID,
                        connectionID: receiveConnectionID
                    )
                } catch {
                    await self.handleReceiveError(
                        error,
                        sessionID: receiveSessionID,
                        connectionID: receiveConnectionID,
                        wasCancelled: Task.isCancelled
                    )
                    break
                }
            }
            await self.receiveLoopDidEnd(
                sessionID: receiveSessionID,
                connectionID: receiveConnectionID
            )
        }
        receiveTask = loopTask
        receiveTaskConnectionID = receiveConnectionID
    }

    private func handleReceiveError(
        _ error: Error,
        sessionID receiveSessionID: UUID,
        connectionID receiveConnectionID: UUID,
        wasCancelled: Bool
    ) {
        guard sessionID == receiveSessionID,
              connectionID == receiveConnectionID else { return }
        logger.info("SenseVoiceWS receive loop ended: \(error)")
        guard !wasCancelled, !didEmitTerminalEvent else { return }

        if didRequestEndAudio {
            if !isAwaitingQwenFinal {
                emitCompletedOnce(sessionID: receiveSessionID)
            }
        } else {
            emitEvent(.streamingInterrupted, sessionID: receiveSessionID)
        }
    }

    private func receiveLoopDidEnd(
        sessionID receiveSessionID: UUID,
        connectionID receiveConnectionID: UUID
    ) {
        guard sessionID == receiveSessionID,
              connectionID == receiveConnectionID else {
            staleReceiveLoopExitCount += 1
            DebugFileLogger.log(
                "SenseVoiceWS ignored stale receive loop exit connection=\(receiveConnectionID)"
            )
            return
        }
        if receiveTaskConnectionID == receiveConnectionID {
            receiveTask = nil
            receiveTaskConnectionID = nil
        }
    }

    private func handleMessage(
        _ message: URLSessionWebSocketTask.Message,
        sessionID messageSessionID: UUID,
        connectionID messageConnectionID: UUID
    ) {
        guard sessionID == messageSessionID,
              connectionID == messageConnectionID,
              !didEmitTerminalEvent else { return }

        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String
            else { return }

            switch type {
            case "transcript":
                var recognizedText = json["text"] as? String ?? ""
                let isFinal = json["is_final"] as? Bool ?? false

                if !isFinal {
                    recognizedText = Self.filterNonZhEn(recognizedText)
                }

                if isFinal {
                    if !recognizedText.isEmpty {
                        confirmedSegments.append(recognizedText)
                    }
                    currentText = ""
                } else {
                    currentText = recognizedText
                }

                let composedText = (
                    confirmedSegments + (currentText.isEmpty ? [] : [currentText])
                ).joined()
                let transcript = RecognitionTranscript(
                    confirmedSegments: confirmedSegments,
                    partialText: isFinal ? "" : currentText,
                    authoritativeText: isFinal ? composedText : "",
                    isFinal: isFinal
                )
                emitEvent(.transcript(transcript), sessionID: messageSessionID)

                DebugFileLogger.log(
                    "SenseVoiceWS: confirmed=\(confirmedSegments.count) partial=\(currentText.count) composed=\(composedText.count) isFinal=\(isFinal)"
                )

            case "completed":
                if didRequestEndAudio {
                    if !isAwaitingQwenFinal {
                        emitCompletedOnce(sessionID: messageSessionID)
                        logger.info("SenseVoiceWS: server signaled completion")
                    }
                } else {
                    emitEvent(.streamingInterrupted, sessionID: messageSessionID)
                    logger.info("SenseVoiceWS: server completed before endAudio")
                }

            case "error":
                let message = json["message"] as? String ?? "Unknown server error"
                logger.error("SenseVoiceWS server error: \(message)")
                emitTerminalError(
                    NSError(
                        domain: "SenseVoice",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    ),
                    sessionID: messageSessionID
                )

            default:
                break
            }

        case .data:
            break

        @unknown default:
            break
        }
    }

    private func emitEvent(
        _ event: RecognitionEvent,
        sessionID expectedSessionID: UUID
    ) {
        guard sessionID == expectedSessionID, !didEmitTerminalEvent else { return }
        eventContinuation?.yield(event)
    }

    private func emitCompletedOnce(sessionID expectedSessionID: UUID) {
        guard sessionID == expectedSessionID, !didEmitTerminalEvent else { return }
        didEmitTerminalEvent = true
        eventContinuation?.yield(.completed)
        eventContinuation?.finish()
        eventContinuation = nil
    }

    private func emitTerminalError(
        _ error: Error,
        sessionID expectedSessionID: UUID
    ) {
        guard sessionID == expectedSessionID, !didEmitTerminalEvent else { return }
        didEmitTerminalEvent = true
        eventContinuation?.yield(.error(error))
        eventContinuation?.finish()
        eventContinuation = nil
    }
}

#if DEBUG
extension SenseVoiceWSClient {
    var staleReceiveLoopExitCountForTesting: Int {
        staleReceiveLoopExitCount
    }

    var accumulatedAudioCountForTesting: Int {
        allAudioData.count
    }

    func setAccumulatedAudioByteLimitForTesting(_ limit: Int) {
        accumulatedAudioByteLimit = limit
    }
}
#endif

// MARK: - Errors

enum SenseVoiceWSError: Error, LocalizedError {
    case serverNotRunning
    case serverNotHealthy
    case allModelsDisabled

    var errorDescription: String? {
        switch self {
        case .serverNotRunning:
            return L("识别服务未启动", "ASR server not running")
        case .serverNotHealthy:
            return L("识别服务未就绪", "ASR server not ready")
        case .allModelsDisabled:
            return L("请先在设置中启动识别模型", "Please start an ASR model in Settings")
        }
    }
}
