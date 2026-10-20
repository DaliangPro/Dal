import Foundation
import XCTest
@testable import Dal

final class LogRedactionTests: XCTestCase {
    private let fileManager = FileManager.default

    func testRedactionRemovesCredentialsPromptSpeechTextAndURLQuery() {
        let secrets = [
            "authorization-secret",
            "basic-authorization-secret",
            "api-key-secret",
            "spaced-api-key-secret",
            "access-key-secret",
            "token-secret",
            "prompt-secret",
            "speech-secret",
            "query-secret",
            "local-token-secret",
            "escaped-json-prompt-secret",
            "multiline-prompt-secret",
            "custom-query-secret",
        ]
        let message = """
        Authorization: Bearer authorization-secret
        Authorization: Basic basic-authorization-secret
        api_key=api-key-secret access_key=access-key-secret token=token-secret
        API key: spaced-api-key-secret
        url=https://example.test/path?credential=query-secret&mode=debug
        callback=dal://unknown?code=custom-query-secret
        local_token=local-token-secret
        {"prompt":"quoted \\"value\\" escaped-json-prompt-secret"}
        prompt=prompt-secret
        multiline-prompt-secret
        speech_text=speech-secret
        """

        let redacted = LogRedactor.redact(message)

        for secret in secrets {
            XCTAssertFalse(redacted.contains(secret), "日志仍包含 secret: \(secret)")
        }
        XCTAssertTrue(redacted.contains("<redacted>"))
    }

    func testProcessArgumentsFilterSecretFlags() {
        let arguments = [
            "/Applications/Dal.app/Contents/MacOS/Dal",
            "--api-key", "argument-api-secret",
            "--token=argument-token-secret",
            "--authorization", "Bearer", "argument-authorization-secret",
            "--prompt", "multi", "word", "argument-prompt-secret",
            "--safe-flag", "visible",
        ]

        let filtered = LogRedactor.redactedArguments(arguments).joined(separator: " ")

        XCTAssertFalse(filtered.contains("argument-api-secret"))
        XCTAssertFalse(filtered.contains("argument-token-secret"))
        XCTAssertFalse(filtered.contains("argument-authorization-secret"))
        XCTAssertFalse(filtered.contains("argument-prompt-secret"))
        XCTAssertTrue(filtered.contains("--safe-flag"))
        XCTAssertTrue(filtered.contains("visible"))
    }

    func testStructuredPromptAndTranscriptValuesFailClosed() {
        let secrets = [
            "array-prompt-first",
            "array-prompt-second",
            "nested-transcript-secret",
            "trailing-speech-secret",
        ]
        let messages = [
            #"{"prompt":["array-prompt-first","array-prompt-second"]}"#,
            #"{"transcript":{"partial":"nested-transcript-secret"}}"#,
            #"request={"speech_text":["trailing-speech-secret"]} status=pending"#,
        ]

        for message in messages {
            let redacted = LogRedactor.redact(message)
            for secret in secrets {
                XCTAssertFalse(redacted.contains(secret), "结构化正文未完全脱敏: \(secret)")
            }
        }
    }

    func testRotatedAndActiveDebugLogsUseOwnerOnlyPermissions() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.trashItem(at: directory, resultingItemURL: nil) }
        let logURL = directory.appendingPathComponent("debug.log")
        try Data(repeating: 0x41, count: 128).write(to: logURL)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: logURL.path)

        try DebugLogFileWriter.startSession(
            at: logURL,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            maximumBytes: 64
        )

        let rotatedURL = logURL.appendingPathExtension("1")
        XCTAssertEqual(try permissions(of: rotatedURL), 0o600)
        XCTAssertEqual(try permissions(of: logURL), 0o600)
    }

    func testExistingRotationPermissionIsRepairedWithoutNewRotation() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.trashItem(at: directory, resultingItemURL: nil) }
        let logURL = directory.appendingPathComponent("debug.log")
        let rotatedURL = logURL.appendingPathExtension("1")
        try Data("active".utf8).write(to: logURL)
        try Data("previous".utf8).write(to: rotatedURL)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rotatedURL.path)

        try DebugLogFileWriter.startSession(at: logURL, maximumBytes: 1_024)

        XCTAssertEqual(try permissions(of: rotatedURL), 0o600)
        XCTAssertEqual(try permissions(of: logURL), 0o600)
    }

    func testDebugFileWriterUsesSharedRedactor() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? fileManager.trashItem(at: directory, resultingItemURL: nil) }
        let logURL = directory.appendingPathComponent("debug.log")
        let secret = "debug-file-token-secret"

        try DebugLogFileWriter.append("token=\(secret)", to: logURL)

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(contents.contains(secret))
        XCTAssertTrue(contents.contains("token=<redacted>"))
    }

    func testUserTextIsRedactedAndSystemLogDefaultsToPrivate() {
        let userText = "private-user-speech-text"

        XCTAssertTrue(AppLogger.logsMessagesAsPrivateByDefault)
        XCTAssertFalse(AppLogger.redactedMessageForTesting("speech_text=\(userText)").contains(userText))
    }

    func testStaticDebugLoggerIsDisabledDuringTests() {
        XCTAssertTrue(DebugFileLogger.isFileLoggingDisabledForTests)
    }

    func test质量跑测与钥匙串授权专用进程在解析日志路径前禁用写盘() {
        for flag in ["--voice-polish-quality-run", "--voice-polish-quality-authorize-keychain"] {
            XCTAssertTrue(DebugFileLogger.shouldDisableFileLogging(
                arguments: ["Dal", flag], isRunningTests: false
            ))
        }
        XCTAssertTrue(DebugFileLogger.shouldDisableFileLogging(
            arguments: ["Dal"], isRunningTests: true
        ))
        XCTAssertFalse(DebugFileLogger.shouldDisableFileLogging(
            arguments: ["Dal"], isRunningTests: false
        ))
        XCTAssertFalse(DebugFileLogger.shouldDisableFileLogging(
            arguments: ["Dal", "a-file-containing--voice-polish-quality-run"], isRunningTests: false
        ))
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("dal-log-redaction-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
