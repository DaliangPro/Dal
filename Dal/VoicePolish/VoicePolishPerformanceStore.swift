import Foundation
import os

enum VoicePolishPerformanceOutcome: String, Codable, Sendable, Equatable {
    case success
    case fallback
    case canonicalExit
    case setupFailure
    case cancelled
}

struct VoicePolishPerformanceMeasurement: Sendable, Equatable {
    let outcome: VoicePolishPerformanceOutcome
    let route: VoicePolishRoute?
    let llmAttemptCount: Int
    let firstAutomaticOutcome: VoicePolishPerformanceOutcome?
    let firstAutomaticLLMAttemptCount: Int?
    let firstAutomaticRepairAttemptCount: Int?
    let userRetryCount: Int
    let repairAttemptCount: Int?
    let decisionWaitMilliseconds: Int
    var stopLatencyMilliseconds: Int?
    var asrReadyLatencyMilliseconds: Int?
    var prefetchScheduledCount = 0
    var reusedPrefetch = false

    init(
        outcome: VoicePolishPerformanceOutcome,
        route: VoicePolishRoute? = nil,
        llmAttemptCount: Int = 0,
        firstAutomaticOutcome: VoicePolishPerformanceOutcome? = nil,
        firstAutomaticLLMAttemptCount: Int? = nil,
        firstAutomaticRepairAttemptCount: Int? = nil,
        userRetryCount: Int = 0,
        repairAttemptCount: Int? = nil,
        decisionWaitMilliseconds: Int = 0,
        stopLatencyMilliseconds: Int? = nil,
        asrReadyLatencyMilliseconds: Int? = nil
    ) {
        self.outcome = outcome
        self.route = route
        self.llmAttemptCount = max(0, llmAttemptCount)
        let automaticOutcome = firstAutomaticOutcome ?? (
            outcome == .canonicalExit || outcome == .cancelled ? nil : outcome
        )
        self.firstAutomaticOutcome = automaticOutcome
        self.firstAutomaticLLMAttemptCount = firstAutomaticLLMAttemptCount
            ?? (automaticOutcome != nil && userRetryCount == 0 ? max(0, llmAttemptCount) : nil)
        self.firstAutomaticRepairAttemptCount = firstAutomaticRepairAttemptCount
            ?? (userRetryCount == 0 ? repairAttemptCount : nil)
        self.userRetryCount = max(0, userRetryCount)
        self.repairAttemptCount = repairAttemptCount
        self.decisionWaitMilliseconds = max(0, decisionWaitMilliseconds)
        self.stopLatencyMilliseconds = stopLatencyMilliseconds
        self.asrReadyLatencyMilliseconds = asrReadyLatencyMilliseconds
    }

    init(result: VoicePolishResult) {
        self.init(
            outcome: result.failureReason == .setupFailed
                ? .setupFailure
                : (result.usedFallback ? .fallback : .success),
            route: result.executedRoute,
            llmAttemptCount: result.llmAttemptCount,
            repairAttemptCount: result.repairAttemptCount
        )
    }

    /// 正式注入结束后补齐交付耗时，继续排除已记录的用户决策等待。
    func completing(stopElapsedMilliseconds: Int) -> Self {
        var completed = self
        guard let previous = stopLatencyMilliseconds else { return completed }
        let netElapsed = max(0, stopElapsedMilliseconds - decisionWaitMilliseconds)
        let deliveryElapsed = max(0, netElapsed - previous)
        completed.stopLatencyMilliseconds = netElapsed
        if let asrReadyLatencyMilliseconds {
            completed.asrReadyLatencyMilliseconds = asrReadyLatencyMilliseconds + deliveryElapsed
        }
        return completed
    }
}

/// 一次输入会话的统计账本；用户选择不会覆盖首轮自动结果。
struct VoicePolishSessionPerformance {
    let stoppedAt: ContinuousClock.Instant
    let asrReadyAt: ContinuousClock.Instant
    var decisionWait: Duration = .zero
    var userRetryCount = 0
    var prefetchScheduledCount = 0
    var reusedPrefetch = false
    private(set) var firstOutcome: VoicePolishPerformanceOutcome?
    private(set) var firstAttempts: Int?
    private(set) var firstRepairs: Int?
    private(set) var totalAttempts = 0
    private(set) var totalRepairs: Int? = 0
    private(set) var route: VoicePolishRoute?

    mutating func recordSetupFailure() {
        guard firstOutcome == nil else { return }
        firstOutcome = .setupFailure
        firstAttempts = 0
        firstRepairs = 0
    }

    mutating func record(_ result: VoicePolishResult, completedAutomatically: Bool = true) {
        totalAttempts += result.llmAttemptCount
        if let count = result.repairAttemptCount, let totalRepairs {
            self.totalRepairs = totalRepairs + count
        } else {
            totalRepairs = nil
        }
        route = result.executedRoute
        guard completedAutomatically, firstOutcome == nil else { return }
        firstOutcome = VoicePolishPerformanceMeasurement(result: result).outcome
        firstAttempts = result.llmAttemptCount
        firstRepairs = result.repairAttemptCount
    }

    func measurement(
        outcome: VoicePolishPerformanceOutcome,
        at finishedAt: ContinuousClock.Instant = .now
    ) -> VoicePolishPerformanceMeasurement {
        var measurement = VoicePolishPerformanceMeasurement(
            outcome: outcome, route: route, llmAttemptCount: totalAttempts,
            firstAutomaticOutcome: firstOutcome,
            firstAutomaticLLMAttemptCount: firstAttempts,
            firstAutomaticRepairAttemptCount: firstRepairs,
            userRetryCount: userRetryCount, repairAttemptCount: totalRepairs,
            decisionWaitMilliseconds: Self.milliseconds(decisionWait),
            stopLatencyMilliseconds: Self.milliseconds(finishedAt - stoppedAt - decisionWait),
            asrReadyLatencyMilliseconds: Self.milliseconds(finishedAt - asrReadyAt - decisionWait)
        )
        measurement.prefetchScheduledCount = prefetchScheduledCount
        measurement.reusedPrefetch = reusedPrefetch
        return measurement
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        max(0, Int(clamping: duration.components.seconds * 1_000
            + duration.components.attoseconds / 1_000_000_000_000_000))
    }
}

struct VoicePolishPerformanceSample: Codable, Sendable, Equatable {
    let recordedAt: Date
    /// setup failure / 提前使用 canonical 时可能尚未完成路由判断。
    let route: VoicePolishRoute?
    let latencyMilliseconds: Int
    let llmAttemptCount: Int
    let usedRepair: Bool
    let usedFallback: Bool
    /// optional 用于兼容已经写入的 v1 样本；nil 时由 usedFallback 推断。
    let outcome: VoicePolishPerformanceOutcome?
    /// 旧记录没有产品档位，保持 nil，不根据历史路由猜测轻度或标准。
    var qualityMode: VoicePolishQualityMode? = nil
    /// 新口径字段全部可选，旧样本保持未知，不回填推测值。
    var firstAutomaticOutcome: VoicePolishPerformanceOutcome? = nil
    var firstAutomaticLLMAttemptCount: Int? = nil
    var firstAutomaticRepairAttemptCount: Int? = nil
    var userRetryCount: Int? = nil
    var repairAttemptCount: Int? = nil
    var decisionWaitMilliseconds: Int? = nil
    var asrReadyLatencyMilliseconds: Int? = nil
    /// 预生成的调度数与复用情况独立于正式交付路径尝试数，旧样本保持未知。
    var prefetchScheduledCount: Int? = nil
    var reusedPrefetch: Bool? = nil

    var resolvedOutcome: VoicePolishPerformanceOutcome {
        outcome ?? (usedFallback ? .fallback : .success)
    }
}

struct VoicePolishRoutePerformanceSummary: Sendable, Equatable {
    let route: VoicePolishRoute
    let sampleCount: Int
    let p50Milliseconds: Int
    let p95Milliseconds: Int
}

struct VoicePolishPerformanceSummary: Sendable, Equatable {
    /// 最近保存的全部正式语音润色会话，包含主动使用 canonical 和初始化失败。
    let sampleCount: Int
    /// 首轮自动处理实际调用过模型的会话。
    let llmRequestSampleCount: Int
    /// 有首次自动结果的会话，包含失败后选原文、重试或取消。
    let automaticSampleCount: Int
    /// 尚无实际模型请求时为 nil，避免把 0/0 错写成 0%。
    let singleCallRate: Double?
    /// 未追加修复且成功成稿的自动会话占比；标准的正常生成加复核计为无需修复。
    let unrepairedSuccessRate: Double?
    /// 尚无实际模型请求时为 nil，避免把 0/0 错写成 0%。
    let repairRate: Double?
    let fallbackRate: Double
    let routes: [VoicePolishRoutePerformanceSummary]
    let p50Milliseconds: Int?
    let p95Milliseconds: Int?
    let asrReadyP50Milliseconds: Int?
    let asrReadyP95Milliseconds: Int?
    let legacySampleCount: Int
    let userRetrySampleCount: Int
    let canonicalExitSampleCount: Int
    let cancelledSampleCount: Int
}

/// 仅保存最近的工程指标，不保存识别或润色正文。
enum VoicePolishPerformanceStore {
    static let maximumSampleCount = 200
    static let minimumVisibleSampleCount = 10

    private static let defaultsKey = "muse_voicePolishPerformanceSamples_v1"
    private static let lock = OSAllocatedUnfairLock(initialState: ())

    /// UserDefaults 的读写本身是线程安全的；包装只用于向 Swift 6 明确这一点，
    /// 实际的读-改-写序列仍由上面的 unfair lock 串行化。
    private struct SendableDefaults: @unchecked Sendable {
        let value: UserDefaults
    }

    static func record(
        result: VoicePolishResult,
        latencyMilliseconds: Int,
        qualityMode: VoicePolishQualityMode? = nil,
        recordedAt: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        record(
            measurement: VoicePolishPerformanceMeasurement(result: result),
            latencyMilliseconds: latencyMilliseconds,
            qualityMode: qualityMode,
            recordedAt: recordedAt,
            defaults: defaults
        )
    }

    static func record(
        measurement: VoicePolishPerformanceMeasurement,
        latencyMilliseconds: Int,
        qualityMode: VoicePolishQualityMode? = nil,
        recordedAt: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        let sample = VoicePolishPerformanceSample(
            recordedAt: recordedAt,
            route: measurement.route,
            latencyMilliseconds: max(0, measurement.stopLatencyMilliseconds ?? latencyMilliseconds),
            llmAttemptCount: measurement.llmAttemptCount,
            // 保留旧字段供旧读取方使用，新统计只依据可选的精确计数。
            usedRepair: (measurement.repairAttemptCount ?? 0) > 0,
            usedFallback: measurement.outcome == .fallback
                || measurement.outcome == .setupFailure,
            outcome: measurement.outcome,
            qualityMode: qualityMode,
            firstAutomaticOutcome: measurement.firstAutomaticOutcome,
            firstAutomaticLLMAttemptCount: measurement.firstAutomaticLLMAttemptCount,
            firstAutomaticRepairAttemptCount: measurement.firstAutomaticRepairAttemptCount,
            userRetryCount: measurement.userRetryCount,
            repairAttemptCount: measurement.repairAttemptCount,
            decisionWaitMilliseconds: measurement.decisionWaitMilliseconds,
            asrReadyLatencyMilliseconds: measurement.asrReadyLatencyMilliseconds,
            prefetchScheduledCount: measurement.prefetchScheduledCount,
            reusedPrefetch: measurement.reusedPrefetch
        )
        let storage = SendableDefaults(value: defaults)
        lock.withLock { _ in
            var values = loadUnlocked(defaults: storage.value)
            values.append(sample)
            if values.count > maximumSampleCount {
                values.removeFirst(values.count - maximumSampleCount)
            }
            guard let data = try? JSONEncoder().encode(values) else { return }
            storage.value.set(data, forKey: defaultsKey)
        }
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .voicePolishPerformanceDidChange,
                object: nil
            )
        }
    }

    static func samples(defaults: UserDefaults = .standard) -> [VoicePolishPerformanceSample] {
        let storage = SendableDefaults(value: defaults)
        return lock.withLock { _ in loadUnlocked(defaults: storage.value) }
    }

    static func automaticSampleCount(
        qualityMode: VoicePolishQualityMode? = nil,
        defaults: UserDefaults = .standard
    ) -> Int {
        samples(defaults: defaults).filter {
            $0.firstAutomaticOutcome != nil && (qualityMode == nil || $0.qualityMode == qualityMode)
        }.count
    }

    static func summary(
        minimumSampleCount: Int = minimumVisibleSampleCount,
        qualityMode: VoicePolishQualityMode? = nil,
        defaults: UserDefaults = .standard
    ) -> VoicePolishPerformanceSummary? {
        let values = samples(defaults: defaults).filter { qualityMode == nil || $0.qualityMode == qualityMode }
        let currentValues = values.filter { $0.userRetryCount != nil }
        let automaticValues = currentValues.filter { $0.firstAutomaticOutcome != nil }
        guard automaticValues.count >= max(1, minimumSampleCount) else { return nil }
        let llmRequestValues = automaticValues.filter { ($0.firstAutomaticLLMAttemptCount ?? 0) > 0 }
        let knownRepairValues = llmRequestValues.filter { $0.firstAutomaticRepairAttemptCount != nil }
        let knownCompletionValues = automaticValues.filter { $0.firstAutomaticRepairAttemptCount != nil }
        // 提前选原文与取消没有完整成稿时间；成功重试的耗时保留全部实际处理，扣除选择等待。
        let latencyValues = currentValues.filter { $0.resolvedOutcome == .success }
        let asrLatencies = latencyValues.compactMap(\.asrReadyLatencyMilliseconds).sorted()
        let routeSummaries = VoicePolishRoute.allCasesForMetrics.compactMap { route -> VoicePolishRoutePerformanceSummary? in
            let latencies = latencyValues.filter { $0.route == route }
                .map(\.latencyMilliseconds)
                .sorted()
            guard !latencies.isEmpty else { return nil }
            return VoicePolishRoutePerformanceSummary(
                route: route,
                sampleCount: latencies.count,
                p50Milliseconds: percentile(0.50, values: latencies),
                p95Milliseconds: percentile(0.95, values: latencies)
            )
        }
        return VoicePolishPerformanceSummary(
            sampleCount: values.count,
            llmRequestSampleCount: llmRequestValues.count,
            automaticSampleCount: automaticValues.count,
            singleCallRate: rate(
                numerator: llmRequestValues.filter { $0.firstAutomaticLLMAttemptCount == 1 }.count,
                denominator: llmRequestValues.count
            ),
            unrepairedSuccessRate: rate(
                numerator: knownCompletionValues.filter { $0.firstAutomaticOutcome == .success && $0.firstAutomaticRepairAttemptCount == 0 }.count,
                denominator: knownCompletionValues.count
            ),
            repairRate: rate(
                numerator: knownRepairValues.filter { ($0.firstAutomaticRepairAttemptCount ?? 0) > 0 }.count,
                denominator: knownRepairValues.count
            ),
            fallbackRate: rate(
                numerator: automaticValues.filter {
                $0.firstAutomaticOutcome == .fallback || $0.firstAutomaticOutcome == .setupFailure
                }.count,
                denominator: automaticValues.count
            ) ?? 0,
            routes: routeSummaries,
            p50Milliseconds: latencyValues.isEmpty ? nil : percentile(0.50, values: latencyValues.map(\.latencyMilliseconds).sorted()),
            p95Milliseconds: latencyValues.isEmpty ? nil : percentile(0.95, values: latencyValues.map(\.latencyMilliseconds).sorted()),
            asrReadyP50Milliseconds: asrLatencies.isEmpty ? nil : percentile(0.50, values: asrLatencies),
            asrReadyP95Milliseconds: asrLatencies.isEmpty ? nil : percentile(0.95, values: asrLatencies),
            legacySampleCount: values.count - currentValues.count,
            userRetrySampleCount: currentValues.filter { ($0.userRetryCount ?? 0) > 0 }.count,
            canonicalExitSampleCount: currentValues.filter { $0.resolvedOutcome == .canonicalExit }.count,
            cancelledSampleCount: currentValues.filter { $0.resolvedOutcome == .cancelled }.count
        )
    }

    static func reset(defaults: UserDefaults = .standard) {
        let storage = SendableDefaults(value: defaults)
        lock.withLock { _ in storage.value.removeObject(forKey: defaultsKey) }
    }

    private static func loadUnlocked(defaults: UserDefaults) -> [VoicePolishPerformanceSample] {
        guard let data = defaults.data(forKey: defaultsKey),
              let values = try? JSONDecoder().decode([VoicePolishPerformanceSample].self, from: data)
        else { return [] }
        return Array(values.suffix(maximumSampleCount))
    }

    private static func percentile(_ percentile: Double, values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let rank = max(1, Int(ceil(percentile * Double(values.count))))
        return values[min(values.count - 1, rank - 1)]
    }

    private static func rate(numerator: Int, denominator: Int) -> Double? {
        guard denominator > 0 else { return nil }
        return Double(numerator) / Double(denominator)
    }
}

private extension VoicePolishRoute {
    static let allCasesForMetrics: [VoicePolishRoute] = [.fast, .structured, .deep]
}

extension Notification.Name {
    static let voicePolishPerformanceDidChange = Notification.Name(
        "DalVoicePolishPerformanceDidChange"
    )
}
