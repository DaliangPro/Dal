import Security
import XCTest
@testable import Dal

final class InteractiveKeychainReadOnlyTests: XCTestCase {
    private let credentialKeys = ["tf_asr_volcano", "tf_llm_deepseek", "tf_asr_aliyun", "tf_llm_doubao"]

    private func preservingCredentials(_ body: () throws -> Void) rethrows {
        let originals = credentialKeys.map { ($0, KeychainService.load(key: $0)) }
        defer {
            for (key, value) in originals {
                if let value {
                    try? KeychainService.save(key: key, value: value)
                } else {
                    KeychainService.delete(key: key)
                }
            }
        }
        try body()
    }

    private func assertReadOnlyFailure(
        _ body: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case KeychainError.saveFailed(let status) = error else {
                return XCTFail("应以只读错误拒绝写入：\(error)", file: file, line: line)
            }
            XCTAssertEqual(status, errSecReadOnly, file: file, line: line)
        }
    }

    func testInteractiveReadsOnlyAllowedExistingCredentials() throws {
        XCTAssertTrue(KeychainService.isUsingIsolatedTestStorage)
        try preservingCredentials {
            try KeychainService.saveASRCredentials(for: .volcano, values: ["appKey": "test-volcano"])
            try KeychainService.saveASRCredentials(for: .aliyun, values: ["apiKey": "test-aliyun"])
            try KeychainService.saveLLMCredentials(for: .deepseek, values: ["apiKey": "test-deepseek"])
            try KeychainService.saveLLMCredentials(for: .doubao, values: ["apiKey": "test-doubao"])

            KeychainService.withInteractiveCredentialReadOnlyForTesting {
                XCTAssertEqual(KeychainService.loadASRCredentials(for: .volcano)?["appKey"], "test-volcano")
                XCTAssertEqual(KeychainService.loadLLMCredentials(for: .deepseek)?["apiKey"], "test-deepseek")
                XCTAssertNil(KeychainService.loadASRCredentials(for: .aliyun))
                XCTAssertNil(KeychainService.loadLLMCredentials(for: .doubao))
                XCTAssertNil(KeychainService.load(key: "tf_asr_aliyun"))
            }
            XCTAssertEqual(KeychainService.loadASRCredentials(for: .aliyun)?["apiKey"], "test-aliyun")
        }
    }

    func testInteractiveWritesAndDeletesLeaveExistingCredentialsUntouched() throws {
        try preservingCredentials {
            try KeychainService.saveASRCredentials(for: .volcano, values: ["appKey": "existing-volcano"])
            try KeychainService.saveLLMCredentials(for: .deepseek, values: ["apiKey": "existing-deepseek"])

            KeychainService.withInteractiveCredentialReadOnlyForTesting {
                assertReadOnlyFailure {
                    try KeychainService.save(key: "tf_asr_volcano", value: "replacement")
                }
                assertReadOnlyFailure {
                    try KeychainService.saveASRCredentials(for: .volcano, values: ["appKey": "replacement"])
                }
                assertReadOnlyFailure {
                    try KeychainService.saveLLMCredentials(for: .deepseek, values: ["apiKey": "replacement"])
                }
                XCTAssertFalse(KeychainService.delete(key: "tf_asr_volcano"))
                XCTAssertFalse(KeychainService.delete(key: "tf_llm_deepseek"))
                KeychainService.migrateIfNeeded()
                XCTAssertEqual(KeychainService.loadASRCredentials(for: .volcano)?["appKey"], "existing-volcano")
                XCTAssertEqual(KeychainService.loadLLMCredentials(for: .deepseek)?["apiKey"], "existing-deepseek")
            }
        }
    }

    func testInteractiveAuthorizationIsScopedToAllowedCredentials() throws {
        try preservingCredentials {
            try KeychainService.saveASRCredentials(for: .volcano, values: ["appKey": "test-volcano"])
            try KeychainService.saveLLMCredentials(for: .deepseek, values: ["apiKey": "test-deepseek"])

            KeychainService.withInteractiveCredentialReadOnlyForTesting {
                XCTAssertEqual(KeychainService.authorizeASRCredentialAccess(for: .volcano), errSecSuccess)
                XCTAssertEqual(KeychainService.authorizeLLMCredentialAccess(for: .deepseek), errSecSuccess)
                XCTAssertEqual(KeychainService.authorizeASRCredentialAccess(for: .aliyun), errSecAuthFailed)
                XCTAssertEqual(KeychainService.authorizeLLMCredentialAccess(for: .doubao), errSecAuthFailed)
                XCTAssertEqual(KeychainService.authorizeASRCredentialAccess(for: .apple), errSecParam)
                XCTAssertEqual(KeychainService.authorizeASRCredentialAccess(for: .sherpa), errSecParam)
                XCTAssertEqual(KeychainService.authorizeLLMCredentialAccess(for: .localQwen), errSecParam)
            }
        }
    }

    func testThrowingReadOnlyScopeRestoresNormalTestBackend() throws {
        let key = "interactive-scope-\(UUID().uuidString)"
        defer { KeychainService.delete(key: key) }
        XCTAssertThrowsError(try KeychainService.withInteractiveCredentialReadOnlyForTesting {
            try KeychainService.save(key: key, value: "rejected")
        })
        try KeychainService.save(key: key, value: "normal-test-backend")
        XCTAssertEqual(KeychainService.load(key: key), "normal-test-backend")
    }
}
