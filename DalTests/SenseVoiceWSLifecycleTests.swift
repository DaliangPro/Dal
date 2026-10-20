import Foundation
import XCTest
@testable import Dal

final class SenseVoiceWSLifecycleTests: XCTestCase {
    func testReceiveErrorThenQwenFinalStillArrivesOnSameStream() async throws {
        let socket = ScriptedSenseVoiceWebSocketTask()
        let factory = SenseVoiceDialFactorySpy(tasks: [socket])
        let client = makeClient(factory: factory, qwenResult: "Qwen 终校文本")
        let recorder = SenseVoiceEventRecorder()

        try await connect(client)
        let stream = await client.events
        let consumer = Task { await recorder.consume(stream) }
        let receiveStarted = await waitUntil { socket.pendingReceiveCount == 1 }
        XCTAssertTrue(receiveStarted)

        try await client.sendAudio(Data(repeating: 0x01, count: 4_000))
        socket.failReceive(SenseVoiceLifecycleTestError.transientReceive)
        let interrupted = await waitUntil {
            await recorder.contains("streamingInterrupted")
        }
        XCTAssertTrue(interrupted)
        let finishedBeforeFinal = await recorder.isFinished
        XCTAssertFalse(finishedBeforeFinal)

        try await client.endAudio()
        let finished = await waitUntil { await recorder.isFinished }
        XCTAssertTrue(finished)
        await consumer.value

        let values = await recorder.values
        XCTAssertTrue(values.contains("transcript:Qwen 终校文本:true"))
        XCTAssertEqual(values.filter { $0 == "completed" }.count, 1)
        await client.disconnect()
    }

    func testOldReceiveLoopEndingDoesNotCloseNewStream() async throws {
        let first = ScriptedSenseVoiceWebSocketTask(cancelResumesReceive: false)
        let second = ScriptedSenseVoiceWebSocketTask()
        let factory = SenseVoiceDialFactorySpy(tasks: [first, second])
        let client = makeClient(factory: factory, qwenEnabled: false)
        let recorder = SenseVoiceEventRecorder()

        try await connect(client)
        let firstReceiveStarted = await waitUntil { first.pendingReceiveCount == 1 }
        XCTAssertTrue(firstReceiveStarted)
        try await connect(client)
        let stream = await client.events
        let consumer = Task { await recorder.consume(stream) }
        let secondReceiveStarted = await waitUntil { second.pendingReceiveCount == 1 }
        XCTAssertTrue(secondReceiveStarted)

        first.failReceive(SenseVoiceLifecycleTestError.oldLoopEnded)
        let staleLoopExited = await waitUntil {
            await client.staleReceiveLoopExitCountForTesting == 1
        }
        XCTAssertTrue(staleLoopExited)
        let prematurelyFinished = await recorder.isFinished
        XCTAssertFalse(prematurelyFinished)

        second.yieldReceive(.string(makeTranscriptMessage(text: "新会话字幕", isFinal: false)))
        let transcriptArrived = await waitUntil {
            await recorder.contains("transcript:新会话字幕:false")
        }
        XCTAssertTrue(transcriptArrived)

        await client.disconnect()
        await consumer.value
    }

    func testCompletedIsEmittedOnceAndFinishesStream() async throws {
        let socket = ScriptedSenseVoiceWebSocketTask()
        let factory = SenseVoiceDialFactorySpy(tasks: [socket])
        let client = makeClient(factory: factory, qwenEnabled: false)
        let recorder = SenseVoiceEventRecorder()

        try await connect(client)
        let stream = await client.events
        let consumer = Task { await recorder.consume(stream) }
        let receiveStarted = await waitUntil { socket.pendingReceiveCount == 1 }
        XCTAssertTrue(receiveStarted)

        try await client.endAudio()
        socket.yieldReceive(.string(makeCompletedMessage()))
        socket.yieldReceive(.string(makeCompletedMessage()))
        let finished = await waitUntil { await recorder.isFinished }
        XCTAssertTrue(finished)
        await consumer.value

        let values = await recorder.values
        XCTAssertEqual(values.filter { $0 == "completed" }.count, 1)
        await client.disconnect()
    }

    func testDisconnectRejectsLateQwenFinal() async throws {
        let firstSocket = ScriptedSenseVoiceWebSocketTask()
        let secondSocket = ScriptedSenseVoiceWebSocketTask()
        let factory = SenseVoiceDialFactorySpy(tasks: [firstSocket, secondSocket])
        let transcriber = SuspendedQwenTranscriber()
        let client = makeClient(factory: factory) { audio, port, timeout in
            await transcriber.transcribe(audio: audio, port: port, timeout: timeout)
        }
        let oldRecorder = SenseVoiceEventRecorder()

        try await connect(client)
        let oldStream = await client.events
        let oldConsumer = Task { await oldRecorder.consume(oldStream) }
        try await client.sendAudio(Data(repeating: 0x02, count: 4_000))

        let endTask = Task { try await client.endAudio() }
        let transcriberStarted = await waitUntil { await transcriber.isWaiting }
        XCTAssertTrue(transcriberStarted)

        await client.disconnect()
        await oldConsumer.value

        try await connect(client)
        let newRecorder = SenseVoiceEventRecorder()
        let newStream = await client.events
        let newConsumer = Task { await newRecorder.consume(newStream) }
        try await client.sendAudio(Data(repeating: 0x05, count: 4_000))
        let newAudioCountBeforeOldFinal = await client.accumulatedAudioCountForTesting
        XCTAssertEqual(newAudioCountBeforeOldFinal, 4_000)

        await transcriber.resolve(with: "迟到终校文本")
        _ = try await endTask.value
        try? await Task.sleep(for: .milliseconds(30))

        let oldValues = await oldRecorder.values
        let newValues = await newRecorder.values
        let newAudioCountAfterOldFinal = await client.accumulatedAudioCountForTesting
        XCTAssertFalse(oldValues.contains { $0.contains("迟到终校文本") })
        XCTAssertFalse(oldValues.contains("completed"))
        XCTAssertFalse(newValues.contains { $0.contains("迟到终校文本") })
        XCTAssertEqual(newAudioCountAfterOldFinal, 4_000)

        await client.disconnect()
        await newConsumer.value
    }

    func testAudioOverflowDoesNotUsePartialQwenFinalToOverwriteStreamingText() async throws {
        let socket = ScriptedSenseVoiceWebSocketTask()
        let factory = SenseVoiceDialFactorySpy(tasks: [socket])
        let transcriber = QwenTranscriberSpy(result: "半截音频错误文本")
        let client = makeClient(factory: factory) { audio, port, timeout in
            await transcriber.transcribe(audio: audio, port: port, timeout: timeout)
        }
        await client.setAccumulatedAudioByteLimitForTesting(5_000)
        let recorder = SenseVoiceEventRecorder()

        try await connect(client)
        let stream = await client.events
        let consumer = Task { await recorder.consume(stream) }
        let receiveStarted = await waitUntil { socket.pendingReceiveCount == 1 }
        XCTAssertTrue(receiveStarted)
        socket.yieldReceive(.string(makeTranscriptMessage(text: "已有流式字幕", isFinal: false)))
        let partialArrived = await waitUntil {
            await recorder.contains("transcript:已有流式字幕:false")
        }
        XCTAssertTrue(partialArrived)

        try await client.sendAudio(Data(repeating: 0x03, count: 4_000))
        try await client.sendAudio(Data(repeating: 0x04, count: 2_000))
        try await client.endAudio()
        socket.yieldReceive(.string(makeCompletedMessage()))
        let finished = await waitUntil { await recorder.isFinished }
        XCTAssertTrue(finished)
        await consumer.value

        let values = await recorder.values
        let qwenCallCount = await transcriber.callCount
        XCTAssertEqual(qwenCallCount, 0)
        XCTAssertTrue(values.contains("transcript:已有流式字幕:false"))
        XCTAssertFalse(values.contains { $0.contains("半截音频错误文本") })
        await client.disconnect()
    }

    private func makeClient(
        factory: SenseVoiceDialFactorySpy,
        qwenEnabled: Bool = true,
        qwenResult: String? = nil
    ) -> SenseVoiceWSClient {
        makeClient(factory: factory, qwenEnabled: qwenEnabled) { _, _, _ in
            qwenResult
        }
    }

    private func makeClient(
        factory: SenseVoiceDialFactorySpy,
        qwenEnabled: Bool = true,
        qwenTranscriber: @escaping SenseVoiceQwenTranscriber
    ) -> SenseVoiceWSClient {
        SenseVoiceWSClient(
            connectionPlanProvider: {
                SenseVoiceConnectionPlan(
                    webSocketURL: URL(string: "ws://127.0.0.1:1/ws")!,
                    qwenPort: 2
                )
            },
            dialFactory: { request in
                factory.make(request: request)
            },
            qwenFinalEnabledProvider: { qwenEnabled },
            qwenTranscriber: qwenTranscriber
        )
    }

    private func connect(_ client: SenseVoiceWSClient) async throws {
        let config = try XCTUnwrap(SherpaASRConfig(credentials: ["modelDir": "/tmp/test-model"]))
        try await client.connect(config: config, options: ASRRequestOptions())
    }

    private func makeTranscriptMessage(text: String, isFinal: Bool) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [
            "type": "transcript",
            "text": text,
            "is_final": isFinal,
        ])
        return String(decoding: data, as: UTF8.self)
    }

    private func makeCompletedMessage() -> String {
        #"{"type":"completed"}"#
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let asyncCondition: @Sendable () async -> Bool = { condition() }
        return await waitUntil(timeout: timeout, condition: asyncCondition)
    }
}

private enum SenseVoiceLifecycleTestError: Error {
    case transientReceive
    case oldLoopEnded
}

private final class SenseVoiceDialFactorySpy: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [ScriptedSenseVoiceWebSocketTask]

    init(tasks: [ScriptedSenseVoiceWebSocketTask]) {
        self.tasks = tasks
    }

    func make(request: URLRequest) -> SenseVoiceDialResources {
        _ = request
        return lock.withLock {
            SenseVoiceDialResources(
                task: tasks.removeFirst(),
                invalidateSession: {}
            )
        }
    }
}

private final class ScriptedSenseVoiceWebSocketTask: SenseVoiceWebSocketTasking, @unchecked Sendable {
    private let lock = NSLock()
    private let cancelResumesReceive: Bool
    private var queuedReceives: [Result<URLSessionWebSocketTask.Message, Error>] = []
    private var pendingReceives: [CheckedContinuation<URLSessionWebSocketTask.Message, Error>] = []
    private var sentMessages: [URLSessionWebSocketTask.Message] = []

    init(cancelResumesReceive: Bool = true) {
        self.cancelResumesReceive = cancelResumesReceive
    }

    var pendingReceiveCount: Int {
        lock.withLock { pendingReceives.count }
    }

    func resume() {}

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        lock.withLock { sentMessages.append(message) }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            let immediate: Result<URLSessionWebSocketTask.Message, Error>? = lock.withLock {
                if queuedReceives.isEmpty {
                    pendingReceives.append(continuation)
                    return nil
                }
                return queuedReceives.removeFirst()
            }
            immediate.map { continuation.resume(with: $0) }
        }
    }

    func cancel(
        with closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        _ = closeCode
        _ = reason
        guard cancelResumesReceive else { return }
        let continuations = lock.withLock {
            let result = pendingReceives
            pendingReceives.removeAll()
            return result
        }
        continuations.forEach { $0.resume(throwing: CancellationError()) }
    }

    func yieldReceive(_ message: URLSessionWebSocketTask.Message) {
        enqueueReceive(.success(message))
    }

    func failReceive(_ error: Error) {
        enqueueReceive(.failure(error))
    }

    private func enqueueReceive(
        _ result: Result<URLSessionWebSocketTask.Message, Error>
    ) {
        let continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>? = lock.withLock {
            guard !pendingReceives.isEmpty else {
                queuedReceives.append(result)
                return nil
            }
            return pendingReceives.removeFirst()
        }
        continuation?.resume(with: result)
    }
}

private actor QwenTranscriberSpy {
    private(set) var callCount = 0
    private let result: String?

    init(result: String?) {
        self.result = result
    }

    func transcribe(audio: Data, port: Int, timeout: TimeInterval) -> String? {
        _ = audio
        _ = port
        _ = timeout
        callCount += 1
        return result
    }
}

private actor SuspendedQwenTranscriber {
    private var continuation: CheckedContinuation<String?, Never>?

    var isWaiting: Bool {
        continuation != nil
    }

    func transcribe(audio: Data, port: Int, timeout: TimeInterval) async -> String? {
        _ = audio
        _ = port
        _ = timeout
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(with text: String?) {
        continuation?.resume(returning: text)
        continuation = nil
    }
}

private actor SenseVoiceEventRecorder {
    private(set) var values: [String] = []
    private(set) var isFinished = false

    func consume(_ stream: AsyncStream<RecognitionEvent>) async {
        for await event in stream {
            values.append(Self.describe(event))
        }
        isFinished = true
    }

    func contains(_ value: String) -> Bool {
        values.contains(value)
    }

    private static func describe(_ event: RecognitionEvent) -> String {
        switch event {
        case .ready:
            return "ready"
        case .transcript(let transcript):
            return "transcript:\(transcript.displayText):\(transcript.isFinal)"
        case .error(let error):
            return "error:\(error)"
        case .completed:
            return "completed"
        case .processingResult(let text):
            return "processing:\(text)"
        case .voicePolishStage(let stage):
            return "voicePolishStage:\(stage.rawValue)"
        case .voicePolishUnavailable(let reason):
            return "voicePolishUnavailable:\(reason?.rawValue ?? "unknown")"
        case .finalized(let text, _):
            return "finalized:\(text)"
        case .streamingInterrupted:
            return "streamingInterrupted"
        }
    }
}
