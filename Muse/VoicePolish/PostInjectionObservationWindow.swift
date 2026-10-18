import Foundation

/// 空闲 20 秒结束；相关修改续期，但从开始观察算起最多 60 秒。
struct PostInjectionObservationTiming: Sendable {
    var pollingInterval: Duration = .milliseconds(500)
    var stableDuration: Duration = .seconds(2)
    var idleTimeout: Duration = .seconds(20)
    var maximumLifetime: Duration = .seconds(60)
}

/// 使用单调时钟的相对时间，方便确定性验证续期、稳定和最终快照边界。
struct PostInjectionObservationWindow {
    let timing: PostInjectionObservationTiming
    private(set) var candidate: String?
    private var changedAt: Duration = .zero
    private var lastSampleAt: Duration = .zero
    private var idleDeadline: Duration

    init(timing: PostInjectionObservationTiming) {
        self.timing = timing
        idleDeadline = timing.idleTimeout
    }

    func isOpen(at elapsed: Duration) -> Bool {
        elapsed < min(idleDeadline, timing.maximumLifetime)
    }

    mutating func sample(_ value: String?, at elapsed: Duration) {
        if let value, value != candidate {
            changedAt = elapsed
            idleDeadline = min(elapsed + timing.idleTimeout, timing.maximumLifetime)
        }
        candidate = value
        lastSampleAt = elapsed
    }

    func isStable(at elapsed: Duration) -> Bool {
        candidate != nil && elapsed - changedAt >= timing.stableDuration && isOpen(at: elapsed)
    }

    func recentCandidate(at elapsed: Duration) -> String? {
        guard isOpen(at: elapsed), elapsed - lastSampleAt <= timing.pollingInterval * 2 else { return nil }
        return candidate
    }
}
