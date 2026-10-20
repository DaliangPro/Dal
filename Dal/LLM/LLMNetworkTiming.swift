import Foundation

/// 只在显式质量跑测中开启；沿用原连接池，不写正文、请求头或凭据。
final class LLMNetworkTiming: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private static let fileLock = NSLock()
    private let context: VoicePolishProviderAudit.Context
    private let started = ContinuousClock.now
    private let startedDate = Date()
    private let requestID = UUID().uuidString

    init(context: VoicePolishProviderAudit.Context) {
        self.context = context
        super.init()
    }

    static func current() -> LLMNetworkTiming? {
        guard ProcessInfo.processInfo.environment["DAL_NETWORK_TIMING"] == "1",
              let context = VoicePolishProviderAudit.currentContext else { return nil }
        return LLMNetworkTiming(context: context)
    }

    static func intervalMilliseconds(_ start: Date?, _ end: Date?) -> Double? {
        guard let start, let end, end >= start else { return nil }
        return end.timeIntervalSince(start) * 1_000
    }

    func record(_ event: String, fields: [String: Any] = [:]) {
        let elapsed = started.duration(to: .now).components
        var row: [String: Any] = [
            "schema_version": 1,
            "run_nonce": context.runNonce,
            "test_input_id": context.testInputID,
            "request_id": requestID,
            "event": event,
            "elapsed_ms": Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15,
        ]
        row.merge(fields) { _, new in new }
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        do {
            // 与 Provider 回执同目录；由测试发起方预建，缺失时不触碰其他位置。
            let url = URL(fileURLWithPath: context.receiptPath + ".timing.jsonl")
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return }
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            data.append(0x0A)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // 诊断旁路不得改变生产请求的成功/失败与最终正文。
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        let transactions: [[String: Any]] = metrics.transactionMetrics.map { item in
            var row: [String: Any] = [
                "connection_reused": item.isReusedConnection,
                "proxy_connection": item.isProxyConnection,
                "protocol": item.networkProtocolName ?? "unknown",
                "fetch_type": item.resourceFetchType.rawValue,
            ]
            let intervals = [
                ("dns_ms", item.domainLookupStartDate, item.domainLookupEndDate),
                ("connect_ms", item.connectStartDate, item.connectEndDate),
                ("tls_ms", item.secureConnectionStartDate, item.secureConnectionEndDate),
                ("request_send_ms", item.requestStartDate, item.requestEndDate),
                ("request_end_to_response_start_ms", item.requestEndDate, item.responseStartDate),
                ("response_transfer_ms", item.responseStartDate, item.responseEndDate),
            ]
            for (key, start, end) in intervals {
                row[key] = Self.intervalMilliseconds(start, end) ?? NSNull() as Any
            }
            for (key, date) in [
                ("fetch_start_ms", item.fetchStartDate),
                ("request_start_ms", item.requestStartDate),
                ("request_end_ms", item.requestEndDate),
                ("response_start_ms", item.responseStartDate),
                ("response_end_ms", item.responseEndDate),
            ] {
                row[key] = date.map { $0.timeIntervalSince(startedDate) * 1_000 } ?? NSNull() as Any
            }
            return row
        }
        record("network_metrics", fields: ["transactions": transactions,
            "task_interval_ms": metrics.taskInterval.duration * 1_000,
            "redirect_count": metrics.redirectCount])
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        record("transport_complete", fields: ["error_code": (error as NSError?)?.code ?? 0])
    }

    // 设置 task delegate 后仍须保持原会话的重定向禁令，不能转发授权头。
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
