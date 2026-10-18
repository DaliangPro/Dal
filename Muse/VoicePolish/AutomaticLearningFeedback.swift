import AppKit
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
            let pairs = candidates.map { "\($0.alias) → \($0.canonical)" }.joined(separator: "；")
            return hasConflict
                ? L("已保存：\(pairs)（冲突待确认）", "Saved: \(pairs) (conflict pending)")
                : L("已记住：\(pairs)", "Remembered: \(pairs)")
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

    /// 悬浮条显示一组真实对应关系；完整列表由词库最近结果展示。
    /// 超长词分别缩略两端，避免整行裁切后只剩“已记住”或错词。
    var hudMessage: String { hudMessage(reserving: 0) }

    func hudMessage(reserving reservedWidth: CGFloat) -> String {
        let candidates: [TerminologyCorrectionCandidate]
        let conflict: Bool
        switch self {
        case .learned(let pairs, let hasConflict): (candidates, conflict) = (pairs, hasConflict)
        default: return message
        }
        guard let first = candidates.first else { return message }
        let prefix = conflict ? L("已保存：", "Saved: ") : L("已记住：", "Remembered: ")
        let count = candidates.count > 1 ? L("（共 \(candidates.count) 组）", " (\(candidates.count) pairs)") : ""
        let suffix = count + (conflict ? L("（冲突待确认）", " (conflict pending)") : "")
        let full = prefix + first.alias + " → " + first.canonical + suffix
        let available = TF.barWidth - 84 - reservedWidth
        guard Self.width(full) > available else { return full }
        let wordBudget = max(12, (available - Self.width(prefix + " → " + suffix)) / 2)
        return prefix + Self.fitting(first.alias, width: wordBudget) + " → "
            + Self.fitting(first.canonical, width: wordBudget) + suffix
    }

    private static func width(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: TF.hudNSFontTitle]).width)
    }

    private static func fitting(_ text: String, width: CGFloat) -> String {
        guard Self.width(text) > width else { return text }
        var prefix = text
        while !prefix.isEmpty, Self.width(prefix + "…") > width { prefix.removeLast() }
        return prefix + "…"
    }

    var detail: String {
        switch self {
        case .learned(let candidates, _):
            return candidates.map { "\($0.alias) → \($0.canonical)" }.joined(separator: "；")
        default: return message
        }
    }
}

/// 只保存本次运行中的最近结果，词条正文仍由术语仓库负责持久化。
@Observable @MainActor
final class AutomaticLearningStatus {
    static let shared = AutomaticLearningStatus()
    private(set) var latest: AutomaticLearningFeedback?
    private(set) var undo: AutomaticLearningUndo?

    func update(_ feedback: AutomaticLearningFeedback, undo: AutomaticLearningUndo? = nil) {
        latest = feedback
        self.undo = undo
    }
}

/// 一次成功保存的收据，撤销绑定确切版本的纠正记录，不是“删除最近词条”。
struct AutomaticLearningReceipt: Sendable {
    let feedback: AutomaticLearningFeedback
    let undo: AutomaticLearningUndo?

    init(_ feedback: AutomaticLearningFeedback, undo: AutomaticLearningUndo? = nil) {
        self.feedback = feedback
        self.undo = undo
    }
}

extension Notification.Name {
    static let voicePolishAutomaticLearningDidUndo = Notification.Name("Muse.voicePolishAutomaticLearningDidUndo")
}

@Observable @MainActor
final class AutomaticLearningUndo {
    private(set) var isRunning = false
    private(set) var didUndo = false
    private(set) var didFail = false
    @ObservationIgnored private let operation: @Sendable () async throws -> Void

    init(operation: @escaping @Sendable () async throws -> Void) { self.operation = operation }

    var canUndo: Bool { !isRunning && !didUndo }
    var message: String? {
        if didUndo { return L("已撤销此次记词", "Word learning undone") }
        if didFail { return L("撤销失败，请到记录中检查", "Undo failed; check History") }
        return nil
    }

    func perform() async {
        guard canUndo else { return }
        isRunning = true
        didFail = false
        defer { isRunning = false }
        do {
            try await operation()
            didUndo = true
            NotificationCenter.default.post(name: .voicePolishAutomaticLearningDidUndo, object: nil)
        } catch {
            didFail = true
        }
    }
}
