import SwiftUI

struct ModelSettingsTab: View, SettingsCardHelpers {
    @State private var activeEditor: ModelSettingsEditor?
    @State private var refreshID = UUID()
    @State private var asrTestStatus: SettingsTestStatus = .idle
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        let _ = refreshID
        ScrollView {
            VStack(alignment: .leading, spacing: ModelSettingsStyle.cardSpacing) {
                asrCard
                PolishModelSummaryCard(role: .standard, onEdit: { activeEditor = .standardPolish })
                LocalModelResourceStrip()
            }
            .frame(maxWidth: .infinity)
        }
        .onReceive(NotificationCenter.default.publisher(for: .modelConnectivityProbed)) { _ in
            refreshID = UUID()
        }
        .sheet(item: $activeEditor, onDismiss: {
            refreshID = UUID()
            NotificationCenter.default.post(name: .modelConnectivityProbed, object: nil)
        }) { editor in
            ModelSettingsEditorSheet(editor: editor)
        }
        .onDisappear { testTask?.cancel() }
    }

    private var asrCard: some View {
        let asrSummary = ModelSettingsSummary.asr()
        return ModelCapabilityCard(
            title: L("语音识别模型", "Speech Recognition Model"),
            provider: asrSummary.provider,
            model: asrSummary.model,
            statusTitle: liveStatus(asrTestStatus, cached: cachedASRStatus, summary: asrSummary).title,
            statusTone: liveStatus(asrTestStatus, cached: cachedASRStatus, summary: asrSummary).tone,
            testStatus: asrTestStatus,
            onTest: { testASRConnection() },
            onEdit: { activeEditor = .asr }
        )
    }

    private func liveStatus(
        _ test: SettingsTestStatus,
        cached: SettingsTestStatus?,
        summary: ModelSettingsSummaryData
    ) -> (title: String, tone: SettingsStatusTone) {
        switch test {
        case .testing:
            return (L("测试中…", "Testing…"), .neutral)
        case .success:
            return (L("连接正常", "Connected"), .success)
        case .failed:
            return (L("连接异常", "Connection failed"), .danger)
        case .idle, .saved:
            switch cached {
            case .success:
                return (L("连接正常", "Connected"), .success)
            case .failed:
                return (L("连接异常", "Connection failed"), .danger)
            default:
                return summary.statusTone == .warning
                    ? (L("待配置", "Needs setup"), .warning)
                    : (L("未测试", "Not tested"), .neutral)
            }
        }
    }

    private var cachedASRStatus: SettingsTestStatus? {
        guard let cached = ModelConnectivityCache.asr,
              cached.provider == KeychainService.selectedASRProvider else { return nil }
        return cached.status
    }

    func testASRConnection() {
        testTask?.cancel()
        asrTestStatus = .testing
        let provider = KeychainService.selectedASRProvider

        testTask = Task {
            if provider.isLocal {
                let status = await ASRLocalModelHealthCheck.status()
                guard !Task.isCancelled else { return }
                recordASRStatus(status, provider: provider)
                return
            }

            do {
                guard let config = KeychainService.loadASRConfig(for: provider),
                      let client = ASRProviderRegistry.createClient(for: provider)
                else {
                    guard !Task.isCancelled else { return }
                    recordASRStatus(.failed(L("待配置", "Needs setup")), provider: provider)
                    return
                }
                try await client.connect(config: config, options: ASRRequestOptionsFactory.current(enablePunc: false))
                await client.disconnect()
                guard !Task.isCancelled else { return }
                recordASRStatus(.success, provider: provider)
            } catch {
                guard !Task.isCancelled else { return }
                recordASRStatus(.failed(ASRConnectionErrorFormatter.describe(error)), provider: provider)
            }
        }
    }

    /// 测试终态同时记入会话缓存：切页重建后色点可恢复
    func recordASRStatus(_ status: SettingsTestStatus, provider: ASRProvider) {
        asrTestStatus = status
        ModelConnectivityCache.asr = (provider, status)
    }

}

private struct PolishModelSummaryCard: View {
    let role: PolishModelRole
    let onEdit: () -> Void
    @State private var status: SettingsTestStatus = .idle
    @State private var task: Task<Void, Never>?
    @State private var refreshID = UUID()

    var body: some View {
        let _ = refreshID
        let summary = ModelSettingsSummary.llm(role: role)
        let provider = KeychainService.selectedPolishProvider(for: role)
        let config = KeychainService.loadPolishConfig(for: role)
        let cached = ModelConnectivityCache.polish[role]
        let signature = config.map { LLMConnectivitySignature(provider: provider, config: $0) }
        let current = cached?.isCurrent == true && cached?.signature == signature ? cached?.status : nil
        let effective = status == .testing ? status : current ?? status
        let tone: SettingsStatusTone = effective == .success ? .success : {
            if case .failed = effective { return .danger }
            return config == nil ? .warning : .neutral
        }()
        ModelCapabilityCard(
            title: role.title, provider: summary.provider, model: summary.model,
            statusTitle: statusTitle(effective, configured: config != nil),
            statusTone: tone, testStatus: status,
            onTest: { test(provider: provider, config: config) }, onEdit: onEdit
        )
        .onReceive(NotificationCenter.default.publisher(for: .modelConnectivityProbed)) { _ in
            refreshID = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: .llmThinkingValidationInvalidated)) { _ in
            status = .idle
            refreshID = UUID()
        }
        .onChange(of: signature) { _, _ in
            task?.cancel()
            status = .idle
        }
        .onDisappear { task?.cancel() }
    }

    private func statusTitle(_ status: SettingsTestStatus, configured: Bool) -> String {
        switch status {
        case .testing: return L("测试中…", "Testing…")
        case .success: return L("连接正常", "Connected")
        case .failed: return L("连接异常", "Connection failed")
        default: return configured ? L("未测试", "Not tested") : L("待配置", "Needs setup")
        }
    }

    private func test(provider: LLMProvider, config: LLMConfig?) {
        task?.cancel()
        status = .testing
        task = Task {
            guard let config else {
                status = .failed(L("待配置或本地引擎未启动", "Needs setup or local engine stopped"))
                return
            }
            let result: SettingsTestStatus
            do {
                try await PolishModelConnectionTester.test(role: role, config: config, client: LLMProviderRegistry.makeClient(for: provider))
                result = .success
            } catch { result = .failed(error.localizedDescription) }
            guard !Task.isCancelled else { return }
            status = result
            ModelConnectivityCache.polish[role] = LLMConnectivityCacheEntry(
                signature: LLMConnectivitySignature(provider: provider, config: config), status: result
            )
        }
    }
}
