import XCTest
@testable import Dal

final class SettingsInformationArchitectureTests: XCTestCase {
    func testLightweightSettingsKeepFiveDestinations() {
        XCTAssertEqual(SettingsTab.allCases, [.general, .modes, .vocabulary, .models, .about])
        XCTAssertEqual(SettingsTab.modes.displayName, L("输出模式", "Output Modes"))
        XCTAssertEqual(SettingsTab.vocabulary.displayName, L("我的词库", "My Vocabulary"))
    }

    func testVoicePolishAndDirectModesCannotBeDeleted() {
        XCTAssertFalse(ProcessingMode.direct.isUserDeletable)
        XCTAssertFalse(ProcessingMode.formalWriting.isUserDeletable)
        XCTAssertTrue(ProcessingMode.smartDirect.isUserDeletable)
    }

    func testTerminologyAndStyleLearningSwitchesRemainIndependent() {
        let suite = "SettingsInformationArchitectureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        VoicePolishSettings.setTerminologyLearningEnabled(false, defaults: defaults)
        VoicePolishSettings.setPersonalizationEnabled(true, defaults: defaults)

        XCTAssertFalse(VoicePolishSettings.terminologyLearningEnabled(defaults: defaults))
        XCTAssertTrue(VoicePolishSettings.personalizationEnabled(defaults: defaults))

        VoicePolishSettings.setTerminologyLearningEnabled(true, defaults: defaults)
        VoicePolishSettings.setPersonalizationEnabled(false, defaults: defaults)

        XCTAssertTrue(VoicePolishSettings.terminologyLearningEnabled(defaults: defaults))
        XCTAssertFalse(VoicePolishSettings.personalizationEnabled(defaults: defaults))
    }

    func testRecentInputContextDefaultsOnAndCanBeChanged() {
        let suite = "SettingsRecentContextTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(VoicePolishSettings.recentInputContextEnabled(defaults: defaults))
        VoicePolishSettings.setRecentInputContextEnabled(true, defaults: defaults)
        XCTAssertTrue(VoicePolishSettings.recentInputContextEnabled(defaults: defaults))
    }

    func testCorrectionSheetRestoresSavedCorrectionInsteadOfCurrentDefaults() {
        let record = HistoryRecord(
            id: "history-1",
            createdAt: Date(timeIntervalSince1970: 100),
            durationSeconds: 2,
            rawText: "泰普莱斯很好用",
            processingMode: "语音润色",
            processedText: "泰普莱斯很好用。",
            finalText: "泰普莱斯很好用。",
            status: "voice_polish_success",
            characterCount: 9
        )
        let saved = VoicePolishCorrectionRecord(
            id: "correction-1",
            historyID: record.id,
            createdAt: Date(timeIntervalSince1970: 200),
            scene: .workChat,
            sourceText: record.rawText,
            generatedText: record.finalText,
            correctedText: "Typeless 很好用。",
            learnStyle: true,
            learnTerminology: false
        )

        let values = VoicePolishCorrectionInitialValues(
            record: record,
            existingCorrection: saved,
            defaultLearnTerminology: true,
            defaultLearnStyle: false
        )

        XCTAssertEqual(values.correctedText, "Typeless 很好用。")
        XCTAssertEqual(values.scene, .workChat)
        XCTAssertFalse(values.learnTerminology)
        XCTAssertTrue(values.learnStyle)
    }

    func testCorrectionSheetUsesDefaultsForFirstCorrection() {
        let record = HistoryRecord(
            id: "history-2",
            createdAt: Date(timeIntervalSince1970: 100),
            durationSeconds: 1,
            rawText: "原始文本",
            processingMode: nil,
            processedText: nil,
            finalText: "原始文本",
            status: "voice_polish_success",
            characterCount: 4
        )

        let values = VoicePolishCorrectionInitialValues(
            record: record,
            existingCorrection: nil,
            defaultLearnTerminology: true,
            defaultLearnStyle: false
        )

        XCTAssertEqual(values.correctedText, record.finalText)
        XCTAssertEqual(values.scene, .unknown)
        XCTAssertTrue(values.learnTerminology)
        XCTAssertFalse(values.learnStyle)
    }

    func testTerminologyBundleIdentifierValidation() {
        let valid = [
            "com.openai.chat",
            "pro.daliang.muse",
            "com.example.my-app",
            "  com.example.App2  "
        ]
        let invalid = [
            "",
            "Dal",
            ".com.example",
            "com..example",
            "com.example.",
            "com.example.my_app",
            "com.例子.app",
            "com.-example.app",
            "com.example-.app"
        ]

        for bundleID in valid {
            XCTAssertTrue(
                TerminologyBundleIdentifierValidator.isValid(bundleID),
                "应接受 \(bundleID)"
            )
        }
        for bundleID in invalid {
            XCTAssertFalse(
                TerminologyBundleIdentifierValidator.isValid(bundleID),
                "应拒绝 \(bundleID)"
            )
        }
    }

}
