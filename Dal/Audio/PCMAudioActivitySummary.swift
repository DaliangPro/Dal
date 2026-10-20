import Foundation

/// 会话内 PCM 活动摘要，只用于判断「确实录到了声音但云端返回零文本」。
/// 不保存音频、不做语音内容推断，也不取代 ASR；阈值仅过滤数字静音与瞬时点击。
struct PCMAudioActivitySummary: Sendable, Equatable {
    static let frameDurationMilliseconds = 20
    static let samplesPerFrame = 320
    static let minimumPeakAmplitude = 1_000
    static let minimumFrameRMS = 220.0
    static let minimumVoicedFrames = 5
    static let minimumAnalyzedAudioBytes = 3_200
    static let analysisSampleStride = 4

    let validByteCount: Int
    let analyzedFrameCount: Int
    let voicedFrameCount: Int
    let peakAmplitude: Int

    /// 按通过活动阈值的 20ms 帧估算真实有声时长；用于完整性判断时排除长停顿。
    var voicedDurationSeconds: Double {
        Double(voicedFrameCount * Self.frameDurationMilliseconds) / 1_000
    }

    var hasMeaningfulSpeech: Bool {
        validByteCount >= Self.minimumAnalyzedAudioBytes
            && voicedFrameCount >= Self.minimumVoicedFrames
            && peakAmplitude >= Self.minimumPeakAmplitude
    }

    static func analyze(_ pcmData: Data) -> Self {
        let validByteCount = pcmData.count - (pcmData.count % MemoryLayout<Int16>.size)
        guard validByteCount > 0 else {
            return Self(
                validByteCount: 0,
                analyzedFrameCount: 0,
                voicedFrameCount: 0,
                peakAmplitude: 0
            )
        }

        var frameCount = 0
        var voicedFrames = 0
        var sessionPeak = 0
        let bytesPerFrame = samplesPerFrame * MemoryLayout<Int16>.size

        pcmData.withUnsafeBytes { rawBuffer in
            var frameStart = 0
            while frameStart < validByteCount {
                let frameEnd = min(frameStart + bytesPerFrame, validByteCount)
                var sampleOffset = frameStart
                var squaredSum = 0.0
                var sampleCount = 0
                var framePeak = 0

                // 每 20ms 帧抽样 80 个点，足以判断持续语音，同时避免长录音
                // 在停止阶段逐样本扫描造成可感知延迟。
                while sampleOffset + 1 < frameEnd {
                    let bits = UInt16(rawBuffer[sampleOffset])
                        | (UInt16(rawBuffer[sampleOffset + 1]) << 8)
                    let sample = Int(Int16(bitPattern: bits))
                    let amplitude = sample == Int(Int16.min)
                        ? Int(Int16.max) + 1
                        : abs(sample)
                    framePeak = max(framePeak, amplitude)
                    squaredSum += Double(sample) * Double(sample)
                    sampleCount += 1
                    sampleOffset += MemoryLayout<Int16>.size * analysisSampleStride
                }

                if sampleCount > 0 {
                    frameCount += 1
                    sessionPeak = max(sessionPeak, framePeak)
                    let rms = (squaredSum / Double(sampleCount)).squareRoot()
                    if framePeak >= minimumPeakAmplitude, rms >= minimumFrameRMS {
                        voicedFrames += 1
                    }
                }
                frameStart = frameEnd
            }
        }

        return Self(
            validByteCount: validByteCount,
            analyzedFrameCount: frameCount,
            voicedFrameCount: voicedFrames,
            peakAmplitude: sessionPeak
        )
    }
}
