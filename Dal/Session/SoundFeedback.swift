import AppKit
import AVFoundation
import os

/// Synthesized and bundled audio feedback tones.
enum SoundFeedback {

    private struct ToneSpec {
        let tones: [(frequency: Double, duration: Double)]
        let volume: Float
        let label: String
    }

    /// REPAIR_PLAN J11（D3 收口）：AVAudioPlayer 无 Sendable 标注，缓存收进锁。
    /// J21 回归教训：系统音频栈可能让 play()/beep 阻塞数秒，入口必须只入队，
    /// 不能在主线程同步播放，否则菜单栏点击与热键事件会一起卡住。
    private struct Cache {
        var hasWarmedUp = false
        var players: [String: AVAudioPlayer] = [:]
    }
    private static let cache = OSAllocatedUnfairLock(uncheckedState: Cache())
    private static let playbackQueue = DispatchQueue(label: "pro.daliang.muse.sound-feedback")
    /// 系统音频栈真阻塞时，旧提示音会堆在串行队列里。解堵后补播已经失去意义，
    /// 还可能连续占用 CoreAudio；超过此等待时间的请求直接丢弃，只保留新请求。
    private static let maximumPlaybackQueueDelay: TimeInterval = 0.5

    private static let startSpec = ToneSpec(
        tones: [
            (frequency: 587, duration: 0.06),
            (frequency: 880, duration: 0.09),
        ],
        volume: 0.52,
        label: "start"
    )

    private static let stopSpec = ToneSpec(
        tones: [
            (frequency: 740, duration: 0.04),
            (frequency: 1175, duration: 0.06),
        ],
        volume: 0.3,
        label: "stop"
    )

    private static let errorSpec = ToneSpec(
        tones: [
            (frequency: 330, duration: 0.08),
            (frequency: 220, duration: 0.1),
        ],
        volume: 0.35,
        label: "error"
    )

    // MARK: - Public API

    static func warmUp() {
        playbackQueue.async {
            let firstWarmUp = cache.withLock { state -> Bool in
                guard !state.hasWarmedUp else { return false }
                state.hasWarmedUp = true
                return true
            }
            guard firstWarmUp else { return }
            AppLogger.log("[SoundFeedback] warmUp")
            DebugFileLogger.log("sound warmUp")
            preparePlayersIfNeeded()
        }
    }

    /// 固定播放默认开始提示音。
    static func playStart() {
        AppLogger.log("[SoundFeedback] playStart")
        DebugFileLogger.log("sound playStart")
        play(spec: startSpec)
    }

    /// 固定播放默认结束提示音。
    static func playStop() {
        AppLogger.log("[SoundFeedback] playStop")
        DebugFileLogger.log("sound playStop invoked")
        play(spec: stopSpec)
    }

    /// Low descending fifth (330→220 Hz). Unmistakable but not harsh.
    static func playError() {
        AppLogger.log("[SoundFeedback] playError")
        DebugFileLogger.log("sound playError invoked")
        play(spec: errorSpec)
    }

    // MARK: - Synthesized Sound Playback

    private static func play(
        spec: ToneSpec
    ) {
        let requestedAt = Date()
        playbackQueue.async {
            let now = Date()
            guard !shouldDropQueuedPlayback(
                requestedAt: requestedAt,
                now: now,
                maximumDelay: maximumPlaybackQueueDelay
            ) else {
                let queueDelay = now.timeIntervalSince(requestedAt)
                DebugFileLogger.log("sound \(spec.label) skipped: stale queue delay \(String(format: "%.3f", queueDelay))s")
                return
            }
            playNow(spec: spec)
        }
    }

    private static func playNow(spec: ToneSpec) {
        let startedAt = Date()
        do {
            let didPlay = try playWithCachedPlayer(spec: spec)
            let elapsed = Date().timeIntervalSince(startedAt)

            AppLogger.log("[SoundFeedback] \(spec.label) play() => \(didPlay ? "true" : "false")")
            DebugFileLogger.log("sound \(spec.label) play() => \(didPlay) +\(String(format: "%.3f", elapsed))s")
            guard didPlay else {
                DebugFileLogger.log("sound \(spec.label) play returned false; no retry")
                return
            }
        } catch {
            AppLogger.log("[SoundFeedback] \(spec.label) init failed: \(String(describing: error))")
            DebugFileLogger.log("sound \(spec.label) init failed: \(String(describing: error))")
        }
    }

    static func shouldDropQueuedPlayback(
        requestedAt: Date,
        now: Date,
        maximumDelay: TimeInterval
    ) -> Bool {
        now.timeIntervalSince(requestedAt) > maximumDelay
    }

    private static func preparePlayersIfNeeded() {
        do {
            _ = try preparedPlayer(for: startSpec)
            _ = try preparedPlayer(for: stopSpec)
            _ = try preparedPlayer(for: errorSpec)
        } catch {
            DebugFileLogger.log("sound preparePlayersIfNeeded failed: \(String(describing: error))")
        }
    }

    private static func preparedPlayer(for spec: ToneSpec) throws -> AVAudioPlayer {
        if let player = cache.withLock({ $0.players[spec.label] }) {
            return player
        }

        // 构建在锁外（波形合成属 CPU 工作）；并发重复构建幂等，后写覆盖无害
        let player = try AVAudioPlayer(data: buildToneData(for: spec))
        player.prepareToPlay()
        cache.withLock { $0.players[spec.label] = player }
        return player
    }

    private static func playWithCachedPlayer(spec: ToneSpec) throws -> Bool {
        let player = try preparedPlayer(for: spec)
        player.stop()
        player.currentTime = 0
        player.numberOfLoops = 0
        player.volume = spec.volume
        player.prepareToPlay()
        return player.play()
    }

    private static func buildToneData(for spec: ToneSpec) -> Data {
        let sampleRate = 44100.0
        var samples = [Int16]()

        for tone in spec.tones {
            let frameCount = Int(tone.duration * sampleRate)
            for i in 0..<frameCount {
                let t = Double(i) / sampleRate
                let envelope = sin(.pi * t / tone.duration)
                let value = sin(2.0 * .pi * tone.frequency * t) * envelope * 0.5
                samples.append(Int16(value * 32767))
            }
        }

        return buildWAV(samples: samples, sampleRate: Int(sampleRate))
    }

    // MARK: - WAV Builder

    private static func buildWAV(samples: [Int16], sampleRate: Int) -> Data {
        let dataSize = samples.count * 2
        let fileSize = 36 + dataSize

        var wav = Data(capacity: 44 + dataSize)

        // RIFF header
        wav.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        wav.appendLE(UInt32(fileSize))
        wav.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // fmt chunk (16 bytes, PCM)
        wav.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        wav.appendLE(UInt32(16))
        wav.appendLE(UInt16(1))                    // PCM format
        wav.appendLE(UInt16(1))                    // mono
        wav.appendLE(UInt32(sampleRate))
        wav.appendLE(UInt32(sampleRate * 2))       // byte rate
        wav.appendLE(UInt16(2))                    // block align
        wav.appendLE(UInt16(16))                   // bits per sample

        // data chunk
        wav.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        wav.appendLE(UInt32(dataSize))
        for sample in samples {
            wav.appendLE(sample)
        }

        return wav
    }
}

// MARK: - Data Helper

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
