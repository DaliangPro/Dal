import Foundation

enum ASRLocalModelHealthCheck {
    static func status() async -> SettingsTestStatus {
        let manager = SenseVoiceServerManager.shared
        let senseVoiceHealthy = await manager.isHealthy()
        let qwen3Healthy = await isQwen3Healthy(manager: manager)

        if senseVoiceHealthy || qwen3Healthy {
            return .success
        }

        let senseVoicePort = SenseVoiceServerManager.currentPort
        let qwen3Port = SenseVoiceServerManager.currentQwen3Port
        if senseVoicePort == nil && qwen3Port == nil {
            return .failed(L("服务未启动", "No server running"))
        }
        return .failed(L("服务未就绪，请稍候重试", "Server not ready, try again"))
    }

    private static func isQwen3Healthy(manager: SenseVoiceServerManager) async -> Bool {
        guard let port = await manager.qwen3Port else {
            return false
        }

        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        var request = URLRequest(url: url)
        LocalServiceAuth.authorize(&request)
        return (try? await URLSession.shared.data(for: request)).map {
            ($0.1 as? HTTPURLResponse)?.statusCode == 200
        } ?? false
    }
}
