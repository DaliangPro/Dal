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
struct PostInjectionLearningField: Sendable {
    let isAvailable: @Sendable () async -> Bool
    let selectedRange: @Sendable () async -> CFRange?
    let characterCount: @Sendable () async -> Int?
    let stringForRange: @Sendable (CFRange) async -> String?
}

struct PostInjectionEditLearningTarget: Sendable {
    let historyID: String
    let field: PostInjectionLearningField
    let originalText: String
    let windowStart: Int
    let prefix: String
    let suffix: String

    var maximumCandidateLength: Int {
        min(
            PostInjectionEditLearningMonitor.maximumWindowLength - (prefix as NSString).length - (suffix as NSString).length,
            max((originalText as NSString).length * 2 + 128, 512)
        )
    }
}

enum PostInjectionLearningFieldCapture: Sendable {
    case field(PostInjectionLearningField)
    case unavailable(AutomaticLearningFeedback)
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
    static let maximumWindowLength = 4_096

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

    static func focusedField() async -> PostInjectionLearningFieldCapture {
        guard AXIsProcessTrusted() else { return .unavailable(.unavailable) }
        guard let focused = focusedElement() else { return .unavailable(.unavailable) }

        var ownerPID: pid_t = 0
        guard AXUIElementGetPid(focused, &ownerPID) == .success else { return .unavailable(.unavailable) }
        AXUIElementSetMessagingTimeout(focused, 0.2)
        let field = AccessibilityLearningField(element: focused, ownerPID: ownerPID)
        if let reason = await field.rejectionReason() { return .unavailable(reason) }
        return .field(PostInjectionLearningField(
            isAvailable: { await field.isAvailable() },
            selectedRange: { await field.read { cfRangeAttribute($0, kAXSelectedTextRangeAttribute as CFString) } },
            characterCount: { await field.read { numberOfCharacters(in: $0) } },
            stringForRange: { range in await field.read { string(in: $0, range: range) } }
        ))
    }

    /// 粘贴事件已发出不等于目标已消费。固定原输入框，短暂重试，直到确实读到本次上屏正文。
    static func capture(
        injectedText: String, historyID: String, field: PostInjectionLearningField
    ) async -> PostInjectionEditLearningTarget? {
        guard (1...maximumWindowLength).contains((injectedText as NSString).length) else { return nil }
        for attempt in 0..<20 {
            guard !Task.isCancelled, await field.isAvailable() else { return nil }
            if let target = await captureVisibleText(injectedText: injectedText, historyID: historyID, field: field) {
                return target
            }
            if attempt < 19 { try? await Task.sleep(for: .milliseconds(60)) }
        }
        return nil
    }

    private static func captureVisibleText(
        injectedText: String, historyID: String, field: PostInjectionLearningField
    ) async -> PostInjectionEditLearningTarget? {
        guard let selectedRange = await field.selectedRange(), selectedRange.length == 0 else { return nil }

        let insertedLength = (injectedText as NSString).length
        let insertionStart = selectedRange.location - insertedLength
        guard insertedLength > 0, insertionStart >= 0,
              let characterCount = await field.characterCount(),
              selectedRange.location <= characterCount else { return nil }

        let prefixStart = max(0, insertionStart - anchorLength)
        let prefixLength = insertionStart - prefixStart
        let suffixLength = min(anchorLength, characterCount - selectedRange.location)
        let verificationLength = prefixLength + insertedLength + suffixLength
        guard verificationLength <= maximumWindowLength,
              let initialWindow = await field.stringForRange(
            CFRange(location: prefixStart, length: verificationLength)
        ) else { return nil }

        let value = initialWindow as NSString
        guard value.length == verificationLength,
              value.substring(with: NSRange(
                location: prefixLength,
                length: insertedLength
              )) == injectedText,
              await field.isAvailable() else { return nil }

        return PostInjectionEditLearningTarget(
            historyID: historyID,
            field: field,
            originalText: injectedText,
            windowStart: prefixStart,
            prefix: value.substring(with: NSRange(location: 0, length: prefixLength)),
            suffix: value.substring(with: NSRange(
                location: prefixLength + insertedLength,
                length: suffixLength
            ))
        )
    }

    /// 全局按输入框能力判断，不按 APP 或网页来源设置白名单。
    /// Subrole 是可选属性，AXProtectedContent/AXEditable 并非所有标准控件提供；
    /// 属性不支持不能当成密码框。明确保护、只读、未知角色或读取出错仍拒绝。
    /// 范围读取和插入正文的逐字校验仍由 capture 执行，不读取整份网页或聊天记录。
    static func supportsCapture(
        role: String?, subrole: String?, editable: Bool?, protectedContent: Bool?,
        metadataReadable: Bool = true
    ) -> Bool {
        rejectionReason(
            role: role, subrole: subrole, editable: editable,
            protectedContent: protectedContent, metadataReadable: metadataReadable
        ) == nil
    }

    static func rejectionReason(
        role: String?, subrole: String?, editable: Bool?, protectedContent: Bool?,
        metadataReadable: Bool = true
    ) -> AutomaticLearningFeedback? {
        if protectedContent == true || subrole == "AXSecureTextField" { return .protectedField }
        if editable == false { return .readOnlyField }
        guard metadataReadable else { return .fieldUnresponsive }
        guard role == "AXTextField" || role == "AXTextArea"
            || (role == "AXComboBox" && editable == true) else { return .unsupportedField }
        return nil
    }

    static func report(_ feedback: AutomaticLearningFeedback) {
        NotificationCenter.default.post(name: .voicePolishAutomaticLearningDidFinish, object: feedback)
    }

    /// 系统焦点优先，兼容焦点宿主不是前台应用的浮动面板。
    /// 系统未返回焦点时才查询当前应用，不扫描窗口、后代或其他应用。
    static func resolveFocusedElement<Element>(
        system: () -> Element?, application: () -> Element?
    ) -> Element? {
        system() ?? application()
    }

    private static func focusedElement() -> AXUIElement? {
        resolveFocusedElement(system: {
            elementAttribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString)
        }, application: {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(applicationElement, 0.2)
            return elementAttribute(applicationElement, kAXFocusedUIElementAttribute as CFString)
        })
    }

    func start(
        injectedText: String,
        historyID: String,
        capture: PostInjectionLearningFieldCapture,
        historyStore: HistoryStore
    ) {
        tasks[historyID]?.cancel()
        insertionOrder.removeAll { $0 == historyID }
        while tasks.count >= Self.maximumConcurrentTargets,
              let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            tasks.removeValue(forKey: oldest)?.cancel()
        }
        insertionOrder.append(historyID)
        tasks[historyID] = Task { [weak self] in
            await self?.captureAndObserve(
                injectedText: injectedText, historyID: historyID, capture: capture, historyStore: historyStore
            )
        }
    }

    private func captureAndObserve(
        injectedText: String, historyID: String, capture: PostInjectionLearningFieldCapture, historyStore: HistoryStore
    ) async {
        defer {
            tasks.removeValue(forKey: historyID)
            insertionOrder.removeAll { $0 == historyID }
        }
        guard case .field(let field) = capture else {
            if case .unavailable(let feedback) = capture,
               VoicePolishSettings.terminologyLearningEnabled(defaults: settingsContext.userDefaults) {
                Self.report(feedback)
            }
            return
        }
        guard let target = await Self.capture(injectedText: injectedText, historyID: historyID, field: field) else {
            if !Task.isCancelled,
               VoicePolishSettings.terminologyLearningEnabled(defaults: settingsContext.userDefaults) {
                Self.report(.rangeUnavailable)
            }
            return
        }
        await observe(target, historyStore: historyStore)
    }

    private func observe(_ target: PostInjectionEditLearningTarget, historyStore: HistoryStore) async {
        var lastCandidate: String?
        var lastAttemptedCandidate: String?
        var stableSamples = 0
        for _ in 0..<Self.maximumPollCount {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: Self.pollingInterval)
            guard !Task.isCancelled else { return }

            guard await target.field.isAvailable() else { return }
            guard let candidate = await Self.currentCandidate(for: target) else {
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
            guard stableSamples >= Self.stableSampleCount, candidate != lastAttemptedCandidate else { continue }
            lastAttemptedCandidate = candidate
            let feedback = await recordCorrectionFeedback(
                originalText: target.originalText, correctedText: candidate,
                historyID: target.historyID, historyStore: historyStore
            )
            if let feedback {
                Self.report(feedback)
                if case .learned = feedback { return }
            }
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
        await recordCorrectionFeedback(
            originalText: originalText, correctedText: correctedText,
            historyID: historyID, historyStore: historyStore
        )?.didPersist ?? false
    }

    func recordCorrectionFeedback(
        originalText: String,
        correctedText: String,
        historyID: String,
        historyStore: HistoryStore
    ) async -> AutomaticLearningFeedback? {
        let defaults = settingsContext.userDefaults
        let terminologyEnabled = VoicePolishSettings.terminologyLearningEnabled(defaults: defaults)
        let history: HistoryRecord
        do {
            guard let record = try await historyStore.fetchOrThrow(ids: [historyID]).first else {
                return .failed
            }
            history = record
        } catch {
            AppLogger.log("[Muse] 自动纠正学习读取历史失败: \(error.localizedDescription)")
            return .failed
        }
        let isVoicePolish = history.status.hasPrefix("voice_polish_")
        guard isVoicePolish || history.supportsDirectTerminologyLearning else { return .failed }
        let styleEnabled = isVoicePolish
            && VoicePolishSettings.personalizationEnabled(defaults: defaults)
        let candidates = terminologyEnabled
            ? TerminologyCorrectionExtractor.candidates(
                generatedText: originalText,
                correctedText: correctedText
            )
            : []
        let learnsTerminology = terminologyEnabled && !candidates.isEmpty
        guard styleEnabled || learnsTerminology else {
            return terminologyEnabled ? .noTerms : nil
        }

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
            guard learnsTerminology else { return .styleOnly }
            let saved = TerminologyRepository.load(context: settingsContext)
            let keys = Set(candidates.map { TerminologyText.normalizedKey($0.alias) })
            let hasConflict = saved.conflicts.contains { keys.contains($0.normalizedAlias) }
            return .learned(candidates, hasConflict: hasConflict)
        } catch {
            AppLogger.log("[Muse] 自动纠正学习未写入: \(error.localizedDescription)")
            return .failed
        }
    }

    static func currentCandidate(
        for target: PostInjectionEditLearningTarget
    ) async -> String? {
        guard await target.field.isAvailable(),
              let characterCount = await target.field.characterCount(),
              target.windowStart >= 0,
              target.windowStart <= characterCount else { return nil }
        let prefixLength = (target.prefix as NSString).length
        let suffixLength = (target.suffix as NSString).length
        let requestedLength = min(
            characterCount - target.windowStart,
            prefixLength + target.maximumCandidateLength + suffixLength,
            maximumWindowLength
        )
        guard requestedLength >= prefixLength + suffixLength,
              !target.suffix.isEmpty || requestedLength == characterCount - target.windowStart,
              let window = await target.field.stringForRange(
                CFRange(location: target.windowStart, length: requestedLength)
              ),
              (window as NSString).length == requestedLength,
              await target.field.isAvailable() else { return nil }

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

    /// 固定注入时的元素；只查询这一个控件，焦点离开或安全属性变化后立即停止。
    private struct AccessibilityLearningField: @unchecked Sendable {
        let element: AXUIElement
        let ownerPID: pid_t

        func read<T: Sendable>(_ operation: @escaping @Sendable (AXUIElement) -> T) async -> T {
            if ownerPID == ProcessInfo.processInfo.processIdentifier {
                return await MainActor.run { operation(element) }
            }
            return operation(element)
        }

        func rejectionReason() async -> AutomaticLearningFeedback? {
            await read { element in
                var readable = true
                let role = optionalAttribute(element, kAXRoleAttribute as CFString, readable: &readable) as String?
                let subrole = optionalAttribute(element, kAXSubroleAttribute as CFString, readable: &readable) as String?
                let editable = optionalAttribute(element, "AXEditable" as CFString, readable: &readable) as Bool?
                let protected = optionalAttribute(element, "AXProtectedContent" as CFString, readable: &readable) as Bool?
                return PostInjectionEditLearningMonitor.rejectionReason(
                    role: role, subrole: subrole, editable: editable, protectedContent: protected,
                    metadataReadable: readable
                )
            }
        }

        func isAvailable() async -> Bool {
            guard await rejectionReason() == nil else { return false }
            return await read { element in
                guard let focused = focusedElement() else { return false }
                return CFEqual(element, focused)
            }
        }
    }

    private static func optionalAttribute<T>(
        _ element: AXUIElement, _ attribute: CFString, readable: inout Bool
    ) -> T? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        if error == .attributeUnsupported || error == .noValue { return nil }
        guard error == .success else { readable = false; return nil }
        guard let value else { return nil }
        guard let typed = value as? T else { readable = false; return nil }
        return typed
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
        guard range.location >= 0, (0...maximumWindowLength).contains(range.length) else { return nil }
        var mutableRange = range
        guard let parameter = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter,
            &value
        ) == .success else { return nil }
        guard let text = value as? String, (text as NSString).length == range.length else { return nil }
        return text
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

}
