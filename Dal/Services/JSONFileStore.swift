import Foundation

enum JSONFileReadResult<Value> {
    case missing
    case value(Value)
    /// URL 指向保留原始字节的文件；无法隔离时仍指向原文件。
    case corrupt(URL, Error)

    func map<Mapped>(_ transform: (Value) -> Mapped) -> JSONFileReadResult<Mapped> {
        switch self {
        case .missing:
            return .missing
        case .value(let value):
            return .value(transform(value))
        case .corrupt(let url, let error):
            return .corrupt(url, error)
        }
    }
}

enum JSONFileStoreError: Error, LocalizedError {
    case previouslyQuarantined(URL)
    case quarantineFailed(source: URL, underlying: Error)
    case recoveryRequired(URL)

    var errorDescription: String? {
        switch self {
        case .previouslyQuarantined(let url):
            return L(
                "文件此前已因损坏备份为 \(url.lastPathComponent)",
                "The corrupt file was previously backed up as \(url.lastPathComponent)"
            )
        case .quarantineFailed(let source, let underlying):
            return L(
                "无法备份损坏文件 \(source.lastPathComponent)：\(underlying.localizedDescription)",
                "Unable to back up corrupt file \(source.lastPathComponent): \(underlying.localizedDescription)"
            )
        case .recoveryRequired(let url):
            return L(
                "请先恢复或处理备份文件 \(url.lastPathComponent)",
                "Restore or resolve backup \(url.lastPathComponent) before saving"
            )
        }
    }
}

/// 应用 JSON 文件持久化的薄封装：统一目录创建、原子写与编码格式，
/// 供 SnippetStorage / HotwordStorage 等复用此前逐文件重复的读写样板。
enum JSONFileStore {
    /// 同一进程可能由启动迁移、ASR 热词同步和设置页同时读取，隔离动作必须串行，
    /// 否则多个读取者会竞争移动同一个损坏文件并丢失恢复状态。
    private static let ioLock = NSLock()
    /// 读取失败但无法/不应移动原文件时，进程内继续阻止写回，直到一次成功读取明确解除。
    private static var pendingRecoveryPaths = Set<String>()

    /// 读取并解码。解码失败时保留原始字节到时间戳备份；后续读取仍能识别该恢复态。
    static func read<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        fileManager: FileManager = .default,
        now: () -> Date = Date.init
    ) -> JSONFileReadResult<T> {
        ioLock.lock()
        defer { ioLock.unlock() }
        let pathKey = url.standardizedFileURL.path

        guard fileManager.fileExists(atPath: url.path) else {
            if let backupURL = latestCorruptBackup(for: url, fileManager: fileManager) {
                pendingRecoveryPaths.insert(pathKey)
                return .corrupt(backupURL, JSONFileStoreError.previouslyQuarantined(backupURL))
            }
            pendingRecoveryPaths.remove(pathKey)
            return .missing
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // 读取权限、短暂 I/O 等错误不等于内容损坏；保留原文件原位供用户恢复。
            pendingRecoveryPaths.insert(pathKey)
            return .corrupt(url, error)
        }

        do {
            let value = try JSONDecoder().decode(type, from: data)
            pendingRecoveryPaths.remove(pathKey)
            return .value(value)
        } catch {
            pendingRecoveryPaths.insert(pathKey)
            let backupURL = availableBackupURL(for: url, date: now(), fileManager: fileManager)
            do {
                try fileManager.moveItem(at: url, to: backupURL)
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: backupURL.path
                )
                return .corrupt(backupURL.resolvingSymlinksInPath(), error)
            } catch let quarantineError {
                return .corrupt(
                    url,
                    JSONFileStoreError.quarantineFailed(source: url, underlying: quarantineError)
                )
            }
        }
    }

    /// 编码并原子写入（自动创建父目录）；编码使用 prettyPrinted + withoutEscapingSlashes。
    static func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try writeOrThrow(value, to: url)
        } catch {
            AppLogger.log("[JSONFileStore] 写入失败 \(url.path): \(error.localizedDescription)")
        }
    }

    /// 编码并原子写入；失败时向调用方暴露错误，供关键设置保存路径处理。
    static func writeOrThrow<T: Encodable>(_ value: T, to url: URL) throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        let pathKey = url.standardizedFileURL.path
        if pendingRecoveryPaths.contains(pathKey) {
            let recoveryURL = latestCorruptBackup(for: url) ?? url
            throw JSONFileStoreError.recoveryRequired(recoveryURL)
        }
        if !FileManager.default.fileExists(atPath: url.path),
           let backupURL = latestCorruptBackup(for: url) {
            pendingRecoveryPaths.insert(pathKey)
            throw JSONFileStoreError.recoveryRequired(backupURL)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        pendingRecoveryPaths.remove(pathKey)
    }

    private static func latestCorruptBackup(
        for url: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".corrupt-"
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let latest = entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .max { $0.lastPathComponent < $1.lastPathComponent }
        return latest?.resolvingSymlinksInPath()
    }

    static func recoveryURL(
        for url: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard !fileManager.fileExists(atPath: url.path) else { return nil }
        return latestCorruptBackup(for: url, fileManager: fileManager)
    }

    private static func availableBackupURL(
        for url: URL,
        date: Date,
        fileManager: FileManager
    ) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        let baseName = url.lastPathComponent + ".corrupt-" + formatter.string(from: date)
        var candidate = url.deletingLastPathComponent().appendingPathComponent(baseName)
        var suffix = 1
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(baseName)-\(suffix)")
            suffix += 1
        }
        return candidate
    }
}
