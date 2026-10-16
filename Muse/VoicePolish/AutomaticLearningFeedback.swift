import Foundation
import Observation

enum AutomaticLearningFeedback: Sendable, Equatable {
    case learned([TerminologyCorrectionCandidate], hasConflict: Bool)
    case styleOnly
    case noTerms
    case failed
    case unavailable
    case unsafeField
    case protectedField
    case readOnlyField
    case unsupportedField
    case fieldUnresponsive
    case rangeUnavailable
    case selectionUnavailable
    case selectionActive
    case insertionUnverified
    case rangeUnsupported
    case rangeResponseInvalid
    case learningWindowTooLarge

    var didPersist: Bool {
        switch self {
        case .learned, .styleOnly: return true
        default: return false
        }
    }

    var message: String {
        switch self {
        case .learned(let candidates, let hasConflict):
            if hasConflict { return L("已保存改词，冲突词暂不替换", "Correction saved; conflicting forms paused") }
            let word = candidates.first?.canonical.prefix(24) ?? ""
            return candidates.count == 1
                ? L("已记住：\(word)", "Remembered: \(word)")
                : L("已记住 \(candidates.count) 个词", "Remembered \(candidates.count) words")
        case .styleOnly: return L("已学习这次表达修改", "Writing edit remembered")
        case .noTerms: return L("已检测修改，未提取到词条", "Edit detected; no word pair found")
        case .failed: return L("改词保存失败，请到词库重试", "Word could not be saved; check Vocabulary")
        case .unavailable: return L("此输入框暂不支持自动记词", "Automatic word learning is unavailable here")
        case .unsafeField: return L("此输入框未通过记词安全检查", "This field does not meet word-learning safety checks")
        case .protectedField: return L("密码或受保护输入框不自动记词", "Protected fields do not learn words automatically")
        case .readOnlyField: return L("只读内容不自动记词", "Read-only content does not learn words automatically")
        case .unsupportedField: return L("此输入框未提供可读取的文字", "This field does not expose readable text")
        case .fieldUnresponsive: return L("暂时无法读取输入框，请重试", "Text field could not be reached; try again")
        case .rangeUnavailable: return L("无法读取本次文字，未开始记词", "Inserted text could not be read; learning did not start")
        case .selectionUnavailable: return L("无法获取光标位置，未开始记词", "Caret position is unavailable; learning did not start")
        case .selectionActive: return L("文字仍被选中，未开始记词", "Text remains selected; learning did not start")
        case .insertionUnverified: return L("未能核对本次上屏文字，未开始记词", "Output could not be verified; learning did not start")
        case .rangeUnsupported: return L("此输入框不提供文字范围读取，无法自动记词", "This field does not expose text-range access")
        case .rangeResponseInvalid: return L("输入框返回的文字范围异常，未开始记词", "Text-range response is invalid; learning did not start")
        case .learningWindowTooLarge: return L("本次文字超出记词观察范围", "Output exceeds the word-learning window")
        }
    }

    var detail: String {
        if case .learned(let candidates, _) = self {
            return candidates.map { "\($0.alias) → \($0.canonical)" }.joined(separator: "；")
        }
        return message
    }
}

/// 只保存本次运行中的最近结果，词条正文仍由术语仓库负责持久化。
@Observable @MainActor
final class AutomaticLearningStatus {
    static let shared = AutomaticLearningStatus()
    private(set) var latest: AutomaticLearningFeedback?

    func update(_ feedback: AutomaticLearningFeedback) { latest = feedback }
}
