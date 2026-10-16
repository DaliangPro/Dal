import Foundation
import XCTest
@testable import Muse

final class PostInjectionLearningRangeTests: XCTestCase {
    func testOversizedInsertionIsRejectedBeforeReadingAnyText() async {
        let text = String(repeating: "字", count: 4_097)
        let reader = BoundedLearningReader(text: text, caret: text.utf16.count)
        let target = await PostInjectionEditLearningMonitor.capture(
            injectedText: text, historyID: "too-long", field: reader.field
        )
        XCTAssertNil(target)
        let reads = await reader.ranges
        XCTAssertTrue(reads.isEmpty)
    }

    func testLargeFieldOnlyReadsBoundedWindowAroundThisInsertion() async throws {
        let leading = String(repeating: "a", count: 10_000) + "这是本次输入之前的唯一锚点，共二十四字字符甲乙丙丁戊己"
        let trailing = "这是本次输入之后的唯一锚点，共二十四字字符庚辛壬癸子丑" + String(repeating: "z", count: 10_000)
        let reader = BoundedLearningReader(text: leading + "cloud." + trailing, caret: leading.utf16.count + 6)
        let captured = await PostInjectionEditLearningMonitor.capture(
            injectedText: "cloud.", historyID: "large-field", field: reader.field
        )
        let target = try XCTUnwrap(captured)
        await reader.replace(with: leading + "Claude" + trailing)
        let candidate = await PostInjectionEditLearningMonitor.currentCandidate(for: target)
        XCTAssertEqual(candidate, "Claude")
        let reads = await reader.ranges
        XCTAssertEqual(reads.count, 2)
        XCTAssertTrue(reads.allSatisfy { $0.location >= leading.utf16.count - 24 && $0.length <= 4_096 })
        XCTAssertEqual(reads.first?.length, 54, "只验证本次输入及各 24 单位锚点，不读取整个输入框")
    }

    func testUnavailableRangeOrOversizedResponseNeverBecomesLearningCandidate() async throws {
        let reader = BoundedLearningReader(text: "cloud.", caret: 6)
        let captured = await PostInjectionEditLearningMonitor.capture(
            injectedText: "cloud.", historyID: "range-contract", field: reader.field
        )
        let target = try XCTUnwrap(captured)
        await reader.replace(with: "Claude")
        await reader.setResponse(.oversized)
        let oversized = await PostInjectionEditLearningMonitor.currentCandidate(for: target)
        XCTAssertNil(oversized, "控件忽略范围而返回全文时，不能送入提词或持久化")
        await reader.setResponse(.unavailable)
        let unavailable = await PostInjectionEditLearningMonitor.currentCandidate(for: target)
        XCTAssertNil(unavailable, "没有范围 API 时，不使用全文读取回退")
    }

    func testFocusLossDuringReadRejectsReturnedTextAndStopsFurtherReads() async throws {
        let reader = BoundedLearningReader(text: "cloud.", caret: 6)
        let captured = await PostInjectionEditLearningMonitor.capture(
            injectedText: "cloud.", historyID: "focus", field: reader.field
        )
        let target = try XCTUnwrap(captured)
        await reader.replace(with: "Claude")
        await reader.loseFocusDuringNextRead()
        let stale = await PostInjectionEditLearningMonitor.currentCandidate(for: target)
        XCTAssertNil(stale)
        let countAfterLoss = await reader.ranges.count
        let afterLoss = await PostInjectionEditLearningMonitor.currentCandidate(for: target)
        XCTAssertNil(afterLoss)
        let finalCount = await reader.ranges.count
        XCTAssertEqual(finalCount, countAfterLoss)
    }

    func testCandidateOverWindowLimitIsRejectedInsteadOfTruncated() async throws {
        let original = String(repeating: "a", count: 4_000)
        let reader = BoundedLearningReader(text: original, caret: 4_000)
        let captured = await PostInjectionEditLearningMonitor.capture(
            injectedText: original, historyID: "no-truncation", field: reader.field
        )
        let target = try XCTUnwrap(captured)
        await reader.replace(with: "b" + String(repeating: "a", count: 4_200))
        let candidate = await PostInjectionEditLearningMonitor.currentCandidate(for: target)
        XCTAssertNil(candidate)
        let reads = await reader.ranges
        XCTAssertEqual(reads.count, 1, "候选超过范围时不再读取被截断的片段")
    }
}

/// 模拟只提供范围 API 的控件，不提供全文读取或其他输入框的入口。
private actor BoundedLearningReader {
    enum Response { case exact, oversized, unavailable }
    private var text: String
    private let caret: Int
    private var available = true
    private var response = Response.exact
    private var loseFocusOnRead = false
    private(set) var ranges: [CFRange] = []

    init(text: String, caret: Int) { self.text = text; self.caret = caret }

    func replace(with text: String) { self.text = text }
    func setResponse(_ response: Response) { self.response = response }
    func loseFocusDuringNextRead() { loseFocusOnRead = true }

    nonisolated var field: PostInjectionLearningField {
        PostInjectionLearningField(
            isAvailable: { await self.available },
            selectedRange: { CFRange(location: self.caret, length: 0) },
            characterCount: { await self.text.utf16.count },
            stringForRange: { await self.read($0) }
        )
    }

    private func read(_ range: CFRange) -> String? {
        ranges.append(range)
        if loseFocusOnRead { available = false }
        guard response != .unavailable else { return nil }
        let value = text as NSString
        guard range.location >= 0, range.length >= 0, range.location + range.length <= value.length else { return nil }
        let result = value.substring(with: NSRange(location: range.location, length: range.length))
        return response == .oversized ? result + "不应读取的额外文字" : result
    }
}
