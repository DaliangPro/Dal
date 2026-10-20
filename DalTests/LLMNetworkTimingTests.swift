import Foundation
import XCTest
@testable import Dal

final class LLMNetworkTimingTests: XCTestCase {
    func testMissingConnectionDatesAreNotMeasuredZero() {
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertNil(LLMNetworkTiming.intervalMilliseconds(nil, start))
        XCTAssertNil(LLMNetworkTiming.intervalMilliseconds(start, nil))
        XCTAssertNil(LLMNetworkTiming.intervalMilliseconds(start, start.addingTimeInterval(-1)))
        XCTAssertEqual(LLMNetworkTiming.intervalMilliseconds(start, start.addingTimeInterval(0.25)), 250)
    }

    func testHeartbeatAndRoleAreNotFirstContent() throws {
        var parser = LLMStreamingParser()
        for line in [": heartbeat", "", "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}", ""] {
            try parser.consume(line: line)
        }
        XCTAssertFalse(parser.hasContent)
        try parser.consume(line: "data: {\"choices\":[{\"delta\":{\"content\":\"好\"}}]}")
        try parser.consume(line: "")
        XCTAssertTrue(parser.hasContent)
        try parser.consume(line: "data: [DONE]")
        try parser.consume(line: "")
        XCTAssertEqual(try parser.finish(), "好")
    }

    func testTimingEventsAreBoundToCaseAndContainNoRequestContent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("build/network-timing-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let receipt = directory.appendingPathComponent("provider.jsonl")
        let timingURL = URL(fileURLWithPath: receipt.path + ".timing.jsonl")
        try Data().write(to: timingURL)
        let timing = LLMNetworkTiming(context: .init(runNonce: "nonce", testInputID: "case-1", receiptPath: receipt.path))
        timing.record("request_start")
        timing.record("first_body_byte")
        timing.record("first_content")
        timing.record("stream_finished")
        let rows = try String(contentsOf: timingURL, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(Set(rows.compactMap { $0["request_id"] as? String }).count, 1)
        var last = -1.0
        for row in rows {
            XCTAssertEqual(row["test_input_id"] as? String, "case-1")
            XCTAssertEqual(row["run_nonce"] as? String, "nonce")
            XCTAssertEqual(Set(row.keys), ["schema_version", "run_nonce", "test_input_id", "request_id", "event", "elapsed_ms"])
            let ms = try XCTUnwrap(row["elapsed_ms"] as? Double)
            XCTAssertGreaterThanOrEqual(ms, last)
            last = ms
        }
    }

    func testTaskDelegateStillBlocksRedirect() throws {
        let timing = LLMNetworkTiming(context: .init(runNonce: "nonce", testInputID: "case", receiptPath: "/unused"))
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        var called = false
        timing.urlSession(session, task: task, willPerformHTTPRedirection: response,
                          newRequest: URLRequest(url: url)) { request in
            called = true
            XCTAssertNil(request)
        }
        XCTAssertTrue(called)
    }
}
