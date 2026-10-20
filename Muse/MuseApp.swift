import AppKit
import SwiftUI

@main
enum MuseMain {
    static func main() {
        #if HUD_PERFORMANCE_PROBE
        HUDPerformanceProbe.runApplication()
        return
        #endif
        do {
            // 必须先于 AppDelegate 的历史库、模式与设置初始化，隔离失败时不能回退日常目录。
            try InteractiveTestRuntime.bootstrap()
        } catch {
            let message = "Muse 交互测试启动失败：\(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
        if InteractiveTestRuntime.isEnabled {
            InteractiveTestApp.main()
        } else if VoicePolishQualityRunner.isRequested() {
            VoicePolishQualityRunnerApp.main()
        } else {
            MuseApp.main()
        }
    }
}

struct MuseApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// 菜单栏图标：填满的圆角方 + M 镂空（2026-06-23 大梁老师嫌 m.square.fill 自带留白、比其它图标小一圈，
    /// 改自绘：圆角方撑满菜单栏高度、M 用 destinationOut 镂空、isTemplate 自适应明暗）
    static let menuBarIcon: NSImage = {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5).fill()
            let m = NSAttributedString(
                string: "M",
                attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .bold), .foregroundColor: NSColor.black]
            )
            let mSize = m.size()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            m.draw(at: NSPoint(x: rect.midX - mSize.width / 2, y: rect.midY - mSize.height / 2))
            return true
        }
        image.isTemplate = true
        return image
    }()
    nonisolated static let menuBarImageScaling: NSImageScaling = .scaleProportionallyDown
    nonisolated static let menuBarAutosaveName = "MuseMainStatusItem"
    nonisolated static let menuBarPreferredPositionKey = "NSStatusItem Preferred Position \(menuBarAutosaveName)"
    nonisolated static let defaultMenuBarPreferredPosition = 250.0
    nonisolated static let menuBarVisibilityMigrationKey = "tf_menuBarStatusItemV6VisibilityMigrated"
    nonisolated static let legacyMenuBarVisibilityKeys = [
        "NSStatusItem VisibleCC Item-0",
        "NSStatusItem Visible Item-0",
    ]

    nonisolated static func statusItemAutosaveName(
        for operatingSystemVersion: OperatingSystemVersion
    ) -> String? {
        // macOS 26 的 Control Center 会先用 Item-0 登记状态项，再把
        // autosaveName 作为第二个身份处理。当前系统曾同时保存 Muse 自身的允许记录
        // 与启动器下的错误关联；保留原身份可避免修复后再次产生身份分叉。
        guard operatingSystemVersion.majorVersion < 26 else { return nil }
        return menuBarAutosaveName
    }

    nonisolated static func migrateLegacyMenuBarVisibilityIfNeeded(
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: menuBarVisibilityMigrationKey) else { return }

        // NSStatusBar 会先以系统生成的 Item-0 名称创建状态项，再允许设置 autosaveName。
        // 旧质量跑测曾让 macOS 把 Item-0 持久化为隐藏，必须在创建状态项之前清掉。
        for key in legacyMenuBarVisibilityKeys {
            defaults.removeObject(forKey: key)
        }
        defaults.set(defaultMenuBarPreferredPosition, forKey: menuBarPreferredPositionKey)
        defaults.set(true, forKey: menuBarVisibilityMigrationKey)
    }

    var body: some Scene {
        Window(L("Muse 设置", "Muse Settings"), id: "settings") {
            SettingsView()
                .environment(appDelegate.appState)
                .environment(appDelegate.appUpdater)
        }
        .defaultSize(
            width: SettingsLayout.windowContentWidth,
            height: SettingsLayout.windowContentHeight
        )
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                AppWindowMenuCommands(
                    registerSettings: appDelegate.registerSettingsWindowAction,
                    openSettings: appDelegate.openSettingsWindow,
                    registerSetup: appDelegate.registerSetupWindowAction,
                    openSetup: appDelegate.openSetupWindow
                )
            }
        }

        Window(L("Muse 设置向导", "Muse Setup"), id: "setup") {
            SetupWizardView()
                .environment(appDelegate.appState)
                .environment(appDelegate.appUpdater)
        }
        .defaultSize(width: 700, height: 520)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)
    }
}

private struct InteractiveTestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 完整设置页会同步开机启动与模型设置；交互测试只提供菜单入口。
        Settings { EmptyView() }
    }
}

private final class InteractiveTestControlPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct VoicePolishQualityRunnerApp: App {
    @NSApplicationDelegateAdaptor(VoicePolishQualityRunnerAppDelegate.self) var appDelegate

    var body: some Scene {
        // 跑测进程只需要应用生命周期，不得构造生产 MenuBarExtra。
        Settings {
            EmptyView()
        }
    }
}

@MainActor
private final class VoicePolishQualityRunnerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = VoicePolishQualityRunner.startIfRequested()
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let appState = AppState(
        initialModes: InteractiveTestRuntime.isEnabled ? [.direct, .formalWriting] : nil
    )
    let appUpdater = AppUpdater()
    private let holdHotkeyStopFallbackDelay: Duration = .milliseconds(120)
    private var floatingBarController: FloatingBarController?
    private let hudDebugPresenter = HUDDebugPresenter()
    private let hotkeyManager = HotkeyManager()
    private let session = RecognitionSession()
    /// AppState 只接受当前会话的事件；旧会话的 MainActor 任务即使迟到也会被丢弃。
    private var activeUIRequestID: UUID?
    private let settingsWindowPresenter = AppWindowPresenter(windowID: "settings")
    private let setupWindowPresenter = AppWindowPresenter(windowID: "setup")
    private let menuBarVisibilityMonitor = MenuBarVisibilityMonitor()
    private var statusItem: NSStatusItem?
    private var interactiveTestControlPanel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !InteractiveTestRuntime.isEnabled, VoicePolishQualityRunner.startIfRequested() {
            return
        }
        AppLogger.log("[Muse] applicationDidFinishLaunching")
        if InteractiveTestRuntime.isEnabled {
            NSApp.setActivationPolicy(.accessory)
        } else {
            AppStartupCoordinator.configureActivationPolicy()
        }
        AppearanceController.start()  // 启动即设 app 级外观，让窗口创建前就定好，避免设置窗口首帧深色
        if !InteractiveTestRuntime.isEnabled {
            AppStartupCoordinator.runMigrations()
            AppStartupCoordinator.reconcileSelectedASRProviderIfNeeded()
        }

        DebugFileLogger.startSession()
        DebugFileLogger.log("applicationDidFinishLaunching")
        let filteredArguments = LogRedactor.redactedArguments(ProcessInfo.processInfo.arguments)
        DebugFileLogger.log("launch args=\(filteredArguments.joined(separator: " "))")
        floatingBarController = FloatingBarController(state: appState)
        appState.onCopyFallbackVisibilityChange = { [weak self] isVisible in
            self?.hotkeyManager.isCopyFallbackVisible = isVisible
        }
        appState.onRetryVoicePolish = { [weak self] in
            guard let self else { return false }
            return await self.session.retryVoicePolishResult()
        }
        if !InteractiveTestRuntime.isEnabled {
            AppStartupCoordinator.scheduleDebugWindowsIfNeeded(
                hudDebugPresenter: hudDebugPresenter,
                appState: appState,
                openSettingsWindow: { [weak self] in
                    self?.openSettingsWindow()
                }
            )
        }

        // Bridge ASR events → AppState for floating bar display
        let session = self.session

        // 历史记录文本指标迁移（用 session 自带的 historyStore，迁移后 UI 能刷新）
        if !InteractiveTestRuntime.isEnabled {
            Task { await session.historyStore.migrateTextMetrics() }
        }
        let appState = self.appState

        if !InteractiveTestRuntime.isEnabled {
            SoundFeedback.warmUp()
            // Pre-warm audio subsystem so the first recording starts instantly
            Task { await session.warmUp() }
        }

        // Bridge audio level → isolated meter (no SwiftUI observation overhead)
        Task {
            await session.setOnAudioLevel { level in
                Task { @MainActor in
                    appState.audioLevel.current = level
                }
            }
        }

        Task { [weak self] in
            guard let self else { return }
            await session.setOnASREventWithSession { [weak self] envelope in
                Task { @MainActor in
                    guard let self else { return }
                    guard let requestID = self.activeUIRequestID, requestID == envelope.uiRequestID else {
                        DebugFileLogger.log(
                            "ignored stale UI ASR event; UI request no longer active"
                        )
                        return
                    }
                    let event = envelope.event
                    switch event {
                    case .ready:
                        AppLogger.log("[Muse] ready event received")
                        DebugFileLogger.log("ready event received, current barPhase=\(String(describing: appState.barPhase))")
                        appState.markRecordingReady()
                        guard appState.barPhase == .recording else {
                            DebugFileLogger.log("playStart skipped, barPhase=\(String(describing: appState.barPhase))")
                            return
                        }
                        AppLogger.log("[Muse] playStart firing")
                        DebugFileLogger.log("playStart firing")
                        SoundFeedback.playStart()
                    case .transcript(let transcript):
                        appState.setLiveTranscript(transcript)
                    case .completed:
                        switch appState.barPhase {
                        case .recording:
                            // 服务端提前关流只代表采集结束，旧会话仍在执行
                            // stopRecording → fallback/LLM/injection。保持处理中
                            // 占用，避免用户立刻开始新会话触发 forceReset。
                            appState.stopRecording()
                            self.hotkeyManager.isProcessing = true
                            DebugFileLogger.log("completed entered processing; hotkey state retained")
                            return
                        case .preparing:
                            // 用户在录音启动完成前就松键：会话已取消，HUD 也必须
                            // 从 preparing 收起，不能留下一个没有结果的假等待状态。
                            appState.cancel()
                            self.hotkeyManager.isProcessing = false
                            self.hotkeyManager.isSessionActive = false
                            self.activeUIRequestID = nil
                            self.safeResetHotkeyState()
                        case .processing:
                            // 旧会话的迟到 completed 不能清理当前收尾中的热键状态。
                            DebugFileLogger.log("completed ignored in processing; hotkey state retained")
                        default:
                            DebugFileLogger.log("completed ignored in barPhase=\(String(describing: appState.barPhase))")
                            self.hotkeyManager.isProcessing = false
                            self.hotkeyManager.isSessionActive = false
                            self.activeUIRequestID = nil
                            self.safeResetHotkeyState()
                        }
                    case .processingResult(let text):
                        appState.showProcessingResult(text)
                        self.hotkeyManager.isProcessing = true
                    case .voicePolishStage(let stage):
                        appState.showVoicePolishStage(stage)
                        self.hotkeyManager.isProcessing = true
                    case .voicePolishUnavailable(let reason):
                        appState.showVoicePolishUnavailable(reason)
                        self.hotkeyManager.isProcessing = true
                    case .finalized(let text, let injection):
                        appState.finalize(text: text, outcome: injection)
                        self.hotkeyManager.isProcessing = false
                        self.activeUIRequestID = nil
                        self.safeResetHotkeyState()
                    case .streamingInterrupted:
                        appState.showStreamingInterrupted()
                    case .error(let error):
                        appState.showError(AppErrorMessageFormatter.userFacingMessage(for: error))
                        self.hotkeyManager.isProcessing = false
                        self.activeUIRequestID = nil
                        self.safeResetHotkeyState()
                    }
                }
            }
        }

        if InteractiveTestRuntime.isEnabled {
            installInteractiveTestMenuBarItem()
            showInteractiveTestControlPanel()
            DebugFileLogger.log("interactive test ready; microphone idle; global hotkeys disabled")
            return
        }

        if InteractiveTestRuntime.isLiveLearningAcceptanceEnabled {
            showInteractiveTestControlPanel()
        }

        // Start periodic update checking
        UpdateChecker.shared.startPeriodicChecking(appState: appState)
        appUpdater.checkPostUpdateStatus()

        // Reconcile current mode against the active provider before hotkeys are registered.
        refreshModeAvailability()

        // Re-register when modes change in Settings
        NotificationCenter.default.addObserver(
            forName: .modesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.refreshModeAvailability()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .voicePolishAutomaticLearningDidFinish,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let feedback = note.object as? AutomaticLearningFeedback else { return }
            let undo = note.userInfo?["undo"] as? AutomaticLearningUndo
            MainActor.assumeIsolated { [weak self] in
                AutomaticLearningStatus.shared.update(feedback, undo: undo)
                self?.appState.showAutomaticLearningFeedback(feedback, undo: undo)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .asrProviderDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.refreshModeAvailability()
            }
        }

        // Suppress/resume hotkeys during hotkey recording
        NotificationCenter.default.addObserver(
            forName: .hotkeyRecordingDidStart,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.hotkeyManager.isSuppressed = true
            }
        }
        NotificationCenter.default.addObserver(
            forName: .hotkeyRecordingDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.hotkeyManager.isSuppressed = false
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.startHotkeyWithRetry()
        }

        AppStartupCoordinator.showSetupWizardIfNeeded(
            hasCompletedSetup: appState.hasCompletedSetup,
            openSetupWindow: openSetupWindow
        )
        AppStartupCoordinator.startLocalServerIfNeeded()
        // 启动静默探测三模型连通性，模型设置页的灯开箱即亮（2026-06-12）
        ModelConnectivityProber.probeOnLaunchIfNeeded()

        installMenuBarItem()
        menuBarVisibilityMonitor.start()
    }

    private func installMenuBarItem() {
        let autosaveName = MuseApp.statusItemAutosaveName(
            for: ProcessInfo.processInfo.operatingSystemVersion
        )

        if autosaveName != nil {
            MuseApp.migrateLegacyMenuBarVisibilityIfNeeded()

            // 旧版 macOS 的命名状态项若没有用户排序记录，放在右侧常驻区。
            // 只初始化一次，不覆盖用户后续 Cmd 拖动排序。
            if UserDefaults.standard.object(forKey: MuseApp.menuBarPreferredPositionKey) == nil {
                UserDefaults.standard.set(
                    MuseApp.defaultMenuBarPreferredPosition,
                    forKey: MuseApp.menuBarPreferredPositionKey
                )
            }
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let autosaveName {
            item.autosaveName = autosaveName
        }
        item.isVisible = true

        guard let button = item.button else {
            AppLogger.log("[Muse] Failed to create menu bar button")
            return
        }
        button.image = MuseApp.menuBarIcon
        button.imagePosition = .imageOnly
        // 保留原 SwiftUI MenuBarExtra 的 18pt 视觉尺寸；AppKit 若允许向上缩放，
        // 会把素材继续撑到状态按钮可用高度，看起来比原图标大一圈。
        button.imageScaling = MuseApp.menuBarImageScaling
        button.toolTip = "Muse"
        item.menu = makeStatusMenu()
        statusItem = item
        DebugFileLogger.log(
            "menu bar status item installed identity=\(autosaveName ?? "Item-0") visible=\(item.isVisible)"
        )
    }

    private func installInteractiveTestMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Mu测"
        item.button?.toolTip = "Muse 交互测试"
        item.menu = Self.makeInteractiveTestStatusMenu(target: self)
        item.isVisible = true
        statusItem = item
    }

    private func showInteractiveTestControlPanel() {
        let panel = interactiveTestControlPanel ?? Self.makeInteractiveTestControlPanel(
            target: self, liveLearningAcceptance: InteractiveTestRuntime.isLiveLearningAcceptanceEnabled
        )
        interactiveTestControlPanel = panel
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visibleFrame.midX - panel.frame.width / 2,
                y: visibleFrame.maxY - panel.frame.height - 90
            ))
        }
        // 测试入口不依赖系统是否展示菜单栏图标，也不夺取目标应用的输入焦点。
        panel.orderFrontRegardless()
    }

    static func makeInteractiveTestControlPanel(target: AnyObject?, liveLearningAcceptance: Bool = false) -> NSPanel {
        let menu = liveLearningAcceptance
            ? makeLiveLearningAcceptanceMenu(target: target)
            : makeInteractiveTestStatusMenu(target: target)
        let panelHeight = CGFloat(menu.items.count) * 42 + 74
        let panel = InteractiveTestControlPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: panelHeight),
            styleMask: [.nonactivatingPanel, .titled],
            backing: .buffered,
            defer: false
        )
        panel.title = liveLearningAcceptance ? "Muse 自动记词实测" : "Muse 交互测试"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: panelHeight))
        let instruction = NSTextField(labelWithString: "先点选空白输入框，再开始录音")
        instruction.frame = NSRect(x: 20, y: panelHeight - 40, width: 340, height: 22)
        instruction.font = .systemFont(ofSize: 14)
        content.addSubview(instruction)
        for (index, item) in menu.items.enumerated() {
            let button = NSButton(title: item.title, target: item.target, action: item.action)
            button.frame = NSRect(x: 20, y: panelHeight - 90 - CGFloat(index) * 42, width: 340, height: 32)
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 14)
            content.addSubview(button)
        }
        panel.contentView = content
        return panel
    }

    /// 单独构造菜单，测试不需要实例化会打开历史库的 AppDelegate。
    static func makeInteractiveTestStatusMenu(target: AnyObject?) -> NSMenu {
        let menu = NSMenu()
        let actions: [(String, Selector)] = [
            ("准备录音与上屏权限", #selector(AppDelegate.prepareInteractiveTestPermissions)),
            ("开始轻度录音", #selector(AppDelegate.startInteractiveLightRecording)),
            ("开始标准录音", #selector(AppDelegate.startInteractiveStandardRecording)),
            ("开始直出录音", #selector(AppDelegate.startInteractiveDirectRecording)),
            ("停止并上屏", #selector(AppDelegate.stopInteractiveRecording)),
            ("退出测试", #selector(AppDelegate.quitFromStatusMenu)),
        ]
        for (title, action) in actions {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }
        return menu
    }

    /// 验收面板仅提供正常录音入口，不请求新授权，也没有模拟文字或改库按钮。
    static func makeLiveLearningAcceptanceMenu(target: AnyObject?) -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [
            ("开始直出录音", #selector(AppDelegate.startInteractiveDirectRecording)),
            ("开始润色录音", #selector(AppDelegate.startInteractiveStandardRecording)),
            ("停止并上屏", #selector(AppDelegate.stopInteractiveRecording)),
            ("关闭验收面板", #selector(AppDelegate.closeLiveLearningAcceptancePanel)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }
        return menu
    }

    @objc private func closeLiveLearningAcceptancePanel() {
        guard InteractiveTestRuntime.isLiveLearningAcceptanceEnabled else { return }
        interactiveTestControlPanel?.close()
        interactiveTestControlPanel = nil
    }

    @objc private func prepareInteractiveTestPermissions() {
        guard InteractiveTestRuntime.isEnabled else { return }
        statusItem?.button?.title = "Mu测·准备"
        interactiveTestControlPanel?.title = "Muse 交互测试 · 正在准备权限"
        Task { @MainActor in
            defer {
                self.statusItem?.button?.title = "Mu测"
                self.interactiveTestControlPanel?.title = "Muse 交互测试"
            }
            // 仅用户点选时请求原生只读授权，钥匙串中的凭据不复制到测试目录。
            let asrStatus = KeychainService.authorizeASRCredentialAccess(for: .volcano)
            let asrReadable = KeychainService.loadASRConfig(for: .volcano) != nil
            let llmStatus = KeychainService.authorizeLLMCredentialAccess(for: .deepseek)
            let llmReadable = KeychainService.loadLLMProviderConfig(for: .deepseek) != nil
            let microphoneAllowed = await PermissionManager.requestMicrophonePermission()
            if !PermissionManager.hasAccessibilityPermission {
                PermissionManager.promptAccessibilityPermission()
            }
            let accessibilityAllowed = PermissionManager.hasAccessibilityPermission
            DebugFileLogger.log(
                "interactive permissions asrStatus=\(asrStatus) asrReadable=\(asrReadable) llmStatus=\(llmStatus) llmReadable=\(llmReadable) microphone=\(microphoneAllowed) accessibility=\(accessibilityAllowed)"
            )
            let alert = NSAlert()
            alert.messageText = "Muse 交互测试权限"
            alert.informativeText = [
                "识别凭据：\(asrReadable ? "普通读取成功" : "尚不可读取（授权状态 \(asrStatus)）")",
                "润色凭据：\(llmReadable ? "普通读取成功" : "尚不可读取（授权状态 \(llmStatus)）")",
                "麦克风：\(microphoneAllowed ? "已允许" : "未允许")",
                "辅助功能上屏：\(accessibilityAllowed ? "已允许" : "待系统允许")",
                "全部允许后，请关闭此提示，点选空白输入框，再从测试面板开始录音。",
            ].joined(separator: "\n")
            alert.addButton(withTitle: "知道了")
            alert.runModal()
        }
    }

    @objc private func startInteractiveLightRecording() {
        startInteractiveRecording(mode: .formalWriting)
    }

    @objc private func startInteractiveStandardRecording() {
        startInteractiveRecording(mode: .formalWriting)
    }

    @objc private func startInteractiveDirectRecording() {
        startInteractiveRecording(mode: .direct)
    }

    private func startInteractiveRecording(mode: ProcessingMode) {
        guard InteractiveTestRuntime.isEnabled || InteractiveTestRuntime.isLiveLearningAcceptanceEnabled else { return }
        switch appState.barPhase {
        case .hidden, .done, .error:
            break
        default:
            return
        }
        guard PermissionManager.hasMicrophonePermission,
              PermissionManager.hasAccessibilityPermission else {
            appState.showError(InteractiveTestRuntime.isLiveLearningAcceptanceEnabled
                ? "现有麦克风或辅助功能权限未就绪，请到系统设置检查。"
                : "请先从测试面板准备录音与上屏权限，再点选目标输入框开始录音。")
            return
        }
        // 测试面板和状态菜单不激活 Muse；沿用正常会话的焦点捕获、注入流程。
        let effectiveMode = InteractiveTestRuntime.isLiveLearningAcceptanceEnabled
            ? InteractiveTestRuntime.liveLearningMode(mode, modes: appState.availableModes,
                                                       provider: KeychainService.selectedASRProvider)
            : mode
        appState.currentMode = effectiveMode
        let requestID = UUID()
        activeUIRequestID = requestID
        if InteractiveTestRuntime.isLiveLearningAcceptanceEnabled {
            hotkeyManager.isSessionActive = true
        }
        appState.startRecording()
        Task { await session.startRecording(mode: effectiveMode, uiRequestID: requestID) }
    }

    @objc private func stopInteractiveRecording() {
        guard InteractiveTestRuntime.isEnabled || InteractiveTestRuntime.isLiveLearningAcceptanceEnabled,
              appState.barPhase == .recording || appState.barPhase == .preparing else { return }
        requestHotkeyStop()
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(statusMenuItem(L("设置", "Settings"), action: #selector(openSettingsFromStatusMenu)))
        menu.addItem(statusMenuItem(L("使用引导", "Setup Guide"), action: #selector(openSetupFromStatusMenu)))
        menu.addItem(statusMenuItem(L("关于", "About"), action: #selector(openAboutFromStatusMenu)))
        menu.addItem(statusMenuItem(L("检查更新", "Check for Updates"), action: #selector(checkUpdatesFromStatusMenu)))
        menu.addItem(.separator())
        menu.addItem(statusMenuItem(L("退出 Muse", "Quit Muse"), action: #selector(quitFromStatusMenu)))
        return menu
    }

    private func statusMenuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openSettingsFromStatusMenu() {
        openSettingsWindow()
    }

    @objc private func openSetupFromStatusMenu() {
        openSetupWindow()
    }

    @objc private func openAboutFromStatusMenu() {
        openSettingsWindow()
        NotificationCenter.default.post(name: .navigateToTab, object: SettingsTab.about)
    }

    @objc private func checkUpdatesFromStatusMenu() {
        openAboutFromStatusMenu()
        Task {
            await GitHubReleaseChecker.shared.checkForUpdates()
        }
    }

    @objc private func quitFromStatusMenu() {
        NSApp.terminate(nil)
    }

    private func refreshModeAvailability() {
        let provider = KeychainService.selectedASRProvider
        appState.reconcileCurrentMode(for: provider)
        registerHotkeys(for: provider)
    }

    private func registerHotkeys(for provider: ASRProvider) {
        guard !InteractiveTestRuntime.isEnabled else { return }
        let availableModes = appState.availableModes
        let modes = ASRProviderRegistry.supportedModes(from: availableModes, for: provider)
        let bindings: [ModeBinding] = modes.compactMap { mode in
            guard let code = mode.hotkeyCode else { return nil }
            let modifiers = CGEventFlags(rawValue: mode.hotkeyModifiers ?? 0)
            let capturedMode = mode
            return ModeBinding(
                modeId: mode.id,
                keyCode: CGKeyCode(code),
                modifiers: modifiers,
                style: capturedMode.hotkeyStyle,
                onStart: { [weak self] in
                    guard let self else { return }

                    // Safety: if already recording, the toggle state is out of sync.
                    // Redirect to stop so we don't discard accumulated text.
                    let alreadyRecording = MainActor.assumeIsolated {
                        self.appState.barPhase == .recording || self.appState.barPhase == .preparing
                    }
                    if alreadyRecording {
                        AppLogger.log("[Muse] >>> HOTKEY: toggle desync – onStart while recording, redirecting to STOP")
                        DebugFileLogger.log("hotkey toggle desync: onStart while recording, redirecting to stop")
                        MainActor.assumeIsolated { self.hotkeyManager.resetActiveState() }
                        Task { @MainActor in self.appState.stopRecording() }
                        Task { await self.session.stopRecording() }
                        return
                    }

                    let selectedProvider = KeychainService.selectedASRProvider
                    let resolvedMode = ASRProviderRegistry.resolvedMode(for: capturedMode, provider: selectedProvider)
                    let storedMode = availableModes.first(where: { $0.id == resolvedMode.id }) ?? resolvedMode
                    let effectiveMode = VoiceInputModes.resolve(storedMode, in: availableModes)
                    let requestID = UUID()
                    MainActor.assumeIsolated {
                        self.activeUIRequestID = requestID
                        self.hotkeyManager.isSessionActive = true
                    }
                    AppLogger.log("[Muse] >>> HOTKEY: Record START (mode: \(effectiveMode.name))")
                    DebugFileLogger.log("hotkey record start mode=\(effectiveMode.name)")
                    Task { @MainActor in
                        self.appState.currentMode = effectiveMode
                        self.appState.startRecording()
                    }
                    Task { await self.session.startRecording(mode: effectiveMode, uiRequestID: requestID) }
                },
                onStop: { [weak self] in
                    guard let self else { return }
                    AppLogger.log("[Muse] >>> HOTKEY: Record STOP")
                    DebugFileLogger.log("hotkey record stop")
                    Task { @MainActor in
                        self.requestHotkeyStop(needsHoldFallback: capturedMode.hotkeyStyle == .hold)
                    }
                }
            )
        }
        hotkeyManager.registerBindings(bindings)

        // Cross-mode stop: user pressed mode B's key while mode A was recording.
        // Switch to mode B and stop, so the recording is processed with mode B.
        hotkeyManager.onCrossModeStop = { [weak self] newModeId in
            guard let self else { return }
            guard let newMode = availableModes.first(where: { $0.id == newModeId }) else { return }
            let selectedProvider = KeychainService.selectedASRProvider
            let resolvedMode = ASRProviderRegistry.resolvedMode(for: newMode, provider: selectedProvider)
            let storedMode = availableModes.first(where: { $0.id == resolvedMode.id }) ?? resolvedMode
            let effectiveMode = VoiceInputModes.resolve(storedMode, in: availableModes)
            AppLogger.log("[Muse] >>> HOTKEY: Cross-mode stop → \(effectiveMode.name)")
            DebugFileLogger.log("hotkey cross-mode stop → \(effectiveMode.name)")
            Task { @MainActor in
                self.hotkeyManager.isSessionActive = true
                self.appState.currentMode = effectiveMode
                self.appState.stopRecording()
            }
            Task {
                await self.session.switchMode(to: effectiveMode)
                await self.session.stopRecording()
            }
        }

        // Esc统一中断本次输入，不再从处理中切换到其他输出。
        hotkeyManager.onESCAbort = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                let phase = self.appState.barPhase
                AppLogger.log("[Muse] >>> HOTKEY: ESC abort session (phase=\(String(describing: phase)))")
                DebugFileLogger.log("hotkey ESC abort session phase=\(phase)")
                self.activeUIRequestID = nil
                self.hotkeyManager.isSessionActive = false
                self.appState.showCancelled()
                await self.session.abortCurrentSession()
            }
        }

        hotkeyManager.onESCDismissCopyFallback = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                DebugFileLogger.log("hotkey ESC dismiss copy fallback")
                self.appState.dismissCopyFallback()
            }
        }
    }

    private var retryTimer: Timer?
    private var hotkeyRetryCount = 0

    private func startHotkeyWithRetry() {
        guard !InteractiveTestRuntime.isEnabled else { return }
        let success = hotkeyManager.start()
        AppLogger.log("[Muse] Hotkey setup: \(success ? "OK" : "FAILED (need Accessibility permission)")")
        DebugFileLogger.log("hotkey setup \(success ? "OK" : "FAILED need accessibility")")

        if success {
            retryTimer?.invalidate()
            retryTimer = nil
            hotkeyRetryCount = 0
            return
        }

        // Prompt for accessibility and poll until granted
        PermissionManager.promptAccessibilityPermission()
        hotkeyRetryCount = 0
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(
            timeInterval: 2.0,
            target: self,
            selector: #selector(handleHotkeyRetry(_:)),
            userInfo: nil,
            repeats: true
        )
    }

    @objc
    private func handleHotkeyRetry(_ timer: Timer) {
        if PermissionManager.hasAccessibilityPermission {
            let ok = hotkeyManager.start()
            hotkeyRetryCount += 1
            AppLogger.log("[Muse] Hotkey retry #\(hotkeyRetryCount): \(ok ? "OK" : "still failing")")
            DebugFileLogger.log("hotkey retry #\(hotkeyRetryCount) \(ok ? "OK" : "still failing")")
            if ok {
                timer.invalidate()
                retryTimer = nil
                hotkeyRetryCount = 0
            } else if hotkeyRetryCount >= 5 {
                // Permission granted but event tap still fails (macOS caches denial at kernel level).
                // Suggest restart.
                timer.invalidate()
                retryTimer = nil
                hotkeyRetryCount = 0
                AppLogger.log("[Muse] Accessibility granted but hotkey tap failed after retries. Suggesting restart.")
                DebugFileLogger.log("hotkey retry failed after accessibility granted")
                showRestartAlert()
            }
        }
    }

    private func showRestartAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("辅助功能权限已开启，但快捷键未生效", comment: "")
        alert.informativeText = NSLocalizedString(
            "macOS 有时需要重启应用才能激活全局快捷键。点击「重启」自动重启 Muse。",
            comment: ""
        )
        alert.addButton(withTitle: NSLocalizedString("重启", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("稍后", comment: ""))
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            // Relaunch the app
            let url = Bundle.main.bundleURL
            let task = Process()
            task.launchPath = "/usr/bin/open"
            task.arguments = ["-n", url.path]
            try? task.run()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !InteractiveTestRuntime.isEnabled else { return }
        // Synchronous kill: don't rely on async Task, app exits immediately after this returns
        SenseVoiceServerManager.killAllServerProcesses()
    }

    // MARK: - URL Scheme Handling

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !InteractiveTestRuntime.isEnabled else { return }
        AppURLCommandHandler.handle(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !InteractiveTestRuntime.isEnabled else { return false }
        if !flag {
            openSettingsWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        // 已自行展示设置窗口，阻止SwiftUI再执行默认重开而另建一扇窗口。
        return false
    }

    func registerSettingsWindowAction(_ action: @escaping () -> Void) {
        settingsWindowPresenter.register(openAction: action)
    }

    func openSettingsWindow() {
        guard !InteractiveTestRuntime.isEnabled else { return }
        settingsWindowPresenter.open()
    }

    func registerSetupWindowAction(_ action: @escaping () -> Void) {
        setupWindowPresenter.register(openAction: action)
    }

    func openSetupWindow() {
        guard !InteractiveTestRuntime.isEnabled else { return }
        setupWindowPresenter.open()
    }

    /// Only reset hotkey state when no new recording is in progress.
    /// Prevents a stale finalized/completed event from corrupting the toggle
    /// state of a recording that started after the event was emitted.
    private func safeResetHotkeyState() {
        let phase = appState.barPhase
        if phase == .recording || phase == .preparing {
            DebugFileLogger.log("safeResetHotkeyState: skipped (barPhase=\(phase))")
            return
        }
        hotkeyManager.resetActiveState()
    }

    private func requestHotkeyStop(needsHoldFallback: Bool = false) {
        Task { @MainActor in
            self.appState.stopRecording()
        }
        Task {
            await self.session.stopRecording()
        }

        guard needsHoldFallback else { return }

        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: holdHotkeyStopFallbackDelay)

            let shouldRetry = await MainActor.run {
                let phase = self.appState.barPhase
                return phase == .preparing || phase == .recording
            }
            guard shouldRetry else { return }

            DebugFileLogger.log("hotkey hold fallback stop retry")
            await MainActor.run {
                self.appState.stopRecording()
            }
            await self.session.stopRecording()
        }
    }

}
