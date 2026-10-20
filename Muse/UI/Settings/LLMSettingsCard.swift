import SwiftUI

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - LLM Settings Card
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct LLMSettingsCard: View, SettingsCardHelpers {
    let role: PolishModelRole
    let onClose: (() -> Void)?
    /// 底排按钮组量到的实际宽度；输入框与它取齐（左右对齐）
    @State private var footerActionsWidth: CGFloat?
    private var inspectorControlWidth: CGFloat {
        footerActionsWidth ?? ModelSettingsStyle.inspectorControlWidth
    }

    @State private var selectedLLMProvider: LLMProvider = .doubao
    @State private var llmCredentialValues: [String: String] = [:]
    @State private var savedLLMValues: [String: String] = [:]
    @State private var editedFields: Set<String> = []
    @State private var llmTestStatus: SettingsTestStatus = .idle
    // 获取模型列表（2026-06-11 用户拍板新增）
    @State private var modelList = LLMModelListState()
    @State private var isEditingLLM = true
    @State private var hasStoredLLM = false
    @State private var testTask: Task<Void, Never>?
    @State private var serverStarting = false
    @State private var serverRunning = false

    init(role: PolishModelRole = .standard, onClose: (() -> Void)? = nil) {
        self.role = role
        self.onClose = onClose
    }

    private var currentLLMFields: [CredentialField] {
        LLMProviderRegistry.configType(for: selectedLLMProvider)?.credentialFields ?? []
    }

    /// Effective values: saved base + dirty edits overlaid.
    private var effectiveLLMValues: [String: String] {
        var result = savedLLMValues
        for key in editedFields {
            result[key] = llmCredentialValues[key] ?? ""
        }
        return result
    }

    private var hasLLMCredentials: Bool {
        let required = currentLLMFields.filter { !$0.isOptional }
        let effective = effectiveLLMValues
        return required.allSatisfy { field in
            !(effective[field.key] ?? "").isEmpty
        }
    }

    private var providerSelection: Binding<String> {
        Binding(
            get: { selectedLLMProvider.rawValue },
            set: { if let provider = LLMProvider(rawValue: $0) { selectedLLMProvider = provider } }
        )
    }

    private var providerOptions: [(value: String, label: String)] {
        LLMProvider.allCases.map { ($0.rawValue, $0.displayName) }
    }

    private var headerStatusTitle: String {
        if selectedLLMProvider == .localQwen {
            return LocalQwenLLMConfig.isModelAvailable
                ? L("已配置", "Configured")
                : L("待配置", "Needs Setup")
        }
        return hasLLMCredentials
            ? L("已配置", "Configured")
            : L("待配置", "Needs Setup")
    }

    private var headerStatusColor: Color {
        if selectedLLMProvider == .localQwen {
            return LocalQwenLLMConfig.isModelAvailable ? TF.settingsAccentGreen : TF.settingsAccentAmber
        }
        return hasLLMCredentials ? TF.settingsAccentGreen : TF.settingsAccentAmber
    }

    // MARK: Body

    var body: some View {
        settingsGroupCard(
            role.title,
            trailing: AnyView(cardTrailing),
            cornerRadius: ModelSettingsStyle.outerCardCornerRadius,
            headerBottomSpacing: ModelSettingsStyle.headerBottomSpacing,
            fillColor: ModelSettingsStyle.cardFillColor,
            showsBorder: false
        ) {
            VStack(spacing: 0) {
                LLMProviderSelectionRow(
                    selectedProvider: selectedLLMProvider,
                    selection: providerSelection,
                    options: providerOptions,
                    isEditing: isEditingLLM,
                    controlWidth: inspectorControlWidth
                )
                .zIndex(Double(currentLLMFields.count + 1))

                LLMCredentialRows(
                    selectedProvider: selectedLLMProvider,
                    fields: currentLLMFields,
                    credentialValues: $llmCredentialValues,
                    savedValues: savedLLMValues,
                    editedFields: $editedFields,
                    hasCredentials: hasLLMCredentials,
                    isEditing: isEditingLLM,
                    localModelDisplayName: localModelDisplayName,
                    localStatusText: localStatusText,
                    localStatusColor: localStatusColor,
                    controlWidth: inspectorControlWidth
                )

                // 与 CredentialFieldRow 的只读规则对齐：已存凭证且未进入编辑时
                // 字段只读，此时选模型无处保存，故同样隐藏取数行
                if selectedLLMProvider != .localQwen, isEditingLLM || !hasLLMCredentials {
                    modelListFetchRows
                }
            }
            .zIndex(10)

            LLMSettingsFooter(
                role: role,
                showsCancel: onClose == nil,
                selectedProvider: selectedLLMProvider,
                hasCredentials: hasLLMCredentials,
                hasStoredCredentials: hasStoredLLM,
                isEditing: isEditingLLM,
                testStatus: llmTestStatus,
                isServerRunning: serverRunning,
                isLocalModelAvailable: LocalQwenLLMConfig.isModelAvailable,
                onFetchModels: fetchModelList,
                onTestConnection: { testLLMConnection() },
                onStopLocalServer: { stopLocalServer() },
                onStartLocalServer: { startLocalServer() },
                onEdit: {
                    testTask?.cancel()
                    llmTestStatus = .idle
                    llmCredentialValues = [:]
                    editedFields = []
                    isEditingLLM = true
                },
                onCancel: {
                    testTask?.cancel()
                    llmTestStatus = .idle
                    if let onClose {
                        // 直达编辑场景：取消即关闭弹窗、不保存任何改动
                        onClose()
                    } else {
                        loadLLMCredentials()
                    }
                },
                onSave: { saveLLMCredentials() }
            )
            .zIndex(0)
        }
        .onPreferenceChange(SettingsFooterActionsWidthKey.self) { width in
            footerActionsWidth = width > 0 ? width : nil
        }
        .task {
            loadLLMCredentials()
            await checkServerStatus()
        }
        .onDisappear {
            testTask?.cancel()
            modelList.invalidate()
        }
        .onChange(of: selectedLLMProvider) { oldProvider, newProvider in
            handleLLMProviderChange(from: oldProvider, to: newProvider)
            modelList.invalidate()
        }
        .onChange(of: effectiveLLMValues) { oldValues, newValues in
            handleEffectiveValuesChange(from: oldValues, to: newValues)
        }
    }

    // MARK: - 获取模型列表（2026-06-11）

    @ViewBuilder
    private var modelListFetchRows: some View {
        if !modelList.models.isEmpty {
            settingsInspectorRow(
                L("可选模型", "Models"),
                labelWidth: ModelSettingsStyle.inspectorLabelWidth,
                rowHeight: ModelSettingsStyle.inspectorRowHeight,
                horizontalPadding: 0
            ) {
                settingsInspectorInlineDropdown(
                    selection: fetchedModelSelection,
                    options: modelList.models.map { ($0, $0) },
                    width: inspectorControlWidth,
                    height: ModelSettingsStyle.inspectorFieldHeight
                )
            }
        }
        if modelList.status == .testing || isFetchFailed || !modelList.models.isEmpty {
            HStack(spacing: 8) {
                if modelList.status == .testing {
                    Text(L("正在获取模型列表…", "Fetching models…"))
                        .font(TF.settingsFontMetadata)
                        .foregroundStyle(TF.settingsTextTertiary)
                } else if case .failed(let message) = modelList.status {
                    Text(message)
                        .font(TF.settingsFontMetadata)
                        .foregroundStyle(TF.settingsAccentAmber)
                        .lineLimit(1)
                } else {
                    Text(L(
                        "共 \(modelList.models.count) 个模型，选择后记得保存",
                        "\(modelList.models.count) models — remember to save"
                    ))
                        .font(TF.settingsFontMetadata)
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                Spacer()
            }
        }
    }

    private var isFetchFailed: Bool {
        if case .failed = modelList.status { return true }
        return false
    }

    private var fetchedModelSelection: Binding<String> {
        Binding(
            get: { effectiveLLMValues["model"] ?? "" },
            set: { picked in
                llmCredentialValues["model"] = picked
                editedFields.insert("model")
            }
        )
    }

    private func fetchModelList() {
        modelList.fetch(provider: selectedLLMProvider, values: effectiveLLMValues)
    }

    // MARK: - Local Qwen Status

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

    private var localModelDisplayName: String {
        if let model = LocalQwenLLMConfig.availableModel {
            return model.displayName
        }
        return L("未找到本地模型", "Model not found")
    }

    private var localStatusText: String {
        if serverStarting {
            return L("启动中", "Starting")
        }
        if serverRunning {
            return L("运行中", "Running")
        }
        return L("未启用", "Idle")
    }

    private var localStatusColor: Color {
        if serverRunning {
            return TF.settingsAccentGreen
        }
        return LocalQwenLLMConfig.isModelAvailable ? TF.settingsAccentAmber : TF.settingsAccentRed
    }

    private func startLocalServer() {
        Task { await preloadLocalLLM() }
    }

    private func checkServerStatus() async {
        serverRunning = await LocalLLMServerControl.isRunning()
    }

    /// Start server + send dummy request to trigger LLM model loading (~7-13s).
    private func preloadLocalLLM() async {
        serverStarting = true
        if await LocalLLMServerControl.preload() {
            serverRunning = true
        }
        serverStarting = false
    }

    private func stopLocalServer() {
        Task {
            let result = await LocalLLMServerControl.unloadAndStopIfUnneeded(excluding: role)
            if result == .stoppedServer {
                serverRunning = false
            }
        }
    }

    // MARK: - Provider Picker

    private func handleLLMProviderChange(from oldProvider: LLMProvider, to newProvider: LLMProvider) {
        testTask?.cancel()
        llmTestStatus = .idle
        isEditingLLM = true
        loadLLMCredentialsForProvider(newProvider)

    }

    private func handleEffectiveValuesChange(
        from oldValues: [String: String],
        to newValues: [String: String]
    ) {
        guard oldValues != newValues else { return }
        modelList.invalidate()
        invalidateConnectionTest()
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

    private func loadLLMCredentials() {
        selectedLLMProvider = KeychainService.selectedPolishProvider(for: role)
        loadLLMCredentialsForProvider(selectedLLMProvider)
    }

    private func loadLLMCredentialsForProvider(_ provider: LLMProvider) {
        testTask?.cancel()
        editedFields = []
        if let values = KeychainService.loadPolishCredentials(for: provider, role: role) {
            savedLLMValues = values
            hasStoredLLM = true
            llmCredentialValues = Self.displayValues(from: values, fields: currentLLMFields)
            // 弹窗场景直达编辑，字段预填真实值所见即所得
            isEditingLLM = !hasLLMCredentials || onClose != nil
        } else {
            let fields = LLMProviderRegistry.configType(for: provider)?.credentialFields ?? []
            let defaults = CredentialDefaultValues.values(from: fields)
            llmCredentialValues = defaults
            savedLLMValues = [:]
            hasStoredLLM = false
            isEditingLLM = true
        }
    }

    private func invalidateConnectionTest() {
        testTask?.cancel()
        llmTestStatus = .idle
    }

    private func saveLLMCredentials() {
        let values = effectiveLLMValues
        let previousProvider = KeychainService.selectedPolishProvider(for: role)
        do {
            try KeychainService.savePolishCredentials(for: selectedLLMProvider, role: role, values: values)
            KeychainService.setSelectedPolishProvider(selectedLLMProvider, for: role)
            // REPAIR_PLAN H1 改进①：改选本地模型立即预热引擎
            AppStartupCoordinator.startLocalServerIfNeeded()
            llmCredentialValues = Self.displayValues(from: values, fields: currentLLMFields)
            savedLLMValues = values
            editedFields = []
            hasStoredLLM = true
            // 弹窗场景保存后留在编辑态：字段保持可见可改，不退回「只读+修改」模式
            isEditingLLM = onClose != nil
            // 先归零再异步置 .saved：保证连续两次保存时状态确实发生变化，按钮每次都能闪绿
            llmTestStatus = .idle
            Task { @MainActor in llmTestStatus = .saved }
            // 仅当「换了服务商且弹窗里没测过新商」才作废主页色点；原商仅保存不动连通状态
            if previousProvider != selectedLLMProvider {
                ModelConnectivityCache.polish[role] = nil
            }

            // Preload local LLM model on save
            if selectedLLMProvider == .localQwen {
                Task { await preloadLocalLLM() }
            } else if previousProvider == .localQwen {
                Task { _ = await LocalLLMServerControl.unloadAndStopIfUnneeded() }
            }
        } catch {
            llmTestStatus = .failed(L("保存失败", "Save failed"))
        }
    }

    private func testLLMConnection() {
        testTask?.cancel()
        llmTestStatus = .testing
        let values = effectiveLLMValues
        let provider = selectedLLMProvider
        testTask = Task {
            let config: LLMConfig?
            if provider == .localQwen {
                config = KeychainService.loadPolishConfig(for: role, provider: provider)
            } else {
                config = LLMProviderRegistry.configType(for: provider)?.init(credentials: values)?.toLLMConfig().withThinkingMode(.disabled)
            }
            guard let config else {
                recordTestOutcome(.failed(L("配置无效或本地引擎未启动", "Invalid config or local engine stopped")), provider: provider, config: nil)
                return
            }
            do {
                try await PolishModelConnectionTester.test(role: role, config: config, client: LLMProviderRegistry.makeClient(for: provider))
                guard !Task.isCancelled else { return }
                recordTestOutcome(.success, provider: provider, config: config)
                DebugFileLogger.log("[Settings] polish test OK role=\(role.rawValue) provider=\(provider.rawValue) model=\(config.model)")
            } catch {
                guard !Task.isCancelled else { return }
                recordTestOutcome(.failed(error.localizedDescription), provider: provider, config: config)
            }
        }
    }

    /// 测试结果同时记入回传通道，主页色点关弹窗时采纳
    private func recordTestOutcome(
        _ status: SettingsTestStatus,
        provider: LLMProvider,
        config: LLMConfig?
    ) {
        llmTestStatus = status
        if let config {
            ModelConnectivityCache.polish[role] = LLMConnectivityCacheEntry(
                signature: LLMConnectivitySignature(provider: provider, config: config),
                status: status
            )
        } else {
            ModelConnectivityCache.polish[role] = nil
        }
    }
}
