import AppKit
import ApplicationServices
import Foundation

extension Notification.Name {
    static let voicePolishAutomaticLearningDidFinish = Notification.Name(
        "Dal.voicePolishAutomaticLearningDidFinish"
    )
}

/// 一次直出或润色注入后的短时、有限范围观察目标。
///
/// 只保留本次成稿、前后少量锚点和 AX 元素引用，不保存目标输入框全文。
/// 目标 App 不支持安全范围读取时不会创建该对象。
struct PostInjectionLearningField: Sendable {
    let isAvailable: @Sendable () async -> Bool
    let canFinishAfterFocusLoss: @Sendable () async -> Bool
    let selectedRange: @Sendable () async -> CFRange?
    let characterCount: @Sendable () async -> Int?
    let readRange: @Sendable (CFRange) async -> PostInjectionRangeRead

    init(
        isAvailable: @escaping @Sendable () async -> Bool,
        selectedRange: @escaping @Sendable () async -> CFRange?,
        characterCount: @escaping @Sendable () async -> Int?,
        readRange: @escaping @Sendable (CFRange) async -> PostInjectionRangeRead,
        canFinishAfterFocusLoss: @escaping @Sendable () async -> Bool = { false }
    ) {
        self.canFinishAfterFocusLoss = canFinishAfterFocusLoss
        self.isAvailable = isAvailable
        self.selectedRange = selectedRange
        self.characterCount = characterCount
        self.readRange = readRange
    }

    init(
        isAvailable: @escaping @Sendable () async -> Bool,
        selectedRange: @escaping @Sendable () async -> CFRange?,
        characterCount: @escaping @Sendable () async -> Int?,
        stringForRange: @escaping @Sendable (CFRange) async -> String?,
        canFinishAfterFocusLoss: @escaping @Sendable () async -> Bool = { false }
    ) {
        self.init(isAvailable: isAvailable, selectedRange: selectedRange, characterCount: characterCount,
                  readRange: { range in
            guard let text = await stringForRange(range) else { return .unavailable }
            return .text(text)
        }, canFinishAfterFocusLoss: canFinishAfterFocusLoss)
    }
}

enum PostInjectionCaptureResult: Sendable {
    case captured(PostInjectionEditLearningTarget)
    case failure(PostInjectionCaptureFailure)
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
/// 仅观察原安全输入框中“本次插入范围”附近的短窗口；相关编辑延长空闲期，
/// 总时长有硬上限。纯追加新内容不视为纠正，避免用户继续输入时产生误学习。
actor PostInjectionEditLearningMonitor {
    static let shared = PostInjectionEditLearningMonitor()

    private static let anchorLength = 24
    private static let maximumConcurrentTargets = 3
    static let maximumWindowLength = 4_096

    private var tasks: [String: Task<Void, Never>] = [:]
    private var insertionOrder: [String] = []
    private let coordinator: TerminologyHistoryTransactionCoordinator
    private let settingsContext: VocabularyStorageContext
    private let observationTiming: PostInjectionObservationTiming
    private let observationNow: @Sendable () -> ContinuousClock.Instant
    private let observationSleep: @Sendable (Duration) async throws -> Void
    private let diagnostic: @Sendable (String) -> Void

    init(
        coordinator: TerminologyHistoryTransactionCoordinator = .shared,
        settingsContext: VocabularyStorageContext = .production,
        observationTiming: PostInjectionObservationTiming = PostInjectionObservationTiming(),
        observationNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        observationSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        diagnostic: @escaping @Sendable (String) -> Void = { DebugFileLogger.log($0) }
    ) {
        self.coordinator = coordinator
        self.settingsContext = settingsContext
        self.observationTiming = observationTiming
        self.observationNow = observationNow
        self.observationSleep = observationSleep
        self.diagnostic = diagnostic
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
            readRange: { range in await field.read { readRange(in: $0, range: range) } },
            canFinishAfterFocusLoss: { await field.canFinishAfterFocusLoss() }
        ))
    }

    /// 粘贴事件已发出不等于目标已消费。固定原输入框，短暂重试，直到确实读到本次上屏正文。
    static func capture(
        injectedText: String, historyID: String, field: PostInjectionLearningField
    ) async -> PostInjectionEditLearningTarget? {
        if case .captured(let target) = await captureResult(
            injectedText: injectedText, historyID: historyID, field: field
        ) { return target }
        return nil
    }

    static func captureResult(
        injectedText: String, historyID: String, field: PostInjectionLearningField,
        maximumAttempts: Int = 30, retryDelay: Duration = .milliseconds(100)
    ) async -> PostInjectionCaptureResult {
        guard (1...maximumWindowLength).contains(injectedText.utf16.count) else { return .failure(.windowTooLarge) }
        var lastFailure = PostInjectionCaptureFailure.insertionPending
        let attempts = min(30, max(1, maximumAttempts))
        let deadline = ContinuousClock.now + .seconds(3)
        for attempt in 0..<attempts {
            if ContinuousClock.now >= deadline { break }
            guard !Task.isCancelled, await field.isAvailable() else { return .failure(.focusChanged) }
            let result = await captureVisibleText(injectedText: injectedText, historyID: historyID, field: field)
            switch result {
            case .captured: return result
            case .failure(let failure):
                lastFailure = failure
                if !failure.canRetry { return result }
            }
            if attempt + 1 < attempts { try? await Task.sleep(for: retryDelay) }
        }
        return .failure(lastFailure)
    }

    private static func captureVisibleText(
        injectedText: String, historyID: String, field: PostInjectionLearningField
    ) async -> PostInjectionCaptureResult {
        guard let selectedRange = await field.selectedRange(), selectedRange.location >= 0,
              selectedRange.location != NSNotFound,
              selectedRange.length >= 0 else { return .failure(.selectionUnavailable) }
        guard selectedRange.length == 0 else { return .failure(.selectionActive) }

        let insertedLength = (injectedText as NSString).length
        let insertionStart = selectedRange.location - insertedLength
        guard insertedLength > 0, insertionStart >= 0 else { return .failure(.insertionPending) }

        let prefixStart = max(0, insertionStart - anchorLength)
        let prefixLength = insertionStart - prefixStart
        let maximumLength = min(maximumWindowLength, prefixLength + insertedLength + anchorLength)
        let window = await PostInjectionBoundedWindow.read(
            field: field, start: prefixStart, minimumEnd: selectedRange.location,
            maximumLength: maximumLength, reportedCount: await field.characterCount()
        )
        let initialWindow: String
        switch window {
        case .window(let text, _): initialWindow = text
        case .failure(let reason): return .failure(reason)
        }

        let value = initialWindow as NSString
        guard value.length >= prefixLength + insertedLength,
              value.substring(with: NSRange(
                location: prefixLength,
                length: insertedLength
              )) == injectedText else { return .failure(.textMismatch) }
        guard await field.isAvailable() else { return .failure(.focusChanged) }
        let suffixLength = value.length - prefixLength - insertedLength

        return .captured(PostInjectionEditLearningTarget(
            historyID: historyID,
            field: field,
            originalText: injectedText,
            windowStart: prefixStart,
            prefix: value.substring(with: NSRange(location: 0, length: prefixLength)),
            suffix: value.substring(with: NSRange(
                location: prefixLength + insertedLength,
                length: suffixLength
            ))
        ))
    }

    /// 全局按输入框能力判断，不按 APP 或网页来源设置白名单。
    /// Subrole 是可选属性，AXProtectedContent/AXEditable 并非所有标准控件提供；
    /// 属性不支持不能当成密码框。明确保护、只读、未知角色且没有明确可编辑标记、
    /// 或读取出错仍拒绝。
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
            || subrole == "AXSearchField"
            || editable == true else { return .unsupportedField }
        return nil
    }

    static func report(_ receipt: AutomaticLearningReceipt) {
        var actions: [String: Any] = [:]
        if let undo = receipt.undo { actions["undo"] = undo }
        NotificationCenter.default.post(
            name: .voicePolishAutomaticLearningDidFinish, object: receipt.feedback,
            userInfo: actions
        )
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
        start(
            injectedText: injectedText,
            historyID: historyID,
            captureProvider: { capture },
            historyStore: historyStore
        )
    }

    /// 让监控器在上屏后自行获取输入框，避免 RecognitionSession 只查一次焦点。
    func start(
        injectedText: String,
        historyID: String,
        captureProvider: @escaping @Sendable () async -> PostInjectionLearningFieldCapture,
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
        diagnostic("learning.capture started units=\(injectedText.utf16.count)")
        tasks[historyID] = Task { [weak self] in
            await self?.captureAndObserve(
                injectedText: injectedText, historyID: historyID,
                captureProvider: captureProvider, historyStore: historyStore
            )
        }
    }

    private func captureAndObserve(
        injectedText: String,
        historyID: String,
        captureProvider: @escaping @Sendable () async -> PostInjectionLearningFieldCapture,
        historyStore: HistoryStore
    ) async {
        defer {
            tasks.removeValue(forKey: historyID)
            insertionOrder.removeAll { $0 == historyID }
        }
        let result = await Self.captureTargetWithRetry(
            injectedText: injectedText, historyID: historyID, captureProvider: captureProvider
        )
        guard case .captured(let target) = result else {
            if case .failure(let failure) = result {
                DebugFileLogger.log("learning.capture failure=\(failure.rawValue) units=\(injectedText.utf16.count)")
            }
            // 读取失败、焦点变化、范围异常都不打断输入；成功学习才需要反馈。
            return
        }
        diagnostic("learning.capture verified units=\(injectedText.utf16.count)")
        await observe(target, historyStore: historyStore)
    }

    private static func captureTargetWithRetry(
        injectedText: String,
        historyID: String,
        captureProvider: @escaping @Sendable () async -> PostInjectionLearningFieldCapture
    ) async -> PostInjectionCaptureResult {
        // 上屏后的焦点可能在输入框、剪贴板粘贴和宿主 AX 树之间短暂切换。
        // 每次重试都重新获取焦点元素，避免拿着已经失效的 AX 引用继续读取。
        var lastResult = PostInjectionCaptureResult.failure(.insertionPending)
        var lastUnavailable: AutomaticLearningFeedback?
        for attempt in 0..<8 {
            guard !Task.isCancelled else { return lastResult }
            let capture = await captureProvider()
            guard case .field(let field) = capture else {
                if case .unavailable(let feedback) = capture { lastUnavailable = feedback }
                if case .unavailable = capture, Self.shouldRetryCapture(capture), attempt + 1 < 8 {
                    try? await Task.sleep(for: .milliseconds(120))
                    continue
                }
                if let lastUnavailable {
                    DebugFileLogger.log(
                        "learning.capture unavailable reason=\(String(describing: lastUnavailable))"
                    )
                }
                return .failure(.focusChanged)
            }
            let result = await captureResult(
                injectedText: injectedText, historyID: historyID, field: field
            )
            if case .captured = result { return result }
            lastResult = result
            guard case .failure(let failure) = result,
                  Self.shouldRetryCaptureFailure(failure), attempt + 1 < 8 else {
                return result
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return lastResult
    }

    private static func shouldRetryCapture(_ capture: PostInjectionLearningFieldCapture) -> Bool {
        guard case .unavailable(let feedback) = capture else { return false }
        switch feedback {
        case .unavailable, .fieldUnresponsive, .unsupportedField:
            return true
        default:
            return false
        }
    }

    private static func shouldRetryCaptureFailure(_ failure: PostInjectionCaptureFailure) -> Bool {
        switch failure {
        case .focusChanged, .selectionUnavailable, .selectionActive, .insertionPending,
             .rangeUnreadable, .invalidRangeResponse, .textMismatch:
            return true
        case .rangeUnsupported, .windowTooLarge:
            return false
        }
    }

    private func observe(_ target: PostInjectionEditLearningTarget, historyStore: HistoryStore) async {
        let started = observationNow()
        var window = PostInjectionObservationWindow(timing: observationTiming)
        var lastAttemptedCandidate: String?
        while window.isOpen(at: started.duration(to: observationNow())) {
            guard !Task.isCancelled else {
                diagnostic("learning.observe stopped reason=cancelled")
                return
            }
            try? await observationSleep(observationTiming.pollingInterval)
            guard !Task.isCancelled else {
                diagnostic("learning.observe stopped reason=cancelled")
                return
            }
            guard window.isOpen(at: started.duration(to: observationNow())) else { break }
            if !(await target.field.isAvailable()) {
                // 只使用刚才在原安全控件中完整读回的快照；不读取失焦后的正文。
                // 控件受保护/只读/失联时不作最终提交，取消也不会触发此路径。
                if await target.field.canFinishAfterFocusLoss(),
                   let candidate = window.recentCandidate(at: started.duration(to: observationNow())),
                   candidate != lastAttemptedCandidate, !Task.isCancelled {
                    await persistAndReport(candidate, target: target, historyStore: historyStore)
                }
                diagnostic("learning.observe stopped reason=fieldUnavailable")
                return
            }
            let candidate = await Self.currentCandidate(for: target)
            let elapsed = started.duration(to: observationNow())
            let changed = candidate != window.candidate
            window.sample(candidate, at: elapsed)
            if changed, let candidate {
                diagnostic("learning.observe sampled units=\(candidate.utf16.count)")
            }
            guard let candidate, window.isStable(at: elapsed), candidate != lastAttemptedCandidate else { continue }
            lastAttemptedCandidate = candidate
            if await persistAndReport(candidate, target: target, historyStore: historyStore) { return }
        }
        diagnostic("learning.observe stopped reason=expired")
    }

    @discardableResult
    private func persistAndReport(
        _ candidate: String, target: PostInjectionEditLearningTarget, historyStore: HistoryStore
    ) async -> Bool {
        guard !Task.isCancelled,
              let receipt = await recordCorrectionReceipt(
                originalText: target.originalText, correctedText: candidate,
                historyID: target.historyID, historyStore: historyStore
              ) else { return false }
        switch receipt.feedback {
        case .learned: break
        default: return false
        }
        Self.report(receipt)
        return true
    }

    /// 把捕获到的本次修改写入既有纠正历史与术语仓库。AX 观察和持久化分层，
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
        originalText: String, correctedText: String, historyID: String, historyStore: HistoryStore
    ) async -> AutomaticLearningFeedback? {
        await recordCorrectionReceipt(
            originalText: originalText, correctedText: correctedText,
            historyID: historyID, historyStore: historyStore
        )?.feedback
    }

    func recordCorrectionReceipt(
        originalText: String,
        correctedText: String,
        historyID: String,
        historyStore: HistoryStore
    ) async -> AutomaticLearningReceipt? {
        let defaults = settingsContext.userDefaults
        let terminologyEnabled = VoicePolishSettings.terminologyLearningEnabled(defaults: defaults)
        let history: HistoryRecord
        do {
            guard let record = try await historyStore.fetchOrThrow(ids: [historyID]).first else {
                return AutomaticLearningReceipt(.failed)
            }
            history = record
        } catch {
            AppLogger.log("[Dal] 自动纠正学习读取历史失败: \(error.localizedDescription)")
            return AutomaticLearningReceipt(.failed)
        }
        let isVoicePolish = history.status.hasPrefix("voice_polish_")
        guard isVoicePolish || history.supportsDirectTerminologyLearning else { return AutomaticLearningReceipt(.failed) }
        let candidates = terminologyEnabled
            ? TerminologyCorrectionExtractor.automaticASRCandidates(
                generatedText: originalText,
                correctedText: correctedText,
                recognitionText: history.rawText
            )
            : []
        // 只写阶段、长度与数量；不得将用户正文、词对或历史标识带入诊断。
        let extracted = terminologyEnabled
            ? TerminologyCorrectionExtractor.candidates(generatedText: originalText, correctedText: correctedText)
            : []
        let fromASR = extracted.filter { history.rawText.localizedStandardContains($0.alias) }.count
        diagnostic("learning.candidate units=\(correctedText.utf16.count) extracted=\(extracted.count) source=\(fromASR) accepted=\(candidates.count)")
        let learnsTerminology = terminologyEnabled && !candidates.isEmpty
        guard learnsTerminology else {
            return terminologyEnabled ? AutomaticLearningReceipt(.noTerms) : nil
        }

        do {
            return try await saveCorrectionReceipt(
                candidates, correctedText: correctedText, historyID: historyID, historyStore: historyStore,
                expectedUncorrectedHistory: history
            )
        } catch {
            diagnostic("learning.save failed")
            AppLogger.log("[Dal] 自动纠正学习未写入: \(error.localizedDescription)")
            return AutomaticLearningReceipt(.failed)
        }
    }

    private func saveCorrectionReceipt(
        _ candidates: [TerminologyCorrectionCandidate], correctedText: String,
        historyID: String, historyStore: HistoryStore, expectedUncorrectedHistory: HistoryRecord? = nil
    ) async throws -> AutomaticLearningReceipt {
        guard VoicePolishSettings.terminologyLearningEnabled(defaults: settingsContext.userDefaults) else {
            throw TerminologyHistoryTransactionError.correctionChanged
        }
        let record = try await coordinator.confirmCorrection(
            historyStore: historyStore,
            historyID: historyID,
            candidates: candidates,
            correctedText: correctedText,
            scene: .unknown,
            personalizationEnabled: false,
            retentionLimit: VoicePolishSettings.correctionLimit(defaults: settingsContext.userDefaults),
            learnStyle: false,
            learnTerminology: true,
            expectedUncorrectedHistory: expectedUncorrectedHistory
        )
        let saved = TerminologyRepository.load(context: settingsContext)
        let keys = Set(candidates.map { TerminologyText.normalizedKey($0.alias) })
        let hasConflict = saved.conflicts.contains { keys.contains($0.normalizedAlias) }
        let coordinator = self.coordinator
        let undo = await AutomaticLearningUndo {
            try await coordinator.undoCorrection(
                historyStore: historyStore, historyID: historyID, expectedCorrection: record
            )
        }
        diagnostic("learning.save success count=\(candidates.count)")
        return AutomaticLearningReceipt(.learned(candidates, hasConflict: hasConflict), undo: undo)
    }

    static func currentCandidate(
        for target: PostInjectionEditLearningTarget
    ) async -> String? {
        guard await target.field.isAvailable(), target.windowStart >= 0 else { return nil }
        let prefixLength = (target.prefix as NSString).length
        let suffixLength = (target.suffix as NSString).length
        let maximumLength = min(
            prefixLength + target.maximumCandidateLength + suffixLength,
            maximumWindowLength
        )
        let count = await target.field.characterCount()
        let result = await PostInjectionBoundedWindow.read(
            field: target.field, start: target.windowStart,
            minimumEnd: target.windowStart + prefixLength + 1, maximumLength: maximumLength,
            reportedCount: count
        )
        guard case .window(let window, let complete) = result,
              complete || !target.suffix.isEmpty else { return nil }

        // 注入发生在输入框末尾时没有外部 suffix 锚点。此时不能使用编辑后的
        // 光标位置作为成稿终点：用户替换中间术语后，光标通常停在术语后面，
        // 会把原成稿后半段误判为删除。范围读取已经从插入起点覆盖到字段末尾，
        // 因此使用窗口末尾；若用户只是继续追加，extractCandidate 会明确忽略。
        let candidateEnd = target.suffix.isEmpty ? (window as NSString).length : nil
        guard let selection = await target.field.selectedRange(), selection.length == 0,
              await target.field.isAvailable() else { return nil }
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

        func canFinishAfterFocusLoss() async -> Bool {
            guard await rejectionReason() == nil else { return false }
            return await read { element in
                guard let focused = focusedElement() else { return false }
                return !CFEqual(element, focused)
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

    private static func readRange(in element: AXUIElement, range: CFRange) -> PostInjectionRangeRead {
        guard range.location >= 0, (0...maximumWindowLength).contains(range.length),
              range.location <= Int.max - range.length else { return .outOfBounds }
        var mutableRange = range
        guard let parameter = AXValueCreate(.cfRange, &mutableRange) else { return .unavailable }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter,
            &value
        )
        if error == .illegalArgument { return .outOfBounds }
        if error == .parameterizedAttributeUnsupported || error == .attributeUnsupported { return .unsupported }
        guard error == .success, let text = value as? String else { return .unavailable }
        return .text(text)
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
