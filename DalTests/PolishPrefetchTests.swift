import XCTest
@testable import Dal

@MainActor
final class PolishPrefetchTests: XCTestCase {
    private let session = RecognitionSessionID(rawValue: 1)

    private func key(_ text: String = "周四开会", requirements: String = "",
                     model: String = "test", endpoint: String = "https://example.invalid",
                     credential: String = "test") -> PolishPrefetch.Key {
        .init(text: text, requirements: requirements, provider: .openai,
              config: .init(apiKey: credential, model: model, baseURL: endpoint))
    }

    nonisolated private static func result(failed: Bool = false) -> VoicePolishResult {
        .init(text: "周四开会。", detectedRoute: .fast, executedRoute: .fast,
              llmAttemptCount: 1, validationCodes: [], usedFallback: failed,
              failureReason: failed ? .requestFailed : nil)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(20))
    }

    func testCompletedCandidateIsConsumedOnlyOnce() async throws {
        let cache = PolishPrefetch()
        cache.start(session: session, key: key()) { Self.result() }
        try await settle()
        XCTAssertEqual(cache.take(session: session, key: key())?.text, "周四开会。")
        XCTAssertNil(cache.take(session: session, key: key()))
    }

    func testCorrectionsAndEveryRequestSettingInvalidateReuse() async throws {
        let alternatives = [key("周五开会"), key(requirements: "不要句号"),
                            key(model: "other"), key(endpoint: "https://other.invalid"),
                            key(credential: "changed")]
        for other in alternatives {
            let cache = PolishPrefetch()
            cache.start(session: session, key: key()) { Self.result() }
            try await settle()
            XCTAssertNil(cache.take(session: session, key: other))
        }
    }

    func testUnfinishedCandidateDoesNotBlockAndLateCompletionCannotReturn() async throws {
        let cache = PolishPrefetch()
        cache.start(session: session, key: key()) {
            try? await Task.sleep(for: .seconds(1))
            return Self.result()
        }
        XCTAssertNil(cache.take(session: session, key: key()))
        try await settle()
        XCTAssertNil(cache.take(session: session, key: key()))
    }

    func testFailedCandidateFallsBackToNormalPath() async throws {
        let cache = PolishPrefetch()
        cache.start(session: session, key: key()) { Self.result(failed: true) }
        try await settle()
        XCTAssertNil(cache.take(session: session, key: key()))
    }

    func testDuplicateAndThirdRequestAreNotSent() async throws {
        let cache = PolishPrefetch()
        let calls = PrefetchCallCounter()
        let generate: @Sendable () async -> VoicePolishResult = {
            await calls.increment()
            return Self.result()
        }
        cache.start(session: session, key: key(), generate: generate)
        try await settle()
        cache.start(session: session, key: key(), generate: generate)
        cache.invalidate()
        cache.start(session: session, key: key("周五开会"), generate: generate)
        try await settle()
        cache.invalidate()
        cache.start(session: session, key: key("周六开会"), generate: generate)
        try await settle()
        let count = await calls.count
        XCTAssertEqual(count, 2)
        XCTAssertNil(cache.take(session: session, key: key("周六开会")))
    }

    func testResetAndNewSessionRejectOldResult() async throws {
        let cache = PolishPrefetch()
        cache.start(session: session, key: key()) { Self.result() }
        try await settle()
        let next = RecognitionSessionID(rawValue: 2)
        XCTAssertNil(cache.take(session: next, key: key()))
        cache.reset(session: session)
        XCTAssertNil(cache.take(session: session, key: key()))
        cache.start(session: next, key: key()) { Self.result() }
        try await settle()
        cache.reset(session: session)
        XCTAssertNotNil(cache.take(session: next, key: key()))
    }
}

private actor PrefetchCallCounter {
    var count = 0
    func increment() { count += 1 }
}
