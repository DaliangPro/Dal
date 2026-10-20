import Foundation

enum AliyunASRError: Error, LocalizedError, Equatable {
    case unsupportedProvider
    case notConnected
    case taskFailed(code: String?, message: String?)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "AliyunASRClient requires AliyunASRConfig"
        case .notConnected:
            return L("阿里云识别服务尚未连接", "Alibaba Cloud ASR is not connected")
        case .taskFailed(let code, let message):
            let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = detail?.isEmpty == false
                ? detail!
                : L("阿里云识别任务失败", "Alibaba Cloud ASR task failed")
            return code.map { "\(base) (\($0))" } ?? base
        }
    }
}

protocol AliyunWebSocketTasking: AnyObject, Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: AliyunWebSocketTasking {}

struct AliyunDialResources: Sendable {
    let task: any AliyunWebSocketTasking
    let invalidateSession: @Sendable () -> Void
}

typealias AliyunDialFactory = @Sendable (
    _ request: URLRequest,
    _ configuration: URLSessionConfiguration
) -> AliyunDialResources

/// 阿里云实时识别要求 PCM 按实时节奏上传。16kHz / 16bit / mono 的 100ms
/// 音频恰为 3200 字节；整段兜底重放必须复用同一约束，不能一次发送超大帧。
enum AliyunAudioReplay {
    static let chunkByteSize = 3_200
    static let chunkInterval: Duration = .milliseconds(100)

    static func send(
        audio: Data,
        to client: any SpeechRecognizer,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) async throws {
        var offset = 0
        while offset < audio.count {
            let end = min(offset + chunkByteSize, audio.count)
            try await client.sendAudio(audio.subdata(in: offset..<end))
            offset = end
            if offset < audio.count {
                try await sleep(chunkInterval)
            }
        }
    }
}

actor AliyunASRClient: WebSocketASRClient {
    private let dialFactory: AliyunDialFactory
    private var webSocketTask: (any AliyunWebSocketTasking)?
    private var invalidateSession: (@Sendable () -> Void)?
    private var connectionID: UUID?
    private var taskID: String?
    private var receiveTask: Task<Void, Never>?
    private var receiveTaskConnectionID: UUID?
    private var reconnectTask: Task<Bool, Never>?
    private var reconnectAttemptID: UUID?
    private var savedConfig: AliyunASRConfig?
    private var savedOptions: ASRRequestOptions?
    private var didAttemptReconnect = false
    private var didRequestEndAudio = false
    private var didEmitTerminalEvent = false
    private var audioPacketCount = 0
    private var totalAudioBytes = 0
    private var resultEventCount = 0
    private var heartbeatEventCount = 0
    private var accumulator = AliyunTranscriptAccumulator()
    private var lastTranscript: RecognitionTranscript = .empty

    var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    var _events: AsyncStream<RecognitionEvent>?

    init(dialFactory: @escaping AliyunDialFactory = { request, configuration in
        let session = URLSession(configuration: configuration)
        return AliyunDialResources(
            task: session.webSocketTask(with: request),
            invalidateSession: { session.invalidateAndCancel() }
        )
    }) {
        self.dialFactory = dialFactory
    }

    func connect(
        config: any ASRProviderConfig,
        options: ASRRequestOptions = ASRRequestOptions()
    ) async throws {
        guard let aliyunConfig = config as? AliyunASRConfig else {
            throw AliyunASRError.unsupportedProvider
        }
        if connectionID != nil || webSocketTask != nil || receiveTask != nil
            || reconnectTask != nil {
            disconnect()
        }

        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream
        savedConfig = aliyunConfig
        savedOptions = options
        didAttemptReconnect = false
        didRequestEndAudio = false
        didEmitTerminalEvent = false
        audioPacketCount = 0
        totalAudioBytes = 0
        resultEventCount = 0
        heartbeatEventCount = 0
        accumulator = AliyunTranscriptAccumulator()
        lastTranscript = .empty

        do {
            try await dial(config: aliyunConfig, options: options)
        } catch {
            eventContinuation?.finish()
            eventContinuation = nil
            savedConfig = nil
            savedOptions = nil
            throw error
        }
    }

    /// 建立一个阿里云任务。首次连接与会话内唯一一次重连共用此路径；
    /// 事件流、已识别前缀和会话统计均由外层保留。
    private func dial(
        config aliyunConfig: AliyunASRConfig,
        options: ASRRequestOptions
    ) async throws {
        let newConnectionID = UUID()
        let newTaskID = UUID().uuidString.lowercased()
        var request = URLRequest(url: aliyunConfig.endpoint)
        request.setValue("Bearer \(aliyunConfig.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Dal", forHTTPHeaderField: "User-Agent")
        if let workspaceId = aliyunConfig.workspaceId {
            request.setValue(workspaceId, forHTTPHeaderField: "X-DashScope-WorkSpace")
        }

        let resources = dialFactory(request, options.urlSessionConfiguration)
        let socket = resources.task
        connectionID = newConnectionID
        taskID = newTaskID
        webSocketTask = socket
        invalidateSession = resources.invalidateSession
        socket.resume()

        do {
            let runTask = try AliyunASRProtocol.makeRunTaskMessage(
                taskID: newTaskID,
                config: aliyunConfig,
                options: options
            )
            try await socket.send(.string(runTask))
            let firstMessage = try await socket.receive()
            let firstEvent = try Self.parse(firstMessage)
            try Self.validateTaskStarted(firstEvent, expectedTaskID: newTaskID)
        } catch {
            closeConnection(
                connectionID: newConnectionID,
                closeCode: .abnormalClosure,
                finishEvents: true
            )
            throw error
        }

        guard owns(socket, connectionID: newConnectionID) else {
            throw CancellationError()
        }
        startReceiveLoop(connectionID: newConnectionID, taskID: newTaskID, socket: socket)
        AppLogger.log(
            "[AliyunASR] task started workspace=\(aliyunConfig.workspaceId == nil ? "shared" : "dedicated") reconnect=\(didAttemptReconnect)"
        )
    }

    func sendAudio(_ data: Data) async throws {
        if let pendingReconnect = reconnectTask {
            guard await pendingReconnect.value else {
                throw AliyunASRError.notConnected
            }
        }
        guard let socket = webSocketTask,
              let activeConnectionID = connectionID,
              taskID != nil
        else { throw AliyunASRError.notConnected }

        do {
            try await socket.send(.data(data))
            guard owns(socket, connectionID: activeConnectionID) else {
                throw CancellationError()
            }
        } catch {
            let failedConnectionStillActive = owns(
                socket,
                connectionID: activeConnectionID
            )
            var recovery = reconnectTask
            if failedConnectionStillActive {
                recovery = beginReconnect(
                    expectedConnectionID: activeConnectionID,
                    reason: "send error: \(String(describing: error))"
                )
            }

            if let recovery {
                guard await recovery.value else { throw error }
            } else {
                // receive loop 可能已在本次 send 挂起期间完成重连；此时旧连接
                // 已失去身份，但当前连接可直接承担本包重发。
                guard !failedConnectionStillActive,
                      didAttemptReconnect,
                      webSocketTask != nil else { throw error }
            }

            guard let recoveredSocket = webSocketTask,
                  let recoveredConnectionID = connectionID,
                  taskID != nil
            else { throw error }
            try await recoveredSocket.send(.data(data))
            guard owns(recoveredSocket, connectionID: recoveredConnectionID) else {
                throw CancellationError()
            }
        }
        audioPacketCount += 1
        totalAudioBytes += data.count
    }

    func endAudio() async throws {
        didRequestEndAudio = true
        if let pendingReconnect = reconnectTask {
            guard await pendingReconnect.value else {
                throw AliyunASRError.notConnected
            }
        }
        guard let socket = webSocketTask,
              let taskID
        else { throw AliyunASRError.notConnected }
        let finishTask = try AliyunASRProtocol.makeFinishTaskMessage(taskID: taskID)
        try await socket.send(.string(finishTask))
        AppLogger.log("[AliyunASR] finish-task sent")
    }

    func disconnect() {
        let pendingReconnect = reconnectTask
        reconnectTask = nil
        reconnectAttemptID = nil
        pendingReconnect?.cancel()
        savedConfig = nil
        savedOptions = nil

        if let connectionID {
            closeConnection(
                connectionID: connectionID,
                closeCode: .normalClosure,
                finishEvents: true
            )
        } else {
            eventContinuation?.finish()
            eventContinuation = nil
        }
        AppLogger.log("[AliyunASR] disconnected")
    }

    private func startReceiveLoop(
        connectionID: UUID,
        taskID: String,
        socket: any AliyunWebSocketTasking
    ) {
        let loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    await self.handleMessage(
                        message,
                        connectionID: connectionID,
                        expectedTaskID: taskID
                    )
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

    private func handleMessage(
        _ message: URLSessionWebSocketTask.Message,
        connectionID: UUID,
        expectedTaskID: String
    ) {
        guard self.connectionID == connectionID, !didEmitTerminalEvent else { return }
        do {
            let event = try Self.parse(message)
            switch event {
            case .taskStarted(let taskID):
                try Self.validate(taskID: taskID, expectedTaskID: expectedTaskID)

            case .result(let taskID, let sentence):
                try Self.validate(taskID: taskID, expectedTaskID: expectedTaskID)
                resultEventCount += 1
                if sentence.isHeartbeat {
                    heartbeatEventCount += 1
                }
                guard let transcript = accumulator.apply(sentence), transcript != lastTranscript else {
                    return
                }
                lastTranscript = transcript
                emitEvent(.transcript(transcript))

            case .taskFinished(let taskID):
                try Self.validate(taskID: taskID, expectedTaskID: expectedTaskID)
                let finalTranscript = accumulator.transcript(isFinal: true)
                logTerminalStats(
                    event: "task-finished",
                    transcript: finalTranscript
                )
                if finalTranscript != lastTranscript, !finalTranscript.displayText.isEmpty {
                    lastTranscript = finalTranscript
                    emitEvent(.transcript(finalTranscript))
                }
                emitCompletedOnce()
                closeConnection(
                    connectionID: connectionID,
                    closeCode: .normalClosure,
                    finishEvents: false
                )

            case .taskFailed(let taskID, let code, let message):
                try Self.validate(taskID: taskID, expectedTaskID: expectedTaskID)
                logTerminalStats(
                    event: "task-failed",
                    transcript: accumulator.transcript(isFinal: false)
                )
                emitTerminalError(AliyunASRError.taskFailed(code: code, message: message))
                closeConnection(
                    connectionID: connectionID,
                    closeCode: .protocolError,
                    finishEvents: false
                )

            case .unknown(let taskID, let name):
                if let taskID {
                    try Self.validate(taskID: taskID, expectedTaskID: expectedTaskID)
                }
                AppLogger.log("[AliyunASR] ignored event=\(name)")
            }
        } catch {
            AppLogger.log("[AliyunASR] protocol error: \(String(describing: error))")
            emitTerminalError(error)
            closeConnection(
                connectionID: connectionID,
                closeCode: .protocolError,
                finishEvents: false
            )
        }
    }

    private func handleReceiveError(
        _ error: Error,
        connectionID: UUID,
        wasCancelled: Bool
    ) {
        guard self.connectionID == connectionID,
              !wasCancelled,
              !didEmitTerminalEvent
        else { return }
        AppLogger.log("[AliyunASR] receive error: \(String(describing: error))")
        if didRequestEndAudio || audioPacketCount == 0 {
            logTerminalStats(
                event: "receive-error",
                transcript: accumulator.transcript(isFinal: false)
            )
            emitTerminalError(error)
            closeConnection(
                connectionID: connectionID,
                closeCode: .abnormalClosure,
                finishEvents: false
            )
        } else {
            guard beginReconnect(
                expectedConnectionID: connectionID,
                reason: "receive error: \(String(describing: error))"
            ) != nil else {
                // 每会话只重连一次。第二次断流明确关闭连接与事件流，
                // 让会话层停止时立即进入本地整段重放，不再留下假活连接。
                emitEvent(.streamingInterrupted)
                closeConnection(
                    connectionID: connectionID,
                    closeCode: .abnormalClosure,
                    finishEvents: false
                )
                finishEventStream()
                return
            }
        }
    }

    /// 第一次收发中断时冻结已显示前缀、撤销死连接并异步重拨。无论重连是否
    /// 成功都先发 degraded 事件，保证停止时用完整本地录音复核全文。
    private func beginReconnect(
        expectedConnectionID: UUID,
        reason: String
    ) -> Task<Bool, Never>? {
        guard connectionID == expectedConnectionID else {
            return reconnectTask
        }
        guard !didRequestEndAudio, !didAttemptReconnect,
              savedConfig != nil, savedOptions != nil else {
            return reconnectTask
        }

        didAttemptReconnect = true
        accumulator.freezePartialAsConfirmed()
        lastTranscript = accumulator.transcript(isFinal: false)
        emitEvent(.streamingInterrupted)
        AppLogger.log("[AliyunASR] connection degraded, reconnecting once: \(reason)")

        closeConnection(
            connectionID: expectedConnectionID,
            closeCode: .abnormalClosure,
            finishEvents: false
        )

        let attemptID = UUID()
        reconnectAttemptID = attemptID
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.performReconnect(attemptID: attemptID)
        }
        reconnectTask = task
        return task
    }

    private func performReconnect(attemptID: UUID) async -> Bool {
        guard reconnectAttemptID == attemptID,
              !Task.isCancelled,
              let config = savedConfig,
              let options = savedOptions else { return false }
        do {
            try await dial(config: config, options: options)
            guard reconnectAttemptID == attemptID, !Task.isCancelled else {
                if let connectionID {
                    closeConnection(
                        connectionID: connectionID,
                        closeCode: .goingAway,
                        finishEvents: false
                    )
                }
                return false
            }
            reconnectTask = nil
            reconnectAttemptID = nil
            AppLogger.log("[AliyunASR] reconnect succeeded")
            return true
        } catch {
            guard reconnectAttemptID == attemptID else { return false }
            reconnectTask = nil
            reconnectAttemptID = nil
            AppLogger.log("[AliyunASR] reconnect failed: \(String(describing: error))")
            finishEventStream()
            return false
        }
    }

    private func receiveLoopDidEnd(connectionID: UUID) {
        guard self.connectionID == connectionID else { return }
        if receiveTaskConnectionID == connectionID {
            receiveTask = nil
            receiveTaskConnectionID = nil
        }
        AppLogger.log("[AliyunASR] receive loop ended connection=\(connectionID)")
    }

    private func logTerminalStats(
        event: String,
        transcript: RecognitionTranscript
    ) {
        DebugFileLogger.log(
            "Aliyun terminal event=\(event) packets=\(audioPacketCount) bytes=\(totalAudioBytes) results=\(resultEventCount) heartbeats=\(heartbeatEventCount) chars=\(transcript.displayText.count) empty=\(transcript.displayText.isEmpty) reconnected=\(didAttemptReconnect)"
        )
    }

    private func finishEventStream() {
        eventContinuation?.finish()
        eventContinuation = nil
    }

    private func owns(
        _ task: any AliyunWebSocketTasking,
        connectionID expectedConnectionID: UUID
    ) -> Bool {
        guard connectionID == expectedConnectionID,
              let currentTask = webSocketTask
        else { return false }
        return ObjectIdentifier(currentTask) == ObjectIdentifier(task)
    }

    private func closeConnection(
        connectionID expectedConnectionID: UUID,
        closeCode: URLSessionWebSocketTask.CloseCode,
        finishEvents: Bool
    ) {
        guard connectionID == expectedConnectionID else { return }
        let task = webSocketTask
        let invalidate = invalidateSession
        let loop = receiveTaskConnectionID == expectedConnectionID
            ? receiveTask
            : nil
        connectionID = nil
        taskID = nil
        webSocketTask = nil
        invalidateSession = nil
        if receiveTaskConnectionID == expectedConnectionID {
            receiveTask = nil
            receiveTaskConnectionID = nil
        }
        loop?.cancel()
        task?.cancel(with: closeCode, reason: nil)
        invalidate?()
        if finishEvents {
            finishEventStream()
        }
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

    private static func parse(_ message: URLSessionWebSocketTask.Message) throws -> AliyunServerEvent {
        switch message {
        case .string(let text):
            return try AliyunASRProtocol.parseServerMessage(text)
        case .data(let data):
            guard data.count <= AliyunASRProtocol.maximumServerMessageBytes,
                  let text = String(data: data, encoding: .utf8)
            else { throw AliyunASRProtocolError.invalidMessage }
            return try AliyunASRProtocol.parseServerMessage(text)
        @unknown default:
            throw AliyunASRProtocolError.invalidMessage
        }
    }

    private static func validateTaskStarted(
        _ event: AliyunServerEvent,
        expectedTaskID: String
    ) throws {
        switch event {
        case .taskStarted(let taskID):
            try validate(taskID: taskID, expectedTaskID: expectedTaskID)
        case .taskFailed(_, let code, let message):
            throw AliyunASRError.taskFailed(code: code, message: message)
        case .unknown(_, let name):
            throw AliyunASRProtocolError.unexpectedEvent(name)
        default:
            throw AliyunASRProtocolError.unexpectedEvent("handshake")
        }
    }

    private static func validate(taskID: String, expectedTaskID: String) throws {
        guard taskID == expectedTaskID else {
            throw AliyunASRProtocolError.taskIDMismatch
        }
    }
}
