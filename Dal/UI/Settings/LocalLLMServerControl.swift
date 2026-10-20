import Foundation

enum LocalLLMServerStopResult {
    case stoppedServer
    case keptServerRunning
}

@MainActor
enum LocalLLMServerControl {
    static func isRunning() async -> Bool {
        await SenseVoiceServerManager.shared.isRunning
    }

    static func preload() async -> Bool {
        do {
            try await SenseVoiceServerManager.shared.start()

            let qwenPort = SenseVoiceServerManager.currentQwen3Port
            guard let port = qwenPort ?? SenseVoiceServerManager.currentPort else {
                AppLogger.log("[Settings] No server port available for LLM")
                return false
            }

            if qwenPort != nil {
                let enableURL = URL(string: "http://127.0.0.1:\(port)/llm/load")!
                var enableRequest = URLRequest(url: enableURL)
                enableRequest.httpMethod = "POST"
                enableRequest.timeoutInterval = 5
                LocalServiceAuth.authorize(&enableRequest)
                _ = try? await URLSession.shared.data(for: enableRequest)
            }

            let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 60
            let body = #"{"messages":[{"role":"user","content":"hi"}],"max_tokens":1}"#
            request.httpBody = body.data(using: .utf8)
            LocalServiceAuth.authorize(&request)

            AppLogger.log("[Settings] Preloading local LLM model...")
            _ = try? await URLSession.shared.data(for: request)
            AppLogger.log("[Settings] Local LLM model preloaded")
            return true
        } catch {
            AppLogger.log("[Settings] Local server start failed: \(String(describing: error))")
            return false
        }
    }

    static func unloadAndStopIfUnneeded(excluding role: PolishModelRole? = nil) async -> LocalLLMServerStopResult {
        let otherPolishNeedsServer = PolishModelRole.allCases.contains {
            $0 != role && KeychainService.selectedPolishProvider(for: $0) == .localQwen
        }
        guard !otherPolishNeedsServer else {
            return .keptServerRunning
        }
        if let port = SenseVoiceServerManager.currentQwen3Port {
            let url = URL(string: "http://127.0.0.1:\(port)/llm/unload")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            LocalServiceAuth.authorize(&request)
            _ = try? await URLSession.shared.data(for: request)
        }
        DebugFileLogger.log("LLM unloaded via /llm/unload")

        let asrNeedsServer = KeychainService.selectedASRProvider == .sherpa
        guard !asrNeedsServer else {
            return .keptServerRunning
        }

        await SenseVoiceServerManager.shared.stop()
        AppLogger.log("[Settings] Stopped local server (no longer needed)")
        return .stoppedServer
    }

    static func stopQwen3IfASRDoesNotNeedIt() async {
        let asrNeedsQwen3 = KeychainService.selectedASRProvider == .sherpa
            && (UserDefaults.standard.object(forKey: DefaultsKeys.qwen3FinalEnabled) as? Bool ?? true)
        guard !asrNeedsQwen3, !KeychainService.anyPolishUsesLocalModel else { return }

        await SenseVoiceServerManager.shared.stopQwen3()
    }
}
