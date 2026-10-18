import Foundation
import SwiftUI

/// Timeline-driven animation controller that cycles FloatingBarView through
/// a demo loop: preparing -> recording (text flows in) -> processing -> done -> hidden -> repeat.
@Observable
@MainActor
final class DemoState {

    // MARK: FloatingBarState properties

    var barPhase: FloatingBarPhase = .hidden
    var segments: [TranscriptionSegment] = []
    @ObservationIgnored let audioLevel = AudioLevelMeter()
    var currentMode: ProcessingMode = .direct
    var feedbackMessage: String = L("已完成", "Done")
    var processingFinishTime: Date?
    var recordingStartDate: Date?
    var copyFallbackWasCopied = false
    var voicePolishStage: VoicePolishStage?

    var transcriptionText: String {
        segments.map(\.text).joined()
    }

    func copyFallbackToClipboard() {}

    func dismissCopyFallback() {
        stop()
    }

    // MARK: Private

    private var demoTask: Task<Void, Never>?
    private var audioTimer: Timer?

    // MARK: Demo Control

    /// Starts the auto-looping quick mode demo animation.
    func startQuickModeDemo() {
        stop()
        demoTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runOneCycle()
            }
        }
    }

    /// 样式面板按需播放一轮，结束后停在录音预览，避免持续后台循环。
    func playQuickModeDemoOnce() {
        stop()
        demoTask = Task { [weak self] in
            guard let self else { return }
            await self.runOneCycle()
            guard !Task.isCancelled else { return }
            self.showFrozenRecordingPreview(text: L("把此刻的想法，清晰留下来", "Keep this thought, clearly"))
        }
    }

    /// Stops all timers and resets state.
    func stop() {
        demoTask?.cancel()
        demoTask = nil
        stopAudioSimulation()
        barPhase = .hidden
        segments = []
        audioLevel.current = 0
        recordingStartDate = nil
        processingFinishTime = nil
    }

    func showFrozenRecordingPreview(text: String) {
        stop()
        segments = [TranscriptionSegment(text: text, isConfirmed: false)]
        barPhase = .recording
        recordingStartDate = Date()
        audioLevel.current = 0.32
    }

    // MARK: - One Demo Cycle

    private func runOneCycle() async {
        // 1. 直接进录音态：蓝色波形光标先空等一下（模拟「按下即录、还没开口」），不再先转红圈
        segments = []
        audioLevel.current = 0
        recordingStartDate = Date()
        barPhase = .recording
        startAudioSimulation()
        guard await sleep(0.9) else { return }

        // 2. 开口说话：文字分段流入
        let demoSegments = [
            L("突然想到一个不错的点子", "Just caught a great idea"),
            L("突然想到一个不错的点子，关于时间管理", "Just caught a great idea about time management"),
            L("突然想到一个不错的点子，关于时间管理的常见误区", "Just caught a great idea about common time-management traps"),
        ]

        for text in demoSegments {
            guard !Task.isCancelled else { return }
            segments = [TranscriptionSegment(text: text, isConfirmed: text == demoSegments.last)]
            guard await sleep(0.8) else { return }
        }

        stopAudioSimulation()

        // 3. Processing for 0.5s
        processingFinishTime = nil
        barPhase = .processing
        guard await sleep(0.5) else { return }

        // 4. Done "已完成" for 1.5s
        feedbackMessage = L("已完成", "Done")
        barPhase = .done
        guard await sleep(1.5) else { return }

        // 5. Hidden for 1.5s
        barPhase = .hidden
        segments = []
        recordingStartDate = nil
        guard await sleep(1.5) else { return }
    }

    // MARK: - Audio Simulation

    private func startAudioSimulation() {
        stopAudioSimulation()
        audioTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.audioLevel.current = Float.random(in: 0.15...0.5)
            }
        }
    }

    private func stopAudioSimulation() {
        audioTimer?.invalidate()
        audioTimer = nil
        audioLevel.current = 0
    }

    // MARK: - Helpers

    /// Returns false if cancelled during sleep.
    private func sleep(_ seconds: Double) async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

// MARK: - FloatingBarState Conformance

extension DemoState: FloatingBarState {
    var isQwen3OnlyMode: Bool { false }
}
