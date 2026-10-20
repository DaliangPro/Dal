import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// 词库文件系统依赖。生产默认指向 Dal 支持目录；测试必须注入临时目录。
struct VocabularyStorageContext: @unchecked Sendable {
    let supportDirectory: URL
    let userDefaults: UserDefaults
    let fileManager: FileManager
    let hotwordsDidChange: () -> Void
    let revealFile: (URL) -> Void

    static let production = VocabularyStorageContext(
        supportDirectory: AppPaths.supportDir,
        userDefaults: .standard,
        fileManager: .default,
        hotwordsDidChange: {
            SenseVoiceServerManager.syncHotwordsAndRestart()
            AliyunVocabularySyncCoordinator.schedule()
        },
        revealFile: { url in
            #if canImport(AppKit)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            #else
            _ = url
            #endif
        }
    )
}
