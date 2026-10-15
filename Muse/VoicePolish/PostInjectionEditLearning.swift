import AppKit
import ApplicationServices
import Foundation

extension Notification.Name {
    static let voicePolishAutomaticLearningDidFinish = Notification.Name(
        "Muse.voicePolishAutomaticLearningDidFinish"
    )
}

/// 一次直出或润色注入后的短时、有限范围观察目标。
///
/// 只保留本次成稿、前后少量锚点和 AX 元素引用，不保存目标输入框全文。
/// 目标 App 不支持安全范围读取时不会创建该对象。
struct PostInjectionEditLearningTarget: @unchecked Sendable {
    let historyID: String
    let element: AXUIElement
    let originalText: String
    let windowStart: Int
    let prefix: String
    let suffix: String

    var maximumCandidateLength: Int {
        min(4_096, max((originalText as NSString).length * 2 + 128, 512))
    }
}

/// 直出与润色上屏后的自动纠正学习；直出只学习术语。
///
/// 仅观察标准 AX 输入框中“本次插入范围”附近的短窗口，最长 20 秒；连续稳定
/// 2 秒才确认修改。纯追加新内容不视为纠正，避免用户继续输入时产生误学习。
actor PostInjectionEditLearningMonitor {
    static let shared = PostInjectionEditLearningMonitor()

    private static let anchorLength = 24
    private static let pollingInterval: Duration = .milliseconds(500)
    private static let stableSampleCount = 4
    private static let maximumPollCount = 40
    private static let maximumConcurrentTargets = 3

    private var tasks: [String: Task<Void, Never>] = [:]
    private var insertionOrder: [String] = []
    private let coordinator: TerminologyHistoryTransactionCoordinator
    private let settingsContext: VocabularyStorageContext

    init(
        coordinator: TerminologyHistoryTransactionCoordinator = .shared,
        settingsContext: VocabularyStorageContext = .production
    ) {
        self.coordinator = coordinator
        self.settingsContext = settingsContext
    }

    static func shouldObserve(
        kind: ProcessingKind,
        injection: InjectionOutcome,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard case .inserted = injection else { return false }
        switch kind {
        case .direct:
            return VoicePolishSettings.terminologyLearningEnabled(defaults: defaults)
        case .voicePolish:
            return VoicePolishSettings.terminologyLearningEnabled(defaults: defaults)
                || VoicePolishSettings.personalizationEnabled(defaults: defaults)
        default:
            return false
        }
    }

    static func capture(
        injectedText: String,
        historyID: String
    ) -> PostInjectionEditLearningTarget? {
        guard AXIsProcessTrusted(), !injectedText.isEmpty else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        guard let focused = elementAttribute(
            systemWide,
            kAXFocusedUIElementAttribute as CFString
        ) else { return nil }

        let role = stringAttribute(focused, kAXRoleAttribute as CFString)
        let subrole = stringAttribute(focused, kAXSubroleAttribute as CFString)
        let editable = boolAttribute(focused, "AXEditable" as CFString)
        let protected = boolAttribute(focused, "AXProtectedContent" as CFString)
        guard WritingContextCapture.safetyForTesting(
            role: role,
            subrole: subrole,
            editable: editable,
            protectedContent: protected
        ) == .safe,
        !hasWebAreaAncestor(focused),
        let selectedRange = cfRangeAttribute(
            focused,
            kAXSelectedTextRangeAttribute as CFString
        ),
        selectedRange.length == 0 else { return nil }

        let insertedLength = (injectedText as NSString).length
        let insertionStart = selectedRange.location - insertedLength
        guard insertedLength > 0, insertionStart >= 0,
              let characterCount = numberOfCharacters(in: focused),
              selectedRange.location <= characterCount else { return nil }

        let prefixStart = max(0, insertionStart - anchorLength)
        let prefixLength = insertionStart - prefixStart
        let suffixLength = min(anchorLength, characterCount - selectedRange.location)
        let verificationLength = prefixLength + insertedLength + suffixLength
        guard let initialWindow = string(
            in: focused,
            range: CFRange(location: prefixStart, length: verificationLength)
        ) else { return nil }

        let value = initialWindow as NSString
        guard value.length == verificationLength,
              value.substring(with: NSRange(
                location: prefixLength,
                length: insertedLength
              )) == injectedText else { return nil }

        return PostInjectionEditLearningTarget(
            historyID: historyID,
            element: focused,
            originalText: injectedText,
            windowStart: prefixStart,
            prefix: value.substring(with: NSRange(location: 0, length: prefixLength)),
            suffix: value.substring(with: NSRange(
                location: prefixLength + insertedLength,
                length: suffixLength
            ))
        )
    }

    func start(
        _ target: PostInjectionEditLearningTarget,
        historyStore: HistoryStore
    ) {
        tasks[target.historyID]?.cancel()
        insertionOrder.removeAll { $0 == target.historyID }
        while tasks.count >= Self.maximumConcurrentTargets,
              let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            tasks.removeValue(forKey: oldest)?.cancel()
        }
        insertionOrder.append(target.historyID)
        tasks[target.historyID] = Task { [weak self] in
            await self?.observe(target, historyStore: historyStore)
        }
    }

    private func observe(
        _ target: PostInjectionEditLearningTarget,
        historyStore: HistoryStore
    ) async {
        defer {
            tasks.removeValue(forKey: target.historyID)
            insertionOrder.removeAll { $0 == target.historyID }
        }

        var lastCandidate: String?
        var stableSamples = 0
        for _ in 0..<Self.maximumPollCount {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: Self.pollingInterval)
            guard !Task.isCancelled else { return }

            guard let candidate = Self.currentCandidate(for: target) else {
                lastCandidate = nil
                stableSamples = 0
                continue
            }
            if candidate == lastCandidate {
                stableSamples += 1
            } else {
                lastCandidate = candidate
                stableSamples = 1
            }
            guard stableSamples >= Self.stableSampleCount else { continue }
            await learn(candidate, for: target, historyStore: historyStore)
            return
        }
    }

    private func learn(
        _ correctedText: String,
        for target: PostInjectionEditLearningTarget,
        historyStore: HistoryStore
    ) async {
        let didRecord = await recordCorrection(
            originalText: target.originalText,
            correctedText: correctedText,
            historyID: target.historyID,
            historyStore: historyStore
        )
        if didRecord {
            NotificationCenter.default.post(
                name: .voicePolishAutomaticLearningDidFinish,
                object: nil
            )
        }
    }

    /// 把确认后的本次修改写入既有纠正历史与术语仓库。AX 观察和持久化分层，
    /// 既便于使用临时目录做端到端测试，也避免出现第二套学习规则。
    @discardableResult
    func recordCorrection(
        originalText: String,
        correctedText: String,
        historyID: String,
        historyStore: HistoryStore
    ) async -> Bool {
        let defaults = settingsContext.userDefaults
        let terminologyEnabled = VoicePolishSettings.terminologyLearningEnabled(defaults: defaults)
        let history: HistoryRecord
        do {
            guard let record = try await historyStore.fetchOrThrow(ids: [historyID]).first else {
                return false
            }
            history = record
        } catch {
            AppLogger.log("[Muse] 自动纠正学习读取历史失败: \(error.localizedDescription)")
            return false
        }
        let isVoicePolish = history.status.hasPrefix("voice_polish_")
        guard isVoicePolish || history.supportsDirectTerminologyLearning else { return false }
        let styleEnabled = isVoicePolish
            && VoicePolishSettings.personalizationEnabled(defaults: defaults)
        let candidates = terminologyEnabled
            ? TerminologyCorrectionExtractor.candidates(
                generatedText: originalText,
                correctedText: correctedText
            )
            : []
        let learnsTerminology = terminologyEnabled && !candidates.isEmpty
        guard styleEnabled || learnsTerminology else { return false }

        do {
            _ = try await coordinator.confirmCorrection(
                historyStore: historyStore,
                historyID: historyID,
                candidates: candidates,
                correctedText: correctedText,
                scene: .unknown,
                personalizationEnabled: styleEnabled,
                retentionLimit: VoicePolishSettings.correctionLimit(defaults: defaults),
                learnStyle: styleEnabled,
                learnTerminology: learnsTerminology
            )
            return true
        } catch {
            AppLogger.log("[Muse] 自动纠正学习未写入: \(error.localizedDescription)")
            return false
        }
    }

    static func currentCandidate(
        for target: PostInjectionEditLearningTarget
    ) -> String? {
        guard let characterCount = numberOfCharacters(in: target.element),
              target.windowStart <= characterCount else { return nil }
        let prefixLength = (target.prefix as NSString).length
        let suffixLength = (target.suffix as NSString).length
        let requestedLength = min(
            characterCount - target.windowStart,
            prefixLength + target.maximumCandidateLength + suffixLength
        )
        guard requestedLength >= prefixLength + suffixLength,
              let window = string(
                in: target.element,
                range: CFRange(location: target.windowStart, length: requestedLength)
              ) else { return nil }

        // 注入发生在输入框末尾时没有外部 suffix 锚点。此时不能使用编辑后的
        // 光标位置作为成稿终点：用户替换中间术语后，光标通常停在术语后面，
        // 会把原成稿后半段误判为删除。范围读取已经从插入起点覆盖到字段末尾，
        // 因此使用窗口末尾；若用户只是继续追加，extractCandidate 会明确忽略。
        let candidateEnd = target.suffix.isEmpty ? (window as NSString).length : nil
        return extractCandidate(
            original: target.originalText,
            prefix: target.prefix,
            suffix: target.suffix,
            windowText: window,
            caretOffset: candidateEnd,
            maximumCandidateLength: target.maximumCandidateLength
        )
    }

    /// 纯函数边界供单元测试验证“替换会学习、纯追加不会学习”。
    static func extractCandidate(
        original: String,
        prefix: String,
        suffix: String,
        windowText: String,
        caretOffset: Int?,
        maximumCandidateLength: Int = 4_096
    ) -> String? {
        let window = windowText as NSString
        let prefixLength = (prefix as NSString).length
        guard window.length >= prefixLength,
              window.substring(with: NSRange(location: 0, length: prefixLength)) == prefix
        else { return nil }

        let end: Int
        if !suffix.isEmpty {
            let suffixRange = window.range(
                of: suffix,
                options: .backwards,
                range: NSRange(
                    location: prefixLength,
                    length: window.length - prefixLength
                )
            )
            guard suffixRange.location != NSNotFound else { return nil }
            end = suffixRange.location
        } else {
            guard let caretOffset,
                  caretOffset >= prefixLength,
                  caretOffset <= window.length else { return nil }
            end = caretOffset
        }

        let length = end - prefixLength
        guard length > 0, length <= maximumCandidateLength else { return nil }
        let candidate = window.substring(with: NSRange(location: prefixLength, length: length))
        guard candidate != original,
              !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !candidate.hasPrefix(original) else { return nil }
        return candidate
    }

    private static func numberOfCharacters(in element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXNumberOfCharactersAttribute as CFString,
            &value
        ) == .success,
        let number = value as? NSNumber else { return nil }
        return number.intValue
    }

    private static func string(in element: AXUIElement, range: CFRange) -> String? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        var mutableRange = range
        guard let parameter = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    private static func stringAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func boolAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private static func cfRangeAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return range
    }

    private static func elementAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func hasWebAreaAncestor(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<6 {
            guard let value = current else { return false }
            if stringAttribute(value, kAXRoleAttribute as CFString) == "AXWebArea" {
                return true
            }
            current = elementAttribute(value, kAXParentAttribute as CFString)
        }
        return false
    }
}
