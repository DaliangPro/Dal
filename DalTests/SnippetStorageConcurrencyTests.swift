import XCTest
@testable import Dal

/// REPAIR_PLAN J1：cachedRules 静态缓存加锁后的并发冒烟。
/// 场景还原：用户边口述（RecognitionSession actor 线程 applyEffective）
/// 边在设置页改替换词（主线程 save → invalidateCache）。
/// 无锁版本在此压力下 COW 数组并发重置/遍历会撕裂崩溃；加锁后必须恒稳。
final class SnippetStorageConcurrencyTests: XCTestCase {

    func testConcurrentApplyAndInvalidateDoesNotCrash() throws {
        let context = try makeContext()
        DispatchQueue.concurrentPerform(iterations: 500) { i in
            if i % 5 == 0 {
                SnippetStorage.invalidateCache()
            } else {
                _ = SnippetStorage.applyEffective(to: "cloud code 并发压力 \(i)", context: context)
            }
        }
        // 收尾：缓存处于一致状态，apply 仍可正常工作；fixture 只读临时目录。
        let out = SnippetStorage.applyEffective(to: "并发收尾检查", context: context)
        XCTAssertFalse(out.isEmpty)
    }

    func testInvalidateThenApplyRebuildsCache() throws {
        let context = try makeContext()
        SnippetStorage.invalidateCache()
        let first = SnippetStorage.applyEffective(to: "重建检查", context: context)
        let second = SnippetStorage.applyEffective(to: "重建检查", context: context)
        XCTAssertEqual(first, second, "同一输入两次 apply（含缓存重建路径）结果必须一致")
    }

    private func makeContext() throws -> VocabularyStorageContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnippetStorageConcurrencyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = "SnippetStorageConcurrencyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        let context = VocabularyStorageContext(
            supportDirectory: directory,
            userDefaults: defaults,
            fileManager: .default,
            hotwordsDidChange: {},
            revealFile: { _ in }
        )
        try SnippetStorage.saveBuiltin([], context: context)
        try SnippetStorage.save([], context: context)
        return context
    }
}
