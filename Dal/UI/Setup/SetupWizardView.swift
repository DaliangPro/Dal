import SwiftUI
import AVFoundation
import ApplicationServices

/// 使用引导（2026-07-09 大梁老师改版 · 无侧栏幻灯片式）：
/// 全宽画布，6 页线性流——欢迎 → 语音输入 → AI 润色 → 授权 → 识别引擎 → 就绪；
/// 两侧纯线条箭头翻页，左下角保留深浅色开关。引擎只介绍不配置，触发键随模式动态。
struct SetupWizardView: View {

    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @State private var step = 0
    @State private var keyMonitor: Any?
    // 初始即读真实授权态：避免进授权页时 false→true 的跳变被切页动画捕捉（每次进入动画不一）
    @State private var hasMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var hasAccessibility = AXIsProcessTrusted()
    @AppStorage(DefaultsKeys.language) private var language = AppLanguage.systemSelection
    @AppStorage("tf_settingsAppearance") private var appearanceSelection = SettingsAppearanceMode.system.rawValue

    private let lastStep = 5
    private let permissionsContentHeight: CGFloat = 132
    private let enginesContentHeight: CGFloat = 216
    private let readyDescriptionHeight: CGFloat = 58

    var body: some View {
        rightContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .background(TF.settingsCanvas.ignoresSafeArea())
            .background(SetupWindowChrome())
            // 侧栏已砍（2026-07-09 大梁老师）；深浅色开关保留在整页左下角
            .overlay(alignment: .bottomLeading) {
                SetupAppearanceToggle(selection: $appearanceSelection)
                    .padding(.leading, 20)
                    .padding(.bottom, 16)
            }
            .onAppear { installKeyboardMonitor() }
            .onDisappear { removeKeyboardMonitor() }
            .id(language)
    }

    // MARK: - 右侧内容区

    private var rightContent: some View {
        ZStack {
            TF.settingsCanvas
            Group {
                switch step {
                case 0: welcomeScreen
                case 1, 2:
                    // 输入与润色各占一页。
                    SetupFeatureSlide(index: step - 1)
                        .padding(.horizontal, 64)
                        .id(step)
                case 3: permissionsScreen
                case 4: enginesScreen
                default: readyScreen
                }
            }
            .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: step)
        .clipped()
        // 2026-07-09 大梁老师改版：底部按钮行撤掉，改为两侧纯线条箭头翻页
        // （功能介绍页也由同一对箭头依次接管；就绪页无右箭头，页内「开始使用」收尾）
        // 箭头是浮在内容上层的「灵动按钮」（2026-07-09 大梁老师：加大、内收，与 UI 重叠无妨）
        .overlay(alignment: .leading) {
            if canGoBack {
                edgeArrow("chevron.left", label: L("上一步", "Back"), action: back)
                    .padding(.leading, 22)
            }
        }
        .overlay(alignment: .trailing) {
            if canGoForward {
                edgeArrow("chevron.right", label: L("下一步", "Next"), action: advance)
                    .padding(.trailing, 22)
            }
        }
    }

    private var canGoBack: Bool {
        step > 0
    }

    private var canGoForward: Bool {
        step < lastStep
    }

    /// 纯线条侧边箭头（大梁老师拍板：只要 ＜ ＞ 线条，不带圆底）：
    /// 默认淡灰、悬停提亮，热区比图形大一圈方便点按
    private func edgeArrow(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        SetupEdgeArrow(icon: icon, label: label, action: action)
    }

    /// 统一幻灯片模板：内容块垂直居中；需要时标题组在「顶部 → 内容上缘」之间垂直居中。
    @ViewBuilder
    private func scaffold<C: View>(
        title: String,
        subtitle: String? = nil,
        titlePlacement: SetupTitlePlacement = .fixedTop,
        @ViewBuilder content: @escaping () -> C
    ) -> some View {
        switch titlePlacement {
        case .fixedTop:
            ZStack {
                setupTitleBlock(title: title, subtitle: subtitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 52)

                content()
            }
            .padding(.horizontal, 64)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .centeredAboveContent(let contentHeight):
            GeometryReader { proxy in
                let topBandHeight = max(0, (proxy.size.height - contentHeight) / 2)

                ZStack(alignment: .top) {
                    setupTitleBlock(title: title, subtitle: subtitle)
                        .frame(maxWidth: .infinity)
                        .frame(height: topBandHeight, alignment: .center)

                    content()
                        .frame(maxWidth: .infinity)
                        .frame(height: contentHeight)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }
            }
            .padding(.horizontal, 64)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func setupTitleBlock(title: String, subtitle: String?) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(TF.settingsFontMetric)
                .foregroundStyle(TF.settingsText)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(TF.settingsFontBody)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func alignedTitleBandHeight(for pageHeight: CGFloat) -> CGFloat {
        SetupWizardLayout.centeredTitleBandHeight(
            pageHeight: pageHeight,
            referenceContentHeight: permissionsContentHeight
        )
    }

    private func lowerBandCenterY(pageHeight: CGFloat, centeredContentHeight: CGFloat) -> CGFloat {
        SetupWizardLayout.lowerBandCenterY(
            pageHeight: pageHeight,
            centeredContentHeight: centeredContentHeight
        )
    }

    // MARK: - Screen 0 · Welcome

    /// 欢迎页保持整体居中的原布局（2026-07-09 大梁老师：第一页标题位置不动，
    /// 「标题固定上部」模板只用于其余页面）
    private var welcomeScreen: some View {
        ZStack(alignment: .top) {
            SettingsBrandLogo(width: 124, lightOpacity: 0.58, darkOpacity: 0.66)
                .rotationEffect(.degrees(-3))
                .padding(.top, 78)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer(minLength: 20)

                VStack(spacing: 8) {
                    Text(L("让表达自然流畅", "Speak naturally. Write clearly."))
                        .font(TF.settingsFontMetric)
                        .foregroundStyle(TF.settingsText)
                        .multilineTextAlignment(.center)
                    // REPAIR_PLAN J4：默认触发是 toggle（单击开始、再单击结束），
                    // 文案不得写「按住/松手」——与就绪页矛盾会让新用户卡在第一步
                    Text(L("一键开口、说完成文的语音输入法，也是帮你随手留住灵感、随时取用的工作台。",
                           "A voice keyboard that turns speech into text — and a workbench that keeps every idea within reach."))
                        .font(TF.settingsFontBody)
                        .foregroundStyle(TF.settingsTextTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)

                welcomeLanguageChips
                    .padding(.top, 26)

                Spacer(minLength: 20)
            }
        }
        .padding(.horizontal, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcomeLanguageChips: some View {
        Group {
            HStack(spacing: 6) {
                ForEach(["中文", "English", "粤语", "日本語", "한국어"], id: \.self) { lang in
                    Text(lang)
                        .font(TF.settingsFontCaption)
                        .foregroundStyle(TF.settingsTextTertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(TF.settingsCard))
                }
            }
        }
    }

    // MARK: - Screen 1 · Feature Overview


    // MARK: - Screen 2 · Permissions

    private var permissionsScreen: some View {
        scaffold(
            title: L("授予权限", "Grant permissions"),
            subtitle: L("两项系统权限，缺一不可", "Two system permissions, both required"),
            titlePlacement: .centeredAboveContent(permissionsContentHeight)
        ) {
            VStack(spacing: 18) {
                // 两个权限横排一行：图标 · 名称 · 状态胶囊 全在同一行（2026-07-09 大梁老师）
                HStack(alignment: .center, spacing: 48) {
                    permissionInline(
                        icon: "mic",
                        title: L("麦克风", "Microphone"),
                        granted: hasMic
                    ) {
                        AVCaptureDevice.requestAccess(for: .audio) { granted in
                            Task { @MainActor in hasMic = granted }
                        }
                    }
                    permissionInline(
                        icon: "keyboard",
                        title: L("辅助功能", "Accessibility"),
                        granted: hasAccessibility
                    ) {
                        PermissionManager.promptAccessibilityPermission()
                        PermissionManager.openAccessibilitySettings()
                    }
                }

                if !hasAccessibility {
                    Text(L("在系统设置里找到 Dal 打开开关；若已开启快捷键仍无效，请重启 App。",
                           "Toggle Dal ON in System Settings. If hotkeys still fail after enabling, restart the app."))
                        .font(TF.settingsFontCaption)
                        .foregroundStyle(TF.settingsTextTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 400)
                }
            }
        }
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    /// 权限条目（2026-07-09 大梁老师：无背景、单行横排）：图标 · 名称 · 状态胶囊同一行
    private func permissionInline(icon: String, title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(TF.settingsFontIconLarge)
                .foregroundStyle(TF.settingsTextSecondary)

            Text(title)
                .font(TF.settingsFontBodyLarge)
                .foregroundStyle(TF.settingsText)

            if granted {
                Text(L("已授权", "Granted"))
                    .font(TF.settingsFontMetadata)
                    .foregroundStyle(TF.settingsAccentGreen)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(TF.settingsAccentGreen.opacity(0.15)))
            } else {
                Button(action: action) {
                    Text(L("去授权", "Grant"))
                        .font(TF.settingsFontMetadata)
                        .foregroundStyle(TF.amberInk)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(TF.amber))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Screen 3 · Recognition Engines (介绍，不配置)

    private var enginesScreen: some View {
        GeometryReader { proxy in
            let titleBandHeight = alignedTitleBandHeight(for: proxy.size.height)
            let footerCenterY = lowerBandCenterY(
                pageHeight: proxy.size.height,
                centeredContentHeight: enginesContentHeight
            )

            ZStack(alignment: .top) {
                setupTitleBlock(
                    title: L("四种识别引擎", "Recognition engines"),
                    subtitle: L("先开箱即用，后自由配置", "Ready out of the box, configure freely later")
                )
                .frame(maxWidth: .infinity)
                .frame(height: titleBandHeight, alignment: .center)

                engineRows
                    .frame(width: 420, height: enginesContentHeight)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)

                Text(L("以上可在 设置 → 模型配置 里切换与配置", "Switch and configure in Settings → Model Config"))
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .multilineTextAlignment(.center)
                    .frame(width: 420)
                    .position(x: proxy.size.width / 2, y: footerCenterY)
            }
        }
        .padding(.horizontal, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var engineRows: some View {
        VStack(spacing: 16) {
            engineRow(L("Apple 端侧", "Apple on-device"),
                      L("仅端侧识别，音频不上传；不支持时提示切换",
                        "On-device only; no upload; switch language if unsupported"),
                      recommended: true)
            engineRow(L("火山云端", "Volcano cloud"),
                      L("高精度，需填 API 凭据", "High accuracy, needs an API key"),
                      recommended: false)
            engineRow(L("阿里云百炼", "Alibaba Cloud"),
                      L("Fun-ASR / Paraformer 流式识别，需填 API Key", "Fun-ASR / Paraformer streaming, needs an API key"),
                      recommended: false)
            engineRow(L("本地离线", "Local offline"),
                      L("支持 SenseVoice + Qwen3 本地离线识别",
                        "Supports SenseVoice + Qwen3 local offline recognition"),
                      recommended: false)
        }
    }

    /// 引擎条目：两行文字保持居中；默认角标贴近文字组，并用隐形对称占位避免文字组偏轴。
    private func engineRow(_ name: String, _ detail: String, recommended: Bool) -> some View {
        HStack(spacing: 8) {
            defaultBadge
                .hidden()
                .accessibilityHidden(true)

            VStack(spacing: 3) {
                Text(name)
                    .font(TF.settingsFontBodyLarge)
                    .foregroundStyle(TF.settingsText)
                Text(detail)
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .lineLimit(1)
            }

            defaultBadge
                .opacity(recommended ? 1 : 0)
                .accessibilityHidden(!recommended)
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .center)
    }

    private var defaultBadge: some View {
        Text(L("默认", "Default"))
            .font(TF.settingsFontMetadata)
            .foregroundStyle(TF.amber)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(TF.amber.opacity(0.14)))
    }

    // MARK: - Screen 4 · Ready

    private var readyScreen: some View {
        GeometryReader { proxy in
            let titleBandHeight = alignedTitleBandHeight(for: proxy.size.height)
            let buttonCenterY = lowerBandCenterY(
                pageHeight: proxy.size.height,
                centeredContentHeight: readyDescriptionHeight
            )

            ZStack(alignment: .top) {
                setupTitleBlock(
                    title: L("准备就绪", "All set"),
                    subtitle: L("设置完成，可以开始了", "Setup complete")
                )
                .frame(maxWidth: .infinity)
                .frame(height: titleBandHeight, alignment: .center)

                VStack(spacing: 8) {
                    Text(usageText)
                        .font(TF.settingsFontBody)
                        .foregroundStyle(TF.settingsTextSecondary)
                    Text(L("更多设置在菜单栏 Dal 图标 → 设置", "More options: menu bar Dal → Settings"))
                        .font(TF.settingsFontCaption)
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 420, height: readyDescriptionHeight)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)

                SettingsTextButton(L("开始使用", "Start Using"), variant: .primary, minWidth: 88) {
                    finishSetup()
                }
                .position(x: proxy.size.width / 2, y: buttonCenterY)
            }
        }
        .padding(.horizontal, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Navigation & Logic

    private func advance() {
        guard step < lastStep else { return }
        withAnimation(.easeInOut(duration: 0.25)) { step += 1 }
    }

    private func back() {
        guard step > 0 else { return }
        withAnimation(.easeInOut(duration: 0.25)) { step -= 1 }
    }

    private func installKeyboardMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
                return event
            }

            switch event.keyCode {
            case 123 where canGoBack:
                back()
                return nil
            case 124 where canGoForward:
                advance()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyboardMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func refreshPermissions() {
        hasMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasAccessibility = AXIsProcessTrusted()
    }

    /// 引导给新用户看的是产品默认快捷键（右 Option 单击 toggle），不读用户个人配置。
    private var usageText: String {
        L(
            "单击 Option（⌥）开始说话，再单击 Option 结束，文字自动输入到光标位置。",
            "Press Option (⌥) to start speaking, press again to stop — text lands at the cursor."
        )
    }

    private func finishSetup() {
        applyDefaultEngineFallbackIfNeeded()
        appState.hasCompletedSetup = true
        // 先记住引导窗口，打开设置窗口、再关引导——「开始使用」顺势落到设置页，而非凭空消失
        let setupWindow = NSApp.keyWindow
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.close()
        // 重置到第一步：下次从菜单再点「使用引导」时从欢迎页开始
        step = 0
    }

    /// 新手兜底：完成引导时若默认引擎仍是火山且无可用凭据，落到零配置的 Apple 端侧。
    /// 若当前 locale 不支持端侧识别，连接时会明确提示切换语言或引擎；已选其他引擎则尊重不动。
    private func applyDefaultEngineFallbackIfNeeded() {
        guard KeychainService.selectedASRProvider == .volcano else { return }
        let creds = KeychainService.loadASRCredentials(for: .volcano) ?? [:]
        let hasVolcanoCreds = !(creds["appKey"] ?? "").isEmpty && !(creds["accessKey"] ?? "").isEmpty
        if !hasVolcanoCreds {
            KeychainService.selectedASRProvider = .apple
        }
    }
}

private enum SetupTitlePlacement {
    case fixedTop
    case centeredAboveContent(CGFloat)
}

enum SetupWizardLayout {
    static func centeredTitleBandHeight(pageHeight: CGFloat, referenceContentHeight: CGFloat) -> CGFloat {
        max(0, (pageHeight - referenceContentHeight) / 2)
    }

    static func lowerBandCenterY(pageHeight: CGFloat, centeredContentHeight: CGFloat) -> CGFloat {
        let centeredContentBottom = pageHeight / 2 + centeredContentHeight / 2
        return centeredContentBottom + max(0, pageHeight - centeredContentBottom) / 2
    }
}

// MARK: - 侧边翻页箭头（2026-07-09 大梁老师拍板：纯 ＜ ＞ 线条，无圆底）

private struct SetupEdgeArrow: View {
    let icon: String
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(TF.settingsFontIconHero)
                .foregroundStyle(isHovered ? TF.settingsText : TF.settingsTextTertiary.opacity(0.75))
                // 热区比线条大一圈；悬停微放大，给「灵动」的活性
                .frame(width: 44, height: 88)
                .contentShape(Rectangle())
                .scaleEffect(isHovered ? 1.12 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .accessibilityLabel(label)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - 窗口外观：内容延伸到标题栏，消除顶部露出的默认底色（墨绿栏）

private struct SetupWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SetupWindowChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SetupWindowChromeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // 延迟一拍等 SwiftUI 完成窗口初始化，再锁定，避免被覆盖
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(TF.settingsShell)
            // 锁死窗口内容尺寸 = 内容尺寸：窗口不再比内容高出一截，底部空当消失
            let size = NSSize(width: 700, height: 520)
            window.setContentSize(size)
            window.contentMinSize = size
            window.contentMaxSize = size
        }
    }
}

// MARK: - 深浅色两档开关（浅色 / 深色，无描边，靠填充与侧栏区分）

private struct SetupAppearanceToggle: View {
    @Binding var selection: String
    @Environment(\.colorScheme) private var colorScheme

    /// 当前应高亮深色档吗：显式选了 dark 则是；light 则否；其余（含旧 system）看实际外观
    private var isDark: Bool {
        SettingsAppearanceMode.resolvedIsDark(selection: selection, systemColorScheme: colorScheme)
    }

    var body: some View {
        HStack(spacing: 18) {
            iconButton("sun.max", active: !isDark, mode: .light)
            iconButton("moon", active: isDark, mode: .dark)
        }
    }

    private func iconButton(_ icon: String, active: Bool, mode: SettingsAppearanceMode) -> some View {
        Button {
            selection = mode.rawValue
            AppearanceController.apply()
        } label: {
            Image(systemName: icon)
                .font(TF.settingsFontIconControl)
                .foregroundStyle(active ? TF.amber : TF.settingsSidebarText.opacity(0.55))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
