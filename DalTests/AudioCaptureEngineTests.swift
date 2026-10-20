import XCTest
import AVFoundation
@testable import Dal

final class AudioCaptureEngineTests: XCTestCase {

    func testAudioChunkSize() {
        XCTAssertEqual(AudioCaptureEngine.chunkByteSize, 6400)
    }

    func testSamplesPerChunk() {
        XCTAssertEqual(AudioCaptureEngine.samplesPerChunk, 3200)
    }

    func testTargetAudioFormat() {
        let format = AudioCaptureEngine.targetFormat
        XCTAssertEqual(format.sampleRate, 16000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.commonFormat, .pcmFormatInt16)
    }

    // MARK: - REPAIR_PLAN K7：有声零文本检测

    func testAudioActivitySummaryKeepsDigitalSilenceEmpty() {
        let audio = pcmData(sample: 0, sampleCount: 16_000)

        let summary = PCMAudioActivitySummary.analyze(audio)

        XCTAssertEqual(summary.validByteCount, 32_000)
        XCTAssertEqual(summary.voicedFrameCount, 0)
        XCTAssertEqual(summary.peakAmplitude, 0)
        XCTAssertFalse(summary.hasMeaningfulSpeech)
    }

    func testAudioActivitySummaryDetectsSustainedVoiceLevel() {
        let audio = pcmData(sample: 2_000, sampleCount: 3_200)

        let summary = PCMAudioActivitySummary.analyze(audio)

        XCTAssertEqual(summary.analyzedFrameCount, 10)
        XCTAssertEqual(summary.voicedFrameCount, 10)
        XCTAssertEqual(summary.peakAmplitude, 2_000)
        XCTAssertTrue(summary.hasMeaningfulSpeech)
    }

    func testAudioActivitySummaryDoesNotTreatSingleClickAsSpeech() {
        var audio = pcmData(sample: 0, sampleCount: 3_200)
        var click = Int16(20_000).littleEndian
        withUnsafeBytes(of: &click) { bytes in
            audio.replaceSubrange(0..<bytes.count, with: bytes)
        }

        let summary = PCMAudioActivitySummary.analyze(audio)

        XCTAssertFalse(summary.hasMeaningfulSpeech)
    }

    // MARK: - REPAIR_PLAN B8

    func testAccumulatedAudioRespectsByteLimit() {
        let engine = AudioCaptureEngine()
        engine.accumulatedAudioByteLimit = 1000

        engine.ingestForTesting(Data(repeating: 0x01, count: 600))
        XCTAssertEqual(engine.getRecordedAudio().count, 600)

        // 超限后整段缓存被丢弃，且不再累积
        engine.ingestForTesting(Data(repeating: 0x02, count: 600))
        XCTAssertTrue(engine.getRecordedAudio().isEmpty)
        engine.ingestForTesting(Data(repeating: 0x03, count: 100))
        XCTAssertTrue(engine.getRecordedAudio().isEmpty)
    }

    func testChunkCallbackStillFiresAfterOverflow() {
        let engine = AudioCaptureEngine()
        engine.accumulatedAudioByteLimit = 100
        var received = 0
        engine.setAudioChunkHandler { _ in received += 1 }

        // 远超上限的数据：整段缓存停了，流式切块照常工作
        engine.ingestForTesting(Data(repeating: 0x01, count: AudioCaptureEngine.chunkByteSize * 3))
        XCTAssertEqual(received, 3)
        XCTAssertTrue(engine.getRecordedAudio().isEmpty)
    }

    // MARK: - REPAIR_PLAN K3：开始提示音头部跳过

    func testLeadingSkipDefaultCoversToneWindow() {
        // 400ms @16kHz Int16 = 12800 字节，对齐提示音回采窗口
        XCTAssertEqual(AudioCaptureEngine.defaultLeadingSkipBytes, 12800)
        XCTAssertEqual(AudioCaptureEngine().leadingSkipBytes, 12800)
    }

    func testLeadingSkipDropsHeadAcrossIngests() {
        let engine = AudioCaptureEngine()
        engine.leadingSkipBytes = 100
        engine.armLeadingSkipForTesting()

        engine.ingestForTesting(Data(repeating: 0x01, count: 60))
        XCTAssertTrue(engine.getRecordedAudio().isEmpty)

        engine.ingestForTesting(Data(repeating: 0x02, count: 60))
        let recorded = engine.getRecordedAudio()
        XCTAssertEqual(recorded.count, 20)
        XCTAssertTrue(recorded.allSatisfy { $0 == 0x02 })
    }

    func testLeadingSkipAffectsChunkStreamAndAccumulation() {
        let engine = AudioCaptureEngine()
        engine.leadingSkipBytes = AudioCaptureEngine.chunkByteSize
        engine.armLeadingSkipForTesting()

        var chunks: [Data] = []
        engine.setAudioChunkHandler { chunks.append($0) }

        var payload = Data(repeating: 0x01, count: AudioCaptureEngine.chunkByteSize)
        payload.append(Data(repeating: 0x02, count: AudioCaptureEngine.chunkByteSize))
        engine.ingestForTesting(payload)

        // 头部整块被丢弃：流式只回调 1 个 chunk 且全为第二段内容
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].allSatisfy { $0 == 0x02 })
        XCTAssertTrue(engine.getRecordedAudio().allSatisfy { $0 == 0x02 })
    }

    func testIngestWithoutArmKeepsAllAudio() {
        let engine = AudioCaptureEngine()
        engine.ingestForTesting(Data(repeating: 0x01, count: 500))
        XCTAssertEqual(engine.getRecordedAudio().count, 500)
    }

    // MARK: - REPAIR_PLAN J21

    func testStartStateInvalidatesLateStarts() {
        var state = AudioCaptureStartState()

        let first = state.nextToken()
        XCTAssertTrue(state.isCurrent(first))

        state.invalidate()
        XCTAssertFalse(state.isCurrent(first))

        let second = state.nextToken()
        XCTAssertTrue(state.isCurrent(second))
        XCTAssertFalse(state.isCurrent(first))
    }

    private func pcmData(sample: Int16, sampleCount: Int) -> Data {
        var samples = [Int16](repeating: sample.littleEndian, count: sampleCount)
        return samples.withUnsafeMutableBytes { Data($0) }
    }
}
