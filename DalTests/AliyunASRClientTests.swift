import Foundation
import XCTest
@testable import Dal

final class AliyunASRClientTests: XCTestCase {
    func testClientStreamsPCMAndPublishesFinalTranscript() async throws {
        let socket = ScriptedAliyunWebSocketTask()
        let dialSpy = AliyunDialFactorySpy(socket: socket)
        let client = AliyunASRClient { request, configuration in
            dialSpy.make(request: request, configuration: configuration)
        }
        let config = try XCTUnwrap(AliyunASRConfig(credentials: [
            "apiKey": "sk-test",
            "workspaceId": "llm-test123",
        ]))

        try await client.connect(config: config)

        let request = try XCTUnwrap(dialSpy.request)
        XCTAssertEqual(
            request.url?.absoluteString,
            "wss://llm-test123.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-DashScope-WorkSpace"), "llm-test123")

        var iterator = await client.events.makeAsyncIterator()
        let audio = Data([0x01, 0x02, 0x03, 0x04])
        try await client.sendAudio(audio)
        XCTAssertEqual(socket.sentBinaryMessages, [audio])

        let taskID = try XCTUnwrap(socket.taskID)
        socket.yieldServerMessage(resultMessage(taskID: taskID, text: "你好", isFinal: false))
        let partialEvent = await iterator.next()
        guard case .transcript(let partial)? = partialEvent else {
            return XCTFail("应收到阿里云流式中间结果")
        }
        XCTAssertEqual(partial.partialText, "你好")
        XCTAssertEqual(partial.composedText, "你好")

        socket.yieldServerMessage(resultMessage(taskID: taskID, text: "你好，世界。", isFinal: true))
        let sentenceEvent = await iterator.next()
        guard case .transcript(let sentence)? = sentenceEvent else {
            return XCTFail("应收到阿里云句末结果")
        }
        XCTAssertEqual(sentence.confirmedSegments, ["你好，世界。"])
        XCTAssertFalse(sentence.isFinal)

        try await client.endAudio()
        XCTAssertEqual(socket.sentActions.last, "finish-task")
        socket.yieldServerMessage(taskFinishedMessage(taskID: taskID))

        let finalEvent = await iterator.next()
        guard case .transcript(let finalTranscript)? = finalEvent else {
            return XCTFail("任务结束时应收到最终转写")
        }
        XCTAssertEqual(finalTranscript.authoritativeText, "你好，世界。")
        XCTAssertTrue(finalTranscript.isFinal)

        guard case .completed? = await iterator.next() else {
            return XCTFail("最终转写后应关闭事件流")
        }
        let streamEnd = await iterator.next()
        XCTAssertNil(streamEnd)
    }

    func testConnectSurfacesTaskFailure() async throws {
        let socket = ScriptedAliyunWebSocketTask(
            handshakeFailure: (code: "InvalidApiKey", message: "invalid api key")
        )
        let client = AliyunASRClient { _, _ in
            AliyunDialResources(task: socket, invalidateSession: {})
        }
        let config = try XCTUnwrap(AliyunASRConfig(credentials: ["apiKey": "sk-test"]))

        do {
            try await client.connect(config: config)
            XCTFail("鉴权失败时 connect 应抛错")
        } catch let error as AliyunASRError {
            XCTAssertEqual(
                error,
                .taskFailed(code: "InvalidApiKey", message: "invalid api key")
            )
        }
    }

    func testReceiveInterruptionReconnectsOnceAndResendsOnNewTask() async throws {
        let firstSocket = ScriptedAliyunWebSocketTask()
        let secondSocket = ScriptedAliyunWebSocketTask()
        let dialQueue = AliyunDialFactoryQueue(sockets: [firstSocket, secondSocket])
        let client = AliyunASRClient { request, configuration in
            dialQueue.make(request: request, configuration: configuration)
        }
        let config = try XCTUnwrap(AliyunASRConfig(credentials: ["apiKey": "sk-test"]))

        try await client.connect(config: config)
        var iterator = await client.events.makeAsyncIterator()
        let firstAudio = Data([0x01, 0x02])
        try await client.sendAudio(firstAudio)

        firstSocket.failReceive(AliyunSocketTestError.connectionLost)
        guard case .streamingInterrupted? = await iterator.next() else {
            return XCTFail("接收中断后应立即标记流式降级")
        }

        let secondAudio = Data([0x03, 0x04])
        try await client.sendAudio(secondAudio)

        XCTAssertEqual(dialQueue.dialCount, 2)
        XCTAssertEqual(firstSocket.sentBinaryMessages, [firstAudio])
        XCTAssertEqual(secondSocket.sentBinaryMessages, [secondAudio])
        XCTAssertGreaterThanOrEqual(firstSocket.cancelCount, 1)
        await client.disconnect()
    }

    func testSendFailureReconnectsOnceAndRetriesFailedPacket() async throws {
        let firstSocket = ScriptedAliyunWebSocketTask(binarySendFailures: 1)
        let secondSocket = ScriptedAliyunWebSocketTask()
        let dialQueue = AliyunDialFactoryQueue(sockets: [firstSocket, secondSocket])
        let client = AliyunASRClient { request, configuration in
            dialQueue.make(request: request, configuration: configuration)
        }
        let config = try XCTUnwrap(AliyunASRConfig(credentials: ["apiKey": "sk-test"]))
        let audio = Data([0x11, 0x12, 0x13])

        try await client.connect(config: config)
        var iterator = await client.events.makeAsyncIterator()
        try await client.sendAudio(audio)

        guard case .streamingInterrupted? = await iterator.next() else {
            return XCTFail("发送失败重连后也必须标记流式降级")
        }
        XCTAssertEqual(dialQueue.dialCount, 2)
        XCTAssertEqual(firstSocket.sentBinaryMessages, [])
        XCTAssertEqual(secondSocket.sentBinaryMessages, [audio])
        await client.disconnect()
    }

    func testReconnectFailureEndsEventStreamAndRejectsFurtherAudio() async throws {
        let firstSocket = ScriptedAliyunWebSocketTask()
        let failedReconnectSocket = ScriptedAliyunWebSocketTask(
            handshakeFailure: (code: "ServiceUnavailable", message: "try later")
        )
        let dialQueue = AliyunDialFactoryQueue(
            sockets: [firstSocket, failedReconnectSocket]
        )
        let client = AliyunASRClient { request, configuration in
            dialQueue.make(request: request, configuration: configuration)
        }
        let config = try XCTUnwrap(AliyunASRConfig(credentials: ["apiKey": "sk-test"]))

        try await client.connect(config: config)
        var iterator = await client.events.makeAsyncIterator()
        try await client.sendAudio(Data([0x01]))
        firstSocket.failReceive(AliyunSocketTestError.connectionLost)

        guard case .streamingInterrupted? = await iterator.next() else {
            return XCTFail("重连失败前应先标记流式降级")
        }
        do {
            try await client.sendAudio(Data([0x02]))
            XCTFail("唯一一次重连失败后不得继续向死连接发送")
        } catch {
            // 预期：会话层会在停止时使用完整本地录音重放。
        }
        let streamEnd = await iterator.next()
        XCTAssertNil(streamEnd)
        XCTAssertEqual(dialQueue.dialCount, 2)
    }

    func testEmptyTaskFinishedCompletesWithoutInventingTranscript() async throws {
        let socket = ScriptedAliyunWebSocketTask()
        let client = AliyunASRClient { _, _ in
            AliyunDialResources(task: socket, invalidateSession: {})
        }
        let config = try XCTUnwrap(AliyunASRConfig(credentials: ["apiKey": "sk-test"]))

        try await client.connect(config: config)
        var iterator = await client.events.makeAsyncIterator()
        try await client.sendAudio(Data(repeating: 0, count: 3_200))
        try await client.endAudio()
        let taskID = try XCTUnwrap(socket.taskID)
        socket.yieldServerMessage(taskFinishedMessage(taskID: taskID))

        guard case .completed? = await iterator.next() else {
            return XCTFail("空 task-finished 也必须明确结束事件流")
        }
        let streamEnd = await iterator.next()
        XCTAssertNil(streamEnd)
    }

    func testAliyunReplayUses100MillisecondChunksAndPacing() async throws {
        let client = AliyunReplayRecognizerSpy()
        let sleepRecorder = AliyunReplaySleepRecorder()
        let audio = Data((0..<7_000).map { UInt8($0 % 251) })

        try await AliyunAudioReplay.send(
            audio: audio,
            to: client,
            sleep: { duration in
                sleepRecorder.record(duration)
            }
        )

        let packets = await client.sentPackets
        XCTAssertEqual(packets.map(\.count), [3_200, 3_200, 600])
        XCTAssertEqual(Data(packets.joined()), audio)
        XCTAssertEqual(
            sleepRecorder.durations,
            [.milliseconds(100), .milliseconds(100)]
        )
    }

    private func resultMessage(taskID: String, text: String, isFinal: Bool) -> String {
        """
        {
          "header": {"task_id": "\(taskID)", "event": "result-generated"},
          "payload": {"output": {"sentence": {
            "text": "\(text)", "sentence_end": \(isFinal), "heartbeat": false
          }}}
        }
        """
    }

    private func taskFinishedMessage(taskID: String) -> String {
        """
        {
          "header": {"task_id": "\(taskID)", "event": "task-finished"},
          "payload": {"output": {}, "usage": null}
        }
        """
    }
}

private final class AliyunDialFactorySpy: @unchecked Sendable {
    private let lock = NSLock()
    private let socket: ScriptedAliyunWebSocketTask
    private var storedRequest: URLRequest?

    init(socket: ScriptedAliyunWebSocketTask) {
        self.socket = socket
    }

    var request: URLRequest? { lock.withLock { storedRequest } }

    func make(
        request: URLRequest,
        configuration: URLSessionConfiguration
    ) -> AliyunDialResources {
        _ = configuration
        lock.withLock { storedRequest = request }
        return AliyunDialResources(task: socket, invalidateSession: {})
    }
}

private final class AliyunDialFactoryQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [ScriptedAliyunWebSocketTask]
    private var storedDialCount = 0

    init(sockets: [ScriptedAliyunWebSocketTask]) {
        self.sockets = sockets
    }

    var dialCount: Int { lock.withLock { storedDialCount } }

    func make(
        request: URLRequest,
        configuration: URLSessionConfiguration
    ) -> AliyunDialResources {
        _ = request
        _ = configuration
        return lock.withLock {
            storedDialCount += 1
            let socket = sockets.removeFirst()
            return AliyunDialResources(task: socket, invalidateSession: {})
        }
    }
}

private enum AliyunSocketTestError: Error {
    case connectionLost
}

private final class ScriptedAliyunWebSocketTask: AliyunWebSocketTasking, @unchecked Sendable {
    private typealias ReceiveContinuation = CheckedContinuation<
        URLSessionWebSocketTask.Message,
        any Error
    >

    private let lock = NSLock()
    private let handshakeFailure: (code: String, message: String)?
    private var binarySendFailures: Int
    private var queuedMessages: [URLSessionWebSocketTask.Message] = []
    private var receiveContinuation: ReceiveContinuation?
    private var storedTaskID: String?
    private var storedSentActions: [String] = []
    private var storedBinaryMessages: [Data] = []
    private var storedCancelCount = 0

    init(
        handshakeFailure: (code: String, message: String)? = nil,
        binarySendFailures: Int = 0
    ) {
        self.handshakeFailure = handshakeFailure
        self.binarySendFailures = binarySendFailures
    }

    var taskID: String? { lock.withLock { storedTaskID } }
    var sentActions: [String] { lock.withLock { storedSentActions } }
    var sentBinaryMessages: [Data] { lock.withLock { storedBinaryMessages } }
    var cancelCount: Int { lock.withLock { storedCancelCount } }

    func resume() {}

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        switch message {
        case .data(let data):
            let shouldFail = lock.withLock { () -> Bool in
                guard binarySendFailures > 0 else {
                    storedBinaryMessages.append(data)
                    return false
                }
                binarySendFailures -= 1
                return true
            }
            if shouldFail {
                throw AliyunSocketTestError.connectionLost
            }
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let header = root["header"] as? [String: Any],
                  let action = header["action"] as? String,
                  let taskID = header["task_id"] as? String
            else { throw AliyunASRProtocolError.invalidMessage }

            lock.withLock {
                storedTaskID = taskID
                storedSentActions.append(action)
            }
            if action == "run-task" {
                if let handshakeFailure {
                    yieldServerMessage("""
                    {
                      "header": {
                        "task_id": "\(taskID)", "event": "task-failed",
                        "error_code": "\(handshakeFailure.code)",
                        "error_message": "\(handshakeFailure.message)"
                      },
                      "payload": {}
                    }
                    """)
                } else {
                    yieldServerMessage("""
                    {
                      "header": {"task_id": "\(taskID)", "event": "task-started"},
                      "payload": {}
                    }
                    """)
                }
            }
        @unknown default:
            throw AliyunASRProtocolError.invalidMessage
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = lock.withLock { () -> URLSessionWebSocketTask.Message? in
                if !queuedMessages.isEmpty {
                    return queuedMessages.removeFirst()
                }
                receiveContinuation = continuation
                return nil
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        _ = closeCode
        _ = reason
        let continuation = lock.withLock { () -> ReceiveContinuation? in
            storedCancelCount += 1
            defer { receiveContinuation = nil }
            return receiveContinuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    func failReceive(_ error: Error) {
        let continuation = lock.withLock { () -> ReceiveContinuation? in
            defer { receiveContinuation = nil }
            return receiveContinuation
        }
        continuation?.resume(throwing: error)
    }

    func yieldServerMessage(_ text: String) {
        let message = URLSessionWebSocketTask.Message.string(text)
        let continuation = lock.withLock { () -> ReceiveContinuation? in
            guard let continuation = receiveContinuation else {
                queuedMessages.append(message)
                return nil
            }
            receiveContinuation = nil
            return continuation
        }
        continuation?.resume(returning: message)
    }
}

private actor AliyunReplayRecognizerSpy: SpeechRecognizer {
    private(set) var sentPackets: [Data] = []

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {
        _ = config
        _ = options
    }

    func sendAudio(_ data: Data) async throws {
        sentPackets.append(data)
    }

    func endAudio() async throws {}
    func disconnect() async {}

    var events: AsyncStream<RecognitionEvent> {
        AsyncStream { $0.finish() }
    }
}

private final class AliyunReplaySleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Duration] = []

    var durations: [Duration] { lock.withLock { storage } }

    func record(_ duration: Duration) {
        lock.withLock { storage.append(duration) }
    }
}
