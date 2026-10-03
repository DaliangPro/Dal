import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class TextInjectionEngine: @unchecked Sendable {

    /// internal（非 private）：REPAIR_PLAN J2 后 capture/restore 的守卫语义由单测背书。
    struct ClipboardSnapshot {
        private static let maxSnapshotBytes = 32 * 1024 * 1024

        struct Item {
            let types: [NSPasteboard.PasteboardType]
            let data: [NSPasteboard.PasteboardType: Data]
        }

        let items: [Item]
        let changeCount: Int
        let canRestore: Bool

        static func capture(
            from pasteboard: NSPasteboard = .general,
            logger: (String) -> Void = DebugFileLogger.log
        ) -> ClipboardSnapshot {
            let changeCount = pasteboard.changeCount
            var items: [Item] = []
            var totalBytes = 0

            for pasteboardItem in pasteboard.pasteboardItems ?? [] {
                let types = pasteboardItem.types
                guard !types.isEmpty else { continue }

                var data: [NSPasteboard.PasteboardType: Data] = [:]
                var readableTypes: [NSPasteboard.PasteboardType] = []
                for type in types {
                    guard let itemData = pasteboardItem.data(forType: type) else {
                        // 懒加载/promise 类型取不到数据：跳过该类型、保留其余可取表示。
                        // 2026-07-09 大梁老师实测：微信复制后剪贴板带自家懒加载格式
                        // （com.trolltech.anymime.WeChat_RichEdit_Format data=nil），
                        // 此前一个类型失败即放弃整个快照 → 微信场景恢复永不发生。
                        logger("clipboard capture: skip unreadable type=\(type.rawValue)")
                        continue
                    }
                    totalBytes += itemData.count
                    guard totalBytes <= maxSnapshotBytes else {
                        logger("clipboard capture FAIL: over \(maxSnapshotBytes) bytes")
                        return ClipboardSnapshot(items: [], changeCount: changeCount, canRestore: false)
                    }
                    data[type] = itemData
                    readableTypes.append(type)
                }
                if !readableTypes.isEmpty {
                    items.append(Item(types: readableTypes, data: data))
                }
            }

            return ClipboardSnapshot(items: items, changeCount: changeCount, canRestore: true)
        }

        @discardableResult
        func restore(
            expectedChangeCount: Int,
            injectedText: String? = nil,
            on pasteboard: NSPasteboard = .general,
            logger: (String) -> Void = DebugFileLogger.log
        ) -> Bool {
            let ccMatch = pasteboard.changeCount == expectedChangeCount
            if !ccMatch {
                // REPAIR_PLAN J2 回归修复（2026-07-09 大梁老师实测报告）：部分 app
                // （微信等）粘贴时会改写剪贴板（富文本转自家格式），changeCount 前进但
                // 内容仍是我们注入的识别文本——此时恢复依旧安全；只有内容已变成别的
                // （用户/第三方真复制了新东西）才放弃恢复，避免识别文本残留覆盖旧剪贴板。
                let current = pasteboard.string(forType: .string)
                let textMatch = injectedText != nil && current == injectedText
                guard textMatch else {
                    logger("clipboard restore SKIP: ccDelta=\(pasteboard.changeCount - expectedChangeCount) currentIsNil=\(current == nil) textMatch=false")
                    return false
                }
                logger("clipboard restore: cc moved but text matches, proceeding")
            }
            guard canRestore else {
                logger("clipboard restore SKIP: canRestore=false (snapshot capture had failed)")
                return false
            }
            logger("clipboard restore OK: items=\(items.count) ccMatch=\(ccMatch)")

            // 原剪贴板为空时 items 为空——此时仍需 clearContents 清掉刚写入的
            // 识别文本、恢复成「空」的原状；不能因 items 空就直接 return，否则识别文本残留（关了自动复制也留）。
            // 2026-06-24 大梁老师报的 bug：录音前剪贴板是图片/空 → 识别结果偷偷留进剪贴板
            pasteboard.clearContents()
            var restoredItems: [NSPasteboardItem] = []
            for item in items {
                let pasteboardItem = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data[type] {
                        pasteboardItem.setData(data, forType: type)
                    }
                }
                restoredItems.append(pasteboardItem)
            }
            if !restoredItems.isEmpty {
                pasteboard.writeObjects(restoredItems)
            }
            return true
        }
    }

    private let pasteboard: NSPasteboard
    private let clipboardLeaseCoordinator: ClipboardLeaseCoordinator
    private let pasteSimulator: () -> Bool
    private let sleepForMicroseconds: (useconds_t) -> Void
    private let logger: (String) -> Void

    init(
        pasteboard: NSPasteboard = .general,
        clipboardLeaseCoordinator: ClipboardLeaseCoordinator = .shared,
        pasteSimulator: (() -> Bool)? = nil,
        sleep: ((useconds_t) -> Void)? = nil,
        logger: @escaping (String) -> Void = DebugFileLogger.log
    ) {
        self.pasteboard = pasteboard
        self.clipboardLeaseCoordinator = clipboardLeaseCoordinator
        self.pasteSimulator = pasteSimulator ?? Self.postPasteKeyboardShortcut
        self.sleepForMicroseconds = sleep ?? { usleep($0) }
        self.logger = logger
    }

    // MARK: - Public

    var preserveClipboard = true

    static var canReadFocusedEditableElement: Bool {
        AXIsProcessTrusted()
    }

    /// AppKit 的文本输入对象只能在主线程修改。RecognitionSession 在后台 actor 上注入，
    /// 若 AX 目标恰好是 Muse 自己，AXSelectedText 会在当前后台队列直接进入 NSTextView，
    /// 触发 Text Input Source Manager 的队列断言并以 SIGTRAP 退出。
    /// 自身输入框统一走 Cmd+V 通道；外部进程仍可安全使用 AX 直插。
    static func shouldBypassAccessibility(
        targetProcessIdentifier: pid_t,
        currentProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> Bool {
        targetProcessIdentifier == currentProcessIdentifier
    }

    /// REPAIR_PLAN K6：系统级键盘焦点目标——`.nonactivatingPanel`（ProNotch 闪问、
    /// Spotlight 类浮动面板）持有键盘焦点时宿主 app 永不是 frontmost，基于
    /// frontmost 的判定整体错位。systemwide 元素直接给出「真正会接收输入的元素」
    /// 及其宿主；Electron 树未激活时该查询同样失败（err -25204/-25212），由调用方
    /// 回落 frontmost 路径（K5 激活等）。
    struct SystemwideFocusTarget {
        let element: AXUIElement
        let ownerPid: pid_t
        let ownerBundleID: String?
    }

    static func systemwideFocusedTarget() -> SystemwideFocusTarget? {
        let systemWide = AXUIElementCreateSystemWide()
        guard let focused = elementAttribute(systemWide, kAXFocusedUIElementAttribute as CFString) else {
            return nil
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(focused, &pid) == .success, pid > 0 else { return nil }
        return SystemwideFocusTarget(
            element: focused,
            ownerPid: pid,
            ownerBundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        )
    }

    static func frontmostApplicationHasFocusedEditableElement() -> Bool {
        // REPAIR_PLAN K6：先看系统级键盘焦点——面板类宿主非 frontmost，只有这里能看到
        if let target = systemwideFocusedTarget() {
            // 自身进程不做元素级 AX 查询（J22：后台队列进 AppKit 文本系统会崩）
            if shouldBypassAccessibility(targetProcessIdentifier: target.ownerPid) {
                return true
            }
            return isEditableElement(target.element, depth: 0)
        }

        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return false }

        // AppState 会从 detached task 调用本方法。自身进程不做 AX 查询，避免后台队列
        // 进入 Muse 的 AppKit 文本系统；真正注入时由 inject() 改走 Cmd+V。
        if shouldBypassAccessibility(targetProcessIdentifier: frontmostApplication.processIdentifier) {
            return true
        }

        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        if let focusedElement = elementAttribute(applicationElement, kAXFocusedUIElementAttribute as CFString) {
            // 树是活的：查到元素即一锤定音（原生 app 非输入框场景保持零延迟）
            return isEditableElement(focusedElement, depth: 0)
        }
        return hasFocusedEditableElementAfterElectronActivation(
            applicationElement,
            bundleID: frontmostApplication.bundleIdentifier
        )
    }

    /// REPAIR_PLAN K5：Chromium/Electron 的辅助功能树默认懒激活——冷启动后焦点
    /// 元素恒不可查（err -25212），且普通 AX 查询不会触发建树，必须由客户端设置
    /// Electron 官方开关 `AXManualAccessibility`。干净环境（无其他常驻 AX 工具）的
    /// 用户在 Obsidian/Codex 等 app 里因此永远走 noFocusedInput、注入不发生。
    /// 原生 app 不支持该属性（set 返回 -25205）立即回原路径、零延迟；set 成功则
    /// 轮询等待建树（本机实测 Obsidian 约 2.1s，上限 3s），树活即按角色一锤定音。
    /// 开关对目标进程生命周期持久，同一 app 后续注入零等待。
    private static func hasFocusedEditableElementAfterElectronActivation(
        _ applicationElement: AXUIElement,
        bundleID: String?
    ) -> Bool {
        guard AXUIElementSetAttributeValue(
            applicationElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        ) == .success else {
            return false
        }
        DebugFileLogger.log("inject: AXManualAccessibility set for \(bundleID ?? "unknown"), waiting for AX tree")
        for _ in 0..<10 {
            usleep(300_000)
            if let focusedElement = elementAttribute(applicationElement, kAXFocusedUIElementAttribute as CFString) {
                let editable = isEditableElement(focusedElement, depth: 0)
                DebugFileLogger.log("inject: AX tree active after activation, editable=\(editable) app=\(bundleID ?? "unknown")")
                return editable
            }
        }
        DebugFileLogger.log("inject: AX tree still absent 3s after AXManualAccessibility, app=\(bundleID ?? "unknown")")
        return false
    }

    /// 自绘渲染、AX 树不暴露焦点元素的应用（微信 4.x/QQ/钉钉/企业微信等腾讯系与 IM 类）：
    /// 焦点检测必然失败，但用户主动呼出语音输入时几乎必然停在输入框——
    /// 对这些 app 跳过检测直接注入，否则永远无法上屏（2026-07 修微信不注入）。
    /// Meta Muse（com.meta.endo）是 WebKit 页面，输入框外层容器声明为 role=button，
    /// 真实可编辑元素被 WebKit 折叠，焦点只报告该 AXButton（2026-10-03 实测）。
    private static let axOpaqueBundleIDs: Set<String> = [
        "com.tencent.qq",
        "com.tencent.WeWorkMac",
        "com.alibaba.DingTalkMac",
        "com.meta.endo",
    ]

    static func isAXOpaqueApp(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        // 微信(含双开改包)统一前缀匹配
        if bundleID.hasPrefix("com.tencent.xinWeChat") { return true }
        return axOpaqueBundleIDs.contains(bundleID)
    }

    /// 同步注入文本。内部含合计 ~200ms 的 usleep 节拍（REPAIR_PLAN B6），
    /// **禁止从主线程调用**——现实调用方是 RecognitionSession（actor，
    /// 运行于协作线程池），若未来新增调用方必须保持非主线程语境。
    func inject(_ text: String) -> InjectionOutcome {
        guard !text.isEmpty else { return .inserted }
        // REPAIR_PLAN B1：未授权辅助功能时，模拟 Cmd+V 会被系统静默丢弃，
        // 若继续走常规路径，随后的剪贴板恢复会把刚写入的文本一并抹掉，
        // 用户文本两头落空。此时改为：文本留在剪贴板、明确告知手动粘贴。
        guard AXIsProcessTrusted() else {
            copyToClipboard(text)
            return .copiedToClipboardPermissionMissing
        }

        // REPAIR_PLAN K6：系统级键盘焦点优先。nonactivatingPanel（ProNotch 闪问等）
        // 的焦点宿主永不是 frontmost app——以焦点宿主做全部判定并直接注入焦点元素；
        // 剪贴板 Cmd+V 走 CGEvent 发键盘焦点，对面板天然正确。
        if let target = Self.systemwideFocusedTarget() {
            let owner = target.ownerBundleID ?? "pid:\(target.ownerPid)"
            if Self.shouldBypassAccessibility(targetProcessIdentifier: target.ownerPid) {
                DebugFileLogger.log("inject: self target bypass AX (systemwide), using clipboard")
                return injectViaClipboard(text)
            }
            if Self.isAXOpaqueApp(target.ownerBundleID) {
                DebugFileLogger.log("inject: axOpaqueApp bypass (systemwide) owner=\(owner)")
                return injectViaClipboard(text)
            }
            guard Self.isEditableElement(target.element, depth: 0) else {
                DebugFileLogger.log("inject: systemwide focus not editable owner=\(owner)")
                if !preserveClipboard {
                    copyToClipboard(text)
                    return .noFocusedInput(copiedToClipboard: true)
                }
                return .noFocusedInput(copiedToClipboard: false)
            }
            if injectViaAccessibility(text, into: target.element) {
                DebugFileLogger.log("inject: via AX selectedText len=\(text.count) owner=\(owner) (systemwide)")
                return .inserted
            }
            DebugFileLogger.log("inject: AX declined (systemwide), falling back to clipboard owner=\(owner)")
            return injectViaClipboard(text)
        }

        // systemwide 查不到（Electron 树未激活 / 真无键盘焦点）→ frontmost 路径
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let frontmostBundleID = frontmostApplication?.bundleIdentifier
        if let frontmostApplication,
           Self.shouldBypassAccessibility(targetProcessIdentifier: frontmostApplication.processIdentifier) {
            DebugFileLogger.log("inject: self target bypass AX, using clipboard")
            return injectViaClipboard(text)
        }
        if Self.isAXOpaqueApp(frontmostBundleID) {
            DebugFileLogger.log("inject: axOpaqueApp bypass frontmost=\(frontmostBundleID ?? "unknown")")
            return injectViaClipboard(text)
        }

        guard Self.frontmostApplicationHasFocusedEditableElement() else {
            DebugFileLogger.log("inject: noFocusedInput frontmost=\(frontmostBundleID ?? "unknown")")
            if !preserveClipboard {
                copyToClipboard(text)
                return .noFocusedInput(copiedToClipboard: true)
            }
            return .noFocusedInput(copiedToClipboard: false)
        }
        // REPAIR_PLAN J16：标准输入框优先 AX 直插（kAXSelectedText），全程不碰剪贴板；
        // 元素不支持 / 设置失败 / 读回验证不过，回落剪贴板通道（微信等不透明 app
        // 在上方直通名单已分流）。
        if injectViaAccessibility(text) {
            DebugFileLogger.log("inject: via AX selectedText len=\(text.count) frontmost=\(frontmostBundleID ?? "unknown")")
            return .inserted
        }
        // REPAIR_PLAN K4：记目标 app，便于归因哪些应用 AX 直插不可用
        DebugFileLogger.log("inject: AX declined, falling back to clipboard frontmost=\(frontmostBundleID ?? "unknown")")
        return injectViaClipboard(text)
    }

    // MARK: - Accessibility injection (REPAIR_PLAN J16)

    /// 经 AXSelectedText 在焦点输入框光标处直插文本（零剪贴板占用）。
    /// 三重防护：① 元素显式声明该属性可写 ② set 返回 success ③ 光标位置前进验证。
    /// 验证不用「读回内容比对」——智能引号/自动格式化会造成已插入却比对不过 →
    /// 回落剪贴板重复插入；光标前进与否不受格式化影响：假成功时光标不动（回落
    /// 安全无重复），真插入必前进。任一环节不满足返回 false 走剪贴板通道。
    private func injectViaAccessibility(_ text: String) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = Self.elementAttribute(appElement, kAXFocusedUIElementAttribute as CFString) else {
            return false
        }
        return injectViaAccessibility(text, into: focused)
    }

    /// REPAIR_PLAN K6：直插参数化——systemwide 焦点元素（面板类）与 frontmost
    /// 焦点元素共用同一套三重防护（可写声明 / set success / 光标前进验证）。
    private func injectViaAccessibility(_ text: String, into focused: AXUIElement) -> Bool {
        var ownerPid: pid_t = 0
        AXUIElementGetPid(focused, &ownerPid)
        let ownerLabel = NSRunningApplication(processIdentifier: ownerPid)?.bundleIdentifier ?? "pid:\(ownerPid)"

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return false
        }

        // 光标基线读不到则无法验证插入是否真实发生——保守走剪贴板，宁可短占用不可丢字
        guard let locationBefore = Self.selectedRangeLocation(focused) else {
            DebugFileLogger.log("inject: AX no selectedRange baseline, fallback")
            return false
        }

        guard AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            return false
        }

        guard let locationAfter = Self.selectedRangeLocation(focused), locationAfter > locationBefore else {
            DebugFileLogger.log("inject: AX set ok but caret did not advance, fallback app=\(ownerLabel)")
            return false
        }
        return true
    }

    private static func selectedRangeLocation(_ element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue((value as! AXValue), .cfRange, &range) else { return nil }
        return range.location
    }

    func copyToClipboard(_ text: String) {
        clipboardLeaseCoordinator.writeTextPermanently(text, on: pasteboard)
    }

    /// 注入通道的临时写入：内容同 copyToClipboard，但额外标 org.nspasteboard.TransientType——
    /// 告知第三方剪贴板管理器（ProNotch 等历史工具）这是「输入中转」临时内容、勿记入历史。
    /// 背景：注入走「写剪贴板 → Cmd+V → 延迟 0.6s 恢复」，这 0.6s 窗口里按轮询的管理器会抓到
    /// 识别文本、把每句语音都记进历史（2026-07 大梁老师实测 ProNotch 被污染）。transient 是
    /// 输入法/密码管理器的行业标准标记；仍写 .string，故 Cmd+V 粘贴与 restore 的 text 守卫均不受影响。
    /// 注意：不改 copyToClipboard 本身——它还用于「无权限/无输入框」时故意留给用户手动粘贴，
    /// 那些场景若标 transient，管理器会跳过、用户反而找不到。
    private func writeInjectionText(_ text: String) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        pasteboard.writeObjects([item])
    }

    // MARK: - Clipboard injection

    /// REPAIR_PLAN J2：剪贴板恢复延迟。Cmd+V 是异步事件，目标 app 何时消费不可控——
    /// 此前粘贴后 150ms 即同步恢复，慢 app（微信等重客户端）晚于 150ms 读剪贴板会粘到
    /// 恢复后的旧内容，听写文本静默丢失；微信 300ms 特例正是该竞态的点状补丁。
    /// 恢复改为异步调度后不再阻塞注入手感（2026-07 全局同步加长到 350ms 曾拖慢手感被回退），
    /// 余量放到已知最慢客户端实测值（300ms）的两倍，统一覆盖未知慢 app，微信特例并入。
    static let clipboardRestoreDelay: TimeInterval = 0.6

    func injectViaClipboard(
        _ text: String,
        hasFrontmostApplication: Bool? = nil
    ) -> InjectionOutcome {
        clipboardLeaseCoordinator.performInjectionTransaction {
            let hasPasteTarget = hasFrontmostApplication
                ?? (NSWorkspace.shared.frontmostApplication != nil)

            guard hasPasteTarget else {
                clipboardLeaseCoordinator.writePermanently(on: pasteboard) {
                    writeInjectionText(text)
                }
                return .copiedToClipboard
            }

            let ticket: ClipboardLeaseCoordinator.Ticket?
            if preserveClipboard {
                ticket = clipboardLeaseCoordinator.stageInjection(text: text, on: pasteboard) {
                    writeInjectionText(text)
                }
            } else {
                clipboardLeaseCoordinator.writePermanently(on: pasteboard) {
                    writeInjectionText(text)
                }
                ticket = nil
            }

            sleepForMicroseconds(50_000)
            guard simulatePaste() else {
                if let ticket {
                    clipboardLeaseCoordinator.abandon(ticket)
                }
                logger("inject: Cmd+V event creation failed, keeping text in clipboard")
                return .copiedToClipboard
            }
            sleepForMicroseconds(100_000)

            if let ticket {
                clipboardLeaseCoordinator.scheduleRestore(
                    for: ticket,
                    on: pasteboard,
                    after: Self.clipboardRestoreDelay
                )
            }
            return .inserted
        }
    }

    private func simulatePaste() -> Bool {
        pasteSimulator()
    }

    private static func postPasteKeyboardShortcut() -> Bool {
        let vKeyCode: CGKeyCode = 9

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false)
        else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Focus Detection

    private static func isEditableElement(_ element: AXUIElement, depth: Int) -> Bool {
        let role = stringAttribute(element, kAXRoleAttribute as CFString)
        let subrole = stringAttribute(element, kAXSubroleAttribute as CFString)

        if role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" {
            return true
        }
        if subrole == "AXSearchField" {
            return true
        }
        if boolAttribute(element, "AXEditable" as CFString) == true {
            return true
        }
        // 注意：不要在这里加「AXWebArea 即输入框」「支持选区属性即输入框」这类宽松启发式——
        // 浏览器页面/PDF/只读文本视图都会命中，导致无输入框场景被误判、复制兜底界面永不出现
        // （2026-07-08 修：微信等自绘 app 的注入由 isAXOpaqueApp 直通名单负责，不靠此处放宽）
        guard depth < 3,
              let parent = elementAttribute(element, kAXParentAttribute as CFString)
        else { return false }
        return isEditableElement(parent, depth: depth + 1)
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? Bool
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value
        else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

}
