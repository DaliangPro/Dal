import Foundation
import SQLite3
import Darwin

extension Notification.Name {
    static let historyStoreDidChange = Notification.Name("Muse.historyStoreDidChange")
}

enum HistoryStoreError: Error, LocalizedError, Equatable {
    case databaseUnavailable
    case sqlite(String)
    case correctionNotEligible
    case personalizationDisabled
    case correctionUnchanged

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            return L("历史数据库不可用", "History database unavailable")
        case .sqlite(let message):
            return L("历史数据库查询失败：\(message)", "History database query failed: \(message)")
        case .correctionNotEligible:
            return L("这条记录不支持当前学习方式", "This record is not eligible for this type of learning")
        case .personalizationDisabled:
            return L("请先开启语音润色个性化", "Enable Voice Polish personalization first")
        case .correctionUnchanged:
            return L("修改后的文字与当前结果相同", "The corrected text is unchanged")
        }
    }
}

actor HistoryStore {

    static let baselineTypingCharactersPerMinute: Double = 50

    private var db: OpaquePointer?
    private let databasePath: String

    init(path: String? = nil) {
        let dbPath: String
        if let path {
            dbPath = path
        } else {
            AppPaths.ensureSupportDir()
            dbPath = AppPaths.historyDBPath
        }
        databasePath = dbPath

        let databaseURL = URL(fileURLWithPath: dbPath)
        guard ![dbPath, dbPath + "-wal", dbPath + "-shm"].contains(where: {
            SecureFilePermissions.isSymbolicLink(at: URL(fileURLWithPath: $0))
        }) else {
            AppLogger.log("[HistoryStore] 拒绝打开符号链接数据库: \(dbPath)")
            db = nil
            return
        }

        // 首次创建即为 0600；SQLite WAL/SHM 会沿用主库权限，避免先写入再 chmod。
        if dbPath != ":memory:" {
            let descriptor = open(dbPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else {
                db = nil
                return
            }
            let secured = fchmod(descriptor, 0o600) == 0
            close(descriptor)
            guard secured else { db = nil; return }
        }

        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            _ = SecureFilePermissions.setOwnerOnlyPermissions(at: databaseURL, permissions: 0o600)
            let sql = """
            CREATE TABLE IF NOT EXISTS recognition_history (
                id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                duration_seconds REAL,
                raw_text TEXT NOT NULL,
                processing_mode TEXT,
                processed_text TEXT,
                final_text TEXT NOT NULL,
                status TEXT NOT NULL,
                character_count INTEGER,
                token_count INTEGER
            );
            """
            sqlite3_exec(db, sql, nil, nil, nil)

            let correctionsSQL = """
            CREATE TABLE IF NOT EXISTS voice_polish_corrections (
                id TEXT PRIMARY KEY,
                history_id TEXT NOT NULL UNIQUE,
                created_at TEXT NOT NULL,
                scene TEXT NOT NULL,
                corrected_text TEXT NOT NULL
            );
            """
            sqlite3_exec(db, correctionsSQL, nil, nil, nil)

            // 旧库补列：只在列缺失时执行，失败留下日志而不是被静默吞掉。
            Self.addColumnIfMissing(db, table: "recognition_history", column: "character_count", definition: "INTEGER")
            Self.addColumnIfMissing(db, table: "recognition_history", column: "token_count", definition: "INTEGER")
            // 旧纠正记录历史上同时用于风格和术语，迁移默认 true；新记录按用户
            // 本次确认的两个独立开关写入，关闭风格学习不再影响术语记忆。
            Self.addColumnIfMissing(
                db, table: "voice_polish_corrections", column: "learn_style",
                definition: "INTEGER NOT NULL DEFAULT 1"
            )
            Self.addColumnIfMissing(
                db, table: "voice_polish_corrections", column: "learn_terminology",
                definition: "INTEGER NOT NULL DEFAULT 1"
            )

            // REPAIR_PLAN B5：WAL 降低写阻塞；created_at 建索引，
            // 列表按时间倒序查询不再随数据量增长全表排序。
            // busy_timeout：同库并发连接撞锁时等待而非立刻失败
            sqlite3_busy_timeout(db, 3000)
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(
                db,
                "CREATE INDEX IF NOT EXISTS idx_history_created_at ON recognition_history(created_at);",
                nil, nil, nil
            )
            sqlite3_exec(
                db,
                "CREATE INDEX IF NOT EXISTS idx_voice_polish_corrections_created_at ON voice_polish_corrections(created_at);",
                nil, nil, nil
            )
            secureDatabaseFiles()
        } else {
            // REPAIR_PLAN B5：打开失败不再静默——之后所有读写都会变 no-op，
            // 必须留下可诊断的痕迹并允许上层感知
            let message = String(cString: sqlite3_errmsg(db))
            AppLogger.log("[HistoryStore] 数据库打开失败，历史记录将不可用: \(message)（路径: \(dbPath)）")
            DebugFileLogger.log("HistoryStore open FAILED: \(message)")
            sqlite3_close(db)
            db = nil
        }
    }

    private static func addColumnIfMissing(
        _ db: OpaquePointer?, table: String, column: String, definition: String
    ) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else {
            DebugFileLogger.log("HistoryStore migration: table_info(\(table)) failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        var exists = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1), String(cString: name) == column {
                exists = true
                break
            }
        }
        sqlite3_finalize(stmt)
        guard !exists else { return }
        let sql = "ALTER TABLE \(table) ADD COLUMN \(column) \(definition);"
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            AppLogger.log("[HistoryStore] 补列失败 \(table).\(column): \(message)")
            DebugFileLogger.log("HistoryStore migration FAILED \(table).\(column): \(message)")
        }
    }

    // 关闭连接，防止每次 new HistoryStore() 泄漏 sqlite 连接（2026-06-24 修：设置页每次重建都 new，
    // 泄漏连接的读锁会钉住 WAL 不 checkpoint → 越用越卡）
    deinit {
        sqlite3_close(db)
    }

    /// 数据库是否可用（打开失败时为 false，上层可据此提示用户）
    var isHealthy: Bool { db != nil }

    /// 测试与诊断用：指定名称的索引是否存在
    func hasIndex(named name: String) -> Bool {
        do {
            return try hasIndexOrThrow(named: name)
        } catch {
            AppLogger.log("[HistoryStore] 索引查询失败: \(error.localizedDescription)")
            return false
        }
    }

    func hasIndexOrThrow(named name: String) throws -> Bool {
        let db = try requireDB()
        let sql = "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name=?;"
        var stmt: OpaquePointer?
        try prepare(sql, in: db, statement: &stmt)
        defer { sqlite3_finalize(stmt) }
        SQL.bind(stmt, 1, name)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw HistoryStoreError.sqlite(sqliteMessage(in: db))
        }
        return sqlite3_column_int(stmt, 0) > 0
    }

    // MARK: - CRUD

    func insert(_ record: HistoryRecord) {
        let sql = """
        INSERT OR REPLACE INTO recognition_history
        (id, created_at, duration_seconds, raw_text, processing_mode, processed_text, final_text, status, character_count, token_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let iso = ISO8601DateFormatter()
        SQL.bind(stmt, 1, record.id)
        SQL.bind(stmt, 2, iso.string(from: record.createdAt))
        sqlite3_bind_double(stmt, 3, record.durationSeconds)
        SQL.bind(stmt, 4, record.rawText)
        SQL.bindOptional(stmt, 5, record.processingMode)
        SQL.bindOptional(stmt, 6, record.processedText)
        SQL.bind(stmt, 7, record.finalText)
        SQL.bind(stmt, 8, record.status)
        if let count = record.characterCount {
            sqlite3_bind_int(stmt, 9, Int32(count))
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        if let count = record.tokenCount {
            sqlite3_bind_int(stmt, 10, Int32(count))
        } else {
            sqlite3_bind_null(stmt, 10)
        }
        if stepSingleWrite(stmt) {
            postDidChangeNotification()
        }
    }

    func fetchAll(limit: Int? = nil, offset: Int = 0) -> [HistoryRecord] {
        do {
            return try fetchAllOrThrow(limit: limit, offset: offset)
        } catch {
            AppLogger.log("[HistoryStore] 历史查询失败: \(error.localizedDescription)")
            return []
        }
    }

    /// 核心查询：数据库不可用、prepare 或 step 失败均向上传播。
    func fetchAllOrThrow(limit: Int? = nil, offset: Int = 0) throws -> [HistoryRecord] {
        let db = try requireDB()
        let sql = limit == nil
            ? "SELECT * FROM recognition_history ORDER BY created_at DESC;"
            : "SELECT * FROM recognition_history ORDER BY created_at DESC LIMIT ? OFFSET ?;"
        var stmt: OpaquePointer?
        try prepare(sql, in: db, statement: &stmt)
        defer { sqlite3_finalize(stmt) }
        if let limit {
            sqlite3_bind_int64(stmt, 1, sqlite3_int64(max(0, limit)))
            sqlite3_bind_int64(stmt, 2, sqlite3_int64(max(0, offset)))
        }

        var records: [HistoryRecord] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                records.append(decodeRecord(from: stmt))
            case SQLITE_DONE:
                return records
            default:
                throw HistoryStoreError.sqlite(sqliteMessage(in: db))
            }
        }
    }

    func fetchRecent(limit: Int) -> [HistoryRecord] {
        fetchAll(limit: limit)
    }

    func fetchRecentOrThrow(limit: Int) throws -> [HistoryRecord] {
        try fetchAllOrThrow(limit: limit)
    }

    func fetchBetween(start: Date, end: Date) -> [HistoryRecord] {
        do {
            return try fetchBetweenOrThrow(start: start, end: end)
        } catch {
            AppLogger.log("[HistoryStore] 日期范围查询失败: \(error.localizedDescription)")
            return []
        }
    }

    func fetchBetweenOrThrow(start: Date, end: Date) throws -> [HistoryRecord] {
        let db = try requireDB()
        let sql = """
        SELECT * FROM recognition_history
        WHERE created_at >= ? AND created_at < ?
        ORDER BY created_at DESC;
        """
        var stmt: OpaquePointer?
        try prepare(sql, in: db, statement: &stmt)
        defer { sqlite3_finalize(stmt) }

        let iso = ISO8601DateFormatter()
        SQL.bind(stmt, 1, iso.string(from: start))
        SQL.bind(stmt, 2, iso.string(from: end))

        var records: [HistoryRecord] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                records.append(decodeRecord(from: stmt))
            case SQLITE_DONE:
                return records
            default:
                throw HistoryStoreError.sqlite(sqliteMessage(in: db))
            }
        }
    }

    func fetch(ids: [String]) -> [HistoryRecord] {
        do {
            return try fetchOrThrow(ids: ids)
        } catch {
            AppLogger.log("[HistoryStore] 指定记录查询失败: \(error.localizedDescription)")
            return []
        }
    }

    func fetchOrThrow(ids: [String]) throws -> [HistoryRecord] {
        guard !ids.isEmpty else { return [] }
        let db = try requireDB()

        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = """
        SELECT * FROM recognition_history
        WHERE id IN (\(placeholders))
        ORDER BY created_at DESC;
        """
        var stmt: OpaquePointer?
        try prepare(sql, in: db, statement: &stmt)
        defer { sqlite3_finalize(stmt) }

        for (index, id) in ids.enumerated() {
            SQL.bind(stmt, Int32(index + 1), id)
        }

        var records: [HistoryRecord] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                records.append(decodeRecord(from: stmt))
            case SQLITE_DONE:
                return records
            default:
                throw HistoryStoreError.sqlite(sqliteMessage(in: db))
            }
        }
    }

    func count(from start: Date? = nil, to end: Date? = nil) -> Int {
        do {
            return try countOrThrow(from: start, to: end)
        } catch {
            AppLogger.log("[HistoryStore] 历史计数失败: \(error.localizedDescription)")
            return 0
        }
    }

    func countOrThrow(from start: Date? = nil, to end: Date? = nil) throws -> Int {
        let db = try requireDB()
        let hasRange = start != nil && end != nil
        let sql = hasRange
            ? "SELECT COUNT(*) FROM recognition_history WHERE created_at >= ? AND created_at < ?;"
            : "SELECT COUNT(*) FROM recognition_history;"
        var stmt: OpaquePointer?
        try prepare(sql, in: db, statement: &stmt)
        defer { sqlite3_finalize(stmt) }
        if let start, let end {
            let iso = ISO8601DateFormatter()
            SQL.bind(stmt, 1, iso.string(from: start))
            SQL.bind(stmt, 2, iso.string(from: end))
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw HistoryStoreError.sqlite(sqliteMessage(in: db))
        }
        return Int(sqlite3_column_int(stmt, 0))
    }

    func delete(id: String) {
        do {
            try deleteOrThrow(id: id)
        } catch {
            AppLogger.log("[HistoryStore] 删除历史失败: \(error.localizedDescription)")
        }
    }

    /// 原子删除历史及其纠正记录，并把失败显式返回给需要跨存储回滚的上层。
    func deleteOrThrow(id: String) throws {
        let db = try requireDB()
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            throw HistoryStoreError.sqlite(sqliteMessage(in: db))
        }
        do {
            try executeDelete(
                "DELETE FROM voice_polish_corrections WHERE history_id = ?;",
                id: id,
                in: db
            )
            try executeDelete(
                "DELETE FROM recognition_history WHERE id = ?;",
                id: id,
                in: db
            )
            guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                throw HistoryStoreError.sqlite(sqliteMessage(in: db))
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
        postDidChangeNotification()
    }

    /// 历史保留上限的默认值（REPAIR_PLAN C1），可经 defaults 写
    /// tf_historyRetentionLimit 调整
    static let defaultRetentionLimit = 10000

    /// 只保留最近 limit 条，更早的删除（REPAIR_PLAN C1）
    func prune(keepingMostRecent limit: Int) {
        guard limit > 0 else { return }
        let sql = """
        DELETE FROM recognition_history WHERE id NOT IN (
            SELECT id FROM recognition_history ORDER BY created_at DESC LIMIT ?
        );
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        guard stepSingleWrite(stmt) else { return }
        let prunedCount = sqlite3_changes(db)
        // 纠正样本依附于历史记录；裁剪历史后同步清理孤儿样本，避免画像读取到
        // 已经无法追溯来源的私人数据。
        sqlite3_exec(
            db,
            "DELETE FROM voice_polish_corrections WHERE history_id NOT IN (SELECT id FROM recognition_history);",
            nil, nil, nil
        )
        if prunedCount > 0 {
            AppLogger.log("[HistoryStore] 已按上限 \(limit) 裁剪 \(prunedCount) 条旧记录")
            postDidChangeNotification()
        }
    }

    func deleteAll() {
        let sql = """
        BEGIN IMMEDIATE;
        DELETE FROM voice_polish_corrections;
        DELETE FROM recognition_history;
        COMMIT;
        """
        if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
            postDidChangeNotification()
        } else {
            AppLogger.log("[HistoryStore] 清空历史失败: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    // MARK: - 语音输入显式纠正学习（沿用原数据格式）

    @discardableResult
    func confirmVoicePolishCorrection(
        historyID: String,
        correctedText: String,
        scene: WritingScene,
        personalizationEnabled: Bool,
        retentionLimit: Int,
        learnStyle requestedLearnStyle: Bool? = nil,
        learnTerminology requestedLearnTerminology: Bool? = nil
    ) throws -> VoicePolishCorrectionRecord {
        let learnStyle = (requestedLearnStyle ?? personalizationEnabled) && personalizationEnabled
        let learnTerminology = requestedLearnTerminology ?? personalizationEnabled
        guard learnStyle || learnTerminology else {
            throw HistoryStoreError.personalizationDisabled
        }
        guard let history = try fetchOrThrow(ids: [historyID]).first else {
            throw HistoryStoreError.correctionNotEligible
        }
        guard history.status.hasPrefix("voice_polish_")
                || (history.supportsDirectTerminologyLearning && learnTerminology && !learnStyle) else {
            throw HistoryStoreError.correctionNotEligible
        }
        let corrected = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty,
              corrected != history.finalText.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw HistoryStoreError.correctionUnchanged
        }
        let db = try requireDB()
        let id = UUID().uuidString
        let createdAt = Date()
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            throw HistoryStoreError.sqlite(sqliteMessage(in: db))
        }
        do {
            try upsertVoicePolishCorrection(
                id: id,
                historyID: historyID,
                createdAt: createdAt,
                scene: scene,
                correctedText: corrected,
                learnStyle: learnStyle,
                learnTerminology: learnTerminology,
                in: db
            )
            try pruneVoicePolishCorrections(keepingMostRecent: retentionLimit, in: db)
            guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                throw HistoryStoreError.sqlite(sqliteMessage(in: db))
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
        postDidChangeNotification()
        return VoicePolishCorrectionRecord(
            id: id,
            historyID: historyID,
            createdAt: createdAt,
            scene: scene,
            sourceText: history.rawText,
            generatedText: history.finalText,
            correctedText: corrected,
            learnStyle: learnStyle,
            learnTerminology: learnTerminology
        )
    }

    private func upsertVoicePolishCorrection(
        id: String,
        historyID: String,
        createdAt: Date,
        scene: WritingScene,
        correctedText: String,
        learnStyle: Bool,
        learnTerminology: Bool,
        in db: OpaquePointer
    ) throws {
        let sql = """
        INSERT INTO voice_polish_corrections (
            id, history_id, created_at, scene, corrected_text, learn_style, learn_terminology
        )
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(history_id) DO UPDATE SET
            id = excluded.id,
            created_at = excluded.created_at,
            scene = excluded.scene,
            corrected_text = excluded.corrected_text,
            learn_style = excluded.learn_style,
            learn_terminology = excluded.learn_terminology;
        """
        var stmt: OpaquePointer?
        try prepare(sql, in: db, statement: &stmt)
        defer { sqlite3_finalize(stmt) }
        SQL.bind(stmt, 1, id)
        SQL.bind(stmt, 2, historyID)
        SQL.bind(stmt, 3, ISO8601DateFormatter().string(from: createdAt))
        SQL.bind(stmt, 4, scene.rawValue)
        SQL.bind(stmt, 5, correctedText)
        sqlite3_bind_int(stmt, 6, learnStyle ? 1 : 0)
        sqlite3_bind_int(stmt, 7, learnTerminology ? 1 : 0)
        guard stepSingleWrite(stmt) else {
            throw HistoryStoreError.sqlite(sqliteMessage(in: db))
        }
    }

    func fetchVoicePolishCorrections(limit: Int? = nil) throws -> [VoicePolishCorrectionRecord] {
        let db = try requireDB()
        var sql = """
        SELECT c.id, c.history_id, c.created_at, c.scene,
               h.raw_text, h.final_text, c.corrected_text,
               c.learn_style, c.learn_terminology
        FROM voice_polish_corrections c
        INNER JOIN recognition_history h ON h.id = c.history_id
        ORDER BY c.created_at DESC
        """
        if limit != nil { sql += " LIMIT ?" }
        sql += ";"
        var stmt: OpaquePointer?
        try prepare(sql, in: db, statement: &stmt)
        defer { sqlite3_finalize(stmt) }
        if let limit { sqlite3_bind_int64(stmt, 1, sqlite3_int64(max(0, limit))) }

        let iso = ISO8601DateFormatter()
        var records: [VoicePolishCorrectionRecord] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                records.append(VoicePolishCorrectionRecord(
                    id: SQL.column(stmt, 0),
                    historyID: SQL.column(stmt, 1),
                    createdAt: iso.date(from: SQL.column(stmt, 2)) ?? Date(),
                    scene: WritingScene(rawValue: SQL.column(stmt, 3)) ?? .unknown,
                    sourceText: SQL.column(stmt, 4),
                    generatedText: SQL.column(stmt, 5),
                    correctedText: SQL.column(stmt, 6),
                    learnStyle: sqlite3_column_int(stmt, 7) != 0,
                    learnTerminology: sqlite3_column_int(stmt, 8) != 0
                ))
            case SQLITE_DONE:
                return records
            default:
                throw HistoryStoreError.sqlite(sqliteMessage(in: db))
            }
        }
    }

    func exportVoicePolishCorrections() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(fetchVoicePolishCorrections())
    }

    /// 撤销某条历史记录对应的显式纠正。历史正文保持不变，只移除学习样本；
    /// 术语 Repository 的投影撤销由上层使用同一 historyID 协调处理。
    func deleteVoicePolishCorrection(historyID: String) throws {
        let db = try requireDB()
        var stmt: OpaquePointer?
        try prepare(
            "DELETE FROM voice_polish_corrections WHERE history_id = ?;",
            in: db,
            statement: &stmt
        )
        defer { sqlite3_finalize(stmt) }
        SQL.bind(stmt, 1, historyID)
        guard stepSingleWrite(stmt) else {
            throw HistoryStoreError.sqlite(sqliteMessage(in: db))
        }
        postDidChangeNotification()
    }

    func deleteAllVoicePolishCorrections() throws {
        let db = try requireDB()
        guard sqlite3_exec(db, "DELETE FROM voice_polish_corrections;", nil, nil, nil) == SQLITE_OK else {
            throw HistoryStoreError.sqlite(sqliteMessage(in: db))
        }
        postDidChangeNotification()
    }

    /// 只重置表达风格学习，不破坏独立保存的术语纠正证据。
    ///
    /// - 仅学习风格的记录可以直接删除；
    /// - 同时学习术语的记录保留，并把 `learn_style` 关闭；
    /// - 仅学习术语的记录保持原样。
    func resetVoicePolishStyleLearning() throws {
        let db = try requireDB()
        let sql = """
        BEGIN IMMEDIATE;
        DELETE FROM voice_polish_corrections
        WHERE learn_style = 1 AND learn_terminology = 0;
        UPDATE voice_polish_corrections
        SET learn_style = 0
        WHERE learn_style = 1 AND learn_terminology = 1;
        COMMIT;
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw HistoryStoreError.sqlite(sqliteMessage(in: db))
        }
        postDidChangeNotification()
    }

    private func pruneVoicePolishCorrections(
        keepingMostRecent limit: Int,
        in db: OpaquePointer
    ) throws {
        let safeLimit = min(max(1, limit), VoicePolishSettings.maximumCorrectionLimit)
        let sql = """
        DELETE FROM voice_polish_corrections WHERE id NOT IN (
            SELECT id FROM voice_polish_corrections ORDER BY created_at DESC LIMIT ?
        );
        """
        var stmt: OpaquePointer?
        try prepare(sql, in: db, statement: &stmt)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(safeLimit))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw HistoryStoreError.sqlite(sqliteMessage(in: db))
        }
    }

    // MARK: - Migration

    /// 为旧记录计算并保存文本统计指标。应在应用启动时调用一次。
    func migrateTextMetrics() async {
        let sql = """
        SELECT id, final_text, character_count, token_count FROM recognition_history
        WHERE character_count IS NULL OR token_count IS NULL;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var updates: [(id: String, characterCount: Int?, tokenCount: Int?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = SQL.column(stmt, 0)
            let text = SQL.column(stmt, 1)
            let characterCount = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? text.count : nil
            let tokenCount = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? EstimatedTokenCounter.count(in: text) : nil
            updates.append((id: id, characterCount: characterCount, tokenCount: tokenCount))
        }

        guard !updates.isEmpty else { return }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        var stepFailed = false
        for update in updates {
            let updateSQL = """
            UPDATE recognition_history
            SET character_count = COALESCE(?, character_count),
                token_count = COALESCE(?, token_count)
            WHERE id = ?;
            """
            var updateStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK {
                if let count = update.characterCount {
                    sqlite3_bind_int(updateStmt, 1, Int32(count))
                } else {
                    sqlite3_bind_null(updateStmt, 1)
                }
                if let count = update.tokenCount {
                    sqlite3_bind_int(updateStmt, 2, Int32(count))
                } else {
                    sqlite3_bind_null(updateStmt, 2)
                }
                SQL.bind(updateStmt, 3, update.id)
                // REPAIR_PLAN J3：迁移事务不再忽略 step 结果——失败即回滚，下次启动重跑
                if sqlite3_step(updateStmt) != SQLITE_DONE {
                    stepFailed = true
                }
                sqlite3_finalize(updateStmt)
                if stepFailed { break }
            }
        }
        if stepFailed {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            AppLogger.log("[HistoryStore] 文本指标迁移失败已回滚: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        AppLogger.log("[HistoryStore] Migrated \(updates.count) records with text metrics")
    }

    func migrateCharacterCounts() async {
        await migrateTextMetrics()
    }

    // MARK: - Statistics

    struct Statistics: Sendable {
        let totalDuration: Double
        let totalCharacters: Int
        let totalTokens: Int
        let recordCount: Int
        let timeSavedSeconds: Double

        init(
            totalDuration: Double,
            totalCharacters: Int,
            totalTokens: Int = 0,
            recordCount: Int,
            timeSavedSeconds: Double
        ) {
            self.totalDuration = totalDuration
            self.totalCharacters = totalCharacters
            self.totalTokens = totalTokens
            self.recordCount = recordCount
            self.timeSavedSeconds = timeSavedSeconds
        }

        var averageSpeed: Double {
            guard totalDuration > 0 else { return 0 }
            return Double(totalTokens) / totalDuration * 60
        }
    }

    /// 获取全部记录的统计信息（使用数据库聚合查询，高效）
    func getStatistics() async -> Statistics {
        do {
            return try getStatisticsOrThrow()
        } catch {
            AppLogger.log("[HistoryStore] 统计查询失败: \(error.localizedDescription)")
            return Statistics(totalDuration: 0, totalCharacters: 0, recordCount: 0, timeSavedSeconds: 0)
        }
    }

    func getStatisticsOrThrow() throws -> Statistics {
        let db = try requireDB()
        // Only sum duration for rows that have token_count, so averageSpeed
        // is accurate even if some legacy rows haven't been migrated yet.
        let sql = """
        SELECT
            COALESCE(SUM(CASE WHEN token_count IS NOT NULL THEN duration_seconds ELSE 0 END), 0),
            COALESCE(SUM(character_count), 0),
            COALESCE(SUM(token_count), 0),
            COUNT(*),
            COALESCE(SUM(
                CASE
                    WHEN character_count IS NOT NULL THEN
                        MAX(
                            (CAST(character_count AS REAL) / \(Self.baselineTypingCharactersPerMinute) * 60.0)
                            - COALESCE(duration_seconds, 0),
                            0
                        )
                    ELSE 0
                END
            ), 0)
        FROM recognition_history;
        """
        var stmt: OpaquePointer?
        try prepare(sql, in: db, statement: &stmt)
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            let duration = sqlite3_column_double(stmt, 0)
            let chars = Int(sqlite3_column_int(stmt, 1))
            let tokens = Int(sqlite3_column_int(stmt, 2))
            let count = Int(sqlite3_column_int(stmt, 3))
            let timeSaved = sqlite3_column_double(stmt, 4)
            return Statistics(
                totalDuration: duration,
                totalCharacters: chars,
                totalTokens: tokens,
                recordCount: count,
                timeSavedSeconds: timeSaved
            )
        }
        throw HistoryStoreError.sqlite(sqliteMessage(in: db))
    }

    // MARK: - SQLite Helpers

    private func requireDB() throws -> OpaquePointer {
        guard let db else { throw HistoryStoreError.databaseUnavailable }
        return db
    }

    private func prepare(
        _ sql: String,
        in db: OpaquePointer,
        statement: inout OpaquePointer?
    ) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw HistoryStoreError.sqlite(sqliteMessage(in: db))
        }
    }

    private func executeDelete(
        _ sql: String,
        id: String,
        in db: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        try prepare(sql, in: db, statement: &statement)
        defer { sqlite3_finalize(statement) }
        SQL.bind(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw HistoryStoreError.sqlite(sqliteMessage(in: db))
        }
    }

    private func sqliteMessage(in db: OpaquePointer) -> String {
        sqlite3_errmsg(db).map { String(cString: $0) }
            ?? L("SQLite 操作失败", "SQLite operation failed")
    }

    private func decodeRecord(from stmt: OpaquePointer?) -> HistoryRecord {
        let iso = ISO8601DateFormatter()
        return HistoryRecord(
            id: SQL.column(stmt, 0),
            createdAt: iso.date(from: SQL.column(stmt, 1)) ?? Date(),
            durationSeconds: sqlite3_column_double(stmt, 2),
            rawText: SQL.column(stmt, 3),
            processingMode: SQL.optionalColumn(stmt, 4),
            processedText: SQL.optionalColumn(stmt, 5),
            finalText: SQL.column(stmt, 6),
            status: SQL.column(stmt, 7),
            characterCount: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 8)),
            tokenCount: sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 9))
        )
    }

    /// REPAIR_PLAN J3：单行写不再静默失败——busy_timeout(3s) 超时仍 BUSY、磁盘满等
    /// step 失败必须留痕，否则识别记录无声丢失、上层与用户均无感知。
    /// 日志记 sqlite3_sql 模板（含 ? 占位符、不含绑定值），不泄漏用户文本。
    @discardableResult
    private func stepSingleWrite(_ stmt: OpaquePointer?) -> Bool {
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let sql = sqlite3_sql(stmt).map { String(cString: $0) } ?? "unknown"
            AppLogger.log("[HistoryStore] 单行写失败: \(String(cString: sqlite3_errmsg(db))) — \(sql.prefix(80))")
            return false
        }
        return true
    }

    private func postDidChangeNotification() {
        secureDatabaseFiles()
        Task { @MainActor in
            NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)
        }
    }

    /// SQLite 的 WAL/SHM 文件在首次写入时才出现，因此每次写入通知前都
    /// 再次收紧三件套权限，覆盖升级旧库和运行中首次创建 WAL 的情况。
    nonisolated private func secureDatabaseFiles() {
        let databaseURL = URL(fileURLWithPath: databasePath)
        _ = SecureFilePermissions.setOwnerOnlyPermissions(at: databaseURL, permissions: 0o600)
        _ = SecureFilePermissions.setOwnerOnlyPermissions(
            at: URL(fileURLWithPath: databasePath + "-wal"), permissions: 0o600
        )
        _ = SecureFilePermissions.setOwnerOnlyPermissions(
            at: URL(fileURLWithPath: databasePath + "-shm"), permissions: 0o600
        )
    }
}
