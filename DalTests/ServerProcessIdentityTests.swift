import Darwin
import Foundation
import XCTest
@testable import Dal

final class ServerProcessIdentityTests: XCTestCase {
    func testPathMismatchRefusesToTerminateLiveProcess() async throws {
        let process = try launchSleepingProcess()
        defer { forceCleanup(process) }
        let identity = try XCTUnwrap(
            ServerProcessController.captureIdentity(
                kind: "test-server",
                pid: process.processIdentifier
            )
        )
        let mismatched = ServerProcessIdentity(
            kind: identity.kind,
            pid: identity.pid,
            executablePath: identity.executablePath + ".mismatch",
            startTimeSeconds: identity.startTimeSeconds
        )
        let logs = ProcessLogCapture()

        let result = await ServerProcessController.terminate(
            process: process,
            identity: mismatched,
            expectedKind: "test-server",
            gracefulTimeout: .milliseconds(50),
            forceTimeout: .milliseconds(200),
            log: { logs.append($0) }
        )

        XCTAssertEqual(result, .refused)
        XCTAssertTrue(process.isRunning)
        XCTAssertTrue(logs.messages.contains { $0.contains("path") })
    }

    func testStartTimeMismatchRefusesToTerminateLiveProcess() async throws {
        let process = try launchSleepingProcess()
        defer { forceCleanup(process) }
        let identity = try XCTUnwrap(
            ServerProcessController.captureIdentity(
                kind: "test-server",
                pid: process.processIdentifier
            )
        )
        let mismatched = ServerProcessIdentity(
            kind: identity.kind,
            pid: identity.pid,
            executablePath: identity.executablePath,
            startTimeSeconds: identity.startTimeSeconds + 1
        )

        let result = await ServerProcessController.terminate(
            process: process,
            identity: mismatched,
            expectedKind: "test-server",
            gracefulTimeout: .milliseconds(50),
            forceTimeout: .milliseconds(200)
        )

        XCTAssertEqual(result, .refused)
        XCTAssertTrue(process.isRunning)
    }

    func testKindMismatchRefusesToTerminateLiveProcess() async throws {
        let process = try launchSleepingProcess()
        defer { forceCleanup(process) }
        let identity = try XCTUnwrap(
            ServerProcessController.captureIdentity(
                kind: "sensevoice-server",
                pid: process.processIdentifier
            )
        )

        let result = await ServerProcessController.terminate(
            process: process,
            identity: identity,
            expectedKind: "qwen3-asr-server",
            gracefulTimeout: .milliseconds(50),
            forceTimeout: .milliseconds(200)
        )

        XCTAssertEqual(result, .refused)
        XCTAssertTrue(process.isRunning)
    }

    func testMatchingIdentityTerminatesFixtureGracefully() async throws {
        let process = try launchSleepingProcess()
        defer { forceCleanup(process) }
        let identity = try XCTUnwrap(
            ServerProcessController.captureIdentity(
                kind: "test-server",
                pid: process.processIdentifier
            )
        )

        let result = await ServerProcessController.terminate(
            process: process,
            identity: identity,
            expectedKind: "test-server",
            gracefulTimeout: .seconds(1),
            forceTimeout: .seconds(1)
        )

        XCTAssertEqual(result, .terminatedGracefully)
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGTERM)
    }

    func testFixtureIgnoringTermIsEventuallyKilled() async throws {
        let process = try launchTermIgnoringProcess()
        defer { forceCleanup(process) }
        let identity = try XCTUnwrap(
            ServerProcessController.captureIdentity(
                kind: "test-server",
                pid: process.processIdentifier
            )
        )

        let result = await ServerProcessController.terminate(
            process: process,
            identity: identity,
            expectedKind: "test-server",
            gracefulTimeout: .milliseconds(100),
            forceTimeout: .seconds(1)
        )

        XCTAssertEqual(result, .killed)
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
    }

    func testRecordedIdentityWhoseProcessExitedIsAlreadyExited() async throws {
        let process = try launchSleepingProcess()
        let identity = try XCTUnwrap(
            ServerProcessController.captureIdentity(
                kind: "test-server",
                pid: process.processIdentifier
            )
        )
        process.terminate()
        process.waitUntilExit()

        let result = await ServerProcessController.terminate(
            identity: identity,
            expectedKind: "test-server",
            gracefulTimeout: .milliseconds(50),
            forceTimeout: .milliseconds(50)
        )

        XCTAssertEqual(result, .alreadyExited)
    }

    func testCorruptedPIDLedgerIsIgnoredAndLogged() {
        let logs = ProcessLogCapture()

        let identities = ServerProcessIdentityLedger.decode(
            Data("not-json".utf8),
            log: { logs.append($0) }
        )

        XCTAssertTrue(identities.isEmpty)
        XCTAssertFalse(logs.messages.isEmpty)
        XCTAssertTrue(logs.messages.contains { $0.contains("PID") })
    }

    func testIdentityLedgerRoundTripsJSON() throws {
        let identity = ServerProcessIdentity(
            kind: "sensevoice-server",
            pid: 123,
            executablePath: "/tmp/server",
            startTimeSeconds: 456
        )

        let encoded = try ServerProcessIdentityLedger.encode([identity])
        let decoded = ServerProcessIdentityLedger.decode(encoded)

        XCTAssertEqual(decoded, [identity])
    }
}

private func launchSleepingProcess() throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    return process
}

private func launchTermIgnoringProcess() throws -> Process {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
        "-u",
        "-c",
        "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            + "print('READY', flush=True); time.sleep(30)",
    ]
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    let ready = output.fileHandleForReading.readData(ofLength: 6)
    guard String(data: ready, encoding: .utf8) == "READY\n" else {
        forceCleanup(process)
        throw FixtureError.notReady
    }
    return process
}

private func forceCleanup(_ process: Process) {
    guard process.isRunning else { return }
    Darwin.kill(process.processIdentifier, SIGKILL)
    process.waitUntilExit()
}

private enum FixtureError: Error {
    case notReady
}

private final class ProcessLogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var messages: [String] {
        lock.withLock { storage }
    }

    func append(_ message: String) {
        lock.withLock { storage.append(message) }
    }
}
