import SwiftUI

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - ASR Settings Card
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct ASRSettingsCard: View, SettingsCardHelpers {
    let onClose: (() -> Void)?
    private let inspectorControlWidth: CGFloat = ModelSettingsStyle.inspectorControlWidth

    @State private var selectedASRProvider: ASRProvider = .volcano
    @State private var asrCredentialValues: [String: String] = [:]
    @State private var savedASRValues: [String: String] = [:]
    @State private var editedFields: Set<String> = []
    @State private var asrTestStatus: SettingsTestStatus = .idle
    @State private var isEditingASR = true
    @State private var hasStoredASR = false
    @State private var testTask: Task<Void, Never>?
    /// Hint shown below ASR credentials when only bigasr works (not seed 2.0)
    @State private var volcResourceHint: String?
    @State private var aliyunVocabularySyncNotice: AliyunVocabularySyncNotice?

    @AppStorage(DefaultsKeys.qwen3FinalEnabled) private var qwen3FinalEnabled = true
    @AppStorage(DefaultsKeys.sensevoiceEnabled) private var sensevoiceEnabled = true

    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    private var currentASRFields: [CredentialField] {
        ASRProviderRegistry.configType(for: selectedASRProvider)?.credentialFields ?? []
    }

    private var isZeroCredentialProvider: Bool {
        currentASRFields.isEmpty && !selectedASRProvider.isLocal
    }

    /// Effective values: saved base + defaults for unsaved fields + dirty edits overlaid.
    private var effectiveASRValues: [String: String] {
        var result = savedASRValues
        // Fill in defaults for fields not yet saved (new provider scenario)
        for (key, value) in asrCredentialValues where result[key] == nil {
            result[key] = value
        }
        for key in editedFields {
            result[key] = asrCredentialValues[key] ?? ""
        }
        return result
    }

    private var hasASRCredentials: Bool {
        let required = currentASRFields.filter { !$0.isOptional }
        let effective = effectiveASRValues
        return required.allSatisfy { field in
            !(effective[field.key] ?? "").isEmpty
        }
    }

    private var isASRProviderAvailable: Bool {
        ASRProviderRegistry.entry(for: selectedASRProvider)?.isAvailable ?? false
    }

    private var currentASRGuideLinks: [ASRProviderGuideLink] {
        ASRProviderSettingsInfo.guideLinks(for: selectedASRProvider)
    }

    private var showsInlineGuideLink: Bool {
        selectedASRProvider == .volcano && currentASRGuideLinks.count == 1
    }

    private var inlineGuideLink: ASRProviderGuideLink? {
        showsInlineGuideLink ? currentASRGuideLinks.first : nil
    }

    private var showsAliyunWorkspaceHint: Bool {
        guard selectedASRProvider == .aliyun else { return false }
        return (effectiveASRValues["workspaceId"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private var providerOptions: [(value: String, label: String)] {
        // 只列真实可用的厂商：本地识别不再无条件出现——cloud 构建
        // （无本地引擎）的下拉里不显示它，避免选了被静默切回火山的困惑
        ASRProvider.allCases
            .filter { ASRProviderRegistry.entry(for: $0)?.isAvailable ?? false }
            .map { ($0.rawValue, $0.displayName) }
    }

    private var providerSelection: Binding<String> {
        Binding(
            get: { selectedASRProvider.rawValue },
            set: { if let provider = ASRProvider(rawValue: $0) { selectedASRProvider = provider } }
        )
    }

    private var headerStatusColor: Color {
        if selectedASRProvider.isLocal || isZeroCredentialProvider || hasASRCredentials {
            return TF.settingsAccentGreen
        }
        return TF.settingsAccentAmber
    }

    private var headerStatusTitle: String {
        if selectedASRProvider.isLocal || isZeroCredentialProvider || hasASRCredentials {
            return L("已配置", "Configured")
        }
        return L("待配置", "Needs Setup")
    }

    // MARK: Body

    var body: some View {
        settingsGroupCard(
            L("语音识别", "Speech Recognition"),
            trailing: AnyView(cardTrailing),
            cornerRadius: ModelSettingsStyle.outerCardCornerRadius,
            headerBottomSpacing: ModelSettingsStyle.headerBottomSpacing,
            fillColor: ModelSettingsStyle.cardFillColor,
            showsBorder: false
        ) {
            VStack(spacing: 0) {
                ASRProviderSelectionRow(
                    selectedProvider: selectedASRProvider,
                    selection: providerSelection,
                    options: providerOptions,
                    isZeroCredentialProvider: isZeroCredentialProvider,
                    isEditing: isEditingASR,
                    controlWidth: inspectorControlWidth
                )
                .zIndex(Double(currentASRFields.count + 1))

                ASRCredentialRows(
                    selectedProvider: selectedASRProvider,
                    fields: currentASRFields,
                    credentialValues: $asrCredentialValues,
                    savedValues: savedASRValues,
                    editedFields: $editedFields,
                    hasCredentials: hasASRCredentials,
                    isEditing: isEditingASR,
                    isZeroCredentialProvider: isZeroCredentialProvider,
                    controlWidth: inspectorControlWidth
                )
            }
            .zIndex(10)

            ASRSettingsFooter(
                showsCancel: onClose == nil,
                selectedProvider: selectedASRProvider,
                isZeroCredentialProvider: isZeroCredentialProvider,
                hasCredentials: hasASRCredentials,
                isProviderAvailable: isASRProviderAvailable,
                hasStoredCredentials: hasStoredASR,
                isEditing: isEditingASR,
                testStatus: asrTestStatus,
                inlineGuideLink: inlineGuideLink,
                onTestLocalModel: { testLocalModel() },
                onTestASRConnection: { testASRConnection() },
                onEdit: {
                    testTask?.cancel()
                    asrTestStatus = .idle
                    asrCredentialValues = [:]
                    editedFields = []
                    isEditingASR = true
                },
                onCancel: {
                    testTask?.cancel()
                    asrTestStatus = .idle
                    if let onClose {
                        // 直达编辑场景：取消即关闭弹窗、不保存任何改动
                        onClose()
                    } else {
                        loadASRCredentials()
                    }
                },
                onSave: { saveASRCredentials() }
            )
            .zIndex(0)

            if !currentASRGuideLinks.isEmpty && !showsInlineGuideLink {
                ASRGuideLinksView(links: currentASRGuideLinks)
                    .padding(.top, 10)
                    .zIndex(0)
            }

            if let hint = volcResourceHint {
                Text(hint)
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .padding(.top, 6)
                    .zIndex(0)
            }

            if showsAliyunWorkspaceHint {
                Text(L(
                    "建议填写 Workspace ID 使用专属域名，以提高连接稳定性；未填写仍可正常使用。",
                    "Add a Workspace ID to use a dedicated endpoint for better connection stability; it remains optional."
                ))
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                    .zIndex(0)
            }

            if selectedASRProvider == .aliyun,
               let notice = aliyunVocabularySyncNotice {
                Text(notice.message)
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(
                        notice.state == .failed
                            ? TF.settingsAccentRed
                            : TF.settingsTextTertiary
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                    .zIndex(0)
            }
        }
        .task {
            loadASRCredentials()
        }
        .onChange(of: selectedASRProvider) { oldProvider, newProvider in
            handleASRProviderChange(from: oldProvider, to: newProvider)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .aliyunVocabularySyncStatusDidChange)
        ) { notification in
            guard selectedASRProvider == .aliyun,
                  let notice = notification.object as? AliyunVocabularySyncNotice
            else { return }
            aliyunVocabularySyncNotice = notice
            if notice.state == .success,
               editedFields.isEmpty,
               let values = KeychainService.loadASRCredentials(for: .aliyun) {
                savedASRValues = values
                asrCredentialValues = Self.displayValues(
                    from: values,
                    fields: AliyunASRConfig.credentialFields
                )
                editedFields = []
            }
        }
    }

    // MARK: - Provider Picker

    @ViewBuilder
    private var cardTrailing: some View {
        if let onClose {
            SettingsIconButton(
                systemName: "xmark",
                accessibilityLabel: L("关闭", "Close"),
                variant: .ghost,
                action: onClose
            )
        } else {
            settingsHeaderStatus(title: headerStatusTitle, color: headerStatusColor)
        }
    }

    private func handleASRProviderChange(from oldProvider: ASRProvider, to newProvider: ASRProvider) {
        // Skip if this is the initial load (oldProvider is the @State default, not a real switch)
        guard oldProvider == KeychainService.selectedASRProvider || oldProvider == newProvider else {
            // Initial load: just sync credentials, don't start/stop servers
            loadASRCredentialsForProvider(newProvider)
            return
        }

        testTask?.cancel()
        asrTestStatus = .idle
        isEditingASR = true
        KeychainService.selectedASRProvider = newProvider
        loadASRCredentialsForProvider(newProvider)

        if oldProvider == .sherpa && newProvider != .sherpa {
            Task {
                let manager = SenseVoiceServerManager.shared
                await manager.stopSenseVoice()
                let llmNeedsQwen3 = KeychainService.anyPolishUsesLocalModel
                if !llmNeedsQwen3 {
                    await manager.stopQwen3()
                }
            }
        }

        if newProvider == .sherpa {
            sensevoiceEnabled = true
            qwen3FinalEnabled = true
            startServer()
        }
    }

    private func startServer() {
        // Called by start() flow or provider switch - starts both if enabled
        Task {
            let mgr = SenseVoiceServerManager.shared
            do {
                try await mgr.start()
            } catch {
                AppLogger.log("[ASRSettings] Server start failed: \(String(describing: error))")
            }
        }
    }

    private func testLocalModel() {
        testTask?.cancel()
        asrTestStatus = .testing
        testTask = Task {
            let status = await ASRLocalModelHealthCheck.status()
            guard !Task.isCancelled else { return }
            asrTestStatus = status
        }
    }

    // MARK: - Data


    /// 展示用值：空字段回填其默认值（如 Base URL 官方地址）。
    /// 密钥同样预填真实值——所见即所得（安全字段由系统以圆点呈现）
    private static func displayValues(
        from values: [String: String],
        fields: [CredentialField]
    ) -> [String: String] {
        var result = values
        for field in fields where (result[field.key] ?? "").isEmpty && !field.defaultValue.isEmpty {
            result[field.key] = field.defaultValue
        }
        return result
    }

    private func loadASRCredentials() {
        selectedASRProvider = KeychainService.selectedASRProvider
        loadASRCredentialsForProvider(selectedASRProvider)
    }

    private func loadASRCredentialsForProvider(_ provider: ASRProvider) {
        testTask?.cancel()
        editedFields = []
        if let values = KeychainService.loadASRCredentials(for: provider) {
            savedASRValues = values
            hasStoredASR = true
            asrCredentialValues = Self.displayValues(
                from: values,
                fields: ASRProviderRegistry.configType(for: provider)?.credentialFields ?? []
            )
            // 弹窗场景直达编辑，字段预填真实值所见即所得
            isEditingASR = !hasASRCredentials || onClose != nil
        } else {
            let fields = ASRProviderRegistry.configType(for: provider)?.credentialFields ?? []
            let defaults = CredentialDefaultValues.values(from: fields)
            asrCredentialValues = defaults
            savedASRValues = [:]
            hasStoredASR = false
            isEditingASR = true
        }
    }

    private func saveASRCredentials() {
        let values = effectiveASRValues
        let previousProvider = KeychainService.selectedASRProvider
        let previousAliyunModel = selectedASRProvider == .aliyun
            ? AliyunASRConfig(credentials: savedASRValues)?.model
            : nil
        let nextAliyunModel = selectedASRProvider == .aliyun
            ? AliyunASRConfig(credentials: values)?.model
            : nil
        do {
            try KeychainService.saveASRCredentials(for: selectedASRProvider, values: values)
            KeychainService.selectedASRProvider = selectedASRProvider
            asrCredentialValues = Self.displayValues(
                from: values,
                fields: ASRProviderRegistry.configType(for: selectedASRProvider)?.credentialFields ?? []
            )
            savedASRValues = values
            editedFields = []
            hasStoredASR = true
            if selectedASRProvider == .aliyun {
                AliyunVocabularySyncCoordinator.schedule(after: .milliseconds(50))
            }
            // 弹窗场景保存后留在编辑态：字段保持可见可改，不退回「只读+修改」模式
            isEditingASR = onClose != nil
            // 先归零再异步置 .saved：保证连续两次保存时状态确实发生变化，按钮每次都能闪绿
            asrTestStatus = .idle
            Task { @MainActor in asrTestStatus = .saved }
            // 仅当「换了服务商且弹窗里没测过新商」才作废主页色点；原商仅保存不动连通状态
            if previousProvider != selectedASRProvider
                || previousAliyunModel != nextAliyunModel {
                ModelConnectivityCache.asr = (selectedASRProvider, .idle)
            }
        } catch {
            asrTestStatus = .failed(L("保存失败", "Save failed"))
        }
    }

    private func testASRConnection() {
        testTask?.cancel()
        asrTestStatus = .testing
        volcResourceHint = nil
        let testValues = effectiveASRValues
        let provider = selectedASRProvider
        testTask = Task {
            // Volcengine: auto-detect when "auto" is selected
            if provider == .volcano && (testValues["resourceId"] ?? "") == VolcanoASRConfig.resourceIdAuto {
                await testVolcanoWithAutoResource(baseValues: testValues)
                return
            }
            do {
                guard let configType = ASRProviderRegistry.configType(for: provider),
                      let config = configType.init(credentials: testValues),
                      let client = ASRProviderRegistry.createClient(for: provider)
                else {
                    guard !Task.isCancelled else { return }
                    recordTestOutcome(.failed(L("不支持", "Unsupported")), provider: provider)
                    return
                }
                try await client.connect(config: config, options: ASRRequestOptionsFactory.current(enablePunc: false))
                await client.disconnect()
                guard !Task.isCancelled else { return }
                recordTestOutcome(.success, provider: provider)
            } catch {
                guard !Task.isCancelled else { return }
                recordTestOutcome(.failed(ASRConnectionErrorFormatter.describe(error)), provider: provider)
            }
        }
    }

    /// 测试结果同时记入回传通道，主页色点关弹窗时采纳
    private func recordTestOutcome(_ status: SettingsTestStatus, provider: ASRProvider) {
        asrTestStatus = status
        ModelConnectivityCache.asr = (provider, status)
    }

    /// Test both Volcengine resource IDs and pick the best one.
    /// Saves with resourceId="auto" so the picker stays on "Auto", and stores the
    /// resolved ID in "resolvedResourceId" for actual connections.
    private func testVolcanoWithAutoResource(baseValues: [String: String]) async {
        switch await VolcanoASRAutoResourceTester.test(baseValues: baseValues) {
        case .resolved(let resourceId):
            var values = baseValues
            values["resourceId"] = VolcanoASRConfig.resourceIdAuto
            values["resolvedResourceId"] = resourceId
            guard saveASRCredentialsQuietly(values) else {
                recordTestOutcome(.failed(L("保存失败", "Save failed")), provider: .volcano)
                return
            }

            if resourceId == VolcanoASRConfig.resourceIdBigASR {
                volcResourceHint = L(
                    "当前使用大模型版本，开通「模型 2.0」可节省约 80% 费用，识别效果相同",
                    "Using bigmodel tier. Enable \"Model 2.0\" for ~80% cost savings with identical quality"
                )
            }
            recordTestOutcome(.success, provider: .volcano)
        case .failed:
            recordTestOutcome(.failed(L("连接失败，请检查 App ID 和 Access Token", "Connection failed, check App ID & Access Token")), provider: .volcano)
        case .cancelled:
            return
        }
    }

    private func saveASRCredentialsQuietly(_ values: [String: String]) -> Bool {
        do {
            try KeychainService.saveASRCredentials(for: .volcano, values: values)
            KeychainService.selectedASRProvider = .volcano
            asrCredentialValues = values
            savedASRValues = values
            editedFields = []
            hasStoredASR = true
            isEditingASR = onClose != nil
            return true
        } catch {
            AppLogger.log("[ASRSettings] Failed to save resolved Volcengine ASR credentials: \(String(describing: error))")
            return false
        }
    }

}
