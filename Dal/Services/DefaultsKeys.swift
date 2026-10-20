import Foundation

/// 散落在多个文件中的 UserDefaults 偏好 key 的单一来源。
///
/// 仅收口「跨文件重复出现、易因拼写不一致而静默丢数据」的 key。
/// 凭证类 key（tf_asr_*/tf_llm_*）与仅在单个文件内以命名常量定义的 key
/// （如 ModelManager.selectedModelKey）已各自局部集中，无漂移风险，不在此处。
///
/// 注意：key 字符串与历史值逐字一致，切勿更改，否则会丢失既有用户设置。
enum DefaultsKeys {

    // MARK: - 本地 ASR 引擎开关
    static let qwen3FinalEnabled = "tf_qwen3FinalEnabled"
    static let sensevoiceEnabled = "tf_sensevoiceEnabled"

    // MARK: - 通用偏好
    static let language = "tf_language"
    static let showDockIcon = "tf_showDockIcon"
    static let preserveClipboard = "tf_preserveClipboard"
    static let hudStyle = "tf_hudStyle"
    static let hasCompletedSetup = "tf_hasCompletedSetup"
    static let didInitialLoginItemSetup = "tf_didInitialLoginItemSetup"
    static let defaultHotkeyStyle = "tf_defaultHotkeyStyle"
    /// 历史记录保留上限（条），默认见 HistoryStore.defaultRetentionLimit（REPAIR_PLAN C1）
    static let historyRetentionLimit = "tf_historyRetentionLimit"

    // MARK: - Voice Polish V2
    static let voicePolishQualityMode = "tf_voicePolishQualityMode"
    static let voicePolishContextLevel = "tf_voicePolishContextLevel"
    static let voicePolishPersonalizationEnabled = "tf_voicePolishPersonalizationEnabled"
    static let voicePolishTerminologyLearningEnabled = "tf_voicePolishTerminologyLearningEnabled"
    static let voicePolishCorrectionLimit = "tf_voicePolishCorrectionLimit"
    static let voicePolishSceneOverrides = "tf_voicePolishSceneOverrides"
    static let voicePolishSnippetMigrationCompleted = "tf_voicePolishSnippetMigrationCompleted"
    static let voicePolishModelOverride = "tf_voicePolishModelOverride"
    static let voicePolishRecentInputContextEnabled = "tf_voicePolishRecentInputContextEnabled"

    // MARK: - Provider 选择（此前在 ModesSettingsTab 与 KeychainService 各定义一遍，易漂移）
    static let selectedASRProvider = "tf_selectedASRProvider"
    static let selectedLLMProvider = "tf_selectedLLMProvider"
}
