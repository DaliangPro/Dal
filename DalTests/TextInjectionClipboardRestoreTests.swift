import AppKit
@testable import Dal
import XCTest

/// REPAIR_PLAN J2：剪贴板恢复守卫语义单测（不模拟按键、不需辅助功能权限）。
/// 恢复异步化后，安全性完全由 restore 的 changeCount 守卫背书，这里逐条固化：
/// ① 正常恢复 ② 第三方写入后放弃恢复 ③ 原剪贴板为空时恢复成空（2026-06-24 行为）。
final class TextInjectionClipboardRestoreTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.clearContents()
        pasteboard = nil
        super.tearDown()
    }

    func testRestoreBringsBackOldContentAfterInjectionWrite() {
        pasteboard.clearContents()
        pasteboard.setString("用户的旧剪贴板", forType: .string)

        let snapshot = TextInjectionEngine.ClipboardSnapshot.capture(
            from: pasteboard,
            logger: { _ in }
        )

        pasteboard.clearContents()
        pasteboard.setString("识别文本", forType: .string)
        let postWriteCount = pasteboard.changeCount

        snapshot.restore(
            expectedChangeCount: postWriteCount,
            on: pasteboard,
            logger: { _ in }
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "用户的旧剪贴板")
    }

    func testRestoreGuardSkipsWhenClipboardChangedMeanwhile() {
        pasteboard.clearContents()
        pasteboard.setString("用户的旧剪贴板", forType: .string)

        let snapshot = TextInjectionEngine.ClipboardSnapshot.capture(
            from: pasteboard,
            logger: { _ in }
        )

        pasteboard.clearContents()
        pasteboard.setString("识别文本", forType: .string)
        let postWriteCount = pasteboard.changeCount

        // 延迟窗口内第三方（或下一次注入）写入了新内容
        pasteboard.clearContents()
        pasteboard.setString("第三方新复制的内容", forType: .string)

        snapshot.restore(
            expectedChangeCount: postWriteCount,
            on: pasteboard,
            logger: { _ in }
        )
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "第三方新复制的内容",
            "changeCount 不匹配时必须放弃恢复，不得覆盖新内容"
        )
    }

    /// J2 回归修复：目标 app 粘贴时改写剪贴板（changeCount 前进）但内容仍是
    /// 注入文本——必须照常恢复，否则识别文本残留、旧剪贴板丢失（2026-07-09 实测报告）。
    func testRestoreProceedsWhenAppRewroteClipboardWithSameText() {
        pasteboard.clearContents()
        pasteboard.setString("用户的旧剪贴板", forType: .string)

        let snapshot = TextInjectionEngine.ClipboardSnapshot.capture(
            from: pasteboard,
            logger: { _ in }
        )

        pasteboard.clearContents()
        pasteboard.setString("识别文本", forType: .string)
        let postWriteCount = pasteboard.changeCount

        // 模拟目标 app 粘贴时的改写：changeCount 前进、字符串内容不变
        pasteboard.clearContents()
        pasteboard.setString("识别文本", forType: .string)

        snapshot.restore(
            expectedChangeCount: postWriteCount,
            injectedText: "识别文本",
            on: pasteboard,
            logger: { _ in }
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "用户的旧剪贴板",
                       "app 改写但内容未变时必须照常恢复")
    }

    func testRestoreStillSkipsWhenContentTrulyChanged() {
        pasteboard.clearContents()
        pasteboard.setString("用户的旧剪贴板", forType: .string)

        let snapshot = TextInjectionEngine.ClipboardSnapshot.capture(
            from: pasteboard,
            logger: { _ in }
        )

        pasteboard.clearContents()
        pasteboard.setString("识别文本", forType: .string)
        let postWriteCount = pasteboard.changeCount

        pasteboard.clearContents()
        pasteboard.setString("用户复制的新内容", forType: .string)

        snapshot.restore(
            expectedChangeCount: postWriteCount,
            injectedText: "识别文本",
            on: pasteboard,
            logger: { _ in }
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "用户复制的新内容",
                       "内容真变时仍须放弃恢复")
    }

    func testRestoreClearsClipboardWhenOriginalWasEmpty() {
        pasteboard.clearContents()

        let snapshot = TextInjectionEngine.ClipboardSnapshot.capture(
            from: pasteboard,
            logger: { _ in }
        )

        pasteboard.clearContents()
        pasteboard.setString("识别文本", forType: .string)
        let postWriteCount = pasteboard.changeCount

        snapshot.restore(
            expectedChangeCount: postWriteCount,
            on: pasteboard,
            logger: { _ in }
        )
        XCTAssertNil(
            pasteboard.string(forType: .string),
            "原剪贴板为空时恢复必须清掉识别文本，不得残留（2026-06-24 大梁老师报的 bug）"
        )
    }
}
