import XCTest
@testable import Muse

final class AudioChunkUploadPipelineTests: XCTestCase {
    func testDrainTimeoutMarksFailureWithoutQueueOverflow() async {
        let recorder = PipelineEventRecorder()
        let pipeline = AudioChunkUploadPipeline(
            client: SlowPipelineSpeechRecognizer(), audioInput: .pcmData,
            emitInterrupted: { recorder.record($0) }, sendTimeout: .seconds(30)
        )
        pipeline.yield(Data([1, 2]))
        let failed = await pipeline.finish(timeout: .milliseconds(50))
        XCTAssertTrue(failed)
        XCTAssertEqual(recorder.values, ["streamingInterrupted"])
    }

    func testFinishDrainsPCMDataInOrder() async {
        let client = PipelineSpeechRecognizerSpy()
        let pipeline = AudioChunkUploadPipeline(
            client: client,
            audioInput: .pcmData,
            emitInterrupted: nil
        )
        let first = Data([1, 2, 3])
        let second = Data([4, 5, 6])

        pipeline.yield(first)
        pipeline.yield(second)
        let failed = await pipeline.finish(timeout: .seconds(1))

        let sentAudio = await client.sentAudioData()
        XCTAssertEqual(sentAudio, [first, second])
        XCTAssertFalse(failed)
        XCTAssertFalse(pipeline.failed)
    }

    func testSendFailureMarksPipelineFailedAndEmitsInterrupted() async {
        let client = PipelineSpeechRecognizerSpy()
        let recorder = PipelineEventRecorder()
        await client.setSendError(PipelineSendError.intentionalFailure)

        let pipeline = AudioChunkUploadPipeline(
            client: client,
            audioInput: .pcmData,
            emitInterrupted: { recorder.record($0) }
        )

        pipeline.yield(Data([1]))
        let failed = await pipeline.finish(timeout: .seconds(1))

        XCTAssertTrue(failed)
        XCTAssertTrue(pipeline.failed)
        XCTAssertEqual(recorder.values, ["streamingInterrupted"])
    }

    func testBoundedQueueInterruptsWhenSenderCannotKeepUp() async {
        let client = SlowPipelineSpeechRecognizer()
        let recorder = PipelineEventRecorder()
        let pipeline = AudioChunkUploadPipeline(
            client: client,
            audioInput: .pcmData,
            emitInterrupted: { recorder.record($0) },
            maxBufferedChunks: 2,
            sendTimeout: .seconds(30)
        )

        for value in 0..<8 {
            pipeline.yield(Data([UInt8(value)]))
        }
        let failed = await pipeline.finish(timeout: .milliseconds(100))

        XCTAssertTrue(failed)
        XCTAssertEqual(recorder.values, ["streamingInterrupted"])
    }
}

private enum PipelineSendError: Error {
    case intentionalFailure
}

private actor PipelineSpeechRecognizerSpy: SpeechRecognizer {
    private var audioData: [Data] = []
    private var sendError: Error?

    func setSendError(_ error: Error?) {
        sendError = error
    }

    func sentAudioData() -> [Data] {
        audioData
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {}

    func sendAudio(_ data: Data) async throws {
        if let sendError {
            throw sendError
        }
        audioData.append(data)
    }

    func endAudio() async throws {}

    func disconnect() async {}

    var events: AsyncStream<RecognitionEvent> {
        get async {
            AsyncStream { continuation in
                continuation.finish()
            }
        }
    }
}

private actor SlowPipelineSpeechRecognizer: SpeechRecognizer {
    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {}

    func sendAudio(_ data: Data) async throws {
        _ = data
        try await Task.sleep(for: .seconds(60))
    }

    func endAudio() async throws {}

    func disconnect() async {}

    var events: AsyncStream<RecognitionEvent> {
        get async {
            AsyncStream { continuation in
                continuation.finish()
            }
        }
    }
}

private final class PipelineEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func record(_ event: RecognitionEvent) {
        lock.withLock {
            switch event {
            case .streamingInterrupted:
                storage.append("streamingInterrupted")
            default:
                storage.append("other")
            }
        }
    }
}
