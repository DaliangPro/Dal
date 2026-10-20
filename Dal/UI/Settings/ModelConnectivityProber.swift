import Foundation

extension Notification.Name {
    static let modelConnectivityProbed = Notification.Name("Dal.modelConnectivityProbed")
}

/// 启动时静默探测语音识别与文本处理的连通性（2026-06-12 用户拍板）：
/// 结果写入 ModelConnectivityCache，打开模型设置页即见灯，无需逐个手动测试。
/// 每次应用生命周期只探一次；页面内手动测试仍可随时刷新。
@MainActor
enum ModelConnectivityProber {
    private static var didProbe = false

    static func probeOnLaunchIfNeeded() {
        guard !didProbe else { return }
        didProbe = true
        Task {
            // 等启动稳定（菜单栏/本地服务拉起）再测，不挡启动路径
            try? await Task.sleep(for: .seconds(2))
            await probeAll()
        }
    }

    static func probeAll() async {
        async let asr: Void = probeASR()
        async let light: Void = probePolish(.light)
        async let standard: Void = probePolish(.standard)
        _ = await (asr, light, standard)
        AppLogger.log("[ConnectivityProber] 启动连通性探测完成")
        // 通知模型设置页刷新色点（页面可能在探测完成前就已打开）
        NotificationCenter.default.post(name: .modelConnectivityProbed, object: nil)
    }

    private static func probeASR() async {
        let provider = KeychainService.selectedASRProvider
        if provider.isLocal {
            let status = await ASRLocalModelHealthCheck.status()
            ModelConnectivityCache.asr = (provider, status)
            return
        }
        guard let config = KeychainService.loadASRConfig(for: provider),
              let client = ASRProviderRegistry.createClient(for: provider)
        else {
            ModelConnectivityCache.asr = (provider, .failed(L("待配置", "Needs setup")))
            return
        }
        do {
            try await client.connect(config: config, options: ASRRequestOptionsFactory.current(enablePunc: false))
            await client.disconnect()
            ModelConnectivityCache.asr = (provider, .success)
        } catch {
            ModelConnectivityCache.asr = (provider, .failed(ASRConnectionErrorFormatter.describe(error)))
        }
    }

    private static func probePolish(_ role: PolishModelRole) async {
        let provider = KeychainService.selectedPolishProvider(for: role)
        guard let config = KeychainService.loadPolishConfig(for: role) else { return }
        let status: SettingsTestStatus
        do {
            try await PolishModelConnectionTester.test(role: role, config: config, client: LLMProviderRegistry.makeClient(for: provider))
            status = .success
        } catch { status = .failed(error.localizedDescription) }
        ModelConnectivityCache.polish[role] = LLMConnectivityCacheEntry(
            signature: LLMConnectivitySignature(provider: provider, config: config), status: status
        )
    }
}
