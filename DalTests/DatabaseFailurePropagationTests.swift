import Foundation
import SQLite3
import XCTest
@testable import Dal

final class DatabaseFailurePropagationTests: XCTestCase {
    private let fileManager = FileManager.default

    func testHistoryStorePrepareFailurePropagates() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.trashItem(at: directory, resultingItemURL: nil) }
        let path = directory.appendingPathComponent("history.sqlite").path
        let store = HistoryStore(path: path)
        try dropTable("recognition_history", at: path)

        do {
            _ = try await store.fetchAllOrThrow()
            XCTFail("prepare 失败不得伪装成空历史")
        } catch HistoryStoreError.databaseUnavailable {
            XCTFail("连接仍可用，此处应是 SQL 查询失败")
        } catch HistoryStoreError.sqlite {
            // 预期：prepare 错误向上传播。
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("dal-database-failure-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func dropTable(_ table: String, at path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw NSError(domain: "DatabaseFailurePropagationTests", code: 1)
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "DROP TABLE \(table);", nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseFailurePropagationTests", code: 2)
        }
    }
}
