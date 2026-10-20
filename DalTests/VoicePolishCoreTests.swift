import XCTest
@testable import Dal

final class VoicePolishCoreTests: XCTestCase {

    func testCharacterSafetyNormalizesLineEndingsAndPreservesTextCharacters() {
        let safe = "第一行\r\n第二行\t👨‍👩‍👧‍👦e\u{301}"
        XCTAssertFalse(VoicePolishCharacterSafety.containsUnsafeCharacters(safe))
        XCTAssertEqual(
            VoicePolishCharacterSafety.sanitizedFallback(safe),
            "第一行\n第二行\t👨‍👩‍👧‍👦e\u{301}"
        )

        let unsafe = String(decoding: [
            0x41, 0x00, 0x1B, 0x7F, 0xC2, 0x85, 0xEF, 0xB7, 0x90, 0x42,
        ], as: UTF8.self)
        XCTAssertTrue(VoicePolishCharacterSafety.containsUnsafeCharacters(unsafe))
        XCTAssertEqual(VoicePolishCharacterSafety.sanitizedFallback(unsafe), "AB")
    }

    func testWritingContextClearsBodyUnlessExplicitlySafeAndAuthorized() {
        let unknown = WritingContext(
            scene: .email,
            level: .nearbyText,
            safety: .unknown,
            selectedText: "秘密",
            textBeforeCursor: "前文",
            textAfterCursor: "后文"
        )
        XCTAssertNil(unknown.selectedText)
        XCTAssertNil(unknown.textBeforeCursor)
        XCTAssertNil(unknown.textAfterCursor)

        let metadataOnly = WritingContext(
            scene: .email,
            level: .metadataOnly,
            safety: .safe,
            selectedText: "仍不得读取"
        )
        XCTAssertNil(metadataOnly.selectedText)
    }

    func testContextSafetyUsesStrictAllowlistAndExplicitSecureChecks() {
        XCTAssertEqual(
            WritingContextCapture.safetyForTesting(
                role: "AXTextField",
                subrole: "AXStandardTextField",
                editable: true,
                protectedContent: false
            ),
            .safe
        )
        XCTAssertEqual(
            WritingContextCapture.safetyForTesting(
                role: "AXTextField",
                subrole: "AXSecureTextField",
                editable: true,
                protectedContent: true
            ),
            .secure
        )
        XCTAssertEqual(
            WritingContextCapture.safetyForTesting(
                role: "AXWebArea",
                subrole: "AXStandardWindow",
                editable: true,
                protectedContent: false
            ),
            .unknown
        )
        XCTAssertEqual(
            WritingContextCapture.safetyForTesting(
                role: "AXTextArea",
                subrole: nil,
                editable: true,
                protectedContent: false
            ),
            .unknown
        )
        XCTAssertEqual(
            WritingContextCapture.safetyForTesting(
                role: "AXTextArea",
                subrole: "AXStandardTextArea",
                editable: true,
                protectedContent: nil
            ),
            .unknown
        )
    }

    func testSceneClassifierHonorsOverridesAndDoesNotGuessBrowserPages() {
        XCTAssertEqual(
            AppSceneClassifier.classify(
                bundleID: "com.google.Chrome",
                focusedRole: "AXTextField"
            ),
            .unknown
        )
        XCTAssertEqual(
            AppSceneClassifier.classify(
                bundleID: "com.google.Chrome",
                focusedRole: "AXTextField",
                userOverrides: ["com.google.Chrome": .aiPrompt]
            ),
            .aiPrompt
        )
        XCTAssertEqual(
            AppSceneClassifier.classify(
                bundleID: "com.apple.mail",
                focusedRole: "AXTextArea"
            ),
            .email
        )
    }

    func testVoicePolishSettingsDefaultsArePrivacyPreserving() {
        let suite = "VoicePolishSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(VoicePolishSettings.qualityMode(defaults: defaults), .automatic)
        XCTAssertEqual(VoicePolishSettings.contextLevel(defaults: defaults), .nearbyText)
        XCTAssertTrue(VoicePolishSettings.personalizationEnabled(defaults: defaults))
        XCTAssertTrue(VoicePolishSettings.terminologyLearningEnabled(defaults: defaults))
        XCTAssertTrue(VoicePolishSettings.recentInputContextEnabled(defaults: defaults))
        XCTAssertEqual(VoicePolishSettings.correctionLimit(defaults: defaults), 200)
        XCTAssertNil(VoicePolishSettings.modelOverride(defaults: defaults))
    }

    func testLegacyQualitySelectionsAllMigrateToSingleAutomaticMode() {
        let suite = "VoicePolishSingleModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        for legacy in ["fast", "balanced", "quality"] {
            defaults.set(legacy, forKey: DefaultsKeys.voicePolishQualityMode)
            XCTAssertEqual(
                VoicePolishSettings.qualityMode(defaults: defaults),
                .automatic,
                "旧档位 \(legacy) 不得继续改变产品行为"
            )
        }
    }

    func testVoicePolishDedicatedModelOverrideIsTrimmedAndOptional() {
        let suite = "VoicePolishModelOverrideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        VoicePolishSettings.setModelOverride("  fast-model  ", defaults: defaults)
        XCTAssertEqual(VoicePolishSettings.modelOverride(defaults: defaults), "fast-model")

        VoicePolishSettings.setModelOverride("   ", defaults: defaults)
        XCTAssertNil(VoicePolishSettings.modelOverride(defaults: defaults))
    }

    func testInputEnvelopeAlwaysCoversAuthoritativeFinalTranscript() {
        let transcript = RecognitionTranscript(
            confirmedSegments: ["已确认的前半句，"],
            partialText: "尚未确认",
            authoritativeText: "",
            isFinal: true
        )

        let envelope = VoiceInputEnvelope.fromFinalTranscript(
            transcript,
            rawFinalText: "已确认的前半句，最终完整后半句。",
            canonicalText: "已确认的前半句，最终完整后半句。",
            durationMs: 2_000,
            provider: .volcano
        )

        XCTAssertEqual(envelope?.providerFinalText, "已确认的前半句，最终完整后半句。")
        XCTAssertEqual(envelope?.segments.map(\.text), ["已确认的前半句，最终完整后半句。"])
        XCTAssertEqual(envelope?.segments.map(\.id), ["s1"])
    }

    func testInputEnvelopeKeepsRawEvidenceAndUsesCanonicalFallback() {
        let raw = "我正在使用 Type less。"
        let canonical = "我正在使用 Typeless。"
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        let envelope = VoiceInputEnvelope.fromFinalTranscript(
            transcript,
            rawFinalText: raw,
            canonicalText: canonical,
            durationMs: 1_000,
            provider: .volcano
        )

        XCTAssertEqual(envelope?.providerFinalText, raw)
        XCTAssertEqual(envelope?.rawSegments.map(\.text), [raw])
        XCTAssertEqual(envelope?.canonicalText, canonical)
        XCTAssertEqual(envelope?.segments.map(\.text), [canonical])
        XCTAssertEqual(envelope?.fallbackText, canonical)
    }

    func testCanonicalizationKeepsSegmentIdentityAndRecordsActualTerminologyEdit() throws {
        let rawSegments = ["我正在使用 Type less。", "它很好用。"]
        let raw = rawSegments.joined()
        let canonicalSegments = ["我正在使用 Typeless。", "它很好用。"]
        let canonical = canonicalSegments.joined()
        let transcript = RecognitionTranscript(
            confirmedSegments: rawSegments,
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        let envelope = try XCTUnwrap(VoiceInputEnvelope.fromFinalTranscript(
            transcript,
            rawFinalText: raw,
            canonicalText: canonical,
            preferredCanonicalSegmentTexts: canonicalSegments,
            deterministicCorrections: ["Type less": "Typeless"],
            durationMs: 1_000,
            provider: .volcano
        ))

        XCTAssertEqual(envelope.rawSegments.map(\.id), ["s1", "s2"])
        XCTAssertEqual(envelope.segments.map(\.id), ["s1", "s2"])
        XCTAssertEqual(envelope.segments.map(\.text), canonicalSegments)
        XCTAssertEqual(envelope.requiredEntityEdits, [VoiceTerminologyEdit(
            alias: "Type less",
            canonical: "Typeless",
            sourceSegmentIDs: ["s1"]
        )])
    }

    private func makeRequest(
        _ text: String,
        requirements: String = "",
        scene: WritingScene = .unknown
    ) -> VoicePolishRequest {
        VoicePolishRequest(
            input: VoiceInputEnvelope(
                providerFinalText: text,
                segments: [segment(text)],
                durationMs: 1_000,
                provider: .volcano
            ),
            context: WritingContext(scene: scene),
            preferences: UserPolishPreferences(additionalRequirements: requirements),
            qualityMode: .balanced
        )
    }

    private func segment(_ text: String) -> RecognitionSegment {
        RecognitionSegment(
            id: "s1",
            text: text,
            startTimeMs: nil,
            endTimeMs: nil,
            confidence: nil,
            isFinal: true
        )
    }

    private func encoded<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(data: try encoder.encode(value), encoding: .utf8)!
    }
}

private struct SimplePayload: Codable, Equatable {
    let message: String
}
