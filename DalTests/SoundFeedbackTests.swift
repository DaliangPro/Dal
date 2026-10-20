@testable import Dal
import XCTest

final class SoundFeedbackTests: XCTestCase {
    func testFreshPlaybackRequestIsNotDropped() {
        let requestedAt = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(
            SoundFeedback.shouldDropQueuedPlayback(
                requestedAt: requestedAt,
                now: requestedAt.addingTimeInterval(0.3),
                maximumDelay: 0.5
            )
        )
    }

    func testStalePlaybackRequestIsDroppedAfterAudioQueueUnblocks() {
        let requestedAt = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(
            SoundFeedback.shouldDropQueuedPlayback(
                requestedAt: requestedAt,
                now: requestedAt.addingTimeInterval(0.501),
                maximumDelay: 0.5
            )
        )
    }

    func testPlaybackRequestAtDelayBoundaryStillPlays() {
        let requestedAt = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(
            SoundFeedback.shouldDropQueuedPlayback(
                requestedAt: requestedAt,
                now: requestedAt.addingTimeInterval(0.5),
                maximumDelay: 0.5
            )
        )
    }
}
