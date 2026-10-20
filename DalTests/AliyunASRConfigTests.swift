import XCTest
@testable import Dal

final class AliyunASRConfigTests: XCTestCase {
    func testConfigTrimsCredentialsAndBuildsWorkspaceEndpoint() throws {
        let config = try XCTUnwrap(AliyunASRConfig(credentials: [
            "apiKey": "  sk-test  ",
            "workspaceId": "  llm-test123  ",
            "model": "paraformer-realtime-v2",
            "funVocabularyId": "  vocab-fun  ",
            "vocabularyId": "  vocab-test  ",
        ]))

        XCTAssertEqual(config.apiKey, "sk-test")
        XCTAssertEqual(config.workspaceId, "llm-test123")
        XCTAssertEqual(config.model, .paraformerRealtimeV2)
        XCTAssertEqual(config.funVocabularyId, "vocab-fun")
        XCTAssertEqual(config.paraformerVocabularyId, "vocab-test")
        XCTAssertEqual(config.vocabularyId, "vocab-test")
        XCTAssertEqual(
            config.endpoint.absoluteString,
            "wss://llm-test123.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference"
        )
        XCTAssertEqual(
            config.vocabularyEndpoint.absoluteString,
            "https://llm-test123.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/asr/customization"
        )
    }

    func testConfigUsesCompatibilityEndpointWithoutWorkspaceID() throws {
        let config = try XCTUnwrap(AliyunASRConfig(credentials: [
            "apiKey": "sk-test",
        ]))

        XCTAssertNil(config.workspaceId)
        XCTAssertEqual(config.model, .funASRRealtime)
        XCTAssertNil(config.vocabularyId)
        XCTAssertEqual(config.endpoint, AliyunASRConfig.compatibilityEndpoint)
        XCTAssertEqual(
            config.vocabularyEndpoint,
            AliyunASRConfig.compatibilityVocabularyEndpoint
        )
    }

    func testConfigRejectsMissingOrMaskedAPIKey() {
        XCTAssertNil(AliyunASRConfig(credentials: [:]))
        XCTAssertNil(AliyunASRConfig(credentials: ["apiKey": "sk-••••test"]))
    }

    func testConfigRejectsWorkspaceIDThatCannotBeUsedAsHostLabel() {
        XCTAssertNil(AliyunASRConfig(credentials: [
            "apiKey": "sk-test",
            "workspaceId": "https://example.com",
        ]))
        XCTAssertNil(AliyunASRConfig(credentials: [
            "apiKey": "sk-test",
            "workspaceId": "-invalid",
        ]))
    }

    func testConfigSelectsVocabularyForCurrentModelAndKeepsLegacyParaformerID() throws {
        let values = [
            "apiKey": "sk-test",
            "funVocabularyId": "vocab-fun",
            "vocabularyId": "vocab-paraformer",
        ]

        let defaultConfig = try XCTUnwrap(AliyunASRConfig(credentials: values))
        XCTAssertEqual(defaultConfig.model, .funASRRealtime)
        XCTAssertEqual(defaultConfig.vocabularyId, "vocab-fun")

        var paraformerValues = values
        paraformerValues["model"] = AliyunASRModel.paraformerRealtimeV2.rawValue
        let paraformerConfig = try XCTUnwrap(AliyunASRConfig(credentials: paraformerValues))
        XCTAssertEqual(paraformerConfig.vocabularyId, "vocab-paraformer")
    }

    func testConfigRejectsUnsupportedModel() {
        XCTAssertNil(AliyunASRConfig(credentials: [
            "apiKey": "sk-test",
            "model": "unknown-realtime-model",
        ]))
    }

    func testModelFieldDefaultsToFunASRAndListsBothSupportedModels() throws {
        let field = try XCTUnwrap(
            AliyunASRConfig.credentialFields.first(where: { $0.key == "model" })
        )
        XCTAssertEqual(field.defaultValue, AliyunASRModel.funASRRealtime.rawValue)
        XCTAssertEqual(field.options.map(\.value), [
            AliyunASRModel.funASRRealtime.rawValue,
            AliyunASRModel.paraformerRealtimeV2.rawValue,
        ])
    }
}
