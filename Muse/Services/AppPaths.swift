import Foundation
import Darwin

/// 应用所有持久化路径的单一来源。
///
/// 数据根目录为 `~/Library/Application Support/Muse`。
/// 早期版本曾用旧项目名目录，已由 `KeychainService.migrateAppSupportDirectory()` 一次性并入本目录。
enum AppPaths {

    /// 应用支持目录（仅计算路径，不保证目录已创建）。独立交互测试包使用显式隔离目录。
    static var supportDir: URL {
        if InteractiveTestRuntime.isEnabled {
            return InteractiveTestRuntime.supportDirectory
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Muse", isDirectory: true)
    }

    /// 返回支持目录下的子路径。
    static func support(_ component: String, isDirectory: Bool = false) -> URL {
        supportDir.appendingPathComponent(component, isDirectory: isDirectory)
    }

    /// 确保支持目录存在并返回它。
    @discardableResult
    static func ensureSupportDir() -> URL {
        let dir = supportDir
        guard !SecureFilePermissions.isSymbolicLink(at: dir) else { return dir }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = SecureFilePermissions.setOwnerOnlyPermissions(at: dir, permissions: 0o700)
        return dir
    }

    /// 识别历史数据库路径。该文件内另有已下线资产提炼功能的表，数据原样保留。
    static var historyDBPath: String { support("history.db").path }
}

/// 持久化文件的最小权限与符号链接检查，避免用户输入、历史记录和本地
/// 服务热词被同机其他用户读取或被重定向到应用目录之外。
enum SecureFilePermissions {
    static func isSymbolicLink(at url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    @discardableResult
    static func setOwnerOnlyPermissions(at url: URL, permissions: Int) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return fchmod(descriptor, mode_t(permissions)) == 0
    }
}
