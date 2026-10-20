import Foundation

/// 只由显式质量测试入口调用；真实模型、模拟转写时序，不采集麦克风。
enum PolishPrefetchBenchmark {
    struct Plan: Decodable {
        let enabled: Bool
        let stableMilliseconds: Int
        let preliminaryText: String?
    }

    static func run(planPath: String, caseID: String, request: VoicePolishRequest,
                    client: any LLMClient, provider: LLMProvider, config: LLMConfig,
                    outputPath: String) async throws -> (result: VoicePolishResult, elapsed: Duration) {
        let plans = try JSONDecoder().decode([String: Plan].self,
            from: Data(contentsOf: URL(fileURLWithPath: planPath)))
        guard let plan = plans[caseID], (0...5000).contains(plan.stableMilliseconds) else {
            throw CocoaError(.coderInvalidValue)
        }
        let cache = PolishPrefetch()
        let session = RecognitionSessionID(rawValue: 1)
        let pipeline = VoicePolishEditingPipeline(client: client, config: config)
        let requirements = request.preferences.additionalRequirements
        let preliminary = plan.preliminaryText ?? request.fallbackText
        var startedPrefetch = false
        // 稳定 800ms 后才开始请求；两组经历相同的录音尾部等待。
        if plan.enabled && plan.stableMilliseconds >= 800 {
            try await Task.sleep(for: .milliseconds(800))
            startedPrefetch = true
            cache.start(session: session, key: .init(text: preliminary, requirements: requirements,
                        provider: provider, config: config)) {
                await pipeline.processText(preliminary, requirements: requirements, qualityMode: .standard)
            }
            try await Task.sleep(for: .milliseconds(plan.stableMilliseconds - 800))
        } else {
            try await Task.sleep(for: .milliseconds(plan.stableMilliseconds))
        }
        // 模拟停止时最后一条转写回修，与产品相同地废弃旧候选。
        if preliminary != request.fallbackText { cache.invalidate() }
        let stoppedAt = ContinuousClock.now
        let ready = cache.take(session: session, key: .init(text: request.fallbackText,
                             requirements: requirements, provider: provider, config: config))
        let result: VoicePolishResult
        if let ready { result = ready }
        else { result = await pipeline.process(request) }
        let elapsed = ContinuousClock.now - stoppedAt
        cache.reset()
        let record: [String: Any] = [
            "case_id": caseID, "enabled": plan.enabled,
            "stable_ms": plan.stableMilliseconds, "prefetch_started": startedPrefetch,
            "reused": ready != nil, "input_changed": preliminary != request.fallbackText,
            "stop_to_output_ms": VoicePolishQualityRunner.milliseconds(elapsed),
            "fallback": result.usedFallback,
            "scope": "real_model_simulated_transcript_stop_to_output"
        ]
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(10)
        if !FileManager.default.fileExists(atPath: outputPath) {
            FileManager.default.createFile(atPath: outputPath, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: outputPath))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        return (result, elapsed)
    }
}
