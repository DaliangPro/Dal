import XCTest

final class VoicePolishBlindTestScriptTests: XCTestCase {
    func testPrepareRandomizesOneHundredUniqueAudioSamplesAndAppliesFullProductGate() throws {
        let root = try temporaryDirectory()
        defer { trash(root) }
        let input = root.appendingPathComponent("input.json")
        let evaluation = root.appendingPathComponent("evaluation.json")
        let key = root.appendingPathComponent("key.json")
        let report = root.appendingPathComponent("report.json")
        try writeSamples(try samples(in: root), to: input)

        let script = projectRoot.appendingPathComponent("scripts/voice-polish-blind-test.py")
        XCTAssertEqual(try runPython([
            script.path, "prepare",
            "--input", input.path,
            "--output", evaluation.path,
            "--key", key.path,
            "--baseline-commit", "test-baseline",
        ]), 0)

        var publicDocument = try json(at: evaluation)
        var publicSamples = publicDocument["samples"] as! [[String: Any]]
        for index in publicSamples.indices {
            publicSamples[index]["ratings"] = [
                "overall": "tie",
                "writing_quality": "tie",
                "terminology": "tie",
                "fact_preservation": "tie",
                "sendability": "tie",
            ]
        }
        publicDocument["samples"] = publicSamples
        try JSONSerialization.data(withJSONObject: publicDocument, options: [.prettyPrinted, .sortedKeys])
            .write(to: evaluation, options: .atomic)

        XCTAssertEqual(try runPython([
            script.path, "score",
            "--evaluation", evaluation.path,
            "--key", key.path,
            "--output", report.path,
        ]), 0)
        let scored = try json(at: report)
        XCTAssertEqual(scored["baseline_commit"] as? String, "test-baseline")
        XCTAssertEqual(scored["sample_count"] as? Int, 100)
        XCTAssertEqual(scored["product_ready"] as? Bool, true)
        let dimensions = scored["dimensions"] as! [String: Any]
        let overall = dimensions["overall"] as! [String: Any]
        XCTAssertEqual(overall["dal_win_or_tie_rate"] as? Double, 1)
        let metrics = scored["engineering_metrics"] as! [String: Any]
        XCTAssertEqual(metrics["latency_targets_passed"] as? Bool, true)
        let publicMetadata = publicDocument["metadata"] as! [String: Any]
        XCTAssertNil(publicMetadata["seed"])
        let keyMetadata = (try json(at: key))["metadata"] as! [String: Any]
        XCTAssertNil(keyMetadata["seed"])
        XCTAssertEqual(keyMetadata["randomization"] as? String, "system_random")
        let sideCounts = keyMetadata["dal_side_counts"] as! [String: Any]
        XCTAssertEqual(sideCounts["left"] as? Int, 50)
        XCTAssertEqual(sideCounts["right"] as? Int, 50)
    }

    func testPrepareRejectsEmptyAudioReference() throws {
        let root = try temporaryDirectory()
        defer { trash(root) }
        var values = try samples(in: root)
        values[0]["audio_ref"] = ""
        XCTAssertNotEqual(try runPrepare(values, in: root), 0)
    }

    func testPrepareRejectsMissingAudioFile() throws {
        let root = try temporaryDirectory()
        defer { trash(root) }
        var values = try samples(in: root)
        values[0]["audio_ref"] = root.appendingPathComponent("missing.wav").path
        XCTAssertNotEqual(try runPrepare(values, in: root), 0)
    }

    func testPrepareRejectsInvalidAudioBytes() throws {
        let root = try temporaryDirectory()
        defer { trash(root) }
        var values = try samples(in: root)
        let invalidAudio = root.appendingPathComponent("invalid.wav")
        try Data("这不是音频".utf8).write(to: invalidAudio, options: .atomic)
        values[0]["audio_ref"] = invalidAudio.path
        XCTAssertNotEqual(try runPrepare(values, in: root), 0)
    }

    func testPrepareRejectsDecodableButExtremelyShortAudio() throws {
        let root = try temporaryDirectory()
        defer { trash(root) }
        var values = try samples(in: root)
        let shortAudio = root.appendingPathComponent("too-short.wav")
        try wavData(sample: 1, sampleCount: 1).write(to: shortAudio, options: .atomic)
        values[0]["audio_ref"] = shortAudio.path
        XCTAssertNotEqual(try runPrepare(values, in: root), 0)
    }

    func testPrepareRejectsDuplicateAudioContentEvenAtDifferentPaths() throws {
        let root = try temporaryDirectory()
        defer { trash(root) }
        var values = try samples(in: root)
        let original = URL(fileURLWithPath: values[0]["audio_ref"] as! String)
        let remuxed = root.appendingPathComponent("same-pcm-different-container.wav")
        try wavData(sample: 0, includesMetadata: true).write(to: remuxed, options: .atomic)
        XCTAssertNotEqual(try Data(contentsOf: original), try Data(contentsOf: remuxed))
        values[1]["audio_ref"] = remuxed.path
        XCTAssertNotEqual(try runPrepare(values, in: root), 0)
    }

    func testPrepareRejectsDifferentAudioSourcesForDalAndTypeless() throws {
        let root = try temporaryDirectory()
        defer { trash(root) }
        var values = try samples(in: root)
        values[0]["dal_audio_ref"] = values[0]["audio_ref"]
        values[0]["typeless_audio_ref"] = values[1]["audio_ref"]
        XCTAssertNotEqual(try runPrepare(values, in: root), 0)
    }

    func testPrepareAndScoreRejectInvalidRoute() throws {
        let root = try temporaryDirectory()
        defer { trash(root) }
        var invalidPrepareSamples = try samples(in: root)
        var prepareMetrics = invalidPrepareSamples[0]["dal_metrics"] as! [String: Any]
        prepareMetrics["route"] = "turbo"
        invalidPrepareSamples[0]["dal_metrics"] = prepareMetrics
        XCTAssertNotEqual(try runPrepare(invalidPrepareSamples, in: root), 0)

        let paths = try prepare(try samples(in: root), in: root)
        try fillRatings(at: paths.evaluation)
        var keyDocument = try json(at: paths.key)
        var keySamples = keyDocument["samples"] as! [[String: Any]]
        var scoreMetrics = keySamples[0]["dal_metrics"] as! [String: Any]
        scoreMetrics["route"] = "turbo"
        keySamples[0]["dal_metrics"] = scoreMetrics
        keyDocument["samples"] = keySamples
        try writeJSON(keyDocument, to: paths.key)
        XCTAssertNotEqual(try runScore(paths, in: root), 0)
    }

    func testScoreRejectsAudioReferenceChangedAfterPreparation() throws {
        let root = try temporaryDirectory()
        defer { trash(root) }
        let paths = try prepare(try samples(in: root), in: root)
        try fillRatings(at: paths.evaluation)
        var evaluationDocument = try json(at: paths.evaluation)
        var evaluationSamples = evaluationDocument["samples"] as! [[String: Any]]
        evaluationSamples[0]["audio_ref"] = ""
        evaluationDocument["samples"] = evaluationSamples
        try writeJSON(evaluationDocument, to: paths.evaluation)
        XCTAssertNotEqual(try runScore(paths, in: root), 0)
    }

    func testScoreRejectsAudioCorruptedAfterPreparation() throws {
        let root = try temporaryDirectory()
        defer { trash(root) }
        let values = try samples(in: root)
        let paths = try prepare(values, in: root)
        try fillRatings(at: paths.evaluation)
        let audio = URL(fileURLWithPath: values[0]["audio_ref"] as! String)
        try Data("corrupted after prepare".utf8).write(to: audio, options: .atomic)
        XCTAssertNotEqual(try runScore(paths, in: root), 0)
    }

    func testScoreRejectsDuplicateAudioEvidenceInsertedIntoKey() throws {
        let root = try temporaryDirectory()
        defer { trash(root) }
        let paths = try prepare(try samples(in: root), in: root)
        try fillRatings(at: paths.evaluation)
        var keyDocument = try json(at: paths.key)
        var keySamples = keyDocument["samples"] as! [[String: Any]]
        keySamples[1]["audio_ref"] = keySamples[0]["audio_ref"]
        keySamples[1]["audio_sha256"] = keySamples[0]["audio_sha256"]
        keyDocument["samples"] = keySamples
        try writeJSON(keyDocument, to: paths.key)
        XCTAssertNotEqual(try runScore(paths, in: root), 0)
    }

    func testScoreRejectsOutputTamperingAfterPreparation() throws {
        let root = try temporaryDirectory()
        defer { trash(root) }
        let paths = try prepare(try samples(in: root), in: root)
        try fillRatings(at: paths.evaluation)
        var evaluationDocument = try json(at: paths.evaluation)
        var evaluationSamples = evaluationDocument["samples"] as! [[String: Any]]
        evaluationSamples[0]["left"] = "被替换的输出"
        evaluationDocument["samples"] = evaluationSamples
        try writeJSON(evaluationDocument, to: paths.evaluation)
        XCTAssertNotEqual(try runScore(paths, in: root), 0)
    }

    func testPrepareAndScoreRejectInvalidEngineeringMetrics() throws {
        let root = try temporaryDirectory()
        defer { trash(root) }
        var negativeLatencySamples = try samples(in: root)
        var negativeMetrics = negativeLatencySamples[0]["dal_metrics"] as! [String: Any]
        negativeMetrics["latency_ms"] = -1
        negativeLatencySamples[0]["dal_metrics"] = negativeMetrics
        XCTAssertNotEqual(try runPrepare(negativeLatencySamples, in: root), 0)

        var invalidCounterSamples = try samples(in: root)
        var invalidCounterMetrics = invalidCounterSamples[0]["dal_metrics"] as! [String: Any]
        invalidCounterMetrics["confirmed_alias_correct"] = 2
        invalidCounterSamples[0]["dal_metrics"] = invalidCounterMetrics
        XCTAssertNotEqual(try runPrepare(invalidCounterSamples, in: root), 0)

        var inconsistentRepairSamples = try samples(in: root)
        var inconsistentRepairMetrics = inconsistentRepairSamples[3]["dal_metrics"]
            as! [String: Any]
        inconsistentRepairMetrics["call_count"] = 2
        inconsistentRepairMetrics["repair_used"] = false
        inconsistentRepairSamples[3]["dal_metrics"] = inconsistentRepairMetrics
        XCTAssertNotEqual(try runPrepare(inconsistentRepairSamples, in: root), 0)

        let paths = try prepare(try samples(in: root), in: root)
        try fillRatings(at: paths.evaluation)
        var keyDocument = try json(at: paths.key)
        var keySamples = keyDocument["samples"] as! [[String: Any]]
        var stringBooleanMetrics = keySamples[0]["dal_metrics"] as! [String: Any]
        stringBooleanMetrics["repair_used"] = "false"
        keySamples[0]["dal_metrics"] = stringBooleanMetrics
        keyDocument["samples"] = keySamples
        try writeJSON(keyDocument, to: paths.key)
        XCTAssertNotEqual(try runScore(paths, in: root), 0)
    }

    func testPrepareRejectsNonStringIdEmptyEvidenceAndInvalidTypelessLatency() throws {
        let root = try temporaryDirectory()
        defer { trash(root) }
        var nonStringIdSamples = try samples(in: root)
        nonStringIdSamples[0]["id"] = 42
        XCTAssertNotEqual(try runPrepare(nonStringIdSamples, in: root), 0)

        var emptyEvidenceSamples = try samples(in: root)
        emptyEvidenceSamples[0]["reference_transcript"] = "   "
        XCTAssertNotEqual(try runPrepare(emptyEvidenceSamples, in: root), 0)

        var emptyCategorySamples = try samples(in: root)
        emptyCategorySamples[0]["category"] = ""
        XCTAssertNotEqual(try runPrepare(emptyCategorySamples, in: root), 0)

        var emptyOutputSamples = try samples(in: root)
        emptyOutputSamples[0]["dal_output"] = ""
        XCTAssertNotEqual(try runPrepare(emptyOutputSamples, in: root), 0)

        var invalidLatencySamples = try samples(in: root)
        invalidLatencySamples[0]["typeless_latency_ms"] = -1
        XCTAssertNotEqual(try runPrepare(invalidLatencySamples, in: root), 0)

        XCTAssertNotEqual(
            try runPrepare(try samples(in: root), in: root, baselineCommit: "   "),
            0
        )
    }

    func testMissingRouteCannotPassLatencyOrProductGate() throws {
        let root = try temporaryDirectory()
        defer { trash(root) }
        let routes = (0..<100).map { $0.isMultiple(of: 2) ? "fast" : "structured" }
        let paths = try prepare(try samples(in: root, routes: routes), in: root)
        try fillRatings(at: paths.evaluation)
        XCTAssertEqual(try runScore(paths, in: root), 0)

        let scored = try json(at: paths.report)
        XCTAssertEqual(scored["product_ready"] as? Bool, false)
        let metrics = scored["engineering_metrics"] as! [String: Any]
        XCTAssertEqual(metrics["latency_targets_passed"] as? Bool, false)
        let routesReport = metrics["latency_by_route"] as! [String: Any]
        let deep = routesReport["deep"] as! [String: Any]
        XCTAssertEqual(deep["sample_count"] as? Int, 0)
        XCTAssertEqual(deep["minimum_sample_count"] as? Int, 10)
        XCTAssertEqual(deep["passed"] as? Bool, false)
    }

    func testRepairRateUsesOnlySamplesThatActuallyCalledLLM() throws {
        let root = try temporaryDirectory()
        defer { trash(root) }
        var values = try samples(in: root)
        for index in [3, 6] {
            var metrics = values[index]["dal_metrics"] as! [String: Any]
            metrics["call_count"] = 2
            metrics["repair_used"] = true
            values[index]["dal_metrics"] = metrics
        }
        let paths = try prepare(values, in: root)
        try fillRatings(at: paths.evaluation)
        XCTAssertEqual(try runScore(paths, in: root), 0)

        let scored = try json(at: paths.report)
        XCTAssertEqual(scored["engineering_gate_passed"] as? Bool, false)
        XCTAssertEqual(scored["product_ready"] as? Bool, false)
        let metrics = scored["engineering_metrics"] as! [String: Any]
        XCTAssertEqual(metrics["automatic_sample_count"] as? Int, 100)
        XCTAssertEqual(metrics["llm_request_sample_count"] as? Int, 99)
        let repairRate = try XCTUnwrap(metrics["repair_rate"] as? Double)
        XCTAssertEqual(repairRate, 2.0 / 99.0, accuracy: 0.000_001)
    }

    func testMissingRequiredCategoryCannotPassProductGate() throws {
        let root = try temporaryDirectory()
        defer { trash(root) }
        let categories = (0..<100).map { index in
            index.isMultiple(of: 2) ? "proper_noun" : "numbers"
        }
        let paths = try prepare(try samples(in: root, categories: categories), in: root)
        try fillRatings(at: paths.evaluation)
        XCTAssertEqual(try runScore(paths, in: root), 0)

        let scored = try json(at: paths.report)
        XCTAssertEqual(scored["category_coverage_passed"] as? Bool, false)
        XCTAssertEqual(scored["product_ready"] as? Bool, false)
        let coverage = scored["category_coverage"] as! [String: Any]
        let required = coverage["required"] as! [String: Any]
        let aiPrompt = required["ai_prompt"] as! [String: Any]
        XCTAssertEqual(aiPrompt["sample_count"] as? Int, 0)
        XCTAssertEqual(aiPrompt["passed"] as? Bool, false)
    }

    func testSeededRandomizationIsNeverProductReadyAndSeedStaysSecret() throws {
        let root = try temporaryDirectory()
        defer { trash(root) }
        let paths = try prepare(try samples(in: root), in: root, seed: 7)
        try fillRatings(at: paths.evaluation)
        XCTAssertEqual(try runScore(paths, in: root), 0)

        let publicMetadata = (try json(at: paths.evaluation))["metadata"] as! [String: Any]
        XCTAssertNil(publicMetadata["seed"])
        let keyMetadata = (try json(at: paths.key))["metadata"] as! [String: Any]
        XCTAssertEqual(keyMetadata["seed"] as? Int, 7)
        XCTAssertEqual(keyMetadata["randomization"] as? String, "seeded_test_only")
        let scored = try json(at: paths.report)
        XCTAssertEqual(scored["randomization_gate_passed"] as? Bool, false)
        XCTAssertEqual(scored["product_ready"] as? Bool, false)
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private typealias BlindTestPaths = (evaluation: URL, key: URL, report: URL)

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DalVoicePolishBlindTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func trash(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    private func samples(
        in root: URL,
        routes: [String]? = nil,
        categories: [String]? = nil
    ) throws -> [[String: Any]] {
        let audioDirectory = root.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let requiredCategories = [
            "proper_noun", "self_correction", "aside", "disordered",
            "list", "numbers", "mixed_language", "ai_prompt",
        ]
        return try (0..<100).map { index in
            let route = routes?[index]
                ?? (index % 10 == 0 ? "deep" : (index % 3 == 0 ? "structured" : "fast"))
            let isSetupFallback = index == 0 && route == "deep"
            let audio = audioDirectory.appendingPathComponent("sample-\(index).wav")
            try wavData(sample: index).write(to: audio, options: .atomic)
            return [
                "id": "sample-\(index)",
                "audio_ref": audio.path,
                "category": categories?[index] ?? requiredCategories[index % requiredCategories.count],
                "reference_transcript": "input-\(index)",
                "typeless_output": "typeless-\(index)",
                "dal_output": "dal-\(index)",
                "typeless_latency_ms": 1_000,
                "dal_metrics": [
                    "latency_ms": route == "deep" ? 4_000 : 1_000,
                    "route": route,
                    "call_count": isSetupFallback ? 0 : (route == "deep" ? 2 : 1),
                    "repair_used": false,
                    "fallback_used": isSetupFallback,
                    "confirmed_alias_total": 1,
                    "confirmed_alias_correct": 1,
                    "critical_fact_total": 1,
                    "critical_fact_preserved": 1,
                    "whitelist_hallucination_count": 0,
                ],
            ]
        }
    }

    private func wavData(
        sample: Int,
        sampleCount: Int = 12_000,
        includesMetadata: Bool = false
    ) -> Data {
        var data = Data()
        func appendASCII(_ value: String) { data.append(value.data(using: .ascii)!) }
        func appendUInt16(_ value: UInt16) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        func appendUInt32(_ value: UInt32) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        let audioByteCount = sampleCount * MemoryLayout<Int16>.size
        let metadataByteCount = includesMetadata ? 12 : 0
        appendASCII("RIFF")
        appendUInt32(UInt32(36 + metadataByteCount + audioByteCount))
        appendASCII("WAVEfmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(16_000)
        appendUInt32(32_000)
        appendUInt16(2)
        appendUInt16(16)
        if includesMetadata {
            appendASCII("JUNK")
            appendUInt32(4)
            appendASCII("Dal")
        }
        appendASCII("data")
        appendUInt32(UInt32(audioByteCount))
        let pcm = (0..<sampleCount).map { position in
            Int16(((position * (sample + 1)) % 2_000) - 1_000).littleEndian
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    private func prepare(
        _ samples: [[String: Any]],
        in root: URL,
        seed: Int? = nil
    ) throws -> BlindTestPaths {
        let input = root.appendingPathComponent("input.json")
        let paths = (
            evaluation: root.appendingPathComponent("evaluation.json"),
            key: root.appendingPathComponent("key.json"),
            report: root.appendingPathComponent("report.json")
        )
        try writeSamples(samples, to: input)
        var arguments = [
            projectRoot.appendingPathComponent("scripts/voice-polish-blind-test.py").path,
            "prepare", "--input", input.path,
            "--output", paths.evaluation.path,
            "--key", paths.key.path,
            "--baseline-commit", "test-baseline",
        ]
        if let seed {
            arguments.append(contentsOf: ["--seed", String(seed)])
        }
        let status = try runPython(arguments)
        XCTAssertEqual(status, 0)
        return paths
    }

    private func runPrepare(
        _ samples: [[String: Any]],
        in root: URL,
        baselineCommit: String = "test-baseline"
    ) throws -> Int32 {
        let input = root.appendingPathComponent("invalid-input.json")
        try writeSamples(samples, to: input)
        return try runPython([
            projectRoot.appendingPathComponent("scripts/voice-polish-blind-test.py").path,
            "prepare", "--input", input.path,
            "--output", root.appendingPathComponent("invalid-evaluation.json").path,
            "--key", root.appendingPathComponent("invalid-key.json").path,
            "--baseline-commit", baselineCommit,
        ])
    }

    private func runScore(_ paths: BlindTestPaths, in root: URL) throws -> Int32 {
        try runPython([
            projectRoot.appendingPathComponent("scripts/voice-polish-blind-test.py").path,
            "score", "--evaluation", paths.evaluation.path,
            "--key", paths.key.path,
            "--output", paths.report.path,
        ])
    }

    private func fillRatings(at evaluation: URL) throws {
        var document = try json(at: evaluation)
        var samples = document["samples"] as! [[String: Any]]
        for index in samples.indices {
            samples[index]["ratings"] = Dictionary(
                uniqueKeysWithValues: [
                    "overall", "writing_quality", "terminology", "fact_preservation", "sendability",
                ].map { ($0, "tie") }
            )
        }
        document["samples"] = samples
        try writeJSON(document, to: evaluation)
    }

    private func writeSamples(_ samples: [[String: Any]], to url: URL) throws {
        try writeJSON(["samples": samples], to: url)
    }

    private func writeJSON(_ value: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }

    private func runPython(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func json(at url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
}
