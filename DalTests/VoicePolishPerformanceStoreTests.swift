import XCTest
@testable import Dal

final class VoicePolishPerformanceStoreTests: XCTestCase {
    func testModeSummariesDoNotMixLegacyLightAndStandardMeasurements() throws {
        let suiteName = "VoicePolishModePerformanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        VoicePolishPerformanceStore.record(
            result: result(route: .fast, attempts: 1), latencyMilliseconds: 50, defaults: defaults
        )
        for latency in [100, 200] {
            VoicePolishPerformanceStore.record(
                result: result(route: .fast, attempts: 1), latencyMilliseconds: latency,
                qualityMode: .light, defaults: defaults
            )
        }
        VoicePolishPerformanceStore.record(
            result: result(route: .deep, attempts: 2), latencyMilliseconds: 900,
            qualityMode: .standard, defaults: defaults
        )
        let light = try XCTUnwrap(VoicePolishPerformanceStore.summary(
            minimumSampleCount: 1, qualityMode: .light, defaults: defaults
        ))
        let standard = try XCTUnwrap(VoicePolishPerformanceStore.summary(
            minimumSampleCount: 1, qualityMode: .standard, defaults: defaults
        ))
        XCTAssertEqual(light.sampleCount, 2)
        XCTAssertEqual(light.p50Milliseconds, 100)
        XCTAssertEqual(light.p95Milliseconds, 200)
        XCTAssertEqual(standard.sampleCount, 1)
        XCTAssertEqual(standard.p50Milliseconds, 900)
        XCTAssertEqual(standard.repairRate, 0)
        XCTAssertEqual(standard.unrepairedSuccessRate, 1)
        XCTAssertEqual(light.unrepairedSuccessRate, 1)
        XCTAssertEqual(VoicePolishPerformanceStore.automaticSampleCount(qualityMode: .light, defaults: defaults), 2)
        XCTAssertNil(VoicePolishPerformanceStore.samples(defaults: defaults).first?.qualityMode)
    }

    func testOldPerformanceJSONRemainsReadableWithoutInventingAMode() throws {
        let sample = try JSONDecoder().decode(VoicePolishPerformanceSample.self, from: Data(
            #"{"recordedAt":0,"route":"fast","latencyMilliseconds":123,"llmAttemptCount":1,"usedRepair":false,"usedFallback":false}"#.utf8
        ))
        XCTAssertEqual(sample.latencyMilliseconds, 123)
        XCTAssertEqual(sample.resolvedOutcome, .success)
        XCTAssertNil(sample.qualityMode)
        XCTAssertNil(sample.userRetryCount)
        XCTAssertNil(sample.firstAutomaticOutcome)
        XCTAssertNil(sample.repairAttemptCount)
        XCTAssertNil(sample.asrReadyLatencyMilliseconds)
    }

    func testSummaryUsesEndToEndLatencyAndSeparatesDeepBaseCallsFromRepair() throws {
        let suiteName = "VoicePolishPerformanceStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for latency in [100, 200, 300, 400] {
            VoicePolishPerformanceStore.record(
                result: result(route: .fast, attempts: 1),
                latencyMilliseconds: latency,
                defaults: defaults
            )
        }
        VoicePolishPerformanceStore.record(
            result: result(route: .structured, attempts: 2),
            latencyMilliseconds: 500,
            defaults: defaults
        )
        VoicePolishPerformanceStore.record(
            result: result(route: .deep, attempts: 2),
            latencyMilliseconds: 900,
            defaults: defaults
        )

        let summary = try XCTUnwrap(
            VoicePolishPerformanceStore.summary(minimumSampleCount: 1, defaults: defaults)
        )
        XCTAssertEqual(summary.sampleCount, 6)
        XCTAssertEqual(summary.llmRequestSampleCount, 6)
        XCTAssertEqual(summary.automaticSampleCount, 6)
        XCTAssertEqual(try XCTUnwrap(summary.singleCallRate), 4.0 / 6.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.repairRate), 1.0 / 6.0, accuracy: 0.0001)
        XCTAssertEqual(summary.fallbackRate, 0)
        let fast = try XCTUnwrap(summary.routes.first { $0.route == .fast })
        XCTAssertEqual(fast.p50Milliseconds, 200)
        XCTAssertEqual(fast.p95Milliseconds, 400)
    }

    func testSummaryStaysHiddenUntilEnoughSamplesAndRetentionIsBounded() throws {
        let suiteName = "VoicePolishPerformanceRetentionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        VoicePolishPerformanceStore.record(
            result: result(route: .fast, attempts: 1),
            latencyMilliseconds: 10,
            defaults: defaults
        )
        XCTAssertNil(VoicePolishPerformanceStore.summary(defaults: defaults))

        for latency in 0..<(VoicePolishPerformanceStore.maximumSampleCount + 20) {
            VoicePolishPerformanceStore.record(
                result: result(route: .fast, attempts: 1),
                latencyMilliseconds: latency,
                defaults: defaults
            )
        }
        let samples = VoicePolishPerformanceStore.samples(defaults: defaults)
        XCTAssertEqual(samples.count, VoicePolishPerformanceStore.maximumSampleCount)
        XCTAssertEqual(samples.last?.latencyMilliseconds, VoicePolishPerformanceStore.maximumSampleCount + 19)
    }

    func testSummaryUsesOutcomeSpecificDenominators() throws {
        let suiteName = "VoicePolishPerformanceOutcomeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        VoicePolishPerformanceStore.record(
            measurement: VoicePolishPerformanceMeasurement(
                outcome: .fallback,
                route: .fast,
                llmAttemptCount: 1,
                repairAttemptCount: 0
            ),
            latencyMilliseconds: 100,
            defaults: defaults
        )
        VoicePolishPerformanceStore.record(
            measurement: VoicePolishPerformanceMeasurement(
                outcome: .canonicalExit,
                route: .structured,
                llmAttemptCount: 1
            ),
            latencyMilliseconds: 200,
            defaults: defaults
        )
        VoicePolishPerformanceStore.record(
            measurement: VoicePolishPerformanceMeasurement(outcome: .setupFailure, repairAttemptCount: 0),
            latencyMilliseconds: 20,
            defaults: defaults
        )

        let samples = VoicePolishPerformanceStore.samples(defaults: defaults)
        XCTAssertEqual(samples.map(\.resolvedOutcome), [
            .fallback,
            .canonicalExit,
            .setupFailure,
        ])
        let summary = try XCTUnwrap(
            VoicePolishPerformanceStore.summary(minimumSampleCount: 1, defaults: defaults)
        )
        XCTAssertEqual(summary.sampleCount, 3)
        XCTAssertEqual(summary.llmRequestSampleCount, 1)
        XCTAssertEqual(summary.automaticSampleCount, 2)
        XCTAssertEqual(try XCTUnwrap(summary.singleCallRate), 1)
        XCTAssertEqual(summary.fallbackRate, 1)
        XCTAssertEqual(summary.unrepairedSuccessRate, 0)
        XCTAssertTrue(summary.routes.allSatisfy { $0.route != .structured })
    }

    func testSummaryDoesNotInventRatesWhenEverySessionUsesCanonicalExit() throws {
        let suiteName = "VoicePolishPerformanceCanonicalOnlyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for _ in 0..<VoicePolishPerformanceStore.minimumVisibleSampleCount {
            VoicePolishPerformanceStore.record(
                measurement: VoicePolishPerformanceMeasurement(
                    outcome: .canonicalExit,
                    route: .structured,
                    llmAttemptCount: 1
                ),
                latencyMilliseconds: 200,
                defaults: defaults
            )
        }

        XCTAssertEqual(
            VoicePolishPerformanceStore.samples(defaults: defaults).count,
            VoicePolishPerformanceStore.minimumVisibleSampleCount
        )
        XCTAssertEqual(VoicePolishPerformanceStore.automaticSampleCount(defaults: defaults), 0)
        XCTAssertNil(VoicePolishPerformanceStore.summary(defaults: defaults))

        VoicePolishPerformanceStore.record(
            result: result(route: .fast, attempts: 1),
            latencyMilliseconds: 100,
            defaults: defaults
        )
        XCTAssertEqual(VoicePolishPerformanceStore.automaticSampleCount(defaults: defaults), 1)
        XCTAssertNil(VoicePolishPerformanceStore.summary(defaults: defaults))
    }

    func testSummaryShowsUnavailableLLMRatesWhenAutomaticSessionsNeverReachModel() throws {
        let suiteName = "VoicePolishPerformanceNoLLMTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for _ in 0..<VoicePolishPerformanceStore.minimumVisibleSampleCount {
            VoicePolishPerformanceStore.record(
                measurement: VoicePolishPerformanceMeasurement(outcome: .setupFailure),
                latencyMilliseconds: 20,
                defaults: defaults
            )
        }

        let summary = try XCTUnwrap(VoicePolishPerformanceStore.summary(defaults: defaults))
        XCTAssertEqual(summary.automaticSampleCount, VoicePolishPerformanceStore.minimumVisibleSampleCount)
        XCTAssertEqual(summary.llmRequestSampleCount, 0)
        XCTAssertNil(summary.singleCallRate)
        XCTAssertNil(summary.repairRate)
        XCTAssertEqual(summary.fallbackRate, 1)
        XCTAssertTrue(summary.routes.isEmpty)
    }

    func testRetryKeepsFirstFailureAndSeparatesTwoNetLatenciesFromDecisionWait() throws {
        let start = ContinuousClock.now
        var session = VoicePolishSessionPerformance(
            stoppedAt: start, asrReadyAt: start.advanced(by: .seconds(2))
        )
        session.record(result(route: .fast, attempts: 1, fallback: true))
        session.decisionWait = .seconds(10)
        session.userRetryCount += 1
        session.record(result(route: .fast, attempts: 1))
        let measurement = session.measurement(outcome: .success, at: start.advanced(by: .seconds(15)))
            .completing(stopElapsedMilliseconds: 15_100)

        XCTAssertEqual(measurement.firstAutomaticOutcome, .fallback)
        XCTAssertEqual(measurement.outcome, .success)
        XCTAssertEqual(measurement.userRetryCount, 1)
        XCTAssertEqual(measurement.llmAttemptCount, 2)
        XCTAssertEqual(measurement.repairAttemptCount, 0)
        XCTAssertEqual(measurement.stopLatencyMilliseconds, 5_100)
        XCTAssertEqual(measurement.asrReadyLatencyMilliseconds, 3_100)

        let suite = "VoicePolishRetryMetrics.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        VoicePolishPerformanceStore.record(measurement: measurement, latencyMilliseconds: 99_999,
                                          qualityMode: .light, defaults: defaults)
        let summary = try XCTUnwrap(VoicePolishPerformanceStore.summary(minimumSampleCount: 1, defaults: defaults))
        XCTAssertEqual(summary.fallbackRate, 1)
        XCTAssertEqual(summary.unrepairedSuccessRate, 0)
        XCTAssertEqual(summary.repairRate, 0)
        XCTAssertEqual(summary.userRetrySampleCount, 1)
        XCTAssertEqual(summary.p50Milliseconds, 5_100)
        XCTAssertEqual(summary.asrReadyP50Milliseconds, 3_100)
        XCTAssertFalse(try XCTUnwrap(VoicePolishPerformanceStore.samples(defaults: defaults).first).usedRepair)
    }

    func testOriginalAndCancelExitsPreserveFirstFailureWithoutInventingCompletedLatency() throws {
        let suite = "VoicePolishExitMetrics.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = ContinuousClock.now
        for exit in [VoicePolishPerformanceOutcome.canonicalExit, .cancelled] {
            var session = VoicePolishSessionPerformance(stoppedAt: now, asrReadyAt: now)
            session.record(result(route: .fast, attempts: 1, fallback: true))
            VoicePolishPerformanceStore.record(measurement: session.measurement(outcome: exit),
                                              latencyMilliseconds: 100, defaults: defaults)
        }
        var earlyExit = VoicePolishSessionPerformance(stoppedAt: now, asrReadyAt: now)
        earlyExit.record(result(route: .fast, attempts: 1, fallback: true), completedAutomatically: false)
        VoicePolishPerformanceStore.record(measurement: earlyExit.measurement(outcome: .canonicalExit),
                                          latencyMilliseconds: 100, defaults: defaults)
        let summary = try XCTUnwrap(VoicePolishPerformanceStore.summary(minimumSampleCount: 1, defaults: defaults))
        XCTAssertEqual(summary.automaticSampleCount, 2)
        XCTAssertEqual(summary.fallbackRate, 1)
        XCTAssertEqual(summary.canonicalExitSampleCount, 2)
        XCTAssertEqual(summary.cancelledSampleCount, 1)
        XCTAssertNil(summary.p50Milliseconds)
        XCTAssertNil(summary.asrReadyP50Milliseconds)
    }

    func testLegacySamplesAndUnknownRepairCountsRemainUnknown() throws {
        let suite = "VoicePolishLegacyMetrics.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = Data(#"[{"recordedAt":0,"route":"fast","latencyMilliseconds":99999,"llmAttemptCount":1,"usedRepair":false,"usedFallback":false,"qualityMode":"light"}]"#.utf8)
        defaults.set(legacy, forKey: "muse_voicePolishPerformanceSamples_v1")
        XCTAssertNil(VoicePolishPerformanceStore.summary(minimumSampleCount: 1, defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: "muse_voicePolishPerformanceSamples_v1"), legacy)
        VoicePolishPerformanceStore.record(
            measurement: VoicePolishPerformanceMeasurement(outcome: .success, route: .fast, llmAttemptCount: 2),
            latencyMilliseconds: 100, qualityMode: .light, defaults: defaults
        )
        let summary = try XCTUnwrap(VoicePolishPerformanceStore.summary(minimumSampleCount: 1, defaults: defaults))
        XCTAssertEqual(summary.legacySampleCount, 1)
        XCTAssertEqual(summary.automaticSampleCount, 1)
        XCTAssertEqual(summary.p50Milliseconds, 100)
        XCTAssertNil(summary.repairRate)
        XCTAssertNil(summary.unrepairedSuccessRate)
        XCTAssertNil(summary.asrReadyP50Milliseconds)
    }

    private func result(
        route: VoicePolishRoute,
        attempts: Int,
        fallback: Bool = false
    ) -> VoicePolishResult {
        VoicePolishResult(
            text: "结果",
            detectedRoute: route,
            executedRoute: route,
            llmAttemptCount: attempts,
            validationCodes: [],
            usedFallback: fallback,
            failureReason: fallback ? .requestFailed : nil,
            repairAttemptCount: max(0, attempts - (route == .deep ? 2 : 1))
        )
    }
}
