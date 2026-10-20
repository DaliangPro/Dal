import Foundation

enum DebugLogFileWriter {
    static let defaultMaximumBytes: UInt64 = 256 * 1024

    static func startSession(
        at logURL: URL,
        now: Date = Date(),
        maximumBytes: UInt64 = defaultMaximumBytes,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let backupURL = logURL.appendingPathExtension("1")
        if fileManager.fileExists(atPath: backupURL.path) {
            try enforceOwnerOnlyPermissions(at: backupURL, fileManager: fileManager)
        }
        try rotateIfNeeded(
            at: logURL,
            maximumBytes: maximumBytes,
            fileManager: fileManager
        )
        try append("--- session \(timestamp(now)) ---", to: logURL, fileManager: fileManager)
    }

    static func append(
        _ message: String,
        to logURL: URL,
        now: Date = Date(),
        includesTimestamp: Bool = false,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let redacted = LogRedactor.redact(message)
        let line = includesTimestamp ? "[\(timestamp(now))] \(redacted)" : redacted
        let entry = Data((line + "\n").utf8)

        if fileManager.fileExists(atPath: logURL.path) {
            try enforceOwnerOnlyPermissions(at: logURL, fileManager: fileManager)
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: entry)
        } else {
            try entry.write(to: logURL, options: .atomic)
            try enforceOwnerOnlyPermissions(at: logURL, fileManager: fileManager)
        }
    }

    private static func rotateIfNeeded(
        at logURL: URL,
        maximumBytes: UInt64,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: logURL.path) else { return }
        try enforceOwnerOnlyPermissions(at: logURL, fileManager: fileManager)
        let attributes = try fileManager.attributesOfItem(atPath: logURL.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard size > maximumBytes else { return }

        let backupURL = logURL.appendingPathExtension("1")
        if fileManager.fileExists(atPath: backupURL.path) {
            // 轮转只保留上一份现场；这是 debug.log 专用、范围明确的替换。
            try fileManager.removeItem(at: backupURL)
        }
        try fileManager.moveItem(at: logURL, to: backupURL)
        try enforceOwnerOnlyPermissions(at: backupURL, fileManager: fileManager)
    }

    private static func enforceOwnerOnlyPermissions(
        at url: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        guard permissions == 0o600 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

enum DebugFileLogger {
    private static let queue = DispatchQueue(label: "pro.daliang.muse.debug-file-logger")
    private static let isRunningTests: Bool = {
        let process = ProcessInfo.processInfo
        return process.environment["XCTestConfigurationFilePath"] != nil
            || process.arguments.contains(where: { $0.contains(".xctest") })
            || NSClassFromString("XCTestCase") != nil
    }()

    static var isFileLoggingDisabledForTests: Bool { isRunningTests }

    /// 专用质量/授权进程在 AppState 之前启动，仍可能被底层客户端调用日志。
    /// 在解析用户目录之前关闭写盘；外部 sandbox 继续作为第二道隔离边界。
    static func shouldDisableFileLogging(arguments: [String], isRunningTests: Bool) -> Bool {
        isRunningTests
            || VoicePolishQualityRunner.isRequested(arguments: arguments)
    }

    private static let isFileLoggingDisabled = shouldDisableFileLogging(
        arguments: ProcessInfo.processInfo.arguments,
        isRunningTests: isRunningTests
    )

    private static var logURL: URL {
        AppPaths.ensureSupportDir().appendingPathComponent("debug.log")
    }

    static func startSession() {
        guard !isFileLoggingDisabled else { return }
        queue.async {
            try? DebugLogFileWriter.startSession(at: logURL)
        }
    }

    static func log(_ message: String) {
        guard !isFileLoggingDisabled else { return }
        queue.async {
            try? DebugLogFileWriter.append(
                message,
                to: logURL,
                includesTimestamp: true
            )
        }
    }
}
