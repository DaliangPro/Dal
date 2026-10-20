import Foundation
import XCTest
@testable import Dal

final class VolcASRReconnectTests: XCTestCase {
    func testFullReplayUsesTwoHundredMillisecondChunksAndPacing() async throws {
        let client = VolcReplayRecognizer()
        let sleepRecorder = VolcReplaySleepRecorder()
        let audio = Data(
            repeating: 0x2A,
            count: AudioCaptureEngine.chunkByteSize * 2 + 17
        )

        try await VolcanoAudioReplay.send(
            audio: audio,
            to: client,
            sleep: { duration in
                await sleepRecorder.record(duration)
            }
        )

        let packetSizes = await client.packetSizes
        let sleepDurations = await sleepRecorder.durations
        XCTAssertEqual(
            packetSizes,
            [AudioCaptureEngine.chunkByteSize, AudioCaptureEngine.chunkByteSize, 17]
        )
        XCTAssertEqual(
            sleepDurations,
            [VolcanoAudioReplay.chunkInterval, VolcanoAudioReplay.chunkInterval]
        )
    }

    func testOfficialServerErrorAfterEndAudioIsNotReportedAsCompleted() async throws {
        let socket = ScriptedVolcWebSocketTask()
        let factory = VolcDialFactorySpy(tasks: [socket])
        let client = makeClient(factory: factory)
        let recorder = VolcEventRecorder()

        try await client.connect(config: try makeConfig())
        let stream = await client.events
        let consumer = Task { await recorder.consume(stream) }
        let receiveStarted = await awaitValue { socket.pendingReceiveCount == 1 }
        XCTAssertTrue(receiveStarted)

        try await client.sendAudio(Data([0x01]))
        try await client.endAudio()
        socket.yieldReceive(.data(makeOfficialServerErrorMessage(
            code: 55_000_031,
            message: "server busy"
        )))

        let streamFinished = await awaitValue { await recorder.isFinished }
        if streamFinished {
            await consumer.value
        } else {
            consumer.cancel()
        }

        let values = await recorder.values
        XCTAssertTrue(values.contains { value in
            value.contains("55000031") && value.contains("server busy")
        })
        XCTAssertFalse(values.contains("completed"))
    }

    func testReconnectAfterFirstReceiveLoopEndsStillDeliversTranscript() async throws {
        let first = ScriptedVolcWebSocketTask(sendFailureCalls: [3])
        let second = ScriptedVolcWebSocketTask()
        let factory = VolcDialFactorySpy(tasks: [first, second])
        let client = makeClient(factory: factory)
        let recorder = VolcEventRecorder()

        try await client.connect(config: try makeConfig())
        let stream = await client.events
        let consumer = Task { await recorder.consume(stream) }
        let firstReceiveStarted = await awaitValue { first.pendingReceiveCount == 1 }
        XCTAssertTrue(firstReceiveStarted)

        try await client.sendAudio(Data([0x01]))
        first.failReceive(TestVolcLifecycleError.transientReceive)
        let interruptionArrived = await awaitValue {
            await recorder.contains("streamingInterrupted")
        }
        XCTAssertTrue(interruptionArrived)

        try await client.sendAudio(Data([0x02]))
        XCTAssertEqual(factory.dialCount, 2)
        let secondReceiveStarted = await awaitValue { second.pendingReceiveCount == 1 }
        XCTAssertTrue(secondReceiveStarted)

        second.yieldReceive(.data(try makeTranscriptMessage("重连后文本")))
        let transcriptArrived = await awaitValue {
            await recorder.contains("transcript:重连后文本")
        }
        XCTAssertTrue(transcriptArrived)

        await client.disconnect()
        await consumer.value
        let streamFinished = await recorder.isFinished
        XCTAssertTrue(streamFinished)
    }

    func testLateOldReceiveLoopExitDoesNotFinishNewStream() async throws {
        let first = ScriptedVolcWebSocketTask(
            sendFailureCalls: [3],
            cancelResumesReceive: false
        )
        let second = ScriptedVolcWebSocketTask()
        let factory = VolcDialFactorySpy(tasks: [first, second])
        let client = makeClient(factory: factory)
        let recorder = VolcEventRecorder()

        try await client.connect(config: try makeConfig())
        let stream = await client.events
        let consumer = Task { await recorder.consume(stream) }
        let firstReceiveStarted = await awaitValue { first.pendingReceiveCount == 1 }
        XCTAssertTrue(firstReceiveStarted)

        try await client.sendAudio(Data([0x01]))
        try await client.sendAudio(Data([0x02]))
        XCTAssertEqual(factory.dialCount, 2)
        let secondReceiveStarted = await awaitValue { second.pendingReceiveCount == 1 }
        XCTAssertTrue(secondReceiveStarted)

        first.failReceive(TestVolcLifecycleError.lateOldLoop)
        let staleLoopExited = await awaitValue {
            await client.staleReceiveLoopExitCountForTesting == 1
        }
        XCTAssertTrue(staleLoopExited)
        let prematurelyFinished = await recorder.isFinished
        XCTAssertFalse(prematurelyFinished)

        second.yieldReceive(.data(try makeTranscriptMessage("新连接仍可用")))
        let transcriptArrived = await awaitValue {
            await recorder.contains("transcript:新连接仍可用")
        }
        XCTAssertTrue(transcriptArrived)

        await client.disconnect()
        await consumer.value
    }

    func testCompletedIsEmittedOnlyOnceAndFinishesStream() async throws {
        let socket = ScriptedVolcWebSocketTask()
        let factory = VolcDialFactorySpy(tasks: [socket])
        let client = makeClient(factory: factory)
        let recorder = VolcEventRecorder()

        try await client.connect(config: try makeConfig())
        let stream = await client.events
        let consumer = Task { await recorder.consume(stream) }

        await client.emitCompletedForTesting()
        await client.emitCompletedForTesting()
        let finishedBeforeDisconnect = await awaitValue { await recorder.isFinished }
        await client.disconnect()
        if finishedBeforeDisconnect {
            await consumer.value
        } else {
            consumer.cancel()
        }

        let values = await recorder.values
        XCTAssertEqual(values, ["completed"])
        XCTAssertTrue(finishedBeforeDisconnect)
    }

    func testTerminalErrorIsEmittedOnlyOnceAndFinishesStream() async throws {
        let socket = ScriptedVolcWebSocketTask()
        let factory = VolcDialFactorySpy(tasks: [socket])
        let client = makeClient(factory: factory)
        let recorder = VolcEventRecorder()

        try await client.connect(config: try makeConfig())
        let stream = await client.events
        let consumer = Task { await recorder.consume(stream) }

        await client.emitTerminalErrorForTesting(TestVolcLifecycleError.firstTerminal)
        await client.emitTerminalErrorForTesting(TestVolcLifecycleError.secondTerminal)
        let finishedBeforeDisconnect = await awaitValue { await recorder.isFinished }
        await client.disconnect()
        if finishedBeforeDisconnect {
            await consumer.value
        } else {
            consumer.cancel()
        }

        let values = await recorder.values
        XCTAssertEqual(values, ["error:firstTerminal"])
        XCTAssertTrue(finishedBeforeDisconnect)
    }

    func testDisconnectFinishesEventStream() async throws {
        let socket = ScriptedVolcWebSocketTask()
        let factory = VolcDialFactorySpy(tasks: [socket])
        let client = makeClient(factory: factory)
        let recorder = VolcEventRecorder()

        try await client.connect(config: try makeConfig())
        let stream = await client.events
        let consumer = Task { await recorder.consume(stream) }

        await client.disconnect()
        let streamFinished = await awaitValue { await recorder.isFinished }
        if streamFinished {
            await consumer.value
        } else {
            consumer.cancel()
        }

        let values = await recorder.values
        XCTAssertEqual(values, [])
        XCTAssertTrue(streamFinished)
    }

    func testReconnectCarriesConfirmedAndPartialSegmentsIntoNewTranscript() {
        let result = VolcASRResult(
            text: "重连后的句子",
            utterances: [VolcUtterance(text: "重连后的句子", definite: true)]
        )

        let transcript = VolcASRClient.transcript(
            from: result,
            isFinal: true,
            carriedSegments: ["已确认", "断线前未定稿"]
        )

        XCTAssertEqual(
            transcript.confirmedSegments,
            ["已确认", "断线前未定稿", "重连后的句子"]
        )
        XCTAssertEqual(transcript.composedText, "已确认断线前未定稿重连后的句子")
        XCTAssertEqual(transcript.authoritativeText, "已确认断线前未定稿重连后的句子")
    }

    private func makeClient(factory: VolcDialFactorySpy) -> VolcASRClient {
        VolcASRClient(dialFactory: { request, configuration in
            factory.make(request: request, configuration: configuration)
        })
    }

    private func makeConfig() throws -> VolcanoASRConfig {
        try XCTUnwrap(VolcanoASRConfig(credentials: [
            "appKey": "test-app",
            "accessKey": "test-access",
            "resourceId": VolcanoASRConfig.resourceIdSeedASR,
        ]))
    }

    private func makeTranscriptMessage(_ text: String) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: [
            "result": [
                "text": text,
                "utterances": [
                    ["text": text, "definite": true],
                ],
            ],
        ])
        return VolcProtocol.encodeMessage(
            header: VolcHeader(
                messageType: .serverResponse,
                flags: .noSequence,
                serialization: .json,
                compression: .none
            ),
            payload: payload
        )
    }

    private func makeOfficialServerErrorMessage(
        code: UInt32,
        message: String
    ) -> Data {
        let header = VolcHeader(
            messageType: .serverError,
            flags: .noSequence,
            serialization: .json,
            compression: .none
        )
        let messageData = Data(message.utf8)
        var codeBigEndian = code.bigEndian
        var sizeBigEndian = UInt32(messageData.count).bigEndian
        var data = header.encode()
        data.append(Data(bytes: &codeBigEndian, count: MemoryLayout<UInt32>.size))
        data.append(Data(bytes: &sizeBigEndian, count: MemoryLayout<UInt32>.size))
        data.append(messageData)
        return data
    }

    private func awaitValue(
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

}

private actor VolcReplayRecognizer: SpeechRecognizer {
    private var packets: [Data] = []

    var packetSizes: [Int] {
        packets.map(\.count)
    }

    var events: AsyncStream<RecognitionEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {
        _ = config
        _ = options
    }

    func sendAudio(_ data: Data) async throws {
        packets.append(data)
    }

    func endAudio() async throws {}
    func disconnect() async {}
}

private actor VolcReplaySleepRecorder {
    private(set) var durations: [Duration] = []

    func record(_ duration: Duration) {
        durations.append(duration)
    }
}

private enum TestVolcLifecycleError: Error {
    case transientReceive
    case lateOldLoop
    case firstTerminal
    case secondTerminal
}

private final class VolcDialFactorySpy: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [ScriptedVolcWebSocketTask]
    private var storedDialCount = 0

    init(tasks: [ScriptedVolcWebSocketTask]) {
        self.tasks = tasks
    }

    var dialCount: Int {
        lock.withLock { storedDialCount }
    }

    func make(
        request: URLRequest,
        configuration: URLSessionConfiguration
    ) -> VolcDialResources {
        _ = request
        _ = configuration
        return lock.withLock {
            storedDialCount += 1
            let task = tasks.removeFirst()
            return VolcDialResources(task: task, invalidateSession: {})
        }
    }
}

private final class ScriptedVolcWebSocketTask: VolcWebSocketTasking, @unchecked Sendable {
    private let lock = NSLock()
    private let sendFailureCalls: Set<Int>
    private let cancelResumesReceive: Bool
    private var sendCallCount = 0
    private var queuedReceives: [Result<URLSessionWebSocketTask.Message, Error>] = []
    private var pendingReceives: [CheckedContinuation<URLSessionWebSocketTask.Message, Error>] = []

    init(
        sendFailureCalls: Set<Int> = [],
        cancelResumesReceive: Bool = true
    ) {
        self.sendFailureCalls = sendFailureCalls
        self.cancelResumesReceive = cancelResumesReceive
    }

    var pendingReceiveCount: Int {
        lock.withLock { pendingReceives.count }
    }

    func resume() {}

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        _ = message
        let shouldFail = lock.withLock {
            sendCallCount += 1
            return sendFailureCalls.contains(sendCallCount)
        }
        if shouldFail {
            throw TestVolcLifecycleError.transientReceive
        }
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

private actor VolcEventRecorder {
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
            return "transcript:\(transcript.displayText)"
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
