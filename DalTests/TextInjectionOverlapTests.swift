import AppKit
@testable import Dal
import XCTest

final class TextInjectionOverlapTests: XCTestCase {
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private var pasteboard: NSPasteboard!
    private var scheduler: ManualClipboardRestoreScheduler!
    private var coordinator: ClipboardLeaseCoordinator!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        scheduler = ManualClipboardRestoreScheduler()
        coordinator = ClipboardLeaseCoordinator(scheduler: scheduler, logger: { _ in })
    }

    override func tearDown() {
        pasteboard.clearContents()
        coordinator = nil
        scheduler = nil
        pasteboard = nil
        super.tearDown()
    }

    func testTwoOverlappingInjectionsRestoreInitialClipboard() {
        pasteboard.setString("最初用户剪贴板", forType: .string)
        let firstEngine = makeEngine()
        let secondEngine = makeEngine()

        XCTAssertEqual(
            firstEngine.injectViaClipboard("第一次识别", hasFrontmostApplication: true),
            .inserted
        )
        XCTAssertEqual(
            secondEngine.injectViaClipboard("第二次识别", hasFrontmostApplication: true),
            .inserted
        )

        XCTAssertEqual(scheduler.tasks.count, 2)
        XCTAssertTrue(scheduler.tasks[0].isCancelled)
        scheduler.run(at: 1)

        XCTAssertEqual(pasteboard.string(forType: .string), "最初用户剪贴板")
        XCTAssertFalse(coordinator.hasActiveLease)
    }

    func testThreeOverlappingInjectionsRestoreInitialClipboard() {
        pasteboard.setString("最初用户剪贴板", forType: .string)
        let firstEngine = makeEngine()
        let secondEngine = makeEngine()
        let thirdEngine = makeEngine()

        XCTAssertEqual(firstEngine.injectViaClipboard("一", hasFrontmostApplication: true), .inserted)
        XCTAssertEqual(secondEngine.injectViaClipboard("二", hasFrontmostApplication: true), .inserted)
        XCTAssertEqual(thirdEngine.injectViaClipboard("三", hasFrontmostApplication: true), .inserted)

        XCTAssertEqual(scheduler.tasks.count, 3)
        XCTAssertTrue(scheduler.tasks[0].isCancelled)
        XCTAssertTrue(scheduler.tasks[1].isCancelled)
        scheduler.run(at: 2)

        XCTAssertEqual(pasteboard.string(forType: .string), "最初用户剪贴板")
        XCTAssertFalse(coordinator.hasActiveLease)
    }

    func testThirdPartyCopyAfterSecondInjectionAbandonsRestore() {
        pasteboard.setString("最初用户剪贴板", forType: .string)
        let engine = makeEngine()

        XCTAssertEqual(engine.injectViaClipboard("第一次识别", hasFrontmostApplication: true), .inserted)
        XCTAssertEqual(engine.injectViaClipboard("第二次识别", hasFrontmostApplication: true), .inserted)

        pasteboard.clearContents()
        pasteboard.setString("第三方新内容", forType: .string)
        scheduler.run(at: 1)

        XCTAssertEqual(pasteboard.string(forType: .string), "第三方新内容")
        XCTAssertFalse(coordinator.hasActiveLease)

        XCTAssertEqual(engine.injectViaClipboard("第三次识别", hasFrontmostApplication: true), .inserted)
        scheduler.run(at: 2)
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "第三方新内容",
            "第三方写入导致旧 lease 放弃后，应成为下一轮唯一原始快照"
        )
    }

    func testCancelledOldRestoreCannotOverwriteNewInjectionWithSameText() {
        pasteboard.setString("最初用户剪贴板", forType: .string)
        let firstEngine = makeEngine()
        let secondEngine = makeEngine()

        XCTAssertEqual(firstEngine.injectViaClipboard("相同识别文本", hasFrontmostApplication: true), .inserted)
        XCTAssertEqual(secondEngine.injectViaClipboard("相同识别文本", hasFrontmostApplication: true), .inserted)

        XCTAssertTrue(scheduler.tasks[0].isCancelled)
        scheduler.run(at: 0, evenIfCancelled: true)
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "相同识别文本",
            "旧 generation 晚到时不得提前恢复并覆盖当前注入"
        )

        scheduler.run(at: 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "最初用户剪贴板")
    }

    func testOverlappingInjectionsRestoreOriginallyEmptyClipboard() {
        pasteboard.clearContents()
        let engine = makeEngine()

        XCTAssertEqual(engine.injectViaClipboard("第一次识别", hasFrontmostApplication: true), .inserted)
        XCTAssertEqual(engine.injectViaClipboard("第二次识别", hasFrontmostApplication: true), .inserted)
        scheduler.run(at: 1)

        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertTrue(pasteboard.pasteboardItems?.isEmpty ?? true)
    }

    func testOverlappingInjectionsPreserveTextAndImageRepresentations() throws {
        let originalText = "图文剪贴板"
        let originalPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let item = NSPasteboardItem()
        item.setString(originalText, forType: .string)
        item.setData(originalPNG, forType: .png)
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let engine = makeEngine()

        XCTAssertEqual(engine.injectViaClipboard("第一次识别", hasFrontmostApplication: true), .inserted)
        XCTAssertEqual(engine.injectViaClipboard("第二次识别", hasFrontmostApplication: true), .inserted)
        scheduler.run(at: 1)

        let restoredItem = try XCTUnwrap(pasteboard.pasteboardItems?.first)
        XCTAssertEqual(restoredItem.string(forType: .string), originalText)
        XCTAssertEqual(restoredItem.data(forType: .png), originalPNG)
    }

    func testPasteSimulationFailureKeepsTextAndReturnsClipboardOutcome() {
        pasteboard.setString("最初用户剪贴板", forType: .string)
        let engine = makeEngine(pasteSimulationResult: false)

        let outcome = engine.injectViaClipboard("需要手动粘贴", hasFrontmostApplication: true)

        XCTAssertEqual(outcome, .copiedToClipboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "需要手动粘贴")
        XCTAssertTrue(
            pasteboard.pasteboardItems?.first?.types.contains(Self.transientType) == true,
            "CGEvent 创建失败时仍须保留 transient 注入标记"
        )
        XCTAssertTrue(scheduler.tasks.isEmpty)
        XCTAssertFalse(coordinator.hasActiveLease)

        let successfulEngine = makeEngine()
        XCTAssertEqual(
            successfulEngine.injectViaClipboard("下一次自动粘贴", hasFrontmostApplication: true),
            .inserted
        )
        scheduler.run(at: 0)
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "需要手动粘贴",
            "粘贴失败清理 lease 后，失败文本应成为下一轮的原始快照"
        )
    }

    func testConcurrentEnginesSerializeClipboardWriteThroughPaste() {
        pasteboard.setString("最初用户剪贴板", forType: .string)
        let firstPasteEntered = DispatchSemaphore(value: 0)
        let releaseFirstPaste = DispatchSemaphore(value: 0)
        let secondPasteEntered = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()

        let firstEngine = makeEngine(pasteSimulator: {
            firstPasteEntered.signal()
            _ = releaseFirstPaste.wait(timeout: .now() + 2)
            return true
        })
        let secondEngine = makeEngine(pasteSimulator: {
            secondPasteEntered.signal()
            return true
        })

        finished.enter()
        DispatchQueue.global().async {
            _ = firstEngine.injectViaClipboard("第一次识别", hasFrontmostApplication: true)
            finished.leave()
        }
        XCTAssertEqual(firstPasteEntered.wait(timeout: .now() + 1), .success)

        finished.enter()
        DispatchQueue.global().async {
            _ = secondEngine.injectViaClipboard("第二次识别", hasFrontmostApplication: true)
            finished.leave()
        }

        let secondEnteredEarly = secondPasteEntered.wait(timeout: .now() + 0.1)
        XCTAssertEqual(
            secondEnteredEarly,
            .timedOut,
            "第二个 engine 不得在第一轮 Cmd+V 完成前改写临时剪贴板"
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "第一次识别")

        releaseFirstPaste.signal()
        if secondEnteredEarly == .timedOut {
            XCTAssertEqual(secondPasteEntered.wait(timeout: .now() + 1), .success)
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)

        XCTAssertEqual(scheduler.tasks.count, 2)
        if scheduler.tasks.indices.contains(1) {
            scheduler.run(at: 1)
            XCTAssertEqual(pasteboard.string(forType: .string), "最初用户剪贴板")
        }
    }

    func testPermanentCopyInvalidatesActiveLeaseEvenForSameText() {
        pasteboard.setString("最初用户剪贴板", forType: .string)
        let engine = makeEngine()

        XCTAssertEqual(
            engine.injectViaClipboard("相同识别文本", hasFrontmostApplication: true),
            .inserted
        )
        coordinator.writeTextPermanently("相同识别文本", on: pasteboard)

        XCTAssertTrue(scheduler.tasks[0].isCancelled)
        scheduler.run(at: 0, evenIfCancelled: true)
        XCTAssertEqual(pasteboard.string(forType: .string), "相同识别文本")
        XCTAssertFalse(coordinator.hasActiveLease)
    }

    private func makeEngine(
        pasteSimulationResult: Bool = true,
        pasteSimulator: (() -> Bool)? = nil
    ) -> TextInjectionEngine {
        let engine = TextInjectionEngine(
            pasteboard: pasteboard,
            clipboardLeaseCoordinator: coordinator,
            pasteSimulator: pasteSimulator ?? { pasteSimulationResult },
            sleep: { _ in },
            logger: { _ in }
        )
        engine.preserveClipboard = true
        return engine
    }
}

private final class ManualClipboardRestoreScheduler: ClipboardRestoreScheduling {
    final class Task: ClipboardRestoreTask {
        let operation: () -> Void
        private(set) var isCancelled = false

        init(operation: @escaping () -> Void) {
            self.operation = operation
        }

        func cancel() {
            isCancelled = true
        }
    }

    private(set) var tasks: [Task] = []

    func schedule(
        after delay: TimeInterval,
        operation: @escaping () -> Void
    ) -> any ClipboardRestoreTask {
        let task = Task(operation: operation)
        tasks.append(task)
        return task
    }

    func run(at index: Int, evenIfCancelled: Bool = false) {
        let task = tasks[index]
        guard evenIfCancelled || !task.isCancelled else { return }
        task.operation()
    }
}
