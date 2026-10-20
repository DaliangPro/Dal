import XCTest
@testable import Dal

final class VoicePolishContextDiagnosticsTests: XCTestCase {
    override func tearDown() {
        VoicePolishContextDiagnostics.clearForTesting()
        super.tearDown()
    }

    func testRecordsOnlyMetadataAndCountsForSafeNearbyContext() throws {
        let context = WritingContext(
            applicationBundleID: "com.example.editor",
            applicationName: "Editor",
            focusedRole: "AXTextArea",
            scene: .document,
            level: .nearbyText,
            safety: .safe,
            selectedText: "选中",
            textBeforeCursor: "前文",
            textAfterCursor: "后文",
            recentDalInputs: ["最近一次"]
        )

        VoicePolishContextDiagnostics.record(
            context,
            at: Date(timeIntervalSince1970: 123)
        )

        let snapshot = try XCTUnwrap(VoicePolishContextDiagnostics.latest())
        XCTAssertEqual(snapshot.capturedKind, .nearbyText)
        XCTAssertEqual(snapshot.selectedCharacterCount, 2)
        XCTAssertEqual(snapshot.nearbyCharacterCount, 4)
        XCTAssertEqual(snapshot.recentDalInputCount, 1)
        XCTAssertEqual(snapshot.applicationBundleID, "com.example.editor")
    }

    func testUnsafeAuthorizedContextIsReportedUnavailableWithoutBody() throws {
        VoicePolishContextDiagnostics.record(WritingContext(
            applicationBundleID: "com.example.secure",
            level: .nearbyText,
            safety: .secure,
            selectedText: nil,
            textBeforeCursor: nil,
            textAfterCursor: nil
        ))

        let snapshot = try XCTUnwrap(VoicePolishContextDiagnostics.latest())
        XCTAssertEqual(snapshot.capturedKind, .unavailable)
        XCTAssertEqual(snapshot.selectedCharacterCount, 0)
        XCTAssertEqual(snapshot.nearbyCharacterCount, 0)
    }
}
