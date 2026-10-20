import Foundation

enum VolcASRError: Error, LocalizedError {
    case unsupportedProvider
    case serverRejected(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider: return "VolcASRClient requires VolcanoASRConfig"
        case .serverRejected(let code, let message):
            return message ?? "HTTP \(code)"
        }
    }
}

protocol VolcWebSocketTasking: AnyObject, Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: VolcWebSocketTasking {}

struct VolcDialResources: Sendable {
    let task: any VolcWebSocketTasking
    let invalidateSession: @Sendable () -> Void
}

typealias VolcDialFactory = @Sendable (
    _ request: URLRequest,
    _ configuration: URLSessionConfiguration
) -> VolcDialResources

/// 火山全文重识别必须模拟实时流按 200ms 发包；整段 PCM 单包发送会触发服务端限流、
/// 等包超时或直接断流，表现为二次识别连接成功却始终没有 final。
enum VolcanoAudioReplay {
    static let chunkByteSize = AudioCaptureEngine.chunkByteSize
    static let chunkInterval: Duration = .milliseconds(AudioCaptureEngine.chunkDurationMs)

    static func send(
        audio: Data,
        to client: any SpeechRecognizer,
        sleep: @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) async throws {
        guard !audio.isEmpty else { return }

        var offset = 0
        while offset < audio.count {
            let end = min(offset + chunkByteSize, audio.count)
            try await client.sendAudio(audio.subdata(in: offset ..< end))
            offset = end
            if offset < audio.count {
                try await sleep(chunkInterval)
            }
        }
    }
}

actor VolcASRClient: WebSocketASRClient {

    private static let endpoint =
        URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!

    // MARK: - State

    private let dialFactory: VolcDialFactory
    private var webSocketTask: (any VolcWebSocketTasking)?
    private var invalidateSession: (@Sendable () -> Void)?
    private var connectionID: UUID?
    private var receiveTask: Task<Void, Never>?
    private var receiveTaskConnectionID: UUID?
    private var didRequestEndAudio = false
    private var didEmitTerminalEvent = false
    private var staleReceiveLoopExitCount = 0

    var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    var _events: AsyncStream<RecognitionEvent>?

    init(dialFactory: @escaping VolcDialFactory = { request, configuration in
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: request)
        return VolcDialResources(
            task: task,
            invalidateSession: { session.invalidateAndCancel() }
        )
    }) {
        self.dialFactory = dialFactory
    }

    private func ownsWebSocketTask(
        _ task: any VolcWebSocketTasking,
        connectionID expectedConnectionID: UUID
    ) -> Bool {
        guard connectionID == expectedConnectionID,
              let currentTask = webSocketTask else { return false }
        return ObjectIdentifier(currentTask) == ObjectIdentifier(task)
    }

    // MARK: - Connect

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions = ASRRequestOptions()) async throws {
        guard let volcConfig = config as? VolcanoASRConfig else {
            throw VolcASRError.unsupportedProvider
        }
        if connectionID != nil || receiveTask != nil || webSocketTask != nil {
            disconnect()
        }

        // Ensure fresh event stream
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.eventContinuation = continuation
        self._events = stream

        // REPAIR_PLAN B7b：保存连接参数供断网静默重连重拨
        savedConfig = volcConfig
        savedOptions = options
        carriedSegments = []
        didAttemptReconnect = false
        didRequestEndAudio = false
        didEmitTerminalEvent = false
        staleReceiveLoopExitCount = 0

        lastTranscript = .empty
        audioPacketCount = 0
        totalAudioBytes = 0
        sessionStartTime = ContinuousClock.now
        lastTranscriptTime = nil

        try await dial(config: volcConfig, options: options)
    }

    /// 拨号 + 握手 + 启动接收循环（connect 与重连共用；不触碰事件流与计数状态）
    private func dial(config volcConfig: VolcanoASRConfig, options: ASRRequestOptions) async throws {
        let connectId = UUID().uuidString
        let newConnectionID = UUID()

        var request = URLRequest(url: Self.endpoint)
        request.setValue(volcConfig.appKey, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(volcConfig.accessKey, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(volcConfig.resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(connectId, forHTTPHeaderField: "X-Api-Connect-Id")

        let resources = dialFactory(request, options.urlSessionConfiguration)
        let task = resources.task
        task.resume()
        connectionID = newConnectionID
        self.webSocketTask = task
        invalidateSession = resources.invalidateSession

        // Send full_client_request (no compression, plain JSON)
        let payload = VolcProtocol.buildClientRequest(uid: volcConfig.uid, options: options)

        let header = VolcHeader(
            messageType: .fullClientRequest,
            flags: .noSequence,
            serialization: .json,
            compression: .none
        )
        let message = VolcProtocol.encodeMessage(header: header, payload: payload)

        AppLogger.log("[ASR] Sending full_client_request (\(message.count) bytes), connectId=\(connectId)")
        do {
            try await task.send(.data(message))
        } catch {
            let failedCurrentConnection = ownsWebSocketTask(
                task,
                connectionID: newConnectionID
            )
            task.cancel(with: .abnormalClosure, reason: nil)
            resources.invalidateSession()
            if failedCurrentConnection {
                connectionID = nil
                webSocketTask = nil
                invalidateSession = nil
            }
            guard failedCurrentConnection else { throw CancellationError() }
            // WebSocket handshake failed — probe with HTTP to get the real error
            AppLogger.log("[ASR] WebSocket send failed: \(String(describing: error)), probing for server error...")
            if let serverError = await Self.probeServerError(request: request) {
                throw serverError
            }
            throw error
        }

        AppLogger.log("[ASR] full_client_request sent OK")
        guard connectionID == newConnectionID,
              ownsWebSocketTask(task, connectionID: newConnectionID) else {
            task.cancel(with: .goingAway, reason: nil)
            resources.invalidateSession()
            throw CancellationError()
        }

        // Start receive loop
        startReceiveLoop(connectionID: newConnectionID, task: task)
    }

    /// When WebSocket handshake is rejected, make a plain HTTPS request to get the actual error body.
    private static func probeServerError(request: URLRequest) async -> VolcASRError? {
        guard let url = request.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = "https"
        guard let httpsURL = components.url else { return nil }

        var httpRequest = URLRequest(url: httpsURL, timeoutInterval: 5)
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            httpRequest.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: httpRequest)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode != 200 else { return nil }

            // Try to parse JSON error body (e.g. {"code": 1001, "message": "..."})
            var message: String?
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                message = json["message"] as? String ?? json["msg"] as? String
                if let code = json["code"] as? Int, let msg = message {
                    message = "\(msg) (\(code))"
                }
            } else if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                message = String(text.prefix(200))
            }

            // 探测回音过滤（2026-07 修）：本探测是普通 HTTP 打到 ws 端点，服务器回
            // "cannot upgrade to websocket / 'upgrade' token not found" 只说明端点活着，
            // 不是对我们业务的拒绝理由——这类裸文只进日志，不糊给用户
            if let text = message?.lowercased(),
               text.contains("websocket") || text.contains("upgrade") {
                AppLogger.log("[ASR] HTTP probe echo (ws endpoint alive), body suppressed: \(message ?? "")")
                message = nil
            }

            AppLogger.log("[ASR] HTTP probe got \(httpResponse.statusCode) bodyBytes=\(data.count)")
            return .serverRejected(statusCode: httpResponse.statusCode, message: message)
        } catch {
            AppLogger.log("[ASR] HTTP probe failed: \(String(describing: error))")
            return nil
        }
    }

    // MARK: - Send Audio

    private var audioPacketCount = 0
    private var totalAudioBytes = 0
    private var lastTranscript: RecognitionTranscript = .empty
    private var lastTranscriptTime: ContinuousClock.Instant?
    private var sessionStartTime: ContinuousClock.Instant?

    // REPAIR_PLAN B7b：断网静默重连（每会话一次）
    private var savedConfig: VolcanoASRConfig?
    private var savedOptions: ASRRequestOptions?
    /// 重连前冻结的已确认文本，重连后前缀拼接保持字幕连续
    private var carriedSegments: [String] = []
    private var didAttemptReconnect = false

    func sendAudio(_ data: Data) async throws {
        guard let task = webSocketTask,
              let sendingConnectionID = connectionID else { return }
        let packet = VolcProtocol.encodeAudioPacket(
            audioData: data,
            isLast: false
        )
        do {
            try await task.send(.data(packet))
            guard ownsWebSocketTask(task, connectionID: sendingConnectionID) else {
                throw CancellationError()
            }
        } catch {
            // REPAIR_PLAN B7b：发送失败先尝试一次静默重连再重发本包；
            // 重连失败则抛出原错误，走既有失败路径（批量兜底）
            guard ownsWebSocketTask(task, connectionID: sendingConnectionID),
                  !didAttemptReconnect else { throw error }
            didAttemptReconnect = true
            try await reconnectOnce(
                afterError: error,
                expectedConnectionID: sendingConnectionID
            )
            guard let newTask = webSocketTask,
                  let newConnectionID = connectionID,
                  ownsWebSocketTask(newTask, connectionID: newConnectionID) else { throw error }
            try await newTask.send(.data(packet))
            guard ownsWebSocketTask(newTask, connectionID: newConnectionID) else {
                throw CancellationError()
            }
            // 告知会话层本次流式已降级：停止后仍需批量复核全文
            // （断线到重连之间的语音服务端没听到，实时字幕只是显示连续）
            emitEvent(.streamingInterrupted)
        }
        audioPacketCount += 1
        totalAudioBytes += data.count
    }

    /// 重拨一次：冻结已确认文本 → 撤旧连接 → 重新握手。失败抛出原错误
    private func reconnectOnce(
        afterError underlying: Error,
        expectedConnectionID: UUID
    ) async throws {
        guard connectionID == expectedConnectionID else { throw underlying }
        AppLogger.log("[ASR] 连接中断，尝试静默重连…")
        carriedSegments = lastTranscript.confirmedSegments
            + (lastTranscript.partialText.isEmpty ? [] : [lastTranscript.partialText])

        let oldReceiveTask = receiveTaskConnectionID == expectedConnectionID
            ? receiveTask
            : nil
        let oldWebSocketTask = webSocketTask
        let oldInvalidateSession = invalidateSession

        // 先使旧连接身份失效，再取消资源；旧 receive loop 晚到退出时无权触碰新连接。
        connectionID = nil
        receiveTask = nil
        receiveTaskConnectionID = nil
        webSocketTask = nil
        invalidateSession = nil

        oldReceiveTask?.cancel()
        oldWebSocketTask?.cancel(with: .abnormalClosure, reason: nil)
        oldInvalidateSession?()
        guard let config = savedConfig, let options = savedOptions else { throw underlying }
        do {
            try await dial(config: config, options: options)
            AppLogger.log("[ASR] 静默重连成功，已冻结 \(carriedSegments.count) 段前缀")
        } catch {
            AppLogger.log("[ASR] 静默重连失败: \(String(describing: error))")
            throw underlying
        }
    }

    // MARK: - End Audio

    func endAudio() async throws {
        didRequestEndAudio = true
        guard let task = webSocketTask else { return }
        let packet = VolcProtocol.encodeAudioPacket(
            audioData: Data(),
            isLast: true
        )
        try await task.send(.data(packet))
        AppLogger.log("[ASR] Sent last audio packet (empty, isLast=true)")
    }

    // MARK: - Disconnect

    func disconnect() {
        let oldReceiveTask = receiveTask
        let oldWebSocketTask = webSocketTask
        let oldInvalidateSession = invalidateSession

        // 身份先失效，随后才取消旧任务；任何迟到回调都会被 connectionID 守卫拒绝。
        connectionID = nil
        receiveTask = nil
        receiveTaskConnectionID = nil
        webSocketTask = nil
        invalidateSession = nil

        oldReceiveTask?.cancel()
        oldWebSocketTask?.cancel(with: .normalClosure, reason: nil)
        oldInvalidateSession?()
        eventContinuation?.finish()
        eventContinuation = nil
        AppLogger.log("[ASR] Disconnected")
    }

    // MARK: - Receive Loop

    private func startReceiveLoop(
        connectionID: UUID,
        task: any VolcWebSocketTasking
    ) {
        let loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    await self.handleMessage(message, connectionID: connectionID)
                } catch {
                    await self.handleReceiveError(
                        error,
                        connectionID: connectionID,
                        wasCancelled: Task.isCancelled
                    )
                    break
                }
            }
            await self.receiveLoopDidEnd(connectionID: connectionID)
        }
        receiveTask = loopTask
        receiveTaskConnectionID = connectionID
    }

    private func handleReceiveError(
        _ error: Error,
        connectionID: UUID,
        wasCancelled: Bool
    ) {
        guard self.connectionID == connectionID else { return }
        AppLogger.log("[ASR] Receive loop error: \(String(describing: error))")
        guard !wasCancelled, !didEmitTerminalEvent else { return }

        if didRequestEndAudio {
            emitCompletedOnce()
        } else if audioPacketCount == 0 {
            // No audio sent yet — real connection/auth error.
            emitTerminalError(error)
        } else {
            AppLogger.log("[ASR] Receive loop interrupted while recording (sent \(audioPacketCount) packets)")
            emitEvent(.streamingInterrupted)
        }
    }

    private func receiveLoopDidEnd(connectionID: UUID) {
        guard self.connectionID == connectionID else {
            staleReceiveLoopExitCount += 1
            AppLogger.log("[ASR] Ignored stale receive loop exit connection=\(connectionID)")
            return
        }
        if receiveTaskConnectionID == connectionID {
            receiveTask = nil
            receiveTaskConnectionID = nil
        }
        AppLogger.log("[ASR] Receive loop ended connection=\(connectionID)")
    }

    private func handleMessage(
        _ message: URLSessionWebSocketTask.Message,
        connectionID: UUID
    ) {
        guard self.connectionID == connectionID, !didEmitTerminalEvent else {
            AppLogger.log("[ASR] Ignored inactive message connection=\(connectionID)")
            return
        }
        switch message {
        case .data(let data):
            let headerByte1 = data.count > 1 ? data[1] : 0
            let msgType = (headerByte1 >> 4) & 0x0F

            // 官方协议中 0xF 始终是错误帧；成功结束由 0x9 final 或正常关闭表示。
            // 旧逻辑在 endAudio 后把所有 0xF 都伪装成 completed，导致全文重识别
            // 失败时既没有文本，也看不到真实错误码。
            if msgType == 0x0F {
                let serverError: Error
                do {
                    _ = try VolcProtocol.decodeServerResponse(data)
                    serverError = VolcProtocolError.invalidPayload
                } catch {
                    serverError = error
                }
                AppLogger.log("[ASR] Server error: \(String(describing: serverError))")
                emitTerminalError(serverError)
                closeWebSocketIfCurrent(
                    connectionID: connectionID,
                    closeCode: .protocolError
                )
                return
            }

            do {
                let response = try VolcProtocol.decodeServerResponse(data)
                let transcript = makeTranscript(
                    from: response.result,
                    isFinal: response.header.flags == .asyncFinal
                )
                guard transcript != lastTranscript else { return }
                lastTranscript = transcript

                let now = ContinuousClock.now
                let sinceStart = sessionStartTime.map { now - $0 } ?? .zero
                let sinceLastUpdate = lastTranscriptTime.map { now - $0 } ?? .zero
                lastTranscriptTime = now

                let gapMs = Int(sinceLastUpdate.components.seconds * 1000 + sinceLastUpdate.components.attoseconds / 1_000_000_000_000_000)
                // REPAIR_PLAN K2：auth/composed 是注入取值的关键维度（asyncFinal 的
                // result.text 偶发短于流式累积），必须留痕才能事后归因丢字
                DebugFileLogger.log("ASR transcript +\(sinceStart) gap=\(gapMs)ms confirmed=\(transcript.confirmedSegments.count) partial=\(transcript.partialText.count) auth=\(transcript.authoritativeText.count) composed=\(transcript.composedText.count) final=\(transcript.isFinal)")

                AppLogger.log("[ASR] Transcript update +\(String(describing: sinceStart)) gap=\(gapMs)ms confirmed=\(transcript.confirmedSegments.count) partial=\(transcript.partialText.count) final=\(transcript.isFinal ? "yes" : "no")")
                emitEvent(.transcript(transcript))

                if transcript.isFinal, !transcript.authoritativeText.isEmpty {
                    AppLogger.log("[ASR] Final transcript len=\(transcript.authoritativeText.count)")
                }
            } catch {
                AppLogger.log("[ASR] Decode error: \(String(describing: error))")
                emitTerminalError(error)
                closeWebSocketIfCurrent(
                    connectionID: connectionID,
                    closeCode: .protocolError
                )
            }

        case .string(let text):
            AppLogger.log("[ASR] Unexpected text message bytes=\(text.utf8.count)")

        @unknown default:
            break
        }
    }

    private func closeWebSocketIfCurrent(
        connectionID: UUID,
        closeCode: URLSessionWebSocketTask.CloseCode
    ) {
        guard self.connectionID == connectionID else { return }
        let task = webSocketTask
        let invalidate = invalidateSession
        webSocketTask = nil
        invalidateSession = nil
        task?.cancel(with: closeCode, reason: nil)
        invalidate?()
    }


    private func makeTranscript(from result: VolcASRResult, isFinal: Bool) -> RecognitionTranscript {
        Self.transcript(from: result, isFinal: isFinal, carriedSegments: carriedSegments)
    }

    private func emitCompletedOnce() {
        guard !didEmitTerminalEvent else { return }
        didEmitTerminalEvent = true
        eventContinuation?.yield(.completed)
        eventContinuation?.finish()
        eventContinuation = nil
    }

    private func emitTerminalError(_ error: Error) {
        guard !didEmitTerminalEvent else { return }
        didEmitTerminalEvent = true
        eventContinuation?.yield(.error(error))
        eventContinuation?.finish()
        eventContinuation = nil
    }

    /// 纯函数：服务端结果 + 重连前冻结前缀 → 统一转写（REPAIR_PLAN B7b，可单测）
    static func transcript(
        from result: VolcASRResult,
        isFinal: Bool,
        carriedSegments: [String]
    ) -> RecognitionTranscript {
        let confirmedSegments = carriedSegments + result.utterances
            .filter(\.definite)
            .map(\.text)
            .filter { !$0.isEmpty }
        let partialText = result.utterances.last(where: { !$0.definite && !$0.text.isEmpty })?.text ?? ""
        let composedText = (confirmedSegments + (partialText.isEmpty ? [] : [partialText])).joined()
        let authoritativeText = result.text.isEmpty
            ? composedText
            : carriedSegments.joined() + result.text
        return RecognitionTranscript(
            confirmedSegments: confirmedSegments,
            partialText: partialText,
            authoritativeText: authoritativeText,
            isFinal: isFinal
        )
    }
}

#if DEBUG
extension VolcASRClient {
    var staleReceiveLoopExitCountForTesting: Int {
        staleReceiveLoopExitCount
    }

    func emitCompletedForTesting() {
        emitCompletedOnce()
    }

    func emitTerminalErrorForTesting(_ error: Error) {
        emitTerminalError(error)
    }
}
#endif
