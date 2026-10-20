import Foundation

enum VoicePolishSettings {
    static let defaultCorrectionLimit = 200
    static let maximumCorrectionLimit = 200

    static func qualityMode(defaults: UserDefaults = .standard) -> VoicePolishQualityMode {
        // 2026-08-17：用户侧只保留一个语音润色模式。旧安装可能仍保存
        // fast / balanced / quality，但这些历史值不得继续改变生产行为。
        .automatic
    }

    static func setQualityMode(
        _ value: VoicePolishQualityMode,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(VoicePolishQualityMode.automatic.rawValue, forKey: DefaultsKeys.voicePolishQualityMode)
    }

    static func contextLevel(defaults: UserDefaults = .standard) -> WritingContextLevel {
        guard let raw = defaults.string(forKey: DefaultsKeys.voicePolishContextLevel),
              let value = WritingContextLevel(rawValue: raw) else { return .nearbyText }
        return value
    }

    static func setContextLevel(
        _ value: WritingContextLevel,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(value.rawValue, forKey: DefaultsKeys.voicePolishContextLevel)
    }

    static func personalizationEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: DefaultsKeys.voicePolishPersonalizationEnabled) as? Bool ?? true
    }

    static func setPersonalizationEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: DefaultsKeys.voicePolishPersonalizationEnabled)
    }

    static func terminologyLearningEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: DefaultsKeys.voicePolishTerminologyLearningEnabled) as? Bool ?? true
    }

    static func setTerminologyLearningEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: DefaultsKeys.voicePolishTerminologyLearningEnabled)
    }

    static func correctionLimit(defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: DefaultsKeys.voicePolishCorrectionLimit) != nil else {
            return defaultCorrectionLimit
        }
        return min(max(1, defaults.integer(forKey: DefaultsKeys.voicePolishCorrectionLimit)), maximumCorrectionLimit)
    }

    static func setCorrectionLimit(_ value: Int, defaults: UserDefaults = .standard) {
        defaults.set(min(max(1, value), maximumCorrectionLimit), forKey: DefaultsKeys.voicePolishCorrectionLimit)
    }

    static func sceneOverrides(defaults: UserDefaults = .standard) -> [String: WritingScene] {
        guard let data = defaults.data(forKey: DefaultsKeys.voicePolishSceneOverrides),
              let raw = try? JSONDecoder().decode([String: WritingScene].self, from: data)
        else { return [:] }
        return raw
    }

    static func setSceneOverrides(
        _ overrides: [String: WritingScene],
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        defaults.set(data, forKey: DefaultsKeys.voicePolishSceneOverrides)
    }

    /// 旧版本模型覆盖值，仅为历史配置和测试兼容保留；新配置由两档独立管理。
    static func modelOverride(defaults: UserDefaults = .standard) -> String? {
        let value = defaults.string(forKey: DefaultsKeys.voicePolishModelOverride)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    static func setModelOverride(_ value: String?, defaults: UserDefaults = .standard) {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if normalized.isEmpty {
            defaults.removeObject(forKey: DefaultsKeys.voicePolishModelOverride)
        } else {
            defaults.set(normalized, forKey: DefaultsKeys.voicePolishModelOverride)
        }
    }

    static func recentInputContextEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: DefaultsKeys.voicePolishRecentInputContextEnabled) as? Bool ?? true
    }

    static func setRecentInputContextEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: DefaultsKeys.voicePolishRecentInputContextEnabled)
    }
}
