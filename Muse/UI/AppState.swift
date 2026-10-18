import AppKit
import SwiftUI

// MARK: - Floating Bar Phase

enum FloatingBarPhase: Equatable {
    case hidden
    case preparing
    case recording
    case processing
    case done
    case copyFallback
    case error
}

// MARK: - Transcription Segment

struct TranscriptionSegment: Identifiable, Equatable {
    let id: UUID
    let text: String
    let isConfirmed: Bool

    init(text: String, isConfirmed: Bool) {
        self.id = UUID()
        self.text = text
        self.isConfirmed = isConfirmed
    }
}


// MARK: - Audio Level (isolated from @Observable to avoid high-frequency view invalidation)

@MainActor
final class AudioLevelMeter {
    /// Current mic level. Updated at audio-callback rate but NOT observed by SwiftUI,
    /// so it won't trigger view-tree diffs. Views read it inside Canvas/TimelineView draws.
    var current: Float = 0.0
}

// MARK: - App State

@Observable
@MainActor
final class AppState {

    // MARK: Floating Bar

    var barPhase: FloatingBarPhase = .hidden
    var segments: [TranscriptionSegment] = []
    var currentMode: ProcessingMode
    @ObservationIgnored let audioLevel = AudioLevelMeter()
    var recordingStartDate: Date?
    /// preparing 起点：观测「HUD 转很久才能输入」的实际耗时
    var preparingStartDate: Date?
    var availableModes: [ProcessingMode]
    var learningConfirmation: AutomaticLearningConfirmation?
    var learningUndo: AutomaticLearningUndo?
    var feedbackMessage: String = L("已完成", "Done")
    var processingFinishTime: Date?
    var copyFallbackWasCopied = false
    var voicePolishStage: VoicePolishStage?
    var isVoicePolishUnavailable = false
    var isRetryingVoicePolish = false
    var voicePolishUnavailableMessage: String?
    var isQwen3OnlyMode: Bool {
        SenseVoiceServerManager.currentPort == nil && SenseVoiceServerManager.currentQwen3Port != nil
    }

    // MARK: Panel Control (not observed by SwiftUI)

    @ObservationIgnored var onShowPanel: (() -> Void)?
    @ObservationIgnored var onHidePanel: (() -> Void)?
    @ObservationIgnored var onCopyFallbackVisibilityChange: ((Bool) -> Void)?
    @ObservationIgnored var onRetryVoicePolish: (() async -> Bool)?

    // MARK: Live Transcript (HUD only)

    @ObservationIgnored private var lastLiveTranscript: RecognitionTranscript?
    /// 服务端偶发在切句时让尚未确认的上一句从新帧中消失（09-29 实测火山 partial 28→4 字，
    /// 结束时才回归）。此处暂存已显示的那句，仅用于 HUD，不参与注入。
    @ObservationIgnored private var heldLiveText = ""
    @ObservationIgnored private var pendingLearningFeedback: AutomaticLearningFeedback?
    @ObservationIgnored private var pendingLearningUndo: AutomaticLearningUndo?
    @ObservationIgnored private var pendingLearningConfirmation: AutomaticLearningConfirmation?

    // MARK: Update Check

    var availableUpdates: [UpdateInfo] = []
    var hasUnseenUpdate: Bool = false

    // MARK: Setup

    var hasCompletedSetup: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKeys.hasCompletedSetup) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKeys.hasCompletedSetup) }
    }

    init(initialModes: [ProcessingMode]? = nil) {
        // 测试必须注入内存模式，避免读取或隔离真实用户的 modes.json。
        let modes = initialModes ?? ModeStorage().load()
        availableModes = modes
        let initialMode = modes.first(where: { $0.id == ProcessingMode.smartDirectId })
            ?? modes.first
            ?? .direct
        currentMode = initialModes == nil
            ? VoiceInputModes.resolve(initialMode, in: modes)
            : initialMode
    }

    // MARK: Actions

    func startRecording() {
        learningUndo = nil
        learningConfirmation = nil
        segments = []
        resetLiveTranscriptTracking()
        audioLevel.current = 0
        recordingStartDate = nil
        feedbackMessage = L("已完成", "Done")
        copyFallbackWasCopied = false
        resetVoicePolishProcessingState()
        onCopyFallbackVisibilityChange?(false)
        barPhase = .preparing
        preparingStartDate = Date()
        onShowPanel?()
    }

    func markRecordingReady() {
        guard barPhase == .preparing else { return }
        // 观测：偶发「HUD 红色图标转很久才能输入」——记录 preparing 实际耗时便于复现定位
        if let preparingStartDate {
            let elapsedMs = Int(Date().timeIntervalSince(preparingStartDate) * 1000)
            if elapsedMs > 800 {
                DebugFileLogger.log("preparing→recording 偏慢: \(elapsedMs)ms")
            }
        }
        preparingStartDate = nil
        audioLevel.current = 0
        recordingStartDate = Date()
        barPhase = .recording
    }

    func stopRecording() {
        switch barPhase {
        case .preparing:
            cancel()
        case .recording:
            processingFinishTime = nil
            resetVoicePolishProcessingState()
            withAnimation(TF.hudMorph) {
                barPhase = .processing
            }
        default:
            break
        }
    }

    /// 流式上传中断（REPAIR_PLAN B7a）：录音继续、文本不丢（停止后批量兜底），
    /// 在实时字幕区追加一条未确认段提示用户继续说话即可
    func showStreamingInterrupted() {
        guard barPhase == .recording else { return }
        let hint = L("（网络中断，松手后自动完整重识别）",
                     "(Connection lost — full re-recognition after you stop)")
        guard segments.last?.text != hint else { return }
        segments.append(TranscriptionSegment(text: hint, isConfirmed: false))
    }

    func setLiveTranscript(_ transcript: RecognitionTranscript) {
        updateHeldLiveText(previous: lastLiveTranscript, next: transcript)
        lastLiveTranscript = transcript

        if transcript.isFinal,
           !transcript.authoritativeText.isEmpty,
           transcript.authoritativeText != transcript.composedText {
            segments = [TranscriptionSegment(text: transcript.authoritativeText, isConfirmed: true)]
            return
        }

        segments = transcript.confirmedSegments.map {
            TranscriptionSegment(text: $0, isConfirmed: true)
        }
        if !heldLiveText.isEmpty {
            segments.append(TranscriptionSegment(text: heldLiveText, isConfirmed: false))
        }
        if !transcript.partialText.isEmpty {
            segments.append(TranscriptionSegment(text: transcript.partialText, isConfirmed: false))
        }
    }

    func showProcessingResult(_ result: String) {
        if result.isEmpty {
            cancel()
            return
        }
        copyFallbackWasCopied = false
        segments = [TranscriptionSegment(text: result, isConfirmed: true)]
        resetVoicePolishProcessingState()
    }

    func showVoicePolishStage(_ stage: VoicePolishStage) {
        guard barPhase == .processing, currentMode.kind == .voicePolish else { return }
        isVoicePolishUnavailable = false
        isRetryingVoicePolish = false
        voicePolishUnavailableMessage = nil
        voicePolishStage = stage
    }

    func showVoicePolishUnavailable(_ reason: VoicePolishFailureReason?) {
        guard barPhase == .processing, currentMode.kind == .voicePolish else { return }
        voicePolishStage = nil
        isVoicePolishUnavailable = true
        isRetryingVoicePolish = false
        switch reason {
        case .timeout:
            voicePolishUnavailableMessage = L(
                "润色超时，原转写已保留",
                "Polishing timed out. The transcript was preserved."
            )
        case .requestFailed:
            voicePolishUnavailableMessage = L(
                "润色服务暂时不可用，原转写已保留",
                "Polishing is temporarily unavailable. The transcript was preserved."
            )
        case .validationFailed:
            voicePolishUnavailableMessage = L(
                "这次润色未通过核对，原转写已保留",
                "This draft did not pass review. The transcript was preserved."
            )
        case .setupFailed, .none:
            voicePolishUnavailableMessage = L(
                "这次没有完成润色，原转写已保留",
                "Polishing did not finish. The transcript was preserved."
            )
        }
        onShowPanel?()
    }

    func retryVoicePolish() {
        guard isVoicePolishUnavailable, !isRetryingVoicePolish else { return }
        isRetryingVoicePolish = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let accepted = await self.onRetryVoicePolish?() ?? false
            guard self.barPhase == .processing,
                  self.currentMode.kind == .voicePolish else { return }
            if accepted {
                self.isVoicePolishUnavailable = false
                self.voicePolishUnavailableMessage = nil
                self.voicePolishStage = .analyzing
            } else {
                self.isRetryingVoicePolish = false
                self.isVoicePolishUnavailable = true
            }
        }
    }

    func finalize(text: String, outcome: InjectionOutcome) {
        guard !text.isEmpty else {
            cancel()
            return
        }
        segments = [TranscriptionSegment(text: text, isConfirmed: true)]
        resetVoicePolishProcessingState()
        if case .noFocusedInput(let copiedToClipboard) = outcome {
            showCopyFallback(message: outcome.completionMessage, copiedToClipboard: copiedToClipboard)
            return
        }
        showDone(message: outcome.completionMessage)
    }

    func showError(_ message: String) {
        learningUndo = nil
        learningConfirmation = nil
        feedbackMessage = message
        resetVoicePolishProcessingState()
        audioLevel.current = 0
        recordingStartDate = nil
        onCopyFallbackVisibilityChange?(false)
        barPhase = .error
        onShowPanel?()
        scheduleAutoHide(for: .error, delay: .seconds(1.8))
    }

    /// 忙碌时保留最近结果，当前录音或输出结束后再显示，不覆盖进行中的交互。
    func showAutomaticLearningFeedback(_ feedback: AutomaticLearningFeedback, undo: AutomaticLearningUndo? = nil, confirmation: AutomaticLearningConfirmation? = nil) {
        guard barPhase == .hidden || barPhase == .done else {
            pendingLearningFeedback = feedback
            pendingLearningUndo = undo
            pendingLearningConfirmation = confirmation
            return
        }
        pendingLearningFeedback = nil
        pendingLearningUndo = nil
        pendingLearningConfirmation = nil
        learningUndo = undo
        learningConfirmation = confirmation
        feedbackMessage = feedback.hudMessage(reserving: confirmation != nil ? 96 : (undo == nil ? 0 : 72))
        resetVoicePolishProcessingState()
        barPhase = .done
        onShowPanel?()
        scheduleAutoHide(for: .done, delay: confirmation != nil ? .seconds(8) : (undo == nil ? .seconds(2.8) : .seconds(5)))
    }

    func cancel() {
        learningUndo = nil
        learningConfirmation = nil
        pendingLearningUndo = nil
        pendingLearningConfirmation = nil
        pendingLearningFeedback = nil
        barPhase = .hidden
        segments = []
        resetLiveTranscriptTracking()
        audioLevel.current = 0
        copyFallbackWasCopied = false
        resetVoicePolishProcessingState()
        onCopyFallbackVisibilityChange?(false)
        onHidePanel?()
    }

    func showCancelled() {
        learningUndo = nil
        learningConfirmation = nil
        feedbackMessage = L("已取消", "Cancelled")
        resetVoicePolishProcessingState()
        audioLevel.current = 0
        recordingStartDate = nil
        onCopyFallbackVisibilityChange?(false)
        barPhase = .done
        scheduleAutoHide(for: .done, delay: .seconds(0.8))
    }

    func copyFallbackToClipboard() {
        let text = transcriptionText
        guard !text.isEmpty else {
            dismissCopyFallback()
            return
        }

        ClipboardLeaseCoordinator.shared.writeTextPermanently(text)
        copyFallbackWasCopied = true
        feedbackMessage = L("已复制", "Copied")
        scheduleAutoHide(for: .copyFallback, delay: .seconds(0.9))
    }

    func dismissCopyFallback() {
        cancel()
    }

    // MARK: Computed

    var transcriptionText: String {
        segments.map(\.text).joined()
    }

    func reconcileCurrentMode(for provider: ASRProvider) {
        let resolved = ASRProviderRegistry.resolvedMode(for: currentMode, provider: provider)
        guard resolved.id != currentMode.id else { return }
        currentMode = availableModes.first(where: { $0.id == resolved.id }) ?? resolved
    }

    // MARK: Private

    private var hideGeneration = 0

    private func resetLiveTranscriptTracking() {
        lastLiveTranscript = nil
        heldLiveText = ""
    }

    /// 确认段不变、partial 被一段更短且无关的新文本替换时，视为上一句被服务端暂时丢掉；
    /// 服务端新增确认段或给出最终结果后，一律以服务端文本为准。
    private func updateHeldLiveText(previous: RecognitionTranscript?, next: RecognitionTranscript) {
        guard let previous else { return }
        if next.isFinal || next.confirmedSegments.count > previous.confirmedSegments.count {
            heldLiveText = ""
            return
        }
        let dropped = previous.partialText
        guard next.confirmedSegments == previous.confirmedSegments,
              !dropped.isEmpty,
              next.partialText.count * 2 <= dropped.count,
              !dropped.contains(next.partialText)
        else { return }
        heldLiveText += dropped
    }

    private func resetVoicePolishProcessingState() {
        voicePolishStage = nil
        isVoicePolishUnavailable = false
        isRetryingVoicePolish = false
        voicePolishUnavailableMessage = nil
    }

    private func showDone(message: String = L("已完成", "Done")) {
        learningUndo = nil
        learningConfirmation = nil
        feedbackMessage = message
        resetVoicePolishProcessingState()
        copyFallbackWasCopied = false
        onCopyFallbackVisibilityChange?(false)
        barPhase = .done
        scheduleAutoHide(for: .done, delay: .seconds(0.8))
    }

    private func showCopyFallback(message: String, copiedToClipboard: Bool) {
        learningUndo = nil
        learningConfirmation = nil
        feedbackMessage = message
        copyFallbackWasCopied = copiedToClipboard
        audioLevel.current = 0
        recordingStartDate = nil
        withAnimation(TF.hudMorph) {
            barPhase = .copyFallback
        }
        onCopyFallbackVisibilityChange?(true)
        onShowPanel?()
    }

    private func scheduleAutoHide(for phase: FloatingBarPhase, delay: Duration) {
        hideGeneration += 1
        let myGeneration = hideGeneration
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard barPhase == phase, hideGeneration == myGeneration else { return }
            barPhase = .hidden
            if phase == .copyFallback {
                copyFallbackWasCopied = false
                onCopyFallbackVisibilityChange?(false)
            }
            if let feedback = pendingLearningFeedback {
                showAutomaticLearningFeedback(feedback, undo: pendingLearningUndo, confirmation: pendingLearningConfirmation)
            } else {
                onHidePanel?()
            }
        }
    }
}

// MARK: - FloatingBarState Conformance

extension AppState: FloatingBarState {}

extension Notification.Name {
    static let modesDidChange = Notification.Name("MuseModesDidChange")
    static let asrProviderDidChange = Notification.Name("MuseASRProviderDidChange")
    static let hotkeyRecordingDidStart = Notification.Name("MuseHotkeyRecordingDidStart")
    static let hotkeyRecordingDidEnd = Notification.Name("MuseHotkeyRecordingDidEnd")
    static let navigateToMode = Notification.Name("MuseNavigateToMode")
    static let navigateToTab = Notification.Name("MuseNavigateToTab")
    static let selectMode = Notification.Name("MuseSelectMode")
}
