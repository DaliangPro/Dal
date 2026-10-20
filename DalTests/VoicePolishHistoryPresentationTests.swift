import XCTest
@testable import Dal

final class VoicePolishHistoryPresentationTests: XCTestCase {
    func testHistoryShowsRecordedModeNamesWithoutGuessingLegacyModes() {
        XCTAssertEqual(
            historyRecord(mode: ProcessingMode.direct.name).processingModeDisplayName,
            L("直出", "Direct")
        )
        XCTAssertEqual(
            historyRecord(mode: ProcessingMode.direct.name, status: "voice_polish_success").processingModeDisplayName,
            L("轻度润色", "Light Polish")
        )
        for name in [ProcessingMode.lightPolish.name, ProcessingMode.formalWriting.name,
                     "语音润色", "我的自定义工作表达"] {
            let record = historyRecord(mode: name)
            XCTAssertEqual(record.processingModeDisplayName, name)
        }
        XCTAssertNil(historyRecord(mode: nil).processingModeDisplayName)
        XCTAssertNil(historyRecord(mode: " ").processingModeDisplayName)
    }

    private func historyRecord(mode: String?, status: String = "completed") -> HistoryRecord {
        HistoryRecord(
            id: "mode-label", createdAt: Date(), durationSeconds: 1,
            rawText: "原文", processingMode: mode, processedText: nil,
            finalText: "原文", status: status, characterCount: 2
        )
    }

    func testKnownStatusesHaveDistinctVisibleAndAccessibleMeanings() throws {
        let cases: [(String, VoicePolishHistoryPresentation.Kind, VoicePolishHistoryPresentation.Tone, String)] = [
            ("voice_polish_success", .success, .success, "润色完成"),
            ("voice_polish_validation_failed", .validationFallback, .failure, "校验回退"),
            ("voice_polish_timeout", .timeoutFallback, .caution, "超时回退"),
            ("voice_polish_fallback", .fallback, .failure, "润色回退"),
            ("voice_polish_canonical", .canonical, .caution, "主动原文"),
            ("voice_polish_cancelled", .cancelled, .caution, "已取消"),
        ]

        var labels = Set<String>()
        var details = Set<String>()
        for (status, kind, tone, label) in cases {
            let presentation = try XCTUnwrap(VoicePolishHistoryPresentation(status: status))
            XCTAssertEqual(presentation.kind, kind, status)
            XCTAssertEqual(presentation.tone, tone, status)
            XCTAssertEqual(presentation.labelZH, label, status)
            XCTAssertLessThanOrEqual(presentation.labelZH.count, 4, status)
            XCTAssertFalse(presentation.detailZH.isEmpty, status)
            labels.insert(presentation.labelZH)
            details.insert(presentation.detailZH)
        }

        XCTAssertEqual(labels.count, cases.count)
        XCTAssertEqual(details.count, cases.count)
    }

    func testFallbackDescriptionsExplainThatCorrectedTranscriptWasUsed() throws {
        for status in [
            "voice_polish_validation_failed",
            "voice_polish_timeout",
            "voice_polish_fallback",
            "voice_polish_canonical",
        ] {
            let presentation = try XCTUnwrap(VoicePolishHistoryPresentation(status: status))
            XCTAssertTrue(presentation.detailZH.contains("术语纠正后的"), status)
        }
    }

    func testCanonicalStatusExplainsItWasAUserChoice() throws {
        let presentation = try XCTUnwrap(
            VoicePolishHistoryPresentation(status: "voice_polish_canonical")
        )

        XCTAssertEqual(presentation.kind, .canonical)
        XCTAssertTrue(presentation.detailZH.contains("主动停止等待"))
    }

    func testUnknownVoicePolishStatusKeepsGenericCompatibilityBadge() throws {
        let presentation = try XCTUnwrap(
            VoicePolishHistoryPresentation(status: "voice_polish_future_status")
        )

        XCTAssertEqual(presentation.kind, .unknown)
        XCTAssertEqual(presentation.tone, .caution)
        XCTAssertEqual(presentation.labelZH, "语音润色")
    }

    func testNonVoicePolishStatusDoesNotShowVoicePolishBadge() {
        XCTAssertNil(VoicePolishHistoryPresentation(status: "completed"))
        XCTAssertNil(VoicePolishHistoryPresentation(status: "llm_error"))
    }
}
