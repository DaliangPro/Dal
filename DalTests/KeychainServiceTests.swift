import XCTest
@testable import Dal

final class KeychainServiceTests: XCTestCase {

    private var originalProvider: ASRProvider!
    private var originalLLMProvider: LLMProvider!

    override func setUp() {
        super.setUp()
        originalProvider = KeychainService.selectedASRProvider
        originalLLMProvider = KeychainService.selectedLLMProvider
    }

    override func tearDown() {
        KeychainService.delete(key: "test_key")
        KeychainService.selectedASRProvider = originalProvider
        KeychainService.selectedLLMProvider = originalLLMProvider
        super.tearDown()
    }

    func testTestProcessUsesIsolatedCredentialStorage() {
        XCTAssertTrue(KeychainService.isUsingIsolatedTestStorage)
    }

    func testSaveAndLoad() throws {
        try KeychainService.save(key: "test_key", value: "secret123")
        let loaded = KeychainService.load(key: "test_key")
        XCTAssertEqual(loaded, "secret123")
    }

    func testOverwrite() throws {
        try KeychainService.save(key: "test_key", value: "old")
        try KeychainService.save(key: "test_key", value: "new")
        XCTAssertEqual(KeychainService.load(key: "test_key"), "new")
    }

    func testLoadMissing() {
        let result = KeychainService.load(key: "nonexistent_key_xyz")
        XCTAssertNil(result)
    }

    func testDelete() throws {
        try KeychainService.save(key: "test_key", value: "value")
        KeychainService.delete(key: "test_key")
        XCTAssertNil(KeychainService.load(key: "test_key"))
    }

    func testLoadCredentials_fromKeychain() throws {
        let original = KeychainService.loadASRCredentials(for: .volcano)
        defer {
            if let original {
                try? KeychainService.saveASRCredentials(for: .volcano, values: original)
            } else {
                KeychainService.delete(key: "tf_asr_volcano")
            }
        }

        try KeychainService.saveASRCredentials(for: .volcano, values: [
            "appKey": "myAppKey",
            "accessKey": "myAccessKey",
            "resourceId": "myResource",
        ])

        let config = KeychainService.loadASRConfig()
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.appKey, "myAppKey")
        XCTAssertEqual(config?.accessKey, "myAccessKey")
        XCTAssertEqual(config?.resourceId, "myResource")
    }

    func testSelectedASRProviderPostsNotificationOnChange() {
        let targetProvider: ASRProvider = originalProvider == .apple ? .volcano : .apple
        let expectation = expectation(description: "provider change notification")
        let token = NotificationCenter.default.addObserver(
            forName: .asrProviderDidChange,
            object: nil,
            queue: .main
        ) { note in
            XCTAssertEqual(note.object as? ASRProvider, targetProvider)
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        KeychainService.selectedASRProvider = targetProvider

        wait(for: [expectation], timeout: 1.0)
    }
}
