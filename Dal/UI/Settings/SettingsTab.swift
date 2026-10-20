// 侧栏按用户任务组织；处理设置集中在输出模式，词库只保留一个入口。
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, modes, vocabulary, models, about
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .general: return L("概览与记录", "Overview")
        case .modes: return L("输出模式", "Output Modes")
        case .vocabulary: return L("我的词库", "My Vocabulary")
        case .models: return L("模型配置", "Model Config")
        case .about: return L("关于", "About")
        }
    }
}
