import AppKit
import XCTest
@testable import Muse

@MainActor
final class AppStateTests: XCTestCase {
    func testUndoActionFollowsItsFeedbackAndClearsForNewRecording() async {
        let state = AppState(initialModes: ProcessingMode.defaults)
        let undo = AutomaticLearningUndo {}
        let feedback = AutomaticLearningFeedback.learned([
            TerminologyCorrectionCandidate(alias: "cloud", canonical: "Claude")
        ], hasConflict: false)
        state.showAutomaticLearningFeedback(feedback, undo: undo)
        XCTAssertTrue(state.learningUndo === undo)
        await undo.perform()
        XCTAssertTrue(undo.didUndo)
        XCTAssertNotNil(undo.message)
        state.startRecording()
        XCTAssertNil(state.learningUndo)
        state.cancel()
    }

    func testUndoButtonBudgetPreservesBothLongWords() {
        let feedback = AutomaticLearningFeedback.learned([
            TerminologyCorrectionCandidate(alias: String(repeating: "错词", count: 32),
                                           canonical: String(repeating: "正词", count: 32))
        ], hasConflict: false)
        let text = feedback.hudMessage(reserving: 72)
        XCTAssertTrue(text.contains("错词"))
        XCTAssertTrue(text.contains("正词"))
        XCTAssertLessThanOrEqual((text as NSString).size(withAttributes: [.font: TF.hudNSFontTitle]).width + 84 + 72,
                                 TF.barWidth)
    }

    func testLearningFeedbackShowsSpecificSuccessAndFailure() {
        let state = AppState(initialModes: ProcessingMode.defaults)
        let success = AutomaticLearningFeedback.learned(
            [TerminologyCorrectionCandidate(alias: "cloud", canonical: "Claude")], hasConflict: false
        )
        state.showAutomaticLearningFeedback(success)
        XCTAssertEqual(state.barPhase, .done)
        XCTAssertEqual(state.feedbackMessage, success.message)
        XCTAssertTrue(state.feedbackMessage.contains("Claude"))
        XCTAssertTrue(state.feedbackMessage.contains("cloud → Claude"))
        state.showAutomaticLearningFeedback(.failed)
        XCTAssertEqual(state.feedbackMessage, AutomaticLearningFeedback.failed.message)
        XCTAssertFalse(AutomaticLearningFeedback.failed.didPersist)
        state.cancel()
    }

    func testLearningFeedbackWaitsForCurrentRecordingToFinish() async throws {
        let state = AppState(initialModes: ProcessingMode.defaults)
        state.startRecording()
        state.markRecordingReady()
        let start = state.recordingStartDate
        state.showAutomaticLearningFeedback(.noTerms)
        XCTAssertEqual(state.barPhase, .recording)
        XCTAssertEqual(state.recordingStartDate, start)
        state.stopRecording()
        XCTAssertEqual(state.barPhase, .processing)
        state.finalize(text: "新的一次输入", outcome: .inserted)
        let deadline = ContinuousClock.now + .seconds(3)
        while state.feedbackMessage != AutomaticLearningFeedback.noTerms.message, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(state.barPhase, .done)
        XCTAssertEqual(state.feedbackMessage, AutomaticLearningFeedback.noTerms.message)
        state.cancel()
    }

    func testLatestLearningResultRetainsReasonForVocabularyPage() {
        let status = AutomaticLearningStatus()
        status.update(.rangeUnavailable)
        XCTAssertEqual(status.latest, .rangeUnavailable)
        let learned = AutomaticLearningFeedback.learned(
            [TerminologyCorrectionCandidate(alias: "cloud", canonical: "Claude")], hasConflict: false
        )
        status.update(learned)
        XCTAssertEqual(status.latest?.detail, "cloud → Claude")
    }

    func testAutomaticLearningKeepsSameUndoOnHUDAndVocabularyWithoutExtraAction() {
        let state = AppState(initialModes: ProcessingMode.defaults)
        defer { state.cancel() }
        let undo = AutomaticLearningUndo { }
        let feedback = AutomaticLearningFeedback.learned([.init(alias: "Tablets", canonical: "Typeless")], hasConflict: false)
        state.showAutomaticLearningFeedback(feedback, undo: undo)
        XCTAssertEqual(state.barPhase, .done)
        XCTAssertTrue(state.learningUndo === undo)
        XCTAssertTrue(state.feedbackMessage.contains("Tablets → Typeless"))
        XCTAssertTrue(feedback.didPersist)
        let status = AutomaticLearningStatus()
        status.update(feedback, undo: undo)
        XCTAssertTrue(status.undo === undo)
        state.startRecording()
        XCTAssertNil(state.learningUndo, "录音时不能让上次撤销按钮覆盖当前操作")
        XCTAssertTrue(status.undo === undo, "词库保留同一精确撤销收据")
    }

    func testLearningFeedbackRetainsPairsForMultipleLongAndConflictingCorrections() {
        withChineseAppLanguage {
            let pairs = [
                TerminologyCorrectionCandidate(alias: "cloud", canonical: "Claude"),
                TerminologyCorrectionCandidate(alias: "Type less", canonical: "Typeless")
            ]
            for conflict in [false, true] {
                let feedback = AutomaticLearningFeedback.learned(pairs, hasConflict: conflict)
                XCTAssertTrue(feedback.message.contains("cloud → Claude"))
                XCTAssertTrue(feedback.message.contains("Type less → Typeless"))
                XCTAssertTrue(feedback.hudMessage.contains("cloud → Claude"))
                XCTAssertTrue(feedback.hudMessage.contains("2"))
                XCTAssertEqual(feedback.hudMessage.contains("冲突"), conflict)
            }
            let alias = String(repeating: "识别错词", count: 16)
            let canonical = String(repeating: "正确写法", count: 16)
            let feedback = AutomaticLearningFeedback.learned([
                TerminologyCorrectionCandidate(alias: alias, canonical: canonical)
            ], hasConflict: false)
            XCTAssertTrue(feedback.message.contains(alias + " → " + canonical))
            XCTAssertTrue(feedback.hudMessage.contains("识别错词"))
            XCTAssertTrue(feedback.hudMessage.contains("正确写法"))
            XCTAssertTrue(feedback.hudMessage.contains("… → "))
            let width = (feedback.hudMessage as NSString).size(withAttributes: [.font: TF.hudNSFontTitle]).width
            XCTAssertLessThanOrEqual(width + 84, TF.barWidth)
        }
    }

    private func withChineseAppLanguage(_ action: () -> Void) {
        let savedLanguage = UserDefaults.standard.string(forKey: DefaultsKeys.language)
        UserDefaults.standard.set(AppLanguage.zh.rawValue, forKey: DefaultsKeys.language)
        defer {
            if let savedLanguage {
                UserDefaults.standard.set(savedLanguage, forKey: DefaultsKeys.language)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKeys.language)
            }
        }
        action()
    }

    func testStartRecordingTransitionsToPreparing() {
        let appState = AppState(initialModes: ProcessingMode.defaults)
        appState.startRecording()

        XCTAssertEqual(appState.barPhase, .preparing)
    }

    func testStopRecordingIgnoredWhenNotRecording() {
        let appState = AppState(initialModes: ProcessingMode.defaults)
        appState.currentMode = .smartDirect
        appState.cancel()

        appState.stopRecording()

        XCTAssertEqual(appState.barPhase, .hidden)
    }

    func testStopRecordingCancelsWhenPreparing() {
        let appState = AppState(initialModes: ProcessingMode.defaults)
        appState.startRecording()

        appState.stopRecording()

        XCTAssertEqual(appState.barPhase, .hidden)
    }

    func testStopRecordingTransitionsToProcessingWhenRecording() {
        let appState = AppState(initialModes: ProcessingMode.defaults)
        appState.currentMode = .smartDirect
        appState.startRecording()
        appState.markRecordingReady()

        appState.stopRecording()

        XCTAssertEqual(appState.barPhase, .processing)
    }

    func testStopRecordingTransitionsDirectModeToProcessing() {
        let appState = AppState(initialModes: ProcessingMode.defaults)
        appState.currentMode = .direct
        appState.startRecording()
        appState.markRecordingReady()

        appState.stopRecording()

        XCTAssertEqual(appState.barPhase, .processing)
    }

    func testSetLiveTranscriptReplacesExistingConfirmedSegments() {
        let appState = AppState(initialModes: ProcessingMode.defaults)
        appState.setLiveTranscript(
            RecognitionTranscript(
                confirmedSegments: ["我想", "买咖"],
                partialText: "",
                authoritativeText: "我想买咖",
                isFinal: false
            )
        )
        appState.setLiveTranscript(
            RecognitionTranscript(
                confirmedSegments: ["我想", "买咖啡"],
                partialText: "",
                authoritativeText: "我想买咖啡",
                isFinal: false
            )
        )

        XCTAssertEqual(appState.segments.map(\.text), ["我想", "买咖啡"])
        XCTAssertEqual(appState.transcriptionText, "我想买咖啡")
    }

    func testLiveTranscriptKeepsSentenceDroppedByServerUntilConfirmed() {
        let appState = AppState(initialModes: ProcessingMode.defaults)
        appState.startRecording()
        appState.setLiveTranscript(live(partial: "这是前面已经显示出来的一整句话"))
        // 服务端切句时新帧只剩下一句的开头，前一句既未确认也不在帧内。
        appState.setLiveTranscript(live(partial: "然后"))
        XCTAssertEqual(appState.transcriptionText, "这是前面已经显示出来的一整句话然后")

        appState.setLiveTranscript(live(partial: "然后我们"))
        XCTAssertEqual(appState.transcriptionText, "这是前面已经显示出来的一整句话然后我们")

        appState.setLiveTranscript(live(confirmed: ["这是前面已经显示出来的一整句话，然后我们"]))
        XCTAssertEqual(appState.transcriptionText, "这是前面已经显示出来的一整句话，然后我们")
    }

    func testLiveTranscriptRevisionIsNotHeld() {
        let appState = AppState(initialModes: ProcessingMode.defaults)
        appState.startRecording()
        appState.setLiveTranscript(live(partial: "那个我想"))
        appState.setLiveTranscript(live(partial: "我想"))
        XCTAssertEqual(appState.transcriptionText, "我想")

        appState.setLiveTranscript(live(partial: "今天天气不错"))
        appState.setLiveTranscript(live(partial: "今天天气"))
        XCTAssertEqual(appState.transcriptionText, "今天天气")
    }

    func testLiveTranscriptHeldTextResetsForNewRecording() {
        let appState = AppState(initialModes: ProcessingMode.defaults)
        appState.startRecording()
        appState.setLiveTranscript(live(partial: "这是前面已经显示出来的一整句话"))
        appState.setLiveTranscript(live(partial: "然后"))
        appState.cancel()

        appState.startRecording()
        appState.setLiveTranscript(live(partial: "新的"))
        XCTAssertEqual(appState.transcriptionText, "新的")
    }

    private func live(confirmed: [String] = [], partial: String = "") -> RecognitionTranscript {
        RecognitionTranscript(
            confirmedSegments: confirmed,
            partialText: partial,
            authoritativeText: (confirmed + [partial]).joined(),
            isFinal: false
        )
    }

    func testSetLiveTranscriptUsesAuthoritativeFinalTextWhenDifferent() {
        let appState = AppState(initialModes: ProcessingMode.defaults)
        appState.setLiveTranscript(
            RecognitionTranscript(
                confirmedSegments: ["deep seek"],
                partialText: "",
                authoritativeText: "DeepSeek",
                isFinal: true
            )
        )

        XCTAssertEqual(appState.segments.count, 1)
        XCTAssertEqual(appState.segments.first?.text, "DeepSeek")
        XCTAssertTrue(appState.segments.first?.isConfirmed == true)
    }

    func testFinalizeShowsClipboardFallbackMessage() {
        withChineseAppLanguage {
            let appState = AppState(initialModes: ProcessingMode.defaults)

            appState.finalize(text: "测试文本", outcome: .copiedToClipboard)

            XCTAssertEqual(appState.barPhase, .done)
            XCTAssertEqual(appState.feedbackMessage, "已粘贴到剪贴板")
            XCTAssertEqual(appState.transcriptionText, "测试文本")
        }
    }

    func testFinalizeWithoutFocusedInputShowsCopyFallbackCard() {
        withChineseAppLanguage {
            let appState = AppState(initialModes: ProcessingMode.defaults)

            appState.finalize(text: "测试文本", outcome: .noFocusedInput(copiedToClipboard: false))

            XCTAssertEqual(appState.barPhase, .copyFallback)
            XCTAssertEqual(appState.feedbackMessage, "未找到输入位置")
            XCTAssertFalse(appState.copyFallbackWasCopied)
            XCTAssertEqual(appState.transcriptionText, "测试文本")
        }
    }

    func testCopyFallbackCopiesTextAndMarksCopied() {
        withChineseAppLanguage {
            let snapshot = capturePasteboardItems()
            defer { restorePasteboardItems(snapshot) }
            let appState = AppState(initialModes: ProcessingMode.defaults)
            appState.finalize(text: "测试文本", outcome: .noFocusedInput(copiedToClipboard: false))

            appState.copyFallbackToClipboard()

            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "测试文本")
            XCTAssertTrue(appState.copyFallbackWasCopied)
            XCTAssertEqual(appState.feedbackMessage, "已复制")
        }
    }

    func testShowErrorDisplaysErrorPhaseAndMessage() {
        let appState = AppState(initialModes: ProcessingMode.defaults)

        appState.showError("找不到麦克风")

        XCTAssertEqual(appState.barPhase, .error)
        XCTAssertEqual(appState.feedbackMessage, "找不到麦克风")
    }

    func testPolishCompletionClearsProcessingState() {
        let appState = AppState(initialModes: ProcessingMode.defaults)
        appState.currentMode = .formalWriting
        appState.startRecording()
        appState.markRecordingReady()
        appState.stopRecording()
        appState.showVoicePolishStage(.polishing)

        appState.showProcessingResult("已经完成的润色结果")

        XCTAssertNil(appState.voicePolishStage)
        XCTAssertFalse(appState.isVoicePolishUnavailable)
        XCTAssertEqual(appState.transcriptionText, "已经完成的润色结果")
    }

    func testCancelledPolishCannotRestoreProcessingOrFailureUI() {
        let appState = AppState(initialModes: ProcessingMode.defaults)
        appState.currentMode = .formalWriting
        appState.startRecording()
        appState.markRecordingReady()
        appState.stopRecording()
        appState.showVoicePolishStage(.polishing)

        appState.showCancelled()
        appState.showVoicePolishStage(.rendering)
        appState.showVoicePolishUnavailable(.timeout)

        XCTAssertNil(appState.voicePolishStage)
        XCTAssertFalse(appState.isVoicePolishUnavailable)
        XCTAssertNil(appState.voicePolishUnavailableMessage)
        XCTAssertNotEqual(appState.barPhase, .processing)
    }

    func testVoicePolishUnavailableWaitsForExplicitRetry() async {
        let appState = AppState(initialModes: ProcessingMode.defaults)
        appState.currentMode = .formalWriting
        appState.startRecording()
        appState.markRecordingReady()
        appState.stopRecording()

        appState.showVoicePolishUnavailable(.validationFailed)

        XCTAssertEqual(appState.barPhase, .processing)
        XCTAssertTrue(appState.isVoicePolishUnavailable)
        XCTAssertTrue(appState.voicePolishUnavailableMessage?.contains(L("原转写已保留", "The transcript was preserved.")) == true)

        var retryCount = 0
        appState.onRetryVoicePolish = {
            retryCount += 1
            return true
        }
        appState.retryVoicePolish()
        for _ in 0..<20 where retryCount == 0 {
            await Task.yield()
        }

        XCTAssertEqual(retryCount, 1)
        XCTAssertFalse(appState.isVoicePolishUnavailable)
        XCTAssertEqual(appState.voicePolishStage, .analyzing)
    }

    func testReconcileCurrentModeKeepsSupportedCustomModeForQuickOnlyProvider() {
        let appState = AppState(initialModes: ProcessingMode.defaults)
        let customMode = ProcessingMode(
            id: UUID(),
            name: "结构化",
            prompt: "Rewrite {text}",
            isBuiltin: false
        )
        appState.availableModes.append(customMode)
        appState.currentMode = customMode

        appState.reconcileCurrentMode(for: .volcano)

        XCTAssertEqual(appState.currentMode.id, customMode.id)
    }

    private func capturePasteboardItems() -> [NSPasteboardItem] {
        NSPasteboard.general.pasteboardItems?.map { item in
            let copiedItem = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copiedItem.setData(data, forType: type)
                }
            }
            return copiedItem
        } ?? []
    }

    private func restorePasteboardItems(_ items: [NSPasteboardItem]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
