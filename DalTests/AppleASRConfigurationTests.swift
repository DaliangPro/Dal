import XCTest
@preconcurrency import AVFoundation
@preconcurrency import Speech
@testable import Dal

final class AppleASRConfigurationTests: XCTestCase {
    func testMissingRecognizerIsReportedAsUnsupportedLocale() {
        XCTAssertThrowsError(
            try AppleASRClient.validateOnDeviceRecognizerForTesting(
                requestedLocaleIdentifier: "ja-JP",
                resolvedLocaleIdentifier: nil,
                isAvailable: false,
                supportsOnDeviceRecognition: false
            )
        ) { error in
            guard case AppleASRError.onDeviceRecognitionUnsupported(let localeIdentifier) = error else {
                return XCTFail("缺少识别器时应报告语言不支持：\(error)")
            }
            XCTAssertEqual(localeIdentifier, "ja-JP")
        }
    }

    func testFallbackRecognizerLocaleIsRejected() {
        XCTAssertThrowsError(
            try AppleASRClient.validateOnDeviceRecognizerForTesting(
                requestedLocaleIdentifier: "ja-JP",
                resolvedLocaleIdentifier: "en-US",
                isAvailable: true,
                supportsOnDeviceRecognition: true
            )
        ) { error in
            guard case AppleASRError.onDeviceRecognitionUnsupported(let localeIdentifier) = error else {
                return XCTFail("框架回退到其他语言时应明确拒绝：\(error)")
            }
            XCTAssertEqual(localeIdentifier, "ja-JP")
        }
    }

    func testCanonicalEquivalentRecognizerLocaleIsAccepted() throws {
        try AppleASRClient.validateOnDeviceRecognizerForTesting(
            requestedLocaleIdentifier: "zh-CN",
            resolvedLocaleIdentifier: "zh_CN",
            isAvailable: true,
            supportsOnDeviceRecognition: true
        )
    }

    func testMatchingUnavailableRecognizerKeepsTemporaryUnavailableError() {
        XCTAssertThrowsError(
            try AppleASRClient.validateOnDeviceRecognizerForTesting(
                requestedLocaleIdentifier: "en-US",
                resolvedLocaleIdentifier: "en_US",
                isAvailable: false,
                supportsOnDeviceRecognition: true
            )
        ) { error in
            guard case AppleASRError.recognizerUnavailable = error else {
                return XCTFail("匹配语言但服务暂不可用时应保留 unavailable：\(error)")
            }
        }
    }

    func testUnsupportedOnDeviceRecognizerWinsOverTemporaryUnavailableState() {
        XCTAssertThrowsError(
            try AppleASRClient.validateOnDeviceRecognizerForTesting(
                requestedLocaleIdentifier: "ja-JP",
                resolvedLocaleIdentifier: "ja_JP",
                isAvailable: false,
                supportsOnDeviceRecognition: false
            )
        ) { error in
            guard case AppleASRError.onDeviceRecognitionUnsupported(let localeIdentifier) = error else {
                return XCTFail("端侧能力不支持应优先于临时 unavailable：\(error)")
            }
            XCTAssertEqual(localeIdentifier, "ja-JP")
        }
    }

    @MainActor
    func testSupportedRecognizerForcesOnDeviceRequest() throws {
        let request = SFSpeechAudioBufferRecognitionRequest()

        try AppleASRClient.configureOnDeviceRequestForTesting(
            request,
            supportsOnDeviceRecognition: true,
            localeIdentifier: "zh-CN"
        )

        XCTAssertTrue(request.requiresOnDeviceRecognition)
        XCTAssertTrue(request.shouldReportPartialResults)
    }

    @MainActor
    func testUnsupportedLocaleReturnsActionableErrorWithoutCloudFallback() {
        let request = SFSpeechAudioBufferRecognitionRequest()

        XCTAssertThrowsError(
            try AppleASRClient.configureOnDeviceRequestForTesting(
                request,
                supportsOnDeviceRecognition: false,
                localeIdentifier: "ja-JP"
            )
        ) { error in
            guard case AppleASRError.onDeviceRecognitionUnsupported(let localeIdentifier) = error else {
                return XCTFail("错误类型不明确：\(error)")
            }
            XCTAssertEqual(localeIdentifier, "ja-JP")
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("ja-JP"), message)
            XCTAssertTrue(
                message.contains("切换") || message.localizedCaseInsensitiveContains("switch"),
                message
            )
            XCTAssertTrue(
                message.contains("火山") || message.localizedCaseInsensitiveContains("volcano"),
                message
            )
        }
        XCTAssertFalse(request.requiresOnDeviceRecognition)
    }

    func testConfiguredLocaleIsPassedToRecognizerFactory() async throws {
        let recorder = AppleLocaleRecorder()
        let session = AppleConfigurationSessionSpy()
        let client = AppleASRClient(
            permissionProvider: { true },
            recognitionSessionFactory: { locale, _ in
                recorder.record(locale.identifier)
                return session
            }
        )
        let config = try XCTUnwrap(AppleASRConfig(credentials: ["localeIdentifier": "ko-KR"]))

        try await client.connect(config: config, options: ASRRequestOptions())

        XCTAssertEqual(recorder.identifier, "ko-KR")
        await client.disconnect()
    }

    func testApplePrivacyCopyMatchesForcedOnDeviceBehavior() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readme = try source(at: repositoryRoot.appendingPathComponent("README.md"))
        let footer = try source(
            at: repositoryRoot.appendingPathComponent("Dal/UI/Settings/ASRSettingsFooter.swift")
        )
        let setup = try source(
            at: repositoryRoot.appendingPathComponent("Dal/UI/Setup/SetupWizardView.swift")
        )
        let client = try source(
            at: repositoryRoot.appendingPathComponent("Dal/ASR/AppleASRClient.swift")
        )

        XCTAssertFalse(readme.contains("| Apple 本机识别 | 否 |"), readme)
        XCTAssertTrue(readme.contains("识别音频是否上传"), readme)
        XCTAssertTrue(readme.contains("强制端侧"), readme)
        XCTAssertTrue(footer.contains("音频不上传"), footer)
        XCTAssertTrue(footer.localizedCaseInsensitiveContains("audio is not uploaded"), footer)
        XCTAssertTrue(setup.contains("仅端侧识别"), setup)
        XCTAssertTrue(setup.localizedCaseInsensitiveContains("no upload"), setup)
        XCTAssertTrue(setup.localizedCaseInsensitiveContains("switch language"), setup)
        XCTAssertFalse(client.contains("requiresOnDeviceRecognition = false"), client)
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}

private final class AppleLocaleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedIdentifier: String?

    var identifier: String? {
        lock.withLock { storedIdentifier }
    }

    func record(_ identifier: String) {
        lock.withLock { storedIdentifier = identifier }
    }
}

private final class AppleConfigurationSessionSpy: AppleRecognitionSessionControlling, @unchecked Sendable {
    func append(_ buffer: AVAudioPCMBuffer) async {
        _ = buffer
    }

    func endAudio() async {}

    func cancel() {}
}
