import XCTest
@testable import Dal

final class ASRProviderRegistryTests: XCTestCase {

    func testAvailableProvidersSupportDirectMode() {
        for provider in [ASRProvider.volcano, .aliyun] {
            XCTAssertTrue(ASRProviderRegistry.supports(.direct, for: provider))
        }
    }

    func testAliyunProviderIsRegisteredAsStreamingPCM() {
        let entry = ASRProviderRegistry.entry(for: .aliyun)

        XCTAssertTrue(entry?.isAvailable == true)
        XCTAssertEqual(entry?.configType.provider, .aliyun)
        XCTAssertEqual(entry?.capabilities, .streaming())
        XCTAssertTrue(ASRProviderRegistry.createClient(for: .aliyun) is AliyunASRClient)
    }

    func testResolvedModeFallsBackToDirectForUnavailableProvider() {
        let customMode = ProcessingMode(
            id: UUID(),
            name: "Custom",
            prompt: "Rewrite: {text}",
            isBuiltin: false
        )
        // Custom/LLM modes should always be supported
        XCTAssertTrue(ASRProviderRegistry.supports(customMode, for: .volcano))
        XCTAssertTrue(ASRProviderRegistry.supports(customMode, for: .apple))
    }

    func testSupportedModesFilterKeepsAllForAvailableProviders() {
        let customMode = ProcessingMode(
            id: UUID(),
            name: "Custom",
            prompt: "Rewrite: {text}",
            isBuiltin: false
        )
        let modes = [ProcessingMode.direct, customMode]

        let volcanoModes = ASRProviderRegistry.supportedModes(from: modes, for: .volcano)
        XCTAssertEqual(volcanoModes.map(\.id), [ProcessingMode.directId, customMode.id])

        let appleModes = ASRProviderRegistry.supportedModes(from: modes, for: .apple)
        XCTAssertEqual(appleModes.map(\.id), [ProcessingMode.directId, customMode.id])
    }

    func testUnavailableSherpaSupportsNoModes() {
        let customMode = ProcessingMode(
            id: UUID(),
            name: "Custom",
            prompt: "Rewrite: {text}",
            isBuiltin: false
        )

        XCTAssertFalse(
            ASRProviderRegistry.supports(
                .direct,
                for: .sherpa,
                capabilities: .unavailable
            )
        )
        XCTAssertFalse(
            ASRProviderRegistry.supports(
                customMode,
                for: .sherpa,
                capabilities: .unavailable
            )
        )
        XCTAssertTrue(
            ASRProviderRegistry.supportedModes(
                from: [.direct, customMode],
                for: .sherpa,
                capabilities: .unavailable
            ).isEmpty
        )
    }

    func testResolvedModeFallsBackWhenProviderIsUnavailable() {
        let customMode = ProcessingMode(
            id: UUID(),
            name: "Custom",
            prompt: "Rewrite: {text}",
            isBuiltin: false
        )

        XCTAssertEqual(
            ASRProviderRegistry.resolvedMode(
                for: customMode,
                provider: .sherpa,
                capabilities: .unavailable
            ).id,
            ProcessingMode.directId
        )
    }

    @MainActor
    func testLaunchFallbackPersistsAvailableProviderBeforePresentingNoticeOnlyOnce() {
        var selectedProvider = ASRProvider.sherpa
        var events: [String] = []
        let capabilities: [ASRProvider: ASRProviderCapabilities] = [
            .sherpa: .unavailable,
            .volcano: .streaming(),
            .apple: .streaming(audioInput: .pcmBuffer),
        ]

        let first = AppStartupCoordinator.reconcileSelectedASRProviderIfNeeded(
            readSelection: { selectedProvider },
            writeSelection: {
                selectedProvider = $0
                events.append("persist:\($0.rawValue)")
            },
            capabilities: { capabilities[$0] ?? .unavailable },
            presentNotice: { unavailable, replacement in
                events.append("notice:\(unavailable.rawValue)->\(replacement.rawValue)")
            }
        )
        let second = AppStartupCoordinator.reconcileSelectedASRProviderIfNeeded(
            readSelection: { selectedProvider },
            writeSelection: {
                selectedProvider = $0
                events.append("persist:\($0.rawValue)")
            },
            capabilities: { capabilities[$0] ?? .unavailable },
            presentNotice: { unavailable, replacement in
                events.append("notice:\(unavailable.rawValue)->\(replacement.rawValue)")
            }
        )

        XCTAssertEqual(first, .volcano)
        XCTAssertEqual(second, .volcano)
        XCTAssertEqual(selectedProvider, .volcano)
        XCTAssertEqual(events, ["persist:volcano", "notice:sherpa->volcano"])
    }

    @MainActor
    func testLaunchKeepsAvailableSelectionWithoutWritingOrPresentingNotice() {
        var events: [String] = []

        let resolved = AppStartupCoordinator.reconcileSelectedASRProviderIfNeeded(
            readSelection: { .apple },
            writeSelection: { events.append("persist:\($0.rawValue)") },
            capabilities: { provider in
                provider == .apple ? .streaming(audioInput: .pcmBuffer) : .unavailable
            },
            presentNotice: { unavailable, replacement in
                events.append("notice:\(unavailable.rawValue)->\(replacement.rawValue)")
            }
        )

        XCTAssertEqual(resolved, .apple)
        XCTAssertTrue(events.isEmpty)
    }

    @MainActor
    func testLaunchDoesNotInventFallbackWhenNoProviderIsAvailable() {
        var events: [String] = []

        let resolved = AppStartupCoordinator.reconcileSelectedASRProviderIfNeeded(
            readSelection: { .sherpa },
            writeSelection: { events.append("persist:\($0.rawValue)") },
            capabilities: { _ in .unavailable },
            presentNotice: { unavailable, replacement in
                events.append("notice:\(unavailable.rawValue)->\(replacement.rawValue)")
            }
        )

        XCTAssertEqual(resolved, .sherpa)
        XCTAssertTrue(events.isEmpty)
    }
}
