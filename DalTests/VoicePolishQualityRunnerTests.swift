import XCTest
@testable import Dal

final class VoicePolishQualityRunnerTests: XCTestCase {
    private let runNonce = String(repeating: "a", count: 64)

    func test预生成执行和计时范围共用当前及旧参数判定() {
        let new = ["DAL_POLISH_PREFETCH_BENCHMARK_PLAN": "/tmp/current.json"]
        let old = ["DAL_LIGHT_PREFETCH_BENCHMARK_PLAN": "/tmp/legacy.json"]
        XCTAssertEqual(VoicePolishQualityRunner.prefetchBenchmarkPlan(for: .standard, environment: new), "/tmp/current.json")
        XCTAssertEqual(VoicePolishQualityRunner.prefetchBenchmarkPlan(for: .standard, environment: old), "/tmp/legacy.json")
        XCTAssertEqual(VoicePolishQualityRunner.prefetchBenchmarkPlan(for: .standard, environment: new.merging(old) { a, _ in a }), "/tmp/current.json")
        XCTAssertNil(VoicePolishQualityRunner.prefetchBenchmarkPlan(for: .direct, environment: new))
        XCTAssertNil(VoicePolishQualityRunner.prefetchBenchmarkPlan(for: .standard, environment: [:]))
    }

    func test普通启动不进入质量跑测() throws {
        XCTAssertNil(try VoicePolishQualityRunner.parseInvocation(arguments: ["Dal"]))
        XCTAssertFalse(VoicePolishQualityRunner.isRequested(arguments: ["Dal"]))
    }

    func test质量跑测在正常App构建前可被分流() {
        let arguments = ["Dal", "--voice-polish-quality-run"]

        XCTAssertTrue(VoicePolishQualityRunner.isRequested(arguments: arguments))
    }

    func test轻度管线跨超时任务后保留显式请求体捕获路径且默认不捕获() async throws {
        let source = "请先核对完整资料，再发送。"
        let input = VoicePolishRequest(
            input: VoiceInputEnvelope(providerFinalText: source,
                segments: [.init(id: "s1", text: source, startTimeMs: nil, endTimeMs: nil,
                                 confidence: nil, isFinal: true)], durationMs: 1_000, provider: .volcano),
            context: WritingContext(scene: .workChat),
            preferences: UserPolishPreferences(additionalRequirements: ""), qualityMode: .light
        )
        let config = LLMConfig(apiKey: "test-only", model: "test-model", baseURL: "https://example.invalid")
        let capturePaths: [String?] = [nil, "/tmp/quality-probe-context-test/light-request-1.json"]
        for bodyPath in capturePaths {
            let base = QualityRequestProbeContextClient(response: source)
            let client = VoicePolishProviderAuditedLLMClient(
                base: base, runNonce: runNonce, testInputID: "probe-context-1",
                receiptPath: "/tmp/quality-probe-context-test/provider-audit.jsonl",
                requestProbeBodyPath: bodyPath
            )
            let result = await VoicePolishEditingPipeline(client: client, config: config).process(input)
            XCTAssertFalse(result.usedFallback)
            XCTAssertEqual(result.text, source)
            XCTAssertEqual(result.llmAttemptCount, 1)
            let observations = await base.observations
            XCTAssertEqual(observations.count, 1)
            let observation = try XCTUnwrap(observations.first)
            XCTAssertEqual(observation.requestProbeBodyPath, bodyPath)
            XCTAssertEqual(observation.auditContext, client.context)
            XCTAssertEqual(observation.request.task, .voicePolishStructured)
            XCTAssertNil(VoicePolishProviderAudit.requestProbeBodyPath)
        }
    }

    func test审计客户端默认路径不覆盖当前任务已有实验上下文() async throws {
        let base = QualityRequestProbeContextClient(response: "完整正文。")
        let client = VoicePolishProviderAuditedLLMClient(
            base: base, runNonce: runNonce, testInputID: "existing-probe-context",
            receiptPath: "/tmp/quality-probe-context-test/provider-audit.jsonl"
        )
        let request = LLMRequest(context: .structuredTask, task: .voicePolishRender,
            system: "测试提示词", user: "测试原文", options: .init(responseFormat: .text))
        let config = LLMConfig(apiKey: "test-only", model: "test-model", baseURL: "https://example.invalid")
        let existingPath = "/tmp/quality-probe-context-test/request-body.json"
        let response = try await VoicePolishProviderAudit.withRequestProbe(bodyPath: existingPath) {
            try await client.generate(request, config: config)
        }
        XCTAssertEqual(response.text, "完整正文。")
        let observations = await base.observations
        XCTAssertEqual(observations.count, 1)
        let observation = try XCTUnwrap(observations.first)
        XCTAssertEqual(observation.requestProbeBodyPath, existingPath)
        XCTAssertEqual(observation.auditContext, client.context)
        XCTAssertNil(VoicePolishProviderAudit.requestProbeBodyPath)
    }

    func test非法缺失或重复模式不会静默降为旧自动模式() {
        for suffix in [
            ["--mode"], ["--mode", "automatic"], ["--mode", "legacy_automatic"],
            ["--mode", "fast"], ["--mode", "light", "--mode", "standard"],
        ] {
            XCTAssertThrowsError(try VoicePolishQualityRunner.parseInvocation(
                arguments: runnerArguments + suffix
            ))
        }
    }

    func test直出在凭据与Provider配置读取之前分流() throws {
        var configurationReads = 0
        let result = try VoicePolishQualityRunner.configuration(for: .direct) {
            configurationReads += 1
            throw LLMError.timedOut
        }
        XCTAssertNil(result)
        XCTAssertEqual(configurationReads, 0)

        for mode in [VoicePolishQualityRunner.Mode.light, .standard] {
            XCTAssertThrowsError(try VoicePolishQualityRunner.configuration(for: mode) {
                configurationReads += 1
                throw LLMError.timedOut
            })
        }
        XCTAssertEqual(configurationReads, 2)
    }

    func test直出只沿用既有纠词与首尾清理不触发润色清洗() {
        let source = "  嗯嗯现在剪切板里的输入消息不要删，预算一万六。\n"
        XCTAssertEqual(
            VoicePolishQualityRunner.directOutput(source),
            "嗯嗯现在剪切板里的输入消息不要删，预算一万六。"
        )
        XCTAssertEqual(
            VoicePolishQualityRunner.directOutput("用飞猪记录嗯嗯", terminology: ["飞猪": "飞书"]),
            "用飞书记录嗯嗯"
        )
    }

    func test直出报告保留原始证据且不伪造模型调用() throws {
        let source = "  嗯明天不对后天见，预算一万六。  "
        let fixture = try writeRunnerFixture(spokenInput: source, segmentTexts: [source])
        defer { try? FileManager.default.trashItem(at: fixture.deletingLastPathComponent(), resultingItemURL: nil) }
        let reports = try XCTUnwrap(JSONSerialization.jsonObject(
            with: VoicePolishQualityRunner.directCaseReportsForTesting(at: fixture.path)
        ) as? [[String: Any]])
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(report["mode"] as? String, "direct")
        XCTAssertEqual(report["spoken_input"] as? String, source)
        XCTAssertEqual(report["segment_texts"] as? [String], [source])
        XCTAssertEqual(report["canonical_input"] as? String, source)
        XCTAssertEqual(report["model_output"] as? String, source.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(report["executed_route"] as? String, "direct")
        XCTAssertEqual(report["llm_call_count"] as? Int, 0)
        XCTAssertEqual(report["llm_attempt_count"] as? Int, 0)
        XCTAssertEqual(report["repair_attempt_count"] as? Int, 0)
        XCTAssertEqual(report["internal_chunk_count"] as? Int, 0)
        XCTAssertEqual((report["stage_responses"] as? [Any])?.count, 0)
        XCTAssertEqual(report["fallback_used"] as? Bool, false)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(report["latency_milliseconds"] as? Int), 0)
        XCTAssertNotNil(report["started_at"] as? String)
        XCTAssertNotNil(report["finished_at"] as? String)
    }

    func test千字边界原样接受且超限输入拒绝而不截断() throws {
        for count in [1_000, 1_001] {
            let source = String(repeating: "字", count: count)
            let fixture = try writeRunnerFixture(spokenInput: source, segmentTexts: [source])
            defer { try? FileManager.default.trashItem(at: fixture.deletingLastPathComponent(), resultingItemURL: nil) }
            let original = try Data(contentsOf: fixture)
            if count == 1_000 {
                XCTAssertEqual(try VoicePolishQualityRunner.validatedInputCount(
                    at: fixture.path, maximumInputCharacters: 1_000
                ), 1)
            } else {
                XCTAssertThrowsError(try VoicePolishQualityRunner.validatedInputCount(
                    at: fixture.path, maximumInputCharacters: 1_000
                )) { error in
                    XCTAssertTrue(error.localizedDescription.contains("spoken_input"))
                    XCTAssertTrue(error.localizedDescription.contains("1001"))
                }
                XCTAssertThrowsError(try VoicePolishQualityRunner.directCaseReportsForTesting(at: fixture.path))
            }
            XCTAssertEqual(try Data(contentsOf: fixture), original)
        }
    }

    func test源分段总长不能绕过千字上限且必须非空() throws {
        let samples: [(String, [String], String)] = [
            ("短文", [String(repeating: "甲", count: 500), String(repeating: "乙", count: 501)], "segment_texts"),
            ("源文本", [], "源分段"),
        ]
        for (source, segments, expectedError) in samples {
            let fixture = try writeRunnerFixture(spokenInput: source, segmentTexts: segments)
            defer { try? FileManager.default.trashItem(at: fixture.deletingLastPathComponent(), resultingItemURL: nil) }
            XCTAssertThrowsError(try VoicePolishQualityRunner.validatedInputCount(
                at: fixture.path, maximumInputCharacters: 1_000
            )) { error in
                XCTAssertTrue(error.localizedDescription.contains(expectedError))
            }
        }
    }

    func test组合字符按原始码点计数且源文分段证据分别保留() throws {
        let repeated = String(repeating: "e\u{301}", count: 501)
        let fixture = try writeRunnerFixture(spokenInput: repeated, segmentTexts: [repeated])
        defer { try? FileManager.default.trashItem(at: fixture.deletingLastPathComponent(), resultingItemURL: nil) }
        XCTAssertEqual(repeated.count, 501)
        XCTAssertThrowsError(try VoicePolishQualityRunner.validatedInputCount(
            at: fixture.path, maximumInputCharacters: 1_000
        ))

        let differentBytes = try writeRunnerFixture(spokenInput: "é", segmentTexts: ["e\u{301}"])
        defer { try? FileManager.default.trashItem(at: differentBytes.deletingLastPathComponent(), resultingItemURL: nil) }
        XCTAssertEqual(try VoicePolishQualityRunner.validatedInputCount(
            at: differentBytes.path, maximumInputCharacters: 1_000
        ), 1)
        let reports = try XCTUnwrap(JSONSerialization.jsonObject(
            with: VoicePolishQualityRunner.directCaseReportsForTesting(at: differentBytes.path)
        ) as? [[String: Any]])
        XCTAssertEqual((reports.first?["spoken_input"] as? String)?.unicodeScalars.count, 1)
        XCTAssertEqual((reports.first?["segment_texts"] as? [String])?.first?.unicodeScalars.count, 2)
    }

    func test旧阶段记录可解码且不会伪造缺失的计时证据() throws {
        let data = Data(#"{"task":"voicePolishFast","requestPayload":"源文","responseText":"成稿"}"#.utf8)
        let result = try JSONDecoder().decode(VoicePolishQualityStageResponse.self, from: data)
        XCTAssertEqual(result.responseText, "成稿")
        XCTAssertNil(result.startedAt)
        XCTAssertNil(result.finishedAt)
        XCTAssertNil(result.latencyMilliseconds)
        XCTAssertNil(result.status)
    }

    func test完整终稿段落不会被原始ASR分段覆盖() throws {
        let source = "周五发第一版。\n\n预算一万六。"
        let segments = ["周五发第一版。", "预算一万六。"]
        let fixture = try writeRunnerFixture(spokenInput: source, segmentTexts: segments)
        defer { try? FileManager.default.trashItem(at: fixture.deletingLastPathComponent(), resultingItemURL: nil) }
        let envelope = try XCTUnwrap(VoicePolishQualityRunner.envelopesForTesting(at: fixture.path).first)
        XCTAssertEqual(envelope.canonicalText, source)
        XCTAssertEqual(envelope.fallbackText, source)
        XCTAssertEqual(envelope.segments.map(\.text).joined(), source)
        XCTAssertEqual(envelope.segments.count, 1)
        let reports = try XCTUnwrap(JSONSerialization.jsonObject(
            with: VoicePolishQualityRunner.directCaseReportsForTesting(at: fixture.path)
        ) as? [[String: Any]])
        XCTAssertEqual(reports.first?["spoken_input"] as? String, source)
        XCTAssertEqual(reports.first?["segment_texts"] as? [String], segments)
    }

    func test实体映射报告保留来源段置信度且字段可独立解码() throws {
        let entities = [ResolvedEntity(
            surfaceText: "达尔", canonical: "Dal", sourceSegmentIDs: ["s1"],
            candidateSource: .authorizedContext, confidence: 0.96
        )]
        let evidence = VoicePolishQualityRunner.resolvedEntitiesForReport(entities)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(evidence)) as? [[String: Any]])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["surface_text"] as? String, "达尔")
        XCTAssertEqual(row["canonical"] as? String, "Dal")
        XCTAssertEqual(row["source_segment_ids"] as? [String], ["s1"])
        XCTAssertEqual(row["candidate_source"] as? String, "authorizedContext")
        XCTAssertEqual(row["confidence"] as? Double, 0.96)
        XCTAssertEqual(Set(row.keys), ["surface_text", "canonical", "source_segment_ids", "candidate_source", "confidence"])
    }

    func test失败阶段保留真实尝试序号起止与耗时但不计成功调用() async throws {
        let counter = VoicePolishProviderAuditSuccessCounter()
        let request = LLMRequest(
            context: .processingMode, task: .voicePolishFast,
            system: "只润色", user: "源输入", options: .init()
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let ordinal = await counter.recordStarted(request: request, at: startedAt)
        await counter.recordFinished(
            ordinal: ordinal, response: nil, error: LLMError.timedOut,
            at: startedAt.addingTimeInterval(1.25), elapsed: .milliseconds(1_250)
        )
        let successCount = await counter.currentCount()
        let stages = await counter.stageResponses()
        let stage = try XCTUnwrap(stages.first)
        XCTAssertEqual(successCount, 0)
        XCTAssertEqual(stage.attemptOrdinal, 1)
        XCTAssertEqual(stage.status, "failed")
        XCTAssertEqual(stage.startedAt, startedAt)
        XCTAssertEqual(stage.finishedAt, startedAt.addingTimeInterval(1.25))
        XCTAssertEqual(stage.latencyMilliseconds, 1_250)
        XCTAssertEqual(stage.requestPayload, "源输入")
        XCTAssertEqual(stage.responseText, "")
        XCTAssertNotNil(stage.failureReason)
    }

    func test非法数量参数会被拒绝() {
        XCTAssertThrowsError(try VoicePolishQualityRunner.parseInvocation(arguments: [
            "Dal",
            "--voice-polish-quality-run", "--mode", "standard",
            "--run-input", "/tmp/runner-input.json",
            "--report", "/tmp/report.json",
            "--provider-audit", "/tmp/provider-audit.jsonl",
            "--run-nonce", runNonce,
            "--limit", "0",
        ]))
    }

    func test缺失或非法一次性运行标识会被拒绝() {
        XCTAssertThrowsError(try VoicePolishQualityRunner.parseInvocation(arguments: [
            "Dal", "--voice-polish-quality-run", "--mode", "standard",
            "--run-input", "/tmp/runner-input.json",
            "--report", "/tmp/report.json",
            "--provider-audit", "/tmp/provider-audit.jsonl",
        ]))
        XCTAssertThrowsError(try VoicePolishQualityRunner.parseInvocation(arguments: [
            "Dal", "--voice-polish-quality-run", "--mode", "standard",
            "--run-input", "/tmp/runner-input.json",
            "--report", "/tmp/report.json",
            "--provider-audit", "/tmp/provider-audit.jsonl",
            "--run-nonce", "not-a-valid-nonce",
        ]))
    }

    func test旧自动编排已删除时必须显式指定模式() {
        XCTAssertThrowsError(try VoicePolishQualityRunner.parseInvocation(arguments: [
            "Dal",
            "--voice-polish-quality-run",
            "--run-input", "/tmp/runner-input.json",
            "--report", "/tmp/report.json",
            "--provider-audit", "/tmp/provider-audit.jsonl",
            "--run-nonce", runNonce,
        ]))
        XCTAssertThrowsError(try VoicePolishQualityRunner.parseInvocation(arguments: [
            "Dal",
            "--voice-polish-quality-run", "--mode", "legacy_automatic",
            "--run-input", "/tmp/runner-input.json",
            "--report", "/tmp/report.json",
            "--provider-audit", "/tmp/provider-audit.jsonl",
            "--run-nonce", runNonce,
        ]))
    }

    func test质量跑测必须由Evaluator指定独立Provider回执路径() {
        XCTAssertThrowsError(try VoicePolishQualityRunner.parseInvocation(arguments: [
            "Dal",
            "--voice-polish-quality-run", "--mode", "standard",
            "--run-input", "/tmp/runner-input.json",
            "--report", "/tmp/report.json",
            "--run-nonce", runNonce,
        ]))
    }

    func test制品哈希由Runner读取文件计算且不能被CLI字段冒充() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DalQualityRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        let runInputURL = fixtureDirectory.appendingPathComponent("runner-input.json")
        let executableURL = fixtureDirectory.appendingPathComponent("Dal")
        try Data("abc".utf8).write(to: runInputURL)
        try Data("binary".utf8).write(to: executableURL)

        let invocation = try XCTUnwrap(VoicePolishQualityRunner.parseInvocation(arguments: [
            "Dal",
            "--voice-polish-quality-run", "--mode", "standard",
            "--run-input", runInputURL.path,
            "--report", fixtureDirectory.appendingPathComponent("report.json").path,
            "--provider-audit", fixtureDirectory.appendingPathComponent("provider-audit.jsonl").path,
            "--run-nonce", runNonce,
            "--commit", "可由CLI填写但Runner不得采用",
            "--run-input-sha256", "伪造的运行输入哈希",
            "--executable-sha256", "伪造的二进制哈希",
        ]))
        let evidence = try VoicePolishQualityRunner.artifactEvidenceForTesting(
            runInputURL: URL(fileURLWithPath: invocation.runInputPath),
            executableURL: executableURL
        )

        XCTAssertEqual(
            evidence.runInputSHA256,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            evidence.executableSHA256,
            "9a3a45d01531a20e89ac6ae10b0b0beb0492acd7216a368aa062d1a5fecaf9cd"
        )
        XCTAssertEqual(evidence.sourceCommit, String(repeating: "0", count: 40))

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(evidence)) as? [String: String]
        )
        XCTAssertEqual(object["run_input_sha256"], evidence.runInputSHA256)
        XCTAssertEqual(object["executable_sha256"], evidence.executableSHA256)
        XCTAssertEqual(object["source_commit"], evidence.sourceCommit)
    }

    func test非法制品提交标识会被拒绝() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DalQualityRunnerCommitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        let runInputURL = fixtureDirectory.appendingPathComponent("runner-input.json")
        let executableURL = fixtureDirectory.appendingPathComponent("Dal")
        try Data("runner-input".utf8).write(to: runInputURL)
        try Data("binary".utf8).write(to: executableURL)

        XCTAssertThrowsError(try VoicePolishQualityRunner.artifactEvidenceForTesting(
            runInputURL: runInputURL,
            executableURL: executableURL,
            sourceCommit: "可由调用方伪造"
        ))
    }

    func test报告输入证据完整保留实际分段与上下文夹具() throws {
        let fixture = VoicePolishQualityRunner.QualityContextFixture(
            type: "secure_context",
            level: .nearbyText,
            safety: .secure,
            selectedText: nil,
            textBeforeCursor: "上文中的项目代号是星桥",
            textAfterCursor: nil,
            recentDalInputs: ["上一条 Dal 输入"]
        )
        let evidence = VoicePolishQualityRunner.reportInputEvidence(
            segmentTexts: ["第一段原始语音", "第二段原始语音"],
            contextFixture: fixture,
            contextType: "secure_context",
            appliedContext: WritingContext(
                scene: .workChat,
                level: .metadataOnly,
                safety: .secure
            )
        )

        XCTAssertEqual(evidence.segmentTexts, ["第一段原始语音", "第二段原始语音"])
        XCTAssertEqual(evidence.contextFixture, fixture)

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(evidence)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(
            object["segment_texts"] as? [String],
            ["第一段原始语音", "第二段原始语音"]
        )
        let contextObject = try XCTUnwrap(object["context_fixture"] as? [String: Any])
        XCTAssertEqual(contextObject["type"] as? String, "secure_context")
        XCTAssertEqual(contextObject["level"] as? String, "nearbyText")
        XCTAssertEqual(contextObject["safety"] as? String, "secure")
        XCTAssertTrue(contextObject["selected_text"] is NSNull)
        XCTAssertEqual(
            contextObject["text_before_cursor"] as? String,
            "上文中的项目代号是星桥"
        )
        XCTAssertTrue(contextObject["text_after_cursor"] is NSNull)
        XCTAssertEqual(contextObject["recent_muse_inputs"] as? [String], ["上一条 Dal 输入"])

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        XCTAssertEqual(
            try decoder.decode(VoicePolishQualityRunner.QualityReportInputEvidence.self, from: data),
            evidence
        )
    }

    func test没有显式上下文夹具时报告仍写出实际默认上下文() {
        let appliedContext = WritingContext(
            scene: .chat,
            level: .metadataOnly,
            safety: .unknown,
            recentDalInputs: ["最近一次输入"]
        )

        let evidence = VoicePolishQualityRunner.reportInputEvidence(
            segmentTexts: ["请你明天提醒我"],
            contextFixture: nil,
            contextType: "none",
            appliedContext: appliedContext
        )

        XCTAssertEqual(evidence.contextFixture.type, "none")
        XCTAssertEqual(evidence.contextFixture.level, .metadataOnly)
        XCTAssertEqual(evidence.contextFixture.safety, .unknown)
        XCTAssertNil(evidence.contextFixture.selectedText)
        XCTAssertNil(evidence.contextFixture.textBeforeCursor)
        XCTAssertNil(evidence.contextFixture.textAfterCursor)
        XCTAssertEqual(evidence.contextFixture.recentDalInputs, ["最近一次输入"])
    }

    func testEvaluator从130次母集派生的Runner输入不含答案字段且可解析() throws {
        let scriptPath = repositoryRoot
            .appendingPathComponent("scripts/evaluate-voice-polish-quality-report.py")
        let datasetPath = repositoryRoot
            .appendingPathComponent("docs/2026-08-17-Dal-Voice-Polish-Quality-Test-Set.json")
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DalQualityRunnerInputTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let runInputURL = fixtureDirectory.appendingPathComponent("runner-input.json")
        let output = try runPython(
            """
            import importlib.util, json, pathlib, sys
            script = pathlib.Path(sys.argv[1])
            sys.path.insert(0, str(script.parent))
            spec = importlib.util.spec_from_file_location("voice_polish_evaluator", script)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            master = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
            runner_input = module.build_runner_input_document(master)
            pathlib.Path(sys.argv[3]).write_text(
                json.dumps(runner_input, ensure_ascii=False),
                encoding="utf-8",
            )
            leaked = sorted({
                key
                for item in runner_input["inputs"]
                for key in item
                if key in module.RUNNER_FORBIDDEN_ANSWER_FIELDS
            })
            print(json.dumps({
                "count": len(runner_input["inputs"]),
                "document_keys": sorted(runner_input),
                "leaked": leaked,
            }, ensure_ascii=False))
            """,
            arguments: [scriptPath.path, datasetPath.path, runInputURL.path]
        )
        let data = try XCTUnwrap(output.data(using: .utf8))
        let summary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(summary["count"] as? Int, 130)
        XCTAssertEqual(
            summary["document_keys"] as? [String],
            ["inputs", "name", "schema_version"]
        )
        XCTAssertEqual(summary["leaked"] as? [String], [])
        XCTAssertEqual(try VoicePolishQualityRunner.validatedInputCount(at: runInputURL.path), 130)
    }

    func testRunner拒绝夹带答案字段的运行输入() throws {
        let runInput: [String: Any] = [
            "schema_version": 1,
            "name": "forbidden-answer-fixture",
            "inputs": [[
                "test_input_id": "case-1",
                "base_case_id": "case-1",
                "input_kind": "base",
                "writing_scene": "chat",
                "spoken_input": "嗯明天见",
                "preconditions": [],
                "context_type": "none",
                "segment_texts": ["嗯明天见"],
                "context_fixture": NSNull(),
                "reference_output": "明天见。",
            ]],
        ]
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DalQualityRunnerForbiddenTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let runInputURL = fixtureDirectory.appendingPathComponent("runner-input.json")
        try JSONSerialization.data(withJSONObject: runInput).write(to: runInputURL)

        XCTAssertThrowsError(try VoicePolishQualityRunner.validatedInputCount(at: runInputURL.path))
    }

    func test质量报告记录最终ChatCompletions地址() throws {
        XCTAssertEqual(
            try VoicePolishQualityRunner.endpointIdentity(
                rawBaseURL: "https://api.deepseek.com",
                provider: .deepseek
            ),
            "https://api.deepseek.com/chat/completions"
        )
        XCTAssertEqual(
            try VoicePolishQualityRunner.endpointIdentity(
                rawBaseURL: "https://example.com/v1/",
                provider: .openai
            ),
            "https://example.com/v1/chat/completions"
        )
    }

    func testEvaluator只信外部冻结的构建Manifest与Expected值() throws {
        let scriptPath = repositoryRoot
            .appendingPathComponent("scripts/evaluate-voice-polish-quality-report.py")
        let output = try runPython(
            """
            import hashlib, importlib.util, json, pathlib, sys, tempfile
            script = pathlib.Path(sys.argv[1])
            sys.path.insert(0, str(script.parent))
            spec = importlib.util.spec_from_file_location("voice_polish_evaluator", script)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            directory = pathlib.Path(tempfile.mkdtemp(prefix="DalManifestEvaluatorTests-"))
            path = directory / "quality-build-manifest.json"
            commit = "1" * 40
            tree = "2" * 40
            executable = "3" * 64
            dataset = "4" * 64
            requirement = 'identifier "pro.daliang.muse" and certificate leaf = H"abc"'
            requirement_hash = hashlib.sha256(requirement.encode("utf-8")).hexdigest()
            document = {
                "schema_version": 1,
                "artifact_kind": "dal_voice_polish_quality_candidate",
                "package_mode": "production",
                "bundle_id": "pro.daliang.muse",
                "source_commit": commit,
                "source_tree": tree,
                "executable_sha256": executable,
                "dataset_sha256": dataset,
                "designated_requirement": requirement,
                "designated_requirement_sha256": requirement_hash,
                "created_at": "2026-08-17T00:00:00Z",
            }
            path.write_text(json.dumps(document, sort_keys=True), encoding="utf-8")
            manifest_hash = module.sha256_file(path)
            valid = module.validated_build_manifest(
                path,
                expected_manifest_sha256=manifest_hash,
                expected_source_commit=commit,
                expected_source_tree=tree,
                expected_executable_sha256=executable,
                expected_dataset_sha256=dataset,
                expected_designated_requirement_sha256=requirement_hash,
            )
            rejected_executable = False
            try:
                module.validated_build_manifest(
                    path,
                    expected_manifest_sha256=manifest_hash,
                    expected_source_commit=commit,
                    expected_source_tree=tree,
                    expected_executable_sha256="4" * 64,
                    expected_dataset_sha256=dataset,
                    expected_designated_requirement_sha256=requirement_hash,
                )
            except ValueError:
                rejected_executable = True
            rejected_dataset_manifest = False
            try:
                module.validated_build_manifest(
                    path,
                    expected_manifest_sha256=manifest_hash,
                    expected_source_commit=commit,
                    expected_source_tree=tree,
                    expected_executable_sha256=executable,
                    expected_dataset_sha256="5" * 64,
                    expected_designated_requirement_sha256=requirement_hash,
                )
            except ValueError:
                rejected_dataset_manifest = True
            print(json.dumps({
                "commit": valid["source_commit"],
                "rejected_executable": rejected_executable,
                "rejected_dataset_manifest": rejected_dataset_manifest,
            }))
            """,
            arguments: [scriptPath.path]
        )
        let data = try XCTUnwrap(output.data(using: .utf8))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(result["commit"] as? String, String(repeating: "1", count: 40))
        XCTAssertEqual(result["rejected_executable"] as? Bool, true)
        XCTAssertEqual(result["rejected_dataset_manifest"] as? Bool, true)
    }

    func testEvaluator拒绝错误母集SHA并锁定89加41等于130() throws {
        let scriptPath = repositoryRoot
            .appendingPathComponent("scripts/evaluate-voice-polish-quality-report.py")
        let datasetPath = repositoryRoot
            .appendingPathComponent("docs/2026-08-17-Dal-Voice-Polish-Quality-Test-Set.json")
        let output = try runPython(
            """
            import copy, hashlib, importlib.util, json, pathlib, sys, tempfile
            script = pathlib.Path(sys.argv[1])
            dataset_path = pathlib.Path(sys.argv[2])
            sys.path.insert(0, str(script.parent))
            spec = importlib.util.spec_from_file_location("voice_polish_evaluator", script)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            expected_sha = module.sha256_file(dataset_path)
            _, valid, actual_sha = module.validated_quality_dataset(
                dataset_path,
                expected_sha,
            )
            rejected_wrong_sha = False
            try:
                module.validated_quality_dataset(dataset_path, "0" * 64)
            except ValueError:
                rejected_wrong_sha = True

            reduced = copy.deepcopy(valid)
            reduced["cases"] = reduced["cases"][:-1]
            reduced["case_count"] = 88
            reduced["total_input_count"] = 129
            directory = pathlib.Path(tempfile.mkdtemp(prefix="DalDatasetFreezeTests-"))
            reduced_path = directory / "reduced-dataset.json"
            reduced_path.write_text(
                json.dumps(reduced, ensure_ascii=False),
                encoding="utf-8",
            )
            rejected_reduced = False
            try:
                module.validated_quality_dataset(
                    reduced_path,
                    module.sha256_file(reduced_path),
                )
            except ValueError:
                rejected_reduced = True
            print(json.dumps({
                "actual_sha": actual_sha,
                "expected_sha": expected_sha,
                "case_count": len(valid["cases"]),
                "variant_count": len(valid["stress_variants"]),
                "rejected_wrong_sha": rejected_wrong_sha,
                "rejected_reduced": rejected_reduced,
            }))
            """,
            arguments: [scriptPath.path, datasetPath.path]
        )
        let data = try XCTUnwrap(output.data(using: .utf8))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(result["actual_sha"] as? String, result["expected_sha"] as? String)
        XCTAssertEqual(result["case_count"] as? Int, 89)
        XCTAssertEqual(result["variant_count"] as? Int, 41)
        XCTAssertEqual(result["rejected_wrong_sha"] as? Bool, true)
        XCTAssertEqual(result["rejected_reduced"] as? Bool, true)
    }

    func testEvaluator要求网络回执与每条LLM调用一一对应() throws {
        let scriptPath = repositoryRoot
            .appendingPathComponent("scripts/evaluate-voice-polish-quality-report.py")
        let output = try runPython(
            """
            import datetime, importlib.util, json, pathlib, sys
            script = pathlib.Path(sys.argv[1])
            sys.path.insert(0, str(script.parent))
            spec = importlib.util.spec_from_file_location("voice_polish_evaluator", script)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            now = datetime.datetime.now(datetime.timezone.utc)
            nonce = "a" * 64
            receipt = {
                "schema_version": 2,
                "run_nonce": nonce,
                "test_input_id": "VP-001",
                "request_ordinal": 1,
                "llm_task": "voicePolishFast",
                "provider": "deepseek",
                "endpoint_url": "https://api.deepseek.com/chat/completions",
                "configured_model": "deepseek-chat",
                "response_model": "deepseek-chat",
                "transport": "stream",
                "http_status": 200,
                "request_body_sha256": "1" * 64,
                "response_text_sha256": "2" * 64,
                "provider_response_id": "chatcmpl-real-1",
                "recorded_at": now.isoformat(),
            }
            receipt["request_binding_sha256"] = module.provider_request_binding_sha256(
                receipt["run_nonce"],
                receipt["test_input_id"],
                receipt["request_ordinal"],
                receipt["request_body_sha256"],
            )
            cross_implementation_binding = module.provider_request_binding_sha256(
                "a" * 64,
                "样本-01",
                2,
                "b" * 64,
            )
            kwargs = {
                "expected_run_nonce": nonce,
                "expected_provider": "deepseek",
                "expected_model": "deepseek-chat",
                "expected_endpoint_url": "https://api.deepseek.com/chat/completions",
                "expected_test_ids": {"VP-001"},
                "actual_by_id": {"VP-001": {"llm_call_count": 1}},
                "run_started_at": now - datetime.timedelta(seconds=1),
                "run_finished_at": now + datetime.timedelta(seconds=1),
            }
            print(json.dumps({
                "valid": module.provider_audit_failures([receipt], **kwargs),
                "zero_receipt": module.provider_audit_failures([], **kwargs),
                "missing_response_id": module.provider_audit_failures([
                    {**receipt, "provider_response_id": ""}
                ], **kwargs),
                "tampered_binding": module.provider_audit_failures([
                    {**receipt, "request_ordinal": 2}
                ], **kwargs),
                "cross_implementation_binding": cross_implementation_binding,
            }, ensure_ascii=False))
            """,
            arguments: [scriptPath.path]
        )
        let data = try XCTUnwrap(output.data(using: .utf8))
        let result = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(result["valid"] as? [String], [])
        XCTAssertTrue((result["zero_receipt"] as? [String] ?? []).contains {
            $0.contains("Provider 回执 0 条")
        })
        XCTAssertTrue((result["missing_response_id"] as? [String] ?? []).contains {
            $0.contains("response ID")
        })
        XCTAssertTrue((result["tampered_binding"] as? [String] ?? []).contains {
            $0.contains("未绑定本次 nonce、样本、序号和请求体")
        })
        XCTAssertEqual(
            result["cross_implementation_binding"] as? String,
            "ab82d49a29f6f0541f3af63569db7b372e22b6026a43f7903e22f1e6f68bc4f2"
        )
    }

    private var runnerArguments: [String] {
        [
            "Dal", "--voice-polish-quality-run",
            "--run-input", "/tmp/runner-input.json",
            "--report", "/tmp/report.json",
            "--provider-audit", "/tmp/provider-audit.jsonl",
            "--run-nonce", runNonce,
        ]
    }

    private func writeRunnerFixture(spokenInput: String, segmentTexts: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DalThreeModeRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("runner-input.json")
        let document: [String: Any] = [
            "schema_version": 1,
            "name": "three-mode-fixture",
            "inputs": [[
                "test_input_id": "mode-001", "base_case_id": "mode-001",
                "input_kind": "base", "writing_scene": "chat", "spoken_input": spokenInput,
                "preconditions": [], "context_type": "none", "segment_texts": segmentTexts,
                "context_fixture": NSNull(),
            ]],
        ]
        try JSONSerialization.data(withJSONObject: document).write(to: path)
        return path
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runPython(_ source: String, arguments: [String]) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", source] + arguments
        process.currentDirectoryURL = repositoryRoot
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "VoicePolishQualityRunnerTests",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: String(data: error, encoding: .utf8) ?? "Python 执行失败",
                ]
            )
        }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 只读取真正进入 base.generate 时的 TaskLocal，不访问文件或网络。
private actor QualityRequestProbeContextClient: LLMClient {
    struct Observation: Sendable {
        let request: LLMRequest
        let requestProbeBodyPath: String?
        let auditContext: VoicePolishProviderAudit.Context?
    }

    private let response: String
    private(set) var observations: [Observation] = []

    init(response: String) { self.response = response }

    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        observations.append(Observation(
            request: request,
            requestProbeBodyPath: VoicePolishProviderAudit.requestProbeBodyPath,
            auditContext: VoicePolishProviderAudit.currentContext
        ))
        return LLMResponse(text: response, model: config.model)
    }

    func process(text: String, prompt: String, context: LLMRequestContext, config: LLMConfig) async throws -> String {
        throw LLMError.emptyResponse(nil)
    }

    func warmUp(baseURL: String) async {}
}
