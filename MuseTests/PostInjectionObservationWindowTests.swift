import XCTest
@testable import Muse

final class PostInjectionObservationWindowTests: XCTestCase {
    func testEditsExtendIdleWindowButNeverLifetime() {
        var window = PostInjectionObservationWindow(timing: PostInjectionObservationTiming())
        window.sample("中间修改", at: .seconds(19))
        XCTAssertTrue(window.isOpen(at: .seconds(21)))
        window.sample("继续修改", at: .seconds(38))
        window.sample("最后修改", at: .seconds(57))
        XCTAssertTrue(window.isOpen(at: .seconds(59)))
        XCTAssertFalse(window.isOpen(at: .seconds(60)))
    }

    func testUnchangedCandidateDoesNotExtendWindowAndNeedsStability() {
        var window = PostInjectionObservationWindow(timing: PostInjectionObservationTiming())
        window.sample("Claude", at: .seconds(1))
        XCTAssertFalse(window.isStable(at: .seconds(2)))
        window.sample("Claude", at: .seconds(3))
        XCTAssertTrue(window.isStable(at: .seconds(3)))
        window.sample("Claude", at: .seconds(20))
        XCTAssertFalse(window.isOpen(at: .seconds(21)))
    }

    func testUnreadableOrUnchangedOutputInvalidatesFinalSnapshot() {
        var window = PostInjectionObservationWindow(timing: PostInjectionObservationTiming())
        window.sample("Claude", at: .seconds(1))
        XCTAssertEqual(window.recentCandidate(at: .milliseconds(1_500)), "Claude")
        XCTAssertNil(window.recentCandidate(at: .seconds(3)), "不能提交过时快照")
        window.sample(nil, at: .milliseconds(1_600))
        XCTAssertNil(window.recentCandidate(at: .milliseconds(1_700)))
    }
}
