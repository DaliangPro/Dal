import AppKit
import Foundation

@MainActor
enum AppStartupCoordinator {
    static func configureActivationPolicy() {
        let showDock = UserDefaults.standard.object(forKey: DefaultsKeys.showDockIcon) as? Bool ?? true
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
    }

    static func runMigrations() {
        KeychainService.migrateIfNeeded()
        HotwordStorage.migrateIfNeeded()
        SnippetStorage.migrateIfNeeded()
        do {
            let outcome = try TerminologyRepository.migrateIfNeeded()
            DebugFileLogger.log(
                "terminology migration migrated=\(outcome.didMigrate) entries=\(outcome.importedEntryCount) aliases=\(outcome.importedAliasCount) conflicts=\(outcome.conflictCount)"
            )
        } catch {
            // 旧词汇文件继续可用；统一 Repository 的迁移版本不会在失败时推进，
            // 下次启动可安全重试。日志只记录错误类型，不记录任何词条正文。
            AppLogger.log("[App] 统一术语迁移失败，将继续使用兼容词汇数据: \(error.localizedDescription)")
        }
        AliyunVocabularySyncCoordinator.schedule(after: .seconds(1))
        removeOrphanHistoryFileIfNeeded()
    }

    /// 在任何模式解析、热键注册、本地服务启动和连通性探测之前，修正历史中
    /// 已不可用的 ASR Provider。先持久化，再展示一次说明；持久化后的第二次
    /// 调用自然不会重复提示。
    @discardableResult
    static func reconcileSelectedASRProviderIfNeeded(
        readSelection: () -> ASRProvider = { KeychainService.selectedASRProvider },
        writeSelection: (ASRProvider) -> Void = { KeychainService.selectedASRProvider = $0 },
        capabilities: (ASRProvider) -> ASRProviderCapabilities = {
            ASRProviderRegistry.capabilities(for: $0)
        },
        presentNotice: @MainActor (ASRProvider, ASRProvider) -> Void = {
            presentASRProviderFallbackNotice(unavailable: $0, replacement: $1)
        }
    ) -> ASRProvider {
        let requested = readSelection()
        let resolved = ASRProviderRegistry.resolvedProvider(
            for: requested,
            capabilities: capabilities
        )
        guard resolved != requested else { return requested }

        writeSelection(resolved)
        presentNotice(requested, resolved)
        return resolved
    }

    private static func presentASRProviderFallbackNotice(
        unavailable: ASRProvider,
        replacement: ASRProvider
    ) {
        AppLogger.log(
            "[App] ASR provider unavailable; switched from \(unavailable.rawValue) to \(replacement.rawValue)"
        )
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = L("语音识别引擎已切换", "Speech recognizer changed")
            alert.informativeText = L(
                "此前选择的“\(unavailable.displayName)”在当前版本中不可用，Dal 已切换到“\(replacement.displayName)”。您可以稍后在设置中更改。",
                "The previously selected \(unavailable.displayName) is unavailable in this build. Dal switched to \(replacement.displayName). You can change it later in Settings."
            )
            alert.addButton(withTitle: L("知道了", "OK"))
            alert.runModal()
        }
    }

    /// REPAIR_PLAN C1：清理历史遗留的 0 字节孤儿库文件 history.sqlite
    /// （代码早已只用 history.db）。仅在文件为空时移入废纸篓，绝不动有内容的文件
    private static func removeOrphanHistoryFileIfNeeded() {
        let orphan = AppPaths.supportDir.appendingPathComponent("history.sqlite")
        let fm = FileManager.default
        guard fm.fileExists(atPath: orphan.path),
              let size = (try? fm.attributesOfItem(atPath: orphan.path))?[.size] as? NSNumber,
              size.intValue == 0 else { return }
        try? fm.trashItem(at: orphan, resultingItemURL: nil)
        AppLogger.log("[App] 已清理 0 字节孤儿文件 history.sqlite（移入废纸篓）")
    }

    static func scheduleDebugWindowsIfNeeded(
        hudDebugPresenter: HUDDebugPresenter,
        appState: AppState,
        openSettingsWindow: @escaping @MainActor () -> Void
    ) {
        if AppLaunchDebug.hudDemoEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated {
                    hudDebugPresenter.showHUDDebugWindow()
                }
            }
        }

        if AppLaunchDebug.floatingHUDDemoEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                MainActor.assumeIsolated {
                    hudDebugPresenter.showFloatingHUDDebugDemo(appState: appState)
                }
            }
        }

        if AppLaunchDebug.settingsPreviewEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                MainActor.assumeIsolated {
                    openSettingsWindow()
                }
            }
        }
    }

    static func showSetupWizardIfNeeded(
        hasCompletedSetup: Bool,
        openSetupWindow: () -> Void
    ) {
        guard !AppLaunchDebug.hudDemoEnabled, !hasCompletedSetup else { return }
        // 与菜单共用入口；命令场景尚未注册时由展示器保留请求。
        openSetupWindow()
    }

    static func startLocalServerIfNeeded() {
        // 识别（sherpa）或润色（localQwen）任一选了本地引擎都需要拉起本地服务
        let needsLocalServer = KeychainService.selectedASRProvider == .sherpa
            || KeychainService.anyPolishUsesLocalModel
        guard needsLocalServer else { return }

        if ModelManager.isLocalASRModelAvailable || LocalQwenLLMConfig.isModelAvailable {
            Task {
                do {
                    try await SenseVoiceServerManager.shared.start()
                } catch {
                    AppLogger.log("[App] SenseVoice server start failed: \(String(describing: error))")
                }
            }
        } else if KeychainService.selectedASRProvider == .sherpa {
            AppLogger.log("[App] Local ASR model is not available; server was not started")
        }

        // 润色选了本地千问但模型未下载时，服务即使为 ASR 拉起也无法服务 LLM，
        // 此前会静默失败。这里独立告警，避免运行时润色无声出错。
        if !LocalQwenLLMConfig.isModelAvailable, KeychainService.anyPolishUsesLocalModel {
            AppLogger.log("[App] Local Qwen LLM model not downloaded; polish will fail until the model is downloaded")
        }
    }
}
