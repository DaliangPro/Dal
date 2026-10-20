import Foundation
import os

/// 统一的控制台日志门面，替代散落各处的 NSLog，收敛到 os.Logger（系统统一日志）。
///
/// 职责划分：
/// - `AppLogger`：控制台/实时日志（os.Logger），可在 Console.app 按 subsystem 过滤。
/// - `DebugFileLogger`：可落盘的 debug.log（带轮转与 0600 权限），用于事后排障。
///
/// 二者各司其职、互不重复。需要同时记录时，分别调用即可（与历史行为一致）。
///
enum AppLogger {

    private static let subsystem = "pro.daliang.muse"
    static let logsMessagesAsPrivateByDefault = true

    /// 动态消息先统一脱敏，并默认以 private 写入系统日志。
    static func log(_ message: String, category: String = "app") {
        let redacted = LogRedactor.redact(message)
        Logger(subsystem: subsystem, category: category).log("\(redacted, privacy: .private)")
    }

    /// 仅供测试验证 AppLogger 与 debug.log 共用同一脱敏入口。
    static func redactedMessageForTesting(_ message: String) -> String {
        LogRedactor.redact(message)
    }
}
