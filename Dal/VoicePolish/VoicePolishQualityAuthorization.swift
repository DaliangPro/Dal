import AppKit
import Foundation
import Security

/// 仅用于用户在系统窗口授权当前冻结测试制品；不执行润色或启动生产状态。
enum VoicePolishQualityAuthorization {
    static let argument = "--voice-polish-quality-authorize-keychain"

    enum InvocationError: LocalizedError {
        case mixedOperations
        case missingProvider
        case providerMismatch

        var errorDescription: String? {
            switch self {
            case .mixedOperations:
                return "钥匙串授权与质量跑测必须分别启动"
            case .missingProvider:
                return "授权必须显式指定当前云端 LLM Provider"
            case .providerMismatch:
                return "授权对象与当前选择的 LLM Provider 不一致"
            }
        }
    }

    static func requestedProvider(arguments: [String]) throws -> LLMProvider? {
        guard arguments.contains(argument) else { return nil }
        guard !arguments.contains("--voice-polish-quality-run"),
              !arguments.contains(VoicePolishRequestProbe.argument) else {
            throw InvocationError.mixedOperations
        }
        guard let index = arguments.firstIndex(of: "--provider"),
              arguments.indices.contains(index + 1),
              let provider = LLMProvider(rawValue: arguments[index + 1]),
              provider != .localQwen else {
            throw InvocationError.missingProvider
        }
        return provider
    }

    @MainActor
    static func startIfRequested(arguments: [String]) -> Bool {
        guard arguments.contains(argument) else { return false }
        NSApp.setActivationPolicy(.prohibited)
        let provider: LLMProvider
        do {
            guard let requested = try requestedProvider(arguments: arguments) else {
                throw InvocationError.missingProvider
            }
            provider = requested
            guard PolishModelRole.allCases.contains(where: { KeychainService.selectedPolishProvider(for: $0) == provider }) else {
                throw InvocationError.providerMismatch
            }
        } catch {
            print("VOICE_POLISH_AUTHORIZATION_FAILED \(error.localizedDescription)")
            NSApp.terminate(nil)
            return true
        }

        Task { @MainActor in
            // 系统弹窗可能等待用户；不要阻塞应用主线程。
            let status = await Task.detached {
                for role in PolishModelRole.allCases where KeychainService.selectedPolishProvider(for: role) == provider {
                    let status = KeychainService.authorizePolishCredentialAccess(for: provider, role: role)
                    if status != errSecSuccess { return status }
                }
                return errSecSuccess
            }.value
            print("VOICE_POLISH_AUTHORIZATION_STATUS provider=\(provider.rawValue) os_status=\(status)")
            NSApp.terminate(nil)
        }
        return true
    }
}
