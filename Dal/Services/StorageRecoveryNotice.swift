import Foundation

struct StorageRecoveryNotice: Identifiable {
    let title: String
    let backupURL: URL
    let underlyingError: Error

    var id: String { backupURL.path }

    var message: String {
        L(
            "Dal 检测到“\(title)”文件损坏，已保留原始内容为 \(backupURL.lastPathComponent)。在确认或恢复该备份前，Dal 不会用空数据覆盖它。",
            "Dal found a corrupt \(title) file and preserved its original contents as \(backupURL.lastPathComponent). Dal will not replace it with empty data before you review or restore the backup."
        )
    }
}

enum StorageRecoveryScanner {
    /// 设置页打开时重新读取三类配置。隔离备份会持续返回 corrupt，
    /// 因此即使启动服务先读过文件，恢复提示也不会被抢先消费。
    static func firstPendingNotice() -> StorageRecoveryNotice? {
        if case .corrupt(let url, let error) = ModeStorage().loadResult() {
            return StorageRecoveryNotice(
                title: L("处理模式", "processing modes"),
                backupURL: url,
                underlyingError: error
            )
        }
        if case .corrupt(let url, let error) = HotwordStorage.loadResult() {
            return StorageRecoveryNotice(
                title: L("用户热词", "user hotwords"),
                backupURL: url,
                underlyingError: error
            )
        }
        if case .corrupt(let url, let error) = HotwordStorage.loadBuiltinResult() {
            return StorageRecoveryNotice(
                title: L("内置热词", "built-in hotwords"),
                backupURL: url,
                underlyingError: error
            )
        }
        if case .corrupt(let url, let error) = SnippetStorage.loadResult() {
            return StorageRecoveryNotice(
                title: L("用户纠正规则", "user correction rules"),
                backupURL: url,
                underlyingError: error
            )
        }
        if case .corrupt(let url, let error) = SnippetStorage.loadBuiltinResult() {
            return StorageRecoveryNotice(
                title: L("内置纠正规则", "built-in correction rules"),
                backupURL: url,
                underlyingError: error
            )
        }
        return nil
    }
}
