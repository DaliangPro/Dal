import Foundation
import XCTest
@testable import Dal

final class JSONFileStoreRecoveryTests: XCTestCase {
    private let fileManager = FileManager.default

    func testMissingAndCorruptAreDistinctStates() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.trashItem(at: directory, resultingItemURL: nil) }
        let fileURL = directory.appendingPathComponent("settings.json")

        switch JSONFileStore.read([String].self, from: fileURL) {
        case .missing:
            break
        case .value, .corrupt:
            XCTFail("不存在的文件必须返回 missing")
        }

        try Data("{not-json".utf8).write(to: fileURL)

        switch JSONFileStore.read([String].self, from: fileURL) {
        case .corrupt(let backupURL, _):
            XCTAssertTrue(backupURL.lastPathComponent.hasPrefix("settings.json.corrupt-"))
            XCTAssertTrue(fileManager.fileExists(atPath: backupURL.path))
            XCTAssertFalse(fileManager.fileExists(atPath: fileURL.path))
            XCTAssertEqual(try Data(contentsOf: backupURL), Data("{not-json".utf8))
        case .missing, .value:
            XCTFail("损坏的文件必须返回 corrupt")
        }
    }

    func testValidEmptyArrayIsAValueAndQuarantinedStatePersistsAcrossReads() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.trashItem(at: directory, resultingItemURL: nil) }
        let fileURL = directory.appendingPathComponent("items.json")
        try Data("[]".utf8).write(to: fileURL)

        guard case .value(let value) = JSONFileStore.read([String].self, from: fileURL) else {
            return XCTFail("合法空数组必须是 value，而不是 missing")
        }
        XCTAssertTrue(value.isEmpty)

        try Data("broken".utf8).write(to: fileURL)
        guard case .corrupt(let firstBackupURL, _) = JSONFileStore.read([String].self, from: fileURL) else {
            return XCTFail("首次读取必须隔离损坏文件")
        }
        guard case .corrupt(let secondBackupURL, _) = JSONFileStore.read([String].self, from: fileURL) else {
            return XCTFail("后续读取不能把已隔离文件误判为 missing")
        }
        XCTAssertEqual(secondBackupURL, firstBackupURL)
    }

    func testCorruptFileIsBackedUpAndNeverOverwrittenWithEmptyValue() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.trashItem(at: directory, resultingItemURL: nil) }
        let fileURL = directory.appendingPathComponent("modes.json")
        let corruptData = Data("not valid JSON".utf8)
        try corruptData.write(to: fileURL)
        let storage = ModeStorage(fileURL: fileURL)

        let result = storage.loadResult()

        guard case .corrupt(let backupURL, _) = result else {
            return XCTFail("ModeStorage 必须传播 corrupt 状态")
        }
        XCTAssertEqual(try Data(contentsOf: backupURL), corruptData)
        XCTAssertFalse(fileManager.fileExists(atPath: fileURL.path))

        let fallback = storage.load()
        XCTAssertEqual(fallback, ProcessingMode.defaults)
        XCTAssertFalse(fileManager.fileExists(atPath: fileURL.path), "兼容边界不得自动写回空值或默认值")
    }

    func testVocabularyStoragesExposeCorruptState() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.trashItem(at: directory, resultingItemURL: nil) }
        let suiteName = "dal-json-recovery-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("无法创建隔离 UserDefaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = VocabularyStorageContext(
            supportDirectory: directory,
            userDefaults: defaults,
            fileManager: fileManager,
            hotwordsDidChange: {},
            revealFile: { _ in }
        )
        try Data("[broken".utf8).write(to: HotwordStorage.userFileURL(in: context))
        try Data("[broken".utf8).write(to: SnippetStorage.userFileURL(in: context))

        guard case .corrupt = HotwordStorage.loadResult(context: context) else {
            return XCTFail("HotwordStorage 必须传播 corrupt 状态")
        }
        guard case .corrupt = SnippetStorage.loadResult(context: context) else {
            return XCTFail("SnippetStorage 必须传播 corrupt 状态")
        }
    }

    func testCorruptVocabularyBackupBlocksSaveAndFinderRevealsBackup() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.trashItem(at: directory, resultingItemURL: nil) }
        let suiteName = "dal-json-recovery-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("无法创建隔离 UserDefaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var revealedURL: URL?
        let context = VocabularyStorageContext(
            supportDirectory: directory,
            userDefaults: defaults,
            fileManager: fileManager,
            hotwordsDidChange: {},
            revealFile: { revealedURL = $0 }
        )
        let userURL = HotwordStorage.userFileURL(in: context)
        try Data("broken".utf8).write(to: userURL)
        guard case .corrupt(let backupURL, _) = HotwordStorage.loadResult(context: context) else {
            return XCTFail("必须隔离损坏热词")
        }

        XCTAssertThrowsError(try HotwordStorage.save([], context: context))
        HotwordStorage.revealUserInFinder(context: context)

        XCTAssertEqual(revealedURL, backupURL)
        XCTAssertFalse(fileManager.fileExists(atPath: userURL.path))
    }

    func testCorruptBuiltinVocabularyIsNotReseededOrMarkedMigrated() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.trashItem(at: directory, resultingItemURL: nil) }
        let suiteName = "dal-json-recovery-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("无法创建隔离 UserDefaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = VocabularyStorageContext(
            supportDirectory: directory,
            userDefaults: defaults,
            fileManager: fileManager,
            hotwordsDidChange: {},
            revealFile: { _ in }
        )
        let builtinURL = HotwordStorage.builtinFileURL(in: context)
        try Data("broken".utf8).write(to: builtinURL)

        HotwordStorage.migrateIfNeeded(context: context)
        HotwordStorage.migrateIfNeeded(context: context)

        XCTAssertFalse(fileManager.fileExists(atPath: builtinURL.path))
        XCTAssertNil(defaults.object(forKey: "tf_hotwords_schema_version"))
        guard case .corrupt = HotwordStorage.loadBuiltinResult(context: context) else {
            return XCTFail("后续启动必须保持恢复态，不能重建默认文件")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("dal-json-recovery-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
