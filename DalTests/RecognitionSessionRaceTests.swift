import XCTest
@preconcurrency import AVFoundation
@testable import Dal

final class RecognitionSessionRaceTests: XCTestCase {
    func testUserStopCapturesReleaseTailBeforeStoppingAudio() async {
        let client = RaceTestRecognizer(connectMode: .immediate)
        let audio = AudioCaptureSpy()
        let session = makeSession(
            factory: RaceRecognizerFactory(preloaded: [client]),
            audio: audio
        )

        await session.startRecording()
        await session.stopRecording()

        XCTAssertEqual(audio.releaseTailCallCount, 1)
        XCTAssertTrue(audio.wasRunningDuringReleaseTail)
        XCTAssertFalse(audio.isRunning)
    }

    func testServerInitiatedStopSkipsReleaseTail() async throws {
        let client = RaceTestRecognizer(connectMode: .immediate)
        let audio = AudioCaptureSpy()
        let session = makeSession(
            factory: RaceRecognizerFactory(preloaded: [client]),
            audio: audio
        )

        await session.startRecording()
        let sessionIDCandidate = await session.currentSessionIDForTesting
        let sessionID = try XCTUnwrap(sessionIDCandidate)
        await session.stopRecording(expectedSessionID: sessionID)

        XCTAssertEqual(audio.releaseTailCallCount, 0)
        XCTAssertFalse(audio.isRunning)
    }

    func testOldConnectFailureCannotStopNewSessionAudio() async {
        let first = RaceTestRecognizer(connectMode: .suspended)
        let second = RaceTestRecognizer(connectMode: .immediate)
        let factory = RaceRecognizerFactory(preloaded: [first, second])
        let audio = AudioCaptureSpy()
        let session = makeSession(factory: factory, audio: audio)

        let firstStart = Task { await session.startRecording() }
        await waitUntil { await first.isConnecting }

        await session.startRecording()
        let secondIsActive = await session.isActiveClientForTesting(second)
        XCTAssertTrue(secondIsActive)
        XCTAssertTrue(audio.isRunning)

        await first.failConnect(TestRaceError.connectFailed)
        await firstStart.value

        XCTAssertTrue(audio.isRunning, "旧会话连接失败不得停止新会话音频")
        let state = await session.state
        XCTAssertEqual(state, .recording)
        await session.forceResetForTesting()
    }

    func testOldCompletedEventCannotChangeNewSessionState() async throws {
        let first = RaceTestRecognizer(connectMode: .immediate)
        let second = RaceTestRecognizer(connectMode: .immediate)
        let factory = RaceRecognizerFactory(preloaded: [first, second])
        let recorder = RaceRecognitionEventRecorder()
        let session = makeSession(factory: factory)
        await session.setOnASREvent { recorder.record($0) }

        await session.startRecording()
        let firstIDCandidate = await session.currentSessionIDForTesting
        let firstID = try XCTUnwrap(firstIDCandidate)
        await session.startRecording()
        recorder.clear()

        await session.handleASREventForTesting(.completed, expectedSessionID: firstID)

        let state = await session.state
        XCTAssertEqual(state, .recording)
        XCTAssertEqual(recorder.values, [])
        await session.forceResetForTesting()
    }

    func testOldTranscriptCannotReachNewSession() async throws {
        let first = RaceTestRecognizer(connectMode: .immediate)
        let second = RaceTestRecognizer(connectMode: .immediate)
        let factory = RaceRecognizerFactory(preloaded: [first, second])
        let recorder = RaceRecognitionEventRecorder()
        let session = makeSession(factory: factory)
        await session.setOnASREvent { recorder.record($0) }

        await session.startRecording()
        let firstIDCandidate = await session.currentSessionIDForTesting
        let firstID = try XCTUnwrap(firstIDCandidate)
        await session.startRecording()
        recorder.clear()

        await session.handleASREventForTesting(
            .transcript(Self.transcript("旧会话文本")),
            expectedSessionID: firstID
        )

        XCTAssertEqual(recorder.values, [])
        let transcript = await session.transcriptForTesting
        XCTAssertEqual(transcript, .empty)
        await session.forceResetForTesting()
    }

    func testForceResetInvalidatesSessionBeforeDetachedCleanupSuspends() async throws {
        let first = RaceTestRecognizer(connectMode: .immediate, blocksDisconnect: true)
        let factory = RaceRecognizerFactory(preloaded: [first])
        let session = makeSession(factory: factory)

        await session.startRecording()
        let firstIDCandidate = await session.currentSessionIDForTesting
        let firstID = try XCTUnwrap(firstIDCandidate)

        await session.forceResetForTesting()
        await waitUntil { await first.isDisconnecting }

        let currentID = await session.currentSessionIDForTesting
        XCTAssertNotEqual(currentID, firstID)
        XCTAssertNil(currentID)
        let state = await session.state
        XCTAssertEqual(state, .idle)
        let firstIsActive = await session.isActiveClientForTesting(first)
        XCTAssertFalse(firstIsActive)

        await first.releaseDisconnect()
    }

    func testRapidStartStopStartInterleavingLeavesOneActiveClient() async {
        let factory = RaceRecognizerFactory()
        let session = makeSession(factory: factory)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    switch index % 3 {
                    case 0, 2:
                        await session.startRecording()
                    default:
                        await session.stopRecording()
                    }
                }
            }
        }

        // 把最终意图固定为 start；前面的 100 次只负责制造交错。
        await session.startRecording()
        await waitUntil {
            await factory.undisconnectedClientCount == 1
        }

        let state = await session.state
        let activeClientCount = await session.activeClientCountForTesting
        let undisconnectedClientCount = await factory.undisconnectedClientCount
        XCTAssertEqual(state, .recording)
        XCTAssertEqual(activeClientCount, 1)
        XCTAssertEqual(undisconnectedClientCount, 1)
        await session.forceResetForTesting()
    }

    func testLateOldClientDisconnectCannotClearNewClient() async {
        let first = RaceTestRecognizer(connectMode: .immediate, blocksDisconnect: true)
        let second = RaceTestRecognizer(connectMode: .immediate)
        let factory = RaceRecognizerFactory(preloaded: [first, second])
        let session = makeSession(factory: factory)

        await session.startRecording()
        let firstStop = Task { await session.stopRecording() }
        await waitUntil { await first.isDisconnecting }

        await session.startRecording()

        let secondIsActiveBefore = await session.isActiveClientForTesting(second)
        XCTAssertTrue(secondIsActiveBefore)
        await first.releaseDisconnect()
        await firstStop.value
        await waitUntil { await first.isDisconnected }

        let secondIsActiveAfter = await session.isActiveClientForTesting(second)
        XCTAssertTrue(secondIsActiveAfter)
        let activeClientCount = await session.activeClientCountForTesting
        XCTAssertEqual(activeClientCount, 1)
        await session.forceResetForTesting()
    }

    func testSecondStopDoesNotDuplicateInjectionOrHistory() async {
        let client = RaceTestRecognizer(
            connectMode: .immediate,
            finalTranscript: "只应写入一次"
        )
        let factory = RaceRecognizerFactory(preloaded: [client])
        let injection = TextInjectionSpy()
        let history = HistoryStore(path: ":memory:")
        let session = makeSession(
            factory: factory,
            injection: injection,
            historyStore: history
        )

        await session.startRecording()
        await session.stopRecording()
        await session.stopRecording()

        XCTAssertEqual(injection.injectionCount, 1)
        let historyCount = await history.count()
        let state = await session.state
        XCTAssertEqual(historyCount, 1)
        XCTAssertEqual(state, .idle)
    }

    func testAliyunVoicedEmptyTranscriptUsesPacedFullReplay() async {
        let liveClient = RaceTestRecognizer(connectMode: .immediate)
        let replayClient = RaceTestRecognizer(
            connectMode: .immediate,
            finalTranscript: "完整恢复文本"
        )
        let factory = RaceRecognizerFactory(preloaded: [liveClient, replayClient])
        let audio = AudioCaptureSpy(recordedAudio: Self.voicedPCM())
        let injection = TextInjectionSpy()
        let recorder = RaceRecognitionEventRecorder()
        let session = makeSession(
            factory: factory,
            audio: audio,
            injection: injection,
            provider: .aliyun,
            config: AliyunASRConfig(credentials: ["apiKey": "sk-test"])!,
            aliyunReplaySleep: { _ in }
        )
        await session.setOnASREvent { recorder.record($0) }

        await session.startRecording()
        await session.stopRecording()

        XCTAssertEqual(injection.injectionCount, 1)
        XCTAssertTrue(recorder.values.contains {
            $0.hasPrefix("finalized:完整恢复文本:")
        })
        let replayPackets = await replayClient.sentAudioPackets
        let replayPacketSizes = replayPackets.map(\.count)
        XCTAssertFalse(replayPacketSizes.isEmpty)
        XCTAssertTrue(replayPacketSizes.allSatisfy { $0 <= AliyunAudioReplay.chunkByteSize })
    }

    func testAliyunReplayFailurePreservesPartialAndShowsExplicitError() async {
        let liveClient = RaceTestRecognizer(
            connectMode: .immediate,
            finalTranscript: "已有部分文字"
        )
        let replayClient = RaceTestRecognizer(connectMode: .immediate)
        let factory = RaceRecognizerFactory(preloaded: [liveClient, replayClient])
        let injection = TextInjectionSpy()
        let recorder = RaceRecognitionEventRecorder()
        let session = makeSession(
            factory: factory,
            audio: AudioCaptureSpy(recordedAudio: Self.voicedPCM()),
            injection: injection,
            provider: .aliyun,
            config: AliyunASRConfig(credentials: ["apiKey": "sk-test"])!,
            aliyunReplaySleep: { _ in }
        )
        await session.setOnASREvent { recorder.record($0) }

        await session.startRecording()
        await session.handleASREventForTesting(.streamingInterrupted)
        await session.stopRecording()

        XCTAssertEqual(injection.injectionCount, 1)
        XCTAssertTrue(recorder.values.contains {
            $0.hasPrefix("finalized:已有部分文字:")
        })
        XCTAssertTrue(recorder.values.contains {
            $0.contains(L("全文重识别失败", "full re-recognition failed")) && $0.contains(L("已保留现有文字", "Existing text was preserved"))
        })
    }

    func testAliyunVoicedEmptyReplayFailureShowsExplicitError() async {
        let liveClient = RaceTestRecognizer(connectMode: .immediate)
        let replayClient = RaceTestRecognizer(connectMode: .immediate)
        let factory = RaceRecognizerFactory(preloaded: [liveClient, replayClient])
        let injection = TextInjectionSpy()
        let recorder = RaceRecognitionEventRecorder()
        let session = makeSession(
            factory: factory,
            audio: AudioCaptureSpy(recordedAudio: Self.voicedPCM()),
            injection: injection,
            provider: .aliyun,
            config: AliyunASRConfig(credentials: ["apiKey": "sk-test"])!,
            aliyunReplaySleep: { _ in }
        )
        await session.setOnASREvent { recorder.record($0) }

        await session.startRecording()
        await session.stopRecording()

        XCTAssertEqual(injection.injectionCount, 0)
        XCTAssertTrue(recorder.values.contains {
            $0.contains(L("未返回识别结果", "returned no transcript")) && $0.contains(L("豆包", "Doubao"))
        })
    }

    func testAliyunDigitalSilenceStaysEmptyWithoutReplay() async {
        let liveClient = RaceTestRecognizer(connectMode: .immediate)
        let unusedReplayClient = RaceTestRecognizer(
            connectMode: .immediate,
            finalTranscript: "不应使用"
        )
        let factory = RaceRecognizerFactory(
            preloaded: [liveClient, unusedReplayClient]
        )
        let injection = TextInjectionSpy()
        let session = makeSession(
            factory: factory,
            audio: AudioCaptureSpy(
                recordedAudio: Data(repeating: 0, count: 32_000)
            ),
            injection: injection,
            provider: .aliyun,
            config: AliyunASRConfig(credentials: ["apiKey": "sk-test"])!,
            aliyunReplaySleep: { _ in }
        )

        await session.startRecording()
        await session.stopRecording()

        XCTAssertEqual(injection.injectionCount, 0)
        XCTAssertEqual(factory.createdClientCount, 1)
    }

    func testVolcanoReplayUsesLatestNonFinalTranscriptOnNormalCompletion() async {
        let liveClient = RaceTestRecognizer(
            connectMode: .immediate,
            finalTranscript: "已有部分文字"
        )
        let replayClient = RaceTestRecognizer(
            connectMode: .immediate,
            finalTranscript: "全文重放恢复完整文字",
            finalTranscriptIsFinal: false
        )
        let factory = RaceRecognizerFactory(preloaded: [liveClient, replayClient])
        let injection = TextInjectionSpy()
        let recorder = RaceRecognitionEventRecorder()
        let session = makeSession(
            factory: factory,
            audio: AudioCaptureSpy(recordedAudio: Self.voicedPCM()),
            injection: injection,
            provider: .volcano,
            config: VolcanoASRConfig(credentials: [
                "appKey": "test-app",
                "accessKey": "test-access",
                "resourceId": VolcanoASRConfig.resourceIdBigASR,
            ])!
        )
        await session.setOnASREvent { recorder.record($0) }

        await session.startRecording()
        await session.handleASREventForTesting(.streamingInterrupted)
        await session.stopRecording()

        XCTAssertEqual(injection.injectionCount, 1)
        XCTAssertTrue(recorder.values.contains {
            $0.hasPrefix("finalized:全文重放恢复完整文字:")
        })
        XCTAssertFalse(recorder.values.contains {
            $0.contains(L("全文重识别失败", "full re-recognition failed"))
        })
    }

    func testVolcanoEventDrainTimeoutWithValidTextSkipsFullReplay() async {
        let liveClient = RaceTestRecognizer(
            connectMode: .immediate,
            finalTranscript: "已有有效文字",
            finalTranscriptIsFinal: false,
            completesEventsOnEndAudio: false
        )
        let unusedReplayClient = RaceTestRecognizer(
            connectMode: .immediate,
            finalTranscript: "不应创建全文重放"
        )
        let factory = RaceRecognizerFactory(
            preloaded: [liveClient, unusedReplayClient]
        )
        let injection = TextInjectionSpy()
        let recorder = RaceRecognitionEventRecorder()
        let session = makeSession(
            factory: factory,
            audio: AudioCaptureSpy(recordedAudio: Self.voicedPCM()),
            injection: injection,
            provider: .volcano,
            config: VolcanoASRConfig(credentials: [
                "appKey": "test-app",
                "accessKey": "test-access",
                "resourceId": VolcanoASRConfig.resourceIdBigASR,
            ])!
        )
        await session.setOnASREvent { recorder.record($0) }

        await session.startRecording()
        await session.stopRecording()

        XCTAssertEqual(factory.createdClientCount, 1)
        XCTAssertEqual(injection.injectionCount, 1)
        XCTAssertTrue(recorder.values.contains {
            $0.hasPrefix("finalized:已有有效文字:")
        })
        XCTAssertFalse(recorder.values.contains {
            $0.contains(L("全文重识别失败", "full re-recognition failed"))
        })
    }

    func testVolcanoEndAudioFailureStillUsesFullReplay() async {
        let liveClient = RaceTestRecognizer(
            connectMode: .immediate,
            finalTranscript: "已有部分文字",
            finalTranscriptIsFinal: false,
            endAudioFails: true
        )
        let replayClient = RaceTestRecognizer(
            connectMode: .immediate,
            finalTranscript: "结束包失败后的完整文字",
            finalTranscriptIsFinal: false
        )
        let factory = RaceRecognizerFactory(preloaded: [liveClient, replayClient])
        let injection = TextInjectionSpy()
        let recorder = RaceRecognitionEventRecorder()
        let session = makeSession(
            factory: factory,
            audio: AudioCaptureSpy(recordedAudio: Self.voicedPCM()),
            injection: injection,
            provider: .volcano,
            config: VolcanoASRConfig(credentials: [
                "appKey": "test-app",
                "accessKey": "test-access",
                "resourceId": VolcanoASRConfig.resourceIdBigASR,
            ])!
        )
        await session.setOnASREvent { recorder.record($0) }

        await session.startRecording()
        await session.stopRecording()

        XCTAssertEqual(factory.createdClientCount, 2)
        XCTAssertEqual(injection.injectionCount, 1)
        XCTAssertTrue(recorder.values.contains {
            $0.hasPrefix("finalized:结束包失败后的完整文字:")
        })
    }

    func testVolcanoEventDrainTimeoutWithoutTextStillUsesFullReplay() async {
        let liveClient = RaceTestRecognizer(
            connectMode: .immediate,
            completesEventsOnEndAudio: false
        )
        let replayClient = RaceTestRecognizer(
            connectMode: .immediate,
            finalTranscript: "零文本超时后的恢复文字",
            finalTranscriptIsFinal: false
        )
        let factory = RaceRecognizerFactory(preloaded: [liveClient, replayClient])
        let injection = TextInjectionSpy()
        let recorder = RaceRecognitionEventRecorder()
        let session = makeSession(
            factory: factory,
            audio: AudioCaptureSpy(recordedAudio: Self.voicedPCM()),
            injection: injection,
            provider: .volcano,
            config: VolcanoASRConfig(credentials: [
                "appKey": "test-app",
                "accessKey": "test-access",
                "resourceId": VolcanoASRConfig.resourceIdBigASR,
            ])!
        )
        await session.setOnASREvent { recorder.record($0) }

        await session.startRecording()
        await session.stopRecording()

        XCTAssertEqual(factory.createdClientCount, 2)
        XCTAssertEqual(injection.injectionCount, 1)
        XCTAssertTrue(recorder.values.contains {
            $0.hasPrefix("finalized:零文本超时后的恢复文字:")
        })
    }

    private func makeSession(
        factory: RaceRecognizerFactory,
        audio: AudioCaptureSpy = AudioCaptureSpy(),
        injection: TextInjectionSpy = TextInjectionSpy(),
        historyStore: HistoryStore = HistoryStore(path: ":memory:"),
        provider: ASRProvider = .apple,
        config: any ASRProviderConfig = AppleASRConfig(credentials: [:])!,
        aliyunReplaySleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) -> RecognitionSession {
        RecognitionSession(
            audioEngine: audio,
            injectionEngine: injection,
            historyStore: historyStore,
            asrClientFactory: { factory.makeClient(for: $0) },
            selectedASRProvider: { provider },
            asrConfigLoader: { _ in config },
            microphonePermission: { true },
            promptContextCapture: {
                PromptContext(selectedText: "", clipboardText: "")
            },
            requestOptionsProvider: { _ in (ASRRequestOptions(), 0) },
            aliyunReplaySleep: aliyunReplaySleep
        )
    }

    fileprivate static func transcript(
        _ text: String,
        isFinal: Bool = true
    ) -> RecognitionTranscript {
        RecognitionTranscript(
            confirmedSegments: [text],
            partialText: "",
            authoritativeText: text,
            isFinal: isFinal
        )
    }

    private static func voicedPCM() -> Data {
        var samples = [Int16](repeating: 2_000, count: 3_200)
        return samples.withUnsafeMutableBytes { Data($0) }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("等待异步条件超时")
    }
}

private enum TestRaceError: Error {
    case connectFailed
    case endAudioFailed
}

private actor RaceTestRecognizer: SpeechRecognizer {
    enum ConnectMode: Sendable, Equatable {
        case immediate
        case suspended
    }

    private let eventStream: AsyncStream<RecognitionEvent>
    private let eventContinuation: AsyncStream<RecognitionEvent>.Continuation
    private let connectMode: ConnectMode
    private let finalTranscript: String?
    private let finalTranscriptIsFinal: Bool
    private let completesEventsOnEndAudio: Bool
    private let endAudioFails: Bool
    private let blocksDisconnect: Bool
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var disconnectContinuations: [CheckedContinuation<Void, Never>] = []
    private var disconnectReleased = false
    private(set) var sentAudioPackets: [Data] = []
    private(set) var isConnecting = false
    private(set) var isDisconnecting = false
    private(set) var isDisconnected = false

    init(
        connectMode: ConnectMode,
        finalTranscript: String? = nil,
        finalTranscriptIsFinal: Bool = true,
        completesEventsOnEndAudio: Bool = true,
        endAudioFails: Bool = false,
        blocksDisconnect: Bool = false
    ) {
        let pair = AsyncStream<RecognitionEvent>.makeStream()
        self.eventStream = pair.stream
        self.eventContinuation = pair.continuation
        self.connectMode = connectMode
        self.finalTranscript = finalTranscript
        self.finalTranscriptIsFinal = finalTranscriptIsFinal
        self.completesEventsOnEndAudio = completesEventsOnEndAudio
        self.endAudioFails = endAudioFails
        self.blocksDisconnect = blocksDisconnect
    }

    var events: AsyncStream<RecognitionEvent> {
        eventStream
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {
        _ = config
        _ = options
        guard connectMode == .suspended else { return }
        try await withCheckedThrowingContinuation { continuation in
            isConnecting = true
            connectContinuation = continuation
        }
    }

    func failConnect(_ error: Error) {
        isConnecting = false
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
    }

    func sendAudio(_ data: Data) async throws {
        sentAudioPackets.append(data)
    }

    nonisolated func sendAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {
        _ = buffer
    }

    func endAudio() async throws {
        if let finalTranscript {
            eventContinuation.yield(.transcript(RecognitionSessionRaceTests.transcript(
                finalTranscript,
                isFinal: finalTranscriptIsFinal
            )))
        }
        if completesEventsOnEndAudio {
            eventContinuation.yield(.completed)
            eventContinuation.finish()
        }
        if endAudioFails {
            throw TestRaceError.endAudioFailed
        }
    }

    func disconnect() async {
        isDisconnecting = true
        if blocksDisconnect, !disconnectReleased {
            await withCheckedContinuation { continuation in
                disconnectContinuations.append(continuation)
            }
        }
        guard !isDisconnected else { return }
        isDisconnected = true
        eventContinuation.finish()
    }

    func releaseDisconnect() {
        disconnectReleased = true
        let continuations = disconnectContinuations
        disconnectContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private final class RaceRecognizerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var preloaded: [RaceTestRecognizer]
    private var created: [RaceTestRecognizer] = []

    init(preloaded: [RaceTestRecognizer] = []) {
        self.preloaded = preloaded
    }

    func makeClient(for provider: ASRProvider) -> any SpeechRecognizer {
        _ = provider
        return lock.withLock {
            let client = preloaded.isEmpty
                ? RaceTestRecognizer(connectMode: .immediate)
                : preloaded.removeFirst()
            created.append(client)
            return client
        }
    }

    var undisconnectedClientCount: Int {
        get async {
            let clients = lock.withLock { created }
            var count = 0
            for client in clients where !(await client.isDisconnected) {
                count += 1
            }
            return count
        }
    }

    var createdClientCount: Int {
        lock.withLock { created.count }
    }
}

private final class AudioCaptureSpy: AudioCaptureControlling, @unchecked Sendable {
    private let lock = NSLock()
    private let recordedAudio: Data
    private var running = false
    private var onChunk: ((Data) -> Void)?
    private var onLevel: ((Float) -> Void)?
    private var storedReleaseTailCallCount = 0
    private var storedWasRunningDuringReleaseTail = false

    var isRunning: Bool {
        lock.withLock { running }
    }

    var releaseTailCallCount: Int {
        lock.withLock { storedReleaseTailCallCount }
    }

    var wasRunningDuringReleaseTail: Bool {
        lock.withLock { storedWasRunningDuringReleaseTail }
    }

    init(recordedAudio: Data = Data()) {
        self.recordedAudio = recordedAudio
    }

    func warmUp() {}

    func setAudioHandlers(
        onChunk: ((Data) -> Void)?,
        onLevel: ((Float) -> Void)?
    ) {
        lock.withLock {
            self.onChunk = onChunk
            self.onLevel = onLevel
        }
    }

    func setAudioChunkHandler(_ handler: ((Data) -> Void)?) {
        lock.withLock { onChunk = handler }
    }

    func clearAudioHandlers() {
        setAudioHandlers(onChunk: nil, onLevel: nil)
    }

    func start(timeout: Duration) async throws {
        _ = timeout
        lock.withLock { running = true }
    }

    func stop() {
        lock.withLock { running = false }
        clearAudioHandlers()
    }

    func captureReleaseTail() async {
        lock.withLock {
            storedReleaseTailCallCount += 1
            storedWasRunningDuringReleaseTail = running
        }
    }

    func getRecordedAudio() -> Data {
        recordedAudio
    }
}

private final class TextInjectionSpy: TextInjecting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedPreserveClipboard = true
    private var storedInjectionCount = 0

    var preserveClipboard: Bool {
        get { lock.withLock { storedPreserveClipboard } }
        set { lock.withLock { storedPreserveClipboard = newValue } }
    }

    var injectionCount: Int {
        lock.withLock { storedInjectionCount }
    }

    func inject(_ text: String) -> InjectionOutcome {
        _ = text
        lock.withLock { storedInjectionCount += 1 }
        return .inserted
    }
}

private final class RaceRecognitionEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func clear() {
        lock.withLock { storage.removeAll() }
    }

    func record(_ event: RecognitionEvent) {
        lock.withLock {
            switch event {
            case .ready:
                storage.append("ready")
            case .transcript(let transcript):
                storage.append("transcript:\(transcript.displayText)")
            case .error(let error):
                storage.append("error:\(error.localizedDescription)")
            case .completed:
                storage.append("completed")
            case .processingResult(let text):
                storage.append("processing:\(text)")
            case .voicePolishStage(let stage):
                storage.append("voicePolishStage:\(stage.rawValue)")
            case .voicePolishUnavailable(let reason):
                storage.append("voicePolishUnavailable:\(reason?.rawValue ?? "unknown")")
            case .finalized(let text, let injection):
                storage.append("finalized:\(text):\(injection)")
            case .streamingInterrupted:
                storage.append("streamingInterrupted")
            }
        }
    }
}
