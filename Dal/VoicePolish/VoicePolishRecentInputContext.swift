import Foundation

/// Voice Polish 的短期上下文只保存 Dal 自己刚完成的文本。
///
/// - 仅驻留内存，应用退出即清空；
/// - 严格按目标应用 bundle ID 隔离；
/// - 每个应用最多三条、最长十五分钟；
/// - 不读取目标应用后续编辑、剪贴板或第三方页面正文。
actor VoicePolishRecentInputContextStore {
    static let shared = VoicePolishRecentInputContextStore()

    private struct Entry: Sendable {
        let text: String
        let createdAt: Date
    }

    private let maximumEntriesPerApplication: Int
    private let timeToLive: TimeInterval
    private var entriesByApplication: [String: [Entry]] = [:]

    init(
        maximumEntriesPerApplication: Int = 3,
        timeToLive: TimeInterval = 15 * 60
    ) {
        self.maximumEntriesPerApplication = max(1, maximumEntriesPerApplication)
        self.timeToLive = max(1, timeToLive)
    }

    func remember(
        _ text: String,
        applicationBundleID: String?,
        at now: Date = Date()
    ) {
        guard let application = normalizedApplicationID(applicationBundleID) else { return }
        let normalizedText = VoicePolishCharacterSafety.sanitizedFallback(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return }

        prune(at: now)
        var entries = entriesByApplication[application] ?? []
        // 连续相同输出只刷新时效，不重复占满三个槽位。
        entries.removeAll { $0.text == normalizedText }
        entries.append(Entry(text: normalizedText, createdAt: now))
        entriesByApplication[application] = Array(
            entries.suffix(maximumEntriesPerApplication)
        )
    }

    func recentInputs(
        applicationBundleID: String?,
        at now: Date = Date()
    ) -> [String] {
        guard let application = normalizedApplicationID(applicationBundleID) else { return [] }
        prune(at: now)
        return (entriesByApplication[application] ?? []).map(\.text)
    }

    func clear() {
        entriesByApplication.removeAll(keepingCapacity: false)
    }

    private func prune(at now: Date) {
        let cutoff = now.addingTimeInterval(-timeToLive)
        entriesByApplication = entriesByApplication.reduce(into: [:]) { result, item in
            let valid = item.value.filter { $0.createdAt >= cutoff }
            if !valid.isEmpty { result[item.key] = valid }
        }
    }

    private func normalizedApplicationID(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return normalized.isEmpty ? nil : normalized
    }
}
