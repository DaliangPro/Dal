import XCTest
import os
@testable import Muse

final class RecognitionEventIdentityTests: XCTestCase {
    func testFailedStartRetainsUIRequestIdentity() async {
        let requestID = UUID()
        let events = OSAllocatedUnfairLock(initialState: [RecognitionEventEnvelope]())
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            selectedASRProvider: { .volcano },
            microphonePermission: { false },
            frontmostApplicationBundleIdentifier: { nil }
        )
        await session.setOnASREventWithSession { event in events.withLock { $0.append(event) } }
        await session.startRecording(uiRequestID: requestID)
        let envelopes = events.withLock { $0 }
        XCTAssertFalse(envelopes.isEmpty)
        XCTAssertTrue(envelopes.allSatisfy { $0.uiRequestID == requestID && $0.sessionID != nil })
    }
}
