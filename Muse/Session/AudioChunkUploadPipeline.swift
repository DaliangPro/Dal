import Foundation
import os

/// Thread-safe flag for the detached sender to signal upload failure.
private final class UploadFailureFlag: Sendable {
    private struct State {
        var failed = false
        var interruptionEmitted = false
    }

    private let _state = OSAllocatedUnfairLock(initialState: State())

    var failed: Bool {
        _state.withLock { $0.failed }
    }

    /// 标记上传管线失败，并保证只向上层发出一次中断事件。
    func markFailed() -> Bool {
        _state.withLock { state in
            state.failed = true
            guard !state.interruptionEmitted else { return false }
            state.interruptionEmitted = true
            return true
        }
    }
}

private struct AudioChunkSendTimeout: Error {}

/// Sends recorded audio chunks to the active ASR client without hopping back to
/// RecognitionSession's actor on every callback.
final class AudioChunkUploadPipeline: @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let senderTask: Task<Void, Never>
    private let failureFlag: UploadFailureFlag
    private let emitInterrupted: (@Sendable (RecognitionEvent) -> Void)?

    var failed: Bool { failureFlag.failed }

    init(
        client: (any SpeechRecognizer)?,
        audioInput: ASRAudioInputKind,
        emitInterrupted: (@Sendable (RecognitionEvent) -> Void)?,
        maxBufferedChunks: Int = 64,
        sendTimeout: Duration = .seconds(5)
    ) {
        let capacity = max(1, maxBufferedChunks)
        let (stream, continuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingOldest(capacity)
        )
        let failureFlag = UploadFailureFlag()

        self.continuation = continuation
        self.failureFlag = failureFlag
        self.emitInterrupted = emitInterrupted
        self.senderTask = Task.detached {
            var chunkCount = 0
            var lastLogTime: ContinuousClock.Instant?

            for await data in stream {
                guard let client else { break }
                let t0 = ContinuousClock.now

                do {
                    try await AsyncTimeout.throwingValue(
                        sendTimeout,
                        timeoutError: AudioChunkSendTimeout()
                    ) {
                        switch audioInput {
                        case .pcmData:
                            try await client.sendAudio(data)
                        case .pcmBuffer:
                            guard let buffer = AudioCaptureEngine.makePCMBuffer(from: data) else { return }
                            try await client.sendAudioBuffer(buffer)
                        }
                    }
                } catch {
                    DebugFileLogger.log("audio chunk send failed: \(error)")
                    if failureFlag.markFailed() {
                        emitInterrupted?(.streamingInterrupted)
                    }
                    continuation.finish()
                    break
                }

                let elapsed = ContinuousClock.now - t0
                chunkCount += 1
                let shouldLog = chunkCount % 50 == 0
                    || elapsed > .milliseconds(200)
                    || lastLogTime == nil
                if shouldLog {
                    DebugFileLogger.log("audio chunk #\(chunkCount) sent \(data.count)B in \(elapsed)")
                    lastLogTime = ContinuousClock.now
                }
            }
        }
    }

    func yield(_ data: Data) {
        guard !failed else { return }
        switch continuation.yield(data) {
        case .enqueued:
            break
        case .dropped:
            DebugFileLogger.log("audio chunk upload queue reached bounded capacity")
            if failureFlag.markFailed() {
                emitInterrupted?(.streamingInterrupted)
            }
            continuation.finish()
        case .terminated:
            break
        @unknown default:
            DebugFileLogger.log("audio chunk upload queue returned an unknown result")
            if failureFlag.markFailed() {
                emitInterrupted?(.streamingInterrupted)
            }
            continuation.finish()
        }
    }

    func finish(timeout: Duration = .seconds(1)) async -> Bool {
        continuation.finish()

        let drained = await AsyncTimeout.run(timeout) {
            await self.senderTask.value
        }
        if !drained {
            senderTask.cancel()
            DebugFileLogger.log("audio chunk pipeline drain timeout; sender cancelled")
        }
        return failed
    }

    func cancel() {
        continuation.finish()
        senderTask.cancel()
    }
}
