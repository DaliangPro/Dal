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
        let initialReadCount = await reader.ranges.count
        await reader.replace(with: leading + "Claude" + trailing)
        let candidate = await PostInjectionEditLearningMonitor.currentCandidate(for: target)
        XCTAssertEqual(candidate, "Claude")
        let reads = await reader.ranges
        XCTAssertEqual(reads.count, initialReadCount + 1)
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
        XCTAssertTrue(reads.allSatisfy { $0.length <= 4_096 }, "无法确认完整候选时，限定读取范围并放弃学习")
    }

    func testMissingStaleOrOverreportedCountCanStillCaptureAndReadCorrection() async throws {
        for count in [BoundedLearningReader.Count.missing, .fixed(0), .fixed(1), .fixed(100), .fixed(10_000)] {
            let reader = BoundedLearningReader(text: "cloud.", caret: 6)
            await reader.setCount(count)
            let captured = await PostInjectionEditLearningMonitor.captureResult(
                injectedText: "cloud.", historyID: "optional-count", field: reader.field, maximumAttempts: 1
            )
            guard case .captured(let target) = captured else { return XCTFail("字数异常不应阻止可靠范围读取：\(count)") }
            await reader.replace(with: "Claude")
            let candidate = await PostInjectionEditLearningMonitor.currentCandidate(for: target)
            XCTAssertEqual(candidate, "Claude", "\(count)")
            let reads = await reader.ranges
            XCTAssertTrue(reads.allSatisfy { $0.location >= 0 && $0.location + $0.length <= 512 })
            XCTAssertLessThan(reads.count, 35, "终点探测必须有界，不能逐字扫描全文")
        }
    }

    func testCaptureFailuresAreSpecificAndFocusLossDoesNotReportUnsupportedField() async {
        let reader = BoundedLearningReader(text: "cloud.", caret: 6)
        await reader.setResponse(.unsupported)
        let unsupported = await PostInjectionEditLearningMonitor.captureResult(
            injectedText: "cloud.", historyID: "unsupported", field: reader.field, maximumAttempts: 1
        )
        assertFailure(unsupported, .rangeUnsupported)
        await reader.setResponse(.unavailable)
        await reader.setCount(.missing)
        let unreadable = await PostInjectionEditLearningMonitor.captureResult(
            injectedText: "cloud.", historyID: "unreadable", field: reader.field, maximumAttempts: 1
        )
        assertFailure(unreadable, .rangeUnreadable)
        await reader.setResponse(.probeUnavailable)
        let interruptedProbe = await PostInjectionEditLearningMonitor.captureResult(
            injectedText: "cloud.", historyID: "probe-error", field: reader.field, maximumAttempts: 1
        )
        assertFailure(interruptedProbe, .rangeUnreadable)
        XCTAssertNil(PostInjectionCaptureFailure.focusChanged.feedback)
        XCTAssertNotEqual(PostInjectionCaptureFailure.rangeUnsupported.feedback, .fieldUnresponsive)

        let unknownSelection = PostInjectionLearningField(
            isAvailable: { true }, selectedRange: { nil }, characterCount: { 6 }, stringForRange: { _ in nil }
        )
        let selection = await PostInjectionEditLearningMonitor.captureResult(
            injectedText: "cloud.", historyID: "selection", field: unknownSelection, maximumAttempts: 1
        )
        assertFailure(selection, .selectionUnavailable)
        await reader.setCount(.actual)
        await reader.setResponse(.oversized)
        let invalid = await PostInjectionEditLearningMonitor.captureResult(
            injectedText: "cloud.", historyID: "invalid", field: reader.field, maximumAttempts: 1
        )
        assertFailure(invalid, .invalidRangeResponse)
        let activeSelection = PostInjectionLearningField(
            isAvailable: { true }, selectedRange: { CFRange(location: 0, length: 6) },
            characterCount: { 6 }, stringForRange: { _ in nil }
        )
        let active = await PostInjectionEditLearningMonitor.captureResult(
            injectedText: "cloud.", historyID: "active", field: activeSelection, maximumAttempts: 1
        )
        assertFailure(active, .selectionActive)
        await reader.setResponse(.exact)
        await reader.replace(with: "abcdef")
        let mismatch = await PostInjectionEditLearningMonitor.captureResult(
            injectedText: "cloud.", historyID: "mismatch", field: reader.field, maximumAttempts: 1
        )
        assertFailure(mismatch, .textMismatch)
        await reader.loseFocusDuringNextRead()
        let focus = await PostInjectionEditLearningMonitor.captureResult(
            injectedText: "cloud.", historyID: "focus", field: reader.field, maximumAttempts: 1
        )
        assertFailure(focus, .focusChanged)
    }

    func testInsertionAfterOldRetryWindowCanStillBeVerified() async {
        let reader = BoundedLearningReader(text: "", caret: 6)
        let paste = Task {
            try? await Task.sleep(for: .milliseconds(1_450))
            await reader.replace(with: "cloud.")
        }
        let result = await PostInjectionEditLearningMonitor.captureResult(
            injectedText: "cloud.", historyID: "slow-paste", field: reader.field
        )
        await paste.value
        guard case .captured = result else { return XCTFail("1.45 秒的延迟上屏应在新窗口内完成核验") }
    }

    private func assertFailure(
        _ result: PostInjectionCaptureResult, _ expected: PostInjectionCaptureFailure,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .failure(let actual) = result else { return XCTFail("预期具体失败原因", file: file, line: line) }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}

/// 模拟只提供范围 API 的控件，不提供全文读取或其他输入框的入口。
private actor BoundedLearningReader {
    enum Response { case exact, oversized, unavailable, unsupported, probeUnavailable }
    enum Count { case actual, missing, fixed(Int) }
    private var text: String
    private let caret: Int
    private var available = true
    private var response = Response.exact
    private var count = Count.actual
    private var loseFocusOnRead = false
    private(set) var ranges: [CFRange] = []

    init(text: String, caret: Int) { self.text = text; self.caret = caret }

    func replace(with text: String) { self.text = text }
    func setResponse(_ response: Response) { self.response = response }
    func setCount(_ count: Count) { self.count = count }
    func loseFocusDuringNextRead() { loseFocusOnRead = true }

    nonisolated var field: PostInjectionLearningField {
        PostInjectionLearningField(
            isAvailable: { await self.available },
            selectedRange: { CFRange(location: self.caret, length: 0) },
            characterCount: { await self.characterCount() },
            readRange: { await self.read($0) }
        )
    }

    private func characterCount() -> Int? {
        switch count {
        case .actual: return text.utf16.count
        case .missing: return nil
        case .fixed(let value): return value
        }
    }

    private func read(_ range: CFRange) -> PostInjectionRangeRead {
        ranges.append(range)
        if loseFocusOnRead { available = false }
        if response == .unavailable { return .unavailable }
        if response == .unsupported { return .unsupported }
        let value = text as NSString
        if response == .probeUnavailable, range.length == 1, range.location >= value.length { return .unavailable }
        guard range.location >= 0, range.length >= 0, range.location + range.length <= value.length else { return .outOfBounds }
        let result = value.substring(with: NSRange(location: range.location, length: range.length))
        return .text(response == .oversized ? result + "不应读取的额外文字" : result)
    }
}
