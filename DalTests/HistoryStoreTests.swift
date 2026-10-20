import XCTest
import SQLite3
@testable import Dal

final class HistoryStoreTests: XCTestCase {

    private var store: HistoryStore!
    private var testPath: String!

    override func setUp() async throws {
        testPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("dal-test-\(UUID().uuidString).db").path
        store = HistoryStore(path: testPath)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: testPath)
    }

    func testInsertAndFetchAll() async {
        let record = HistoryRecord(
            id: UUID().uuidString, createdAt: Date(), durationSeconds: 3.5,
            rawText: "测试文本", processingMode: nil, processedText: nil,
            finalText: "测试文本", status: "completed", characterCount: 4,
            tokenCount: 4
        )
        await store.insert(record)
        let all = await store.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.rawText, "测试文本")
        XCTAssertEqual(all.first?.durationSeconds ?? 0, 3.5, accuracy: 0.01)
        XCTAssertEqual(all.first?.characterCount, 4)
        XCTAssertEqual(all.first?.tokenCount, 4)
    }

    func testDatabaseAndWALFilesUseOwnerOnlyPermissions() async {
        await store.insert(HistoryRecord(
            id: "permissions", createdAt: Date(), durationSeconds: 1,
            rawText: "权限测试", processingMode: nil, processedText: nil,
            finalText: "权限测试", status: "completed", characterCount: 4
        ))

        let fileManager = FileManager.default
        for path in [testPath!, testPath! + "-wal", testPath! + "-shm"]
            where fileManager.fileExists(atPath: path) {
            let attributes = try? fileManager.attributesOfItem(atPath: path)
            let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(permissions, 0o600, "权限不应超过用户本人: \(path)")
        }
    }

    func testInsertWithProcessedText() async {
        let record = HistoryRecord(
            id: UUID().uuidString, createdAt: Date(), durationSeconds: 2.0,
            rawText: "原始文本", processingMode: "润色",
            processedText: "润色后的文本", finalText: "润色后的文本", status: "completed",
            characterCount: 6,
            tokenCount: 6
        )
        await store.insert(record)
        let all = await store.fetchAll()
        XCTAssertEqual(all.first?.processingMode, "润色")
        XCTAssertEqual(all.first?.processedText, "润色后的文本")
        XCTAssertEqual(all.first?.characterCount, 6)
        XCTAssertEqual(all.first?.tokenCount, 6)
    }

    func testDelete() async {
        let id = UUID().uuidString
        let record = HistoryRecord(
            id: id, createdAt: Date(), durationSeconds: 1.0,
            rawText: "to delete", processingMode: nil, processedText: nil,
            finalText: "to delete", status: "completed", characterCount: 9
        )
        await store.insert(record)
        await store.delete(id: id)
        let all = await store.fetchAll()
        XCTAssertTrue(all.isEmpty)
    }

    func testFetchAllOrderedByDate() async {
        let old = HistoryRecord(
            id: "1", createdAt: Date(timeIntervalSinceNow: -100), durationSeconds: 1,
            rawText: "old", processingMode: nil, processedText: nil,
            finalText: "old", status: "completed", characterCount: 3
        )
        let recent = HistoryRecord(
            id: "2", createdAt: Date(), durationSeconds: 1,
            rawText: "recent", processingMode: nil, processedText: nil,
            finalText: "recent", status: "completed", characterCount: 6
        )
        await store.insert(old)
        await store.insert(recent)
        let all = await store.fetchAll()
        XCTAssertEqual(all.first?.rawText, "recent")
        XCTAssertEqual(all.last?.rawText, "old")
    }

    func testDeleteAll() async {
        for i in 0..<3 {
            await store.insert(HistoryRecord(
                id: "\(i)", createdAt: Date(), durationSeconds: 1,
                rawText: "text\(i)", processingMode: nil, processedText: nil,
                finalText: "text\(i)", status: "completed", characterCount: 5 + i
            ))
        }
        await store.deleteAll()
        let all = await store.fetchAll()
        XCTAssertTrue(all.isEmpty)
    }

    func testVoicePolishCorrectionRequiresExplicitEligibleChangedConfirmation() async throws {
        await store.insert(HistoryRecord(
            id: "vp-1", createdAt: Date(), durationSeconds: 1,
            rawText: "原始口述", processingMode: "语音润色", processedText: "模型结果",
            finalText: "模型结果", status: "voice_polish_success", characterCount: 4
        ))

        do {
            _ = try await store.confirmVoicePolishCorrection(
                historyID: "vp-1",
                correctedText: "用户修改",
                scene: .workChat,
                personalizationEnabled: false,
                retentionLimit: 200
            )
            XCTFail("关闭个性化时不得采集")
        } catch {
            XCTAssertEqual(error as? HistoryStoreError, .personalizationDisabled)
        }

        do {
            _ = try await store.confirmVoicePolishCorrection(
                historyID: "vp-1",
                correctedText: "模型结果",
                scene: .workChat,
                personalizationEnabled: true,
                retentionLimit: 200
            )
            XCTFail("未修改结果不得形成样本")
        } catch {
            XCTAssertEqual(error as? HistoryStoreError, .correctionUnchanged)
        }

        let confirmed = try await store.confirmVoicePolishCorrection(
            historyID: "vp-1",
            correctedText: "用户修改",
            scene: .workChat,
            personalizationEnabled: true,
            retentionLimit: 200
        )
        XCTAssertEqual(confirmed.sourceText, "原始口述")
        XCTAssertEqual(confirmed.generatedText, "模型结果")
        XCTAssertEqual(confirmed.correctedText, "用户修改")
        let stored = try await store.fetchVoicePolishCorrections()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].id, confirmed.id)
        XCTAssertEqual(stored[0].correctedText, confirmed.correctedText)
    }

    func testDirectHistoryOnlyAcceptsTerminologyLearningForSuccessfulDirectOutput() async throws {
        let cases: [(mode: String?, processed: String?, status: String, style: Bool, allowed: Bool)] = [
            ("直出", nil, "completed", false, true),
            ("Direct", nil, "stream_recovered", false, true),
            ("直出", nil, "completed", true, false),
            ("直出", nil, "copied_only", false, false),
            ("直出", nil, "no_input_target", false, false),
            ("直出", "模型输出", "completed", false, false),
            ("翻译", nil, "completed", false, false),
            (nil, nil, "completed", false, false),
        ]
        for (index, item) in cases.enumerated() {
            let id = "direct-learning-\(index)"
            await store.insert(HistoryRecord(
                id: id, createdAt: Date(), durationSeconds: 1,
                rawText: "Type less", processingMode: item.mode, processedText: item.processed,
                finalText: "Type less", status: item.status, characterCount: 9
            ))
            do {
                let correction = try await store.confirmVoicePolishCorrection(
                    historyID: id, correctedText: "Typeless", scene: .unknown,
                    personalizationEnabled: true, retentionLimit: 200,
                    learnStyle: item.style, learnTerminology: true
                )
                XCTAssertTrue(item.allowed, "不应接受案例 \(index)")
                XCTAssertFalse(correction.learnStyle)
                XCTAssertTrue(correction.learnTerminology)
            } catch {
                XCTAssertFalse(item.allowed, "应接受案例 \(index)：\(error)")
                XCTAssertEqual(error as? HistoryStoreError, .correctionNotEligible)
            }
        }
        let corrections = try await store.fetchVoicePolishCorrections()
        XCTAssertEqual(corrections.count, 2)
    }

    func testVoicePolishCorrectionRetentionExportClearAndHistoryDelete() async throws {
        for index in 0..<3 {
            let id = "vp-\(index)"
            await store.insert(HistoryRecord(
                id: id,
                createdAt: Date(timeIntervalSince1970: Double(1_000 + index)),
                durationSeconds: 1,
                rawText: "原文\(index)",
                processingMode: "语音润色",
                processedText: "结果\(index)",
                finalText: "结果\(index)",
                status: "voice_polish_success",
                characterCount: 3
            ))
            _ = try await store.confirmVoicePolishCorrection(
                historyID: id,
                correctedText: "修改\(index)",
                scene: .document,
                personalizationEnabled: true,
                retentionLimit: 2
            )
            try? await Task.sleep(for: .milliseconds(2))
        }

        var corrections = try await store.fetchVoicePolishCorrections()
        XCTAssertEqual(corrections.count, 2)
        let exported = try await store.exportVoicePolishCorrections()
        XCTAssertEqual(
            try JSONDecoder.voicePolishDecoder.decode(
                [VoicePolishCorrectionRecord].self,
                from: exported
            ).count,
            2
        )

        await store.delete(id: corrections[0].historyID)
        corrections = try await store.fetchVoicePolishCorrections()
        XCTAssertEqual(corrections.count, 1)

        try await store.deleteAllVoicePolishCorrections()
        let empty = try await store.fetchVoicePolishCorrections()
        XCTAssertTrue(empty.isEmpty)
    }

    func testVoicePolishCorrectionUpsertRollsBackWhenRetentionPruneFails() async throws {
        await store.insert(HistoryRecord(
            id: "vp-transaction-old",
            createdAt: Date(timeIntervalSince1970: 1_000),
            durationSeconds: 1,
            rawText: "旧原文",
            processingMode: "语音润色",
            processedText: "旧结果",
            finalText: "旧结果",
            status: "voice_polish_success",
            characterCount: 3
        ))
        _ = try await store.confirmVoicePolishCorrection(
            historyID: "vp-transaction-old",
            correctedText: "旧修改",
            scene: .document,
            personalizationEnabled: true,
            retentionLimit: 2
        )
        await store.insert(HistoryRecord(
            id: "vp-transaction-new",
            createdAt: Date(timeIntervalSince1970: 2_000),
            durationSeconds: 1,
            rawText: "新原文",
            processingMode: "语音润色",
            processedText: "新结果",
            finalText: "新结果",
            status: "voice_polish_success",
            characterCount: 3
        ))

        var triggerDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(testPath, &triggerDB), SQLITE_OK)
        defer { sqlite3_close(triggerDB) }
        let triggerSQL = """
        CREATE TRIGGER fail_voice_polish_prune
        BEFORE DELETE ON voice_polish_corrections
        BEGIN
            SELECT RAISE(ABORT, 'planned prune failure');
        END;
        """
        XCTAssertEqual(sqlite3_exec(triggerDB, triggerSQL, nil, nil, nil), SQLITE_OK)

        do {
            _ = try await store.confirmVoicePolishCorrection(
                historyID: "vp-transaction-new",
                correctedText: "新修改",
                scene: .document,
                personalizationEnabled: true,
                retentionLimit: 1
            )
            XCTFail("清理失败时整笔纠正事务必须失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("planned prune failure"))
        }

        let stored = try await store.fetchVoicePolishCorrections()
        XCTAssertEqual(stored.map(\.historyID), ["vp-transaction-old"])
        XCTAssertEqual(stored.first?.correctedText, "旧修改")
    }

    func testVoicePolishCorrectionCanBeUndoneWithoutDeletingHistory() async throws {
        await store.insert(HistoryRecord(
            id: "vp-undo", createdAt: Date(), durationSeconds: 1,
            rawText: "Type less", processingMode: "语音润色", processedText: "Type less",
            finalText: "Type less", status: "voice_polish_success", characterCount: 9
        ))
        _ = try await store.confirmVoicePolishCorrection(
            historyID: "vp-undo",
            correctedText: "Typeless",
            scene: .workChat,
            personalizationEnabled: true,
            retentionLimit: 200
        )

        try await store.deleteVoicePolishCorrection(historyID: "vp-undo")

        let corrections = try await store.fetchVoicePolishCorrections()
        let histories = await store.fetch(ids: ["vp-undo"])
        XCTAssertTrue(corrections.isEmpty)
        XCTAssertEqual(histories.first?.finalText, "Type less")
    }

    func testDeleteOrThrowAtomicallyRemovesHistoryAndCorrection() async throws {
        await store.insert(HistoryRecord(
            id: "vp-delete-throwing", createdAt: Date(), durationSeconds: 1,
            rawText: "Type less", processingMode: "语音润色", processedText: "Type less",
            finalText: "Type less", status: "voice_polish_success", characterCount: 9
        ))
        _ = try await store.confirmVoicePolishCorrection(
            historyID: "vp-delete-throwing",
            correctedText: "Typeless",
            scene: .chat,
            personalizationEnabled: true,
            retentionLimit: 200
        )

        try await store.deleteOrThrow(id: "vp-delete-throwing")

        let histories = await store.fetch(ids: ["vp-delete-throwing"])
        let corrections = try await store.fetchVoicePolishCorrections()
        XCTAssertTrue(histories.isEmpty)
        XCTAssertTrue(corrections.isEmpty)
    }

    func testVoicePolishTerminologyOnlyCorrectionWorksWithStyleLearningOff() async throws {
        await store.insert(HistoryRecord(
            id: "vp-term-only", createdAt: Date(), durationSeconds: 1,
            rawText: "Type less", processingMode: "语音润色", processedText: "Type less",
            finalText: "Type less", status: "voice_polish_success", characterCount: 9
        ))

        let record = try await store.confirmVoicePolishCorrection(
            historyID: "vp-term-only",
            correctedText: "Typeless",
            scene: .workChat,
            personalizationEnabled: false,
            retentionLimit: 200,
            learnStyle: false,
            learnTerminology: true
        )

        XCTAssertFalse(record.learnStyle)
        XCTAssertTrue(record.learnTerminology)
        let stored = try await store.fetchVoicePolishCorrections()
        XCTAssertEqual(stored.map(\.learnStyle), [false])
        XCTAssertEqual(stored.map(\.learnTerminology), [true])
    }

    func testResetVoicePolishStyleLearningPreservesTerminologyEvidence() async throws {
        let fixtures: [(id: String, learnedText: String)] = [
            ("vp-mixed", "Typeless 正确"),
            ("vp-style-only", "更简洁的表达"),
            ("vp-term-only-reset", "Claude Code 正确"),
        ]
        for (index, fixture) in fixtures.enumerated() {
            await store.insert(HistoryRecord(
                id: fixture.id,
                createdAt: Date(timeIntervalSince1970: Double(index + 1)),
                durationSeconds: 1,
                rawText: "原始文字 \(index)",
                processingMode: "语音润色",
                processedText: "生成文字 \(index)",
                finalText: "生成文字 \(index)",
                status: "voice_polish_success",
                characterCount: 6
            ))
        }

        _ = try await store.confirmVoicePolishCorrection(
            historyID: fixtures[0].id,
            correctedText: fixtures[0].learnedText,
            scene: .chat,
            personalizationEnabled: true,
            retentionLimit: 200,
            learnStyle: true,
            learnTerminology: true
        )
        _ = try await store.confirmVoicePolishCorrection(
            historyID: fixtures[1].id,
            correctedText: fixtures[1].learnedText,
            scene: .chat,
            personalizationEnabled: true,
            retentionLimit: 200,
            learnStyle: true,
            learnTerminology: false
        )
        _ = try await store.confirmVoicePolishCorrection(
            historyID: fixtures[2].id,
            correctedText: fixtures[2].learnedText,
            scene: .code,
            personalizationEnabled: false,
            retentionLimit: 200,
            learnStyle: false,
            learnTerminology: true
        )

        try await store.resetVoicePolishStyleLearning()

        let records = try await store.fetchVoicePolishCorrections()
        XCTAssertEqual(Set(records.map(\.historyID)), [fixtures[0].id, fixtures[2].id])
        XCTAssertTrue(records.allSatisfy { !$0.learnStyle })
        XCTAssertTrue(records.allSatisfy(\.learnTerminology))
    }

    func testHistoryPruneAlsoRemovesOrphanedVoicePolishCorrections() async throws {
        for index in 0..<2 {
            let id = "prune-vp-\(index)"
            await store.insert(HistoryRecord(
                id: id,
                createdAt: Date(timeIntervalSince1970: Double(2_000 + index)),
                durationSeconds: 1,
                rawText: "原文\(index)",
                processingMode: "语音润色",
                processedText: "结果\(index)",
                finalText: "结果\(index)",
                status: "voice_polish_success",
                characterCount: 3
            ))
            _ = try await store.confirmVoicePolishCorrection(
                historyID: id,
                correctedText: "修改\(index)",
                scene: .document,
                personalizationEnabled: true,
                retentionLimit: 200
            )
        }

        await store.prune(keepingMostRecent: 1)

        let corrections = try await store.fetchVoicePolishCorrections()
        XCTAssertEqual(corrections.map(\.historyID), ["prune-vp-1"])
    }

    func testFetchRecentReturnsLimitedNewestRecords() async {
        await store.insert(HistoryRecord(
            id: "1", createdAt: Date(timeIntervalSinceNow: -100), durationSeconds: 1,
            rawText: "old", processingMode: nil, processedText: nil,
            finalText: "old", status: "completed", characterCount: 3
        ))
        await store.insert(HistoryRecord(
            id: "2", createdAt: Date(), durationSeconds: 1,
            rawText: "new", processingMode: nil, processedText: nil,
            finalText: "new", status: "completed", characterCount: 3
        ))

        let recent = await store.fetchRecent(limit: 1)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.id, "2")
    }

    func testFetchBetweenFiltersByDateRange() async {
        let olderDate = Date(timeIntervalSinceNow: -3600)
        let inRangeDate = Date(timeIntervalSinceNow: -300)

        await store.insert(HistoryRecord(
            id: "old", createdAt: olderDate, durationSeconds: 1,
            rawText: "old", processingMode: nil, processedText: nil,
            finalText: "old", status: "completed", characterCount: 3
        ))
        await store.insert(HistoryRecord(
            id: "in-range", createdAt: inRangeDate, durationSeconds: 1,
            rawText: "new", processingMode: nil, processedText: nil,
            finalText: "new", status: "completed", characterCount: 3
        ))

        let records = await store.fetchBetween(
            start: Date(timeIntervalSinceNow: -600),
            end: Date()
        )
        XCTAssertEqual(records.map(\.id), ["in-range"])
    }

    func testFetchIDsReturnsOnlyMatchingRecords() async {
        await store.insert(HistoryRecord(
            id: "a", createdAt: Date(timeIntervalSinceNow: -60), durationSeconds: 1,
            rawText: "a", processingMode: nil, processedText: nil,
            finalText: "a", status: "completed", characterCount: 1
        ))
        await store.insert(HistoryRecord(
            id: "b", createdAt: Date(), durationSeconds: 1,
            rawText: "b", processingMode: nil, processedText: nil,
            finalText: "b", status: "completed", characterCount: 1
        ))

        let records = await store.fetch(ids: ["a"])
        XCTAssertEqual(records.map(\.id), ["a"])
    }

    func testInsertPostsHistoryDidChangeNotification() async {
        let notification = expectation(forNotification: .historyStoreDidChange, object: nil)
        let record = HistoryRecord(
            id: UUID().uuidString, createdAt: Date(), durationSeconds: 1.2,
            rawText: "notify", processingMode: "智能模式", processedText: "notify",
            finalText: "notify", status: "completed", characterCount: 6
        )

        await store.insert(record)

        await fulfillment(of: [notification], timeout: 1.0)
    }

    func testStatisticsCalculatesTimeSavedPerRecord() async {
        await store.insert(HistoryRecord(
            id: "fast-dictation",
            createdAt: Date(timeIntervalSinceNow: -60),
            durationSeconds: 30,
            rawText: "一二三四五六七八九十",
            processingMode: nil,
            processedText: nil,
            finalText: "一二三四五六七八九十",
            status: "completed",
            characterCount: 100,
            tokenCount: 50
        ))
        await store.insert(HistoryRecord(
            id: "slow-dictation",
            createdAt: Date(),
            durationSeconds: 30,
            rawText: "短句",
            processingMode: nil,
            processedText: nil,
            finalText: "短句",
            status: "completed",
            characterCount: 10,
            tokenCount: 5
        ))

        let statistics = await store.getStatistics()

        XCTAssertEqual(statistics.totalDuration, 60, accuracy: 0.01)
        XCTAssertEqual(statistics.totalCharacters, 110)
        XCTAssertEqual(statistics.totalTokens, 55)
        XCTAssertEqual(statistics.averageSpeed, 55, accuracy: 0.01)
        XCTAssertEqual(statistics.recordCount, 2)
        XCTAssertEqual(statistics.timeSavedSeconds, 90, accuracy: 0.01)
    }

    func testStatisticsIgnoreDurationForRowsWithoutTokenCount() async {
        await store.insert(HistoryRecord(
            id: "legacy-null-count",
            createdAt: Date(timeIntervalSinceNow: -60),
            durationSeconds: 99,
            rawText: "legacy",
            processingMode: nil,
            processedText: nil,
            finalText: "legacy",
            status: "completed",
            characterCount: nil,
            tokenCount: nil
        ))
        await store.insert(HistoryRecord(
            id: "counted",
            createdAt: Date(),
            durationSeconds: 12,
            rawText: "一二三四五六七八九十",
            processingMode: nil,
            processedText: nil,
            finalText: "一二三四五六七八九十",
            status: "completed",
            characterCount: 10,
            tokenCount: 7
        ))

        let statistics = await store.getStatistics()

        XCTAssertEqual(statistics.recordCount, 2)
        XCTAssertEqual(statistics.totalDuration, 12, accuracy: 0.01)
        XCTAssertEqual(statistics.totalCharacters, 10)
        XCTAssertEqual(statistics.totalTokens, 7)
        XCTAssertEqual(statistics.averageSpeed, 35, accuracy: 0.01)
    }

    func testStatisticsUsesTokenCountForAverageSpeed() async {
        await store.insert(HistoryRecord(
            id: "token-speed",
            createdAt: Date(),
            durationSeconds: 15,
            rawText: "这是一个更长的句子",
            processingMode: nil,
            processedText: nil,
            finalText: "这是一个更长的句子",
            status: "completed",
            characterCount: 100,
            tokenCount: 25
        ))

        let statistics = await store.getStatistics()

        XCTAssertEqual(statistics.totalCharacters, 100)
        XCTAssertEqual(statistics.totalTokens, 25)
        XCTAssertEqual(statistics.averageSpeed, 100, accuracy: 0.01)
    }

    func testMigratesLegacyDatabaseWithoutCharacterCountColumn() async throws {
        let legacyPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("dal-legacy-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: legacyPath) }
        try createLegacyHistoryDatabase(at: legacyPath)
        let legacyStore = HistoryStore(path: legacyPath)

        var records = await legacyStore.fetchAll()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, "legacy-row")
        XCTAssertNil(records.first?.characterCount)
        XCTAssertNil(records.first?.tokenCount)

        await legacyStore.migrateTextMetrics()

        records = await legacyStore.fetchAll()
        XCTAssertEqual(records.first?.characterCount, 3)
        XCTAssertEqual(records.first?.tokenCount, 3)
        let statistics = await legacyStore.getStatistics()
        XCTAssertEqual(statistics.totalCharacters, 3)
        XCTAssertEqual(statistics.totalTokens, 3)
        XCTAssertEqual(statistics.totalDuration, 2.5, accuracy: 0.01)
    }

    func testLegacyCorrectionsTableGainsLearningColumnsOnceAndKeepsRows() throws {
        let legacyPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("dal-legacy-corrections-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: legacyPath) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(legacyPath, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
        CREATE TABLE voice_polish_corrections (
            id TEXT PRIMARY KEY, history_id TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL,
            scene TEXT NOT NULL, corrected_text TEXT NOT NULL
        );
        INSERT INTO voice_polish_corrections VALUES ('c1', 'h1', '2026-01-02T03:04:05Z', 'workChat', '旧纠正');
        """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        // 连续打开两次：第二次列已存在，必须跳过而不是重复 ALTER。
        _ = HistoryStore(path: legacyPath)
        _ = HistoryStore(path: legacyPath)

        XCTAssertEqual(sqlite3_open(legacyPath, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(
            db, "SELECT learn_style, learn_terminology, corrected_text FROM voice_polish_corrections;", -1, &stmt, nil
        ), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 1)
        XCTAssertEqual(sqlite3_column_int(stmt, 1), 1)
        XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 2)), "旧纠正")
    }

    private func createLegacyHistoryDatabase(at path: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let sql = """
        CREATE TABLE recognition_history (
            id TEXT PRIMARY KEY,
            created_at TEXT NOT NULL,
            duration_seconds REAL,
            raw_text TEXT NOT NULL,
            processing_mode TEXT,
            processed_text TEXT,
            final_text TEXT NOT NULL,
            status TEXT NOT NULL
        );
        INSERT INTO recognition_history
        (id, created_at, duration_seconds, raw_text, processing_mode, processed_text, final_text, status)
        VALUES
        ('legacy-row', '2026-01-02T03:04:05Z', 2.5, '旧记录', NULL, NULL, '旧记录', 'completed');
        """

        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    // MARK: - REPAIR_PLAN B5

    func testCreatedAtIndexExists() async {
        let exists = await store.hasIndex(named: "idx_history_created_at")
        XCTAssertTrue(exists, "created_at 索引应在建库时创建")
    }

    func testFreshStoreIsHealthy() async {
        let healthy = await store.isHealthy
        XCTAssertTrue(healthy)
    }

    func testOpenFailureIsUnhealthyAndSilentNoOp() async {
        // 指向一个不可能创建数据库的路径（不存在的目录）
        let badPath = "/nonexistent-\(UUID().uuidString)/h.db"
        let broken = HistoryStore(path: badPath)
        let healthy = await broken.isHealthy
        XCTAssertFalse(healthy)
        // 读写退化为 no-op 而不是崩溃
        let all = await broken.fetchAll()
        XCTAssertTrue(all.isEmpty)
    }

    func testPruneKeepsMostRecent() async {
        for i in 0..<10 {
            let record = HistoryRecord(
                id: "prune-\(i)",
                createdAt: Date(timeIntervalSince1970: Double(1000 + i)),
                durationSeconds: 1,
                rawText: "第\(i)条", processingMode: nil, processedText: nil,
                finalText: "第\(i)条", status: "completed", characterCount: 3
            )
            await store.insert(record)
        }
        await store.prune(keepingMostRecent: 3)
        let remaining = await store.fetchAll()
        XCTAssertEqual(remaining.count, 3)
        XCTAssertEqual(remaining.map(\.id), ["prune-9", "prune-8", "prune-7"])
    }

    func testPruneWithNonPositiveLimitIsNoOp() async {
        let record = HistoryRecord(
            id: "keep", createdAt: Date(), durationSeconds: 1,
            rawText: "在", processingMode: nil, processedText: nil,
            finalText: "在", status: "completed", characterCount: 1
        )
        await store.insert(record)
        await store.prune(keepingMostRecent: 0)
        let remaining = await store.fetchAll()
        XCTAssertEqual(remaining.count, 1)
    }

    /// REPAIR_PLAN J3：库被第二连接短暂锁住（<busy_timeout 3s）时，
    /// insert 必须等待锁释放后成功落库，而非静默丢记录。
    /// 场景还原：另一连接的事务持写锁时来了一条识别记录。
    func testInsertWaitsOutShortLockAndStillPersists() async throws {
        // 第二连接锁库（模拟其他事务持写锁）
        var rival: OpaquePointer?
        XCTAssertEqual(sqlite3_open(testPath, &rival), SQLITE_OK)
        defer { sqlite3_close(rival) }
        XCTAssertEqual(sqlite3_exec(rival, "BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)

        // 400ms 后释放锁（远小于 busy_timeout 3s）。
        // 指针经 UInt 位模式跨任务传递以满足 Sendable 检查；rival 生命周期由本函数 defer 兜底。
        let rivalAddress = UInt(bitPattern: UnsafeMutableRawPointer(rival))
        Task.detached {
            try? await Task.sleep(for: .milliseconds(400))
            sqlite3_exec(OpaquePointer(bitPattern: rivalAddress), "COMMIT;", nil, nil, nil)
        }

        let record = HistoryRecord(
            id: "busy-wait", createdAt: Date(), durationSeconds: 1,
            rawText: "撞锁记录", processingMode: nil, processedText: nil,
            finalText: "撞锁记录", status: "completed", characterCount: 4
        )
        await store.insert(record)

        let all = await store.fetchAll()
        XCTAssertEqual(all.map(\.id), ["busy-wait"], "撞锁 <3s 时记录必须最终落库（busy_timeout 生效）")
    }
}

private extension JSONDecoder {
    static var voicePolishDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
