import Darwin
import Foundation
import os

struct ServerProcessIdentity: Codable, Equatable, Sendable {
    let kind: String
    let pid: Int32
    let executablePath: String
    let startTimeSeconds: UInt64
}

struct ServerProcessSnapshot: Equatable, Sendable {
    let pid: Int32
    let executablePath: String
    let startTimeSeconds: UInt64
}

enum ServerProcessTerminationResult: Equatable, Sendable {
    case alreadyExited
    case terminatedGracefully
    case killed
    case refused
    case failed
}

enum ServerProcessIdentityValidation: Equatable, Sendable {
    case matching
    case notRunning
    case unreadable
    case mismatchedKind
    case mismatchedPath
    case mismatchedStartTime
}

enum ServerProcessIdentityLedger {
    static func encode(_ identities: [ServerProcessIdentity]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(identities)
    }

    static func decode(
        _ data: Data,
        log: @Sendable (String) -> Void = { _ in }
    ) -> [ServerProcessIdentity] {
        guard !data.isEmpty else { return [] }
        do {
            return try JSONDecoder().decode([ServerProcessIdentity].self, from: data)
        } catch {
            log("PID 身份文件损坏，已安全忽略：\(error.localizedDescription)")
            return []
        }
    }
}

/// 在进程启动前绑定到 terminationHandler，允许 stop 在 Actor 外异步等待退出。
final class ServerProcessExitLatch: @unchecked Sendable {
    private struct Waiter {
        let continuation: CheckedContinuation<Bool, Never>
        var timeoutTask: Task<Void, Never>?
    }

    private struct State {
        var exited = false
        var waiters: [UUID: Waiter] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func signal() {
        let waiters = state.withLock { state -> [Waiter] in
            guard !state.exited else { return [] }
            state.exited = true
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return waiters
        }
        waiters.forEach {
            $0.timeoutTask?.cancel()
            $0.continuation.resume(returning: true)
        }
    }

    func wait(timeout: Duration) async -> Bool {
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state -> Bool in
                guard !state.exited else { return true }
                state.waiters[waiterID] = Waiter(
                    continuation: continuation,
                    timeoutTask: nil
                )
                return false
            }
            if shouldResume {
                continuation.resume(returning: true)
                return
            }

            let timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self?.timeout(waiterID)
            }
            installTimeoutTask(timeoutTask, waiterID: waiterID)
        }
    }

    private func installTimeoutTask(_ task: Task<Void, Never>, waiterID: UUID) {
        let shouldCancel = state.withLock { state -> Bool in
            guard var waiter = state.waiters[waiterID] else { return true }
            waiter.timeoutTask = task
            state.waiters[waiterID] = waiter
            return false
        }
        if shouldCancel { task.cancel() }
    }

    private func timeout(_ waiterID: UUID) {
        let waiter = state.withLock { state in
            state.waiters.removeValue(forKey: waiterID)
        }
        waiter?.continuation.resume(returning: false)
    }
}

enum ServerProcessController {
    typealias LogHandler = @Sendable (String) -> Void

    static func captureIdentity(kind: String, pid: Int32) -> ServerProcessIdentity? {
        guard let snapshot = captureSnapshot(pid: pid) else { return nil }
        return ServerProcessIdentity(
            kind: kind,
            pid: pid,
            executablePath: snapshot.executablePath,
            startTimeSeconds: snapshot.startTimeSeconds
        )
    }

    static func captureSnapshot(pid: Int32) -> ServerProcessSnapshot? {
        guard isSafeTarget(pid), kill(pid, 0) == 0 else { return nil }
        guard let firstInfo = readBSDInfo(pid: pid), !isZombie(firstInfo) else { return nil }

        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return nil }
        let executablePath = String(cString: pathBuffer)

        guard let secondInfo = readBSDInfo(pid: pid), !isZombie(secondInfo) else { return nil }
        guard firstInfo.pbi_pid == UInt32(pid), secondInfo.pbi_pid == UInt32(pid) else {
            return nil
        }
        guard firstInfo.pbi_start_tvsec == secondInfo.pbi_start_tvsec else { return nil }

        return ServerProcessSnapshot(
            pid: pid,
            executablePath: executablePath,
            startTimeSeconds: secondInfo.pbi_start_tvsec
        )
    }

    static func matches(
        _ identity: ServerProcessIdentity,
        expectedKind: String,
        log: LogHandler = { _ in }
    ) -> Bool {
        switch validate(identity, expectedKind: expectedKind) {
        case .matching:
            return true
        case .notRunning:
            log("拒绝终止进程：PID 已退出")
        case .unreadable:
            log("拒绝终止进程：无法读取当前进程身份")
        case .mismatchedKind:
            log("拒绝终止进程：identity kind 不匹配")
        case .mismatchedPath:
            log("拒绝终止进程：identity path 不匹配")
        case .mismatchedStartTime:
            log("拒绝终止进程：identity start time 不匹配")
        }
        return false
    }

    static func validate(
        _ identity: ServerProcessIdentity,
        expectedKind: String
    ) -> ServerProcessIdentityValidation {
        guard identity.kind == expectedKind else { return .mismatchedKind }
        guard isSafeTarget(identity.pid) else { return .mismatchedPath }

        if kill(identity.pid, 0) != 0 {
            return errno == ESRCH ? .notRunning : .unreadable
        }
        guard let snapshot = captureSnapshot(pid: identity.pid) else {
            return kill(identity.pid, 0) == 0 ? .unreadable : .notRunning
        }
        guard snapshot.executablePath == identity.executablePath else {
            return .mismatchedPath
        }
        guard snapshot.startTimeSeconds == identity.startTimeSeconds else {
            return .mismatchedStartTime
        }
        return .matching
    }

    static func sendSignal(
        _ signal: Int32,
        identity: ServerProcessIdentity,
        expectedKind: String,
        log: LogHandler = { _ in }
    ) -> Bool {
        guard matches(identity, expectedKind: expectedKind, log: log) else { return false }
        guard kill(identity.pid, signal) == 0 else {
            log("向已验证进程发送信号 \(signal) 失败：errno=\(errno)")
            return false
        }
        return true
    }

    static func terminate(
        process: Process,
        identity: ServerProcessIdentity,
        expectedKind: String,
        exitLatch suppliedLatch: ServerProcessExitLatch? = nil,
        gracefulTimeout: Duration = .seconds(3),
        forceTimeout: Duration = .seconds(1),
        log: @escaping LogHandler = { _ in }
    ) async -> ServerProcessTerminationResult {
        guard process.processIdentifier == identity.pid else {
            log("拒绝终止进程：Process PID 与 identity 不匹配")
            return .refused
        }
        guard process.isRunning else { return .alreadyExited }
        guard matches(identity, expectedKind: expectedKind, log: log) else {
            return process.isRunning ? .refused : .alreadyExited
        }

        let latch: ServerProcessExitLatch
        if let suppliedLatch {
            latch = suppliedLatch
        } else {
            latch = ServerProcessExitLatch()
            let previousHandler = process.terminationHandler
            process.terminationHandler = { terminatedProcess in
                latch.signal()
                previousHandler?(terminatedProcess)
            }
            if !process.isRunning {
                latch.signal()
                return .alreadyExited
            }
        }

        guard sendSignal(
            SIGTERM,
            identity: identity,
            expectedKind: expectedKind,
            log: log
        ) else {
            return process.isRunning ? .failed : .alreadyExited
        }

        if await waitForExit(process: process, latch: latch, timeout: gracefulTimeout) {
            return .terminatedGracefully
        }

        // 等待期间 PID 可能已退出并被复用，SIGKILL 前必须完整重验。
        guard process.isRunning else { return .terminatedGracefully }
        guard matches(identity, expectedKind: expectedKind, log: log) else {
            return process.isRunning ? .refused : .terminatedGracefully
        }
        guard sendSignal(
            SIGKILL,
            identity: identity,
            expectedKind: expectedKind,
            log: log
        ) else {
            return process.isRunning ? .failed : .terminatedGracefully
        }

        return await waitForExit(process: process, latch: latch, timeout: forceTimeout)
            ? .killed
            : .failed
    }

    /// 回收没有 Foundation `Process` 引用的崩溃遗留进程；等待采用异步轮询，
    /// 每次升级信号前仍执行完整 path/start-time 重验。
    static func terminate(
        identity: ServerProcessIdentity,
        expectedKind: String,
        gracefulTimeout: Duration = .seconds(3),
        forceTimeout: Duration = .seconds(1),
        log: @escaping LogHandler = { _ in }
    ) async -> ServerProcessTerminationResult {
        switch validate(identity, expectedKind: expectedKind) {
        case .matching:
            break
        case .notRunning, .mismatchedPath, .mismatchedStartTime:
            return .alreadyExited
        case .unreadable, .mismatchedKind:
            _ = matches(identity, expectedKind: expectedKind, log: log)
            return .refused
        }
        guard sendSignal(
            SIGTERM,
            identity: identity,
            expectedKind: expectedKind,
            log: log
        ) else {
            switch validate(identity, expectedKind: expectedKind) {
            case .notRunning, .mismatchedPath, .mismatchedStartTime:
                return .alreadyExited
            case .matching, .unreadable, .mismatchedKind:
                return .failed
            }
        }

        if await waitUntilIdentityChanges(
            identity,
            expectedKind: expectedKind,
            timeout: gracefulTimeout
        ) {
            return .terminatedGracefully
        }

        switch validate(identity, expectedKind: expectedKind) {
        case .matching:
            break
        case .notRunning, .mismatchedPath, .mismatchedStartTime:
            return .terminatedGracefully
        case .unreadable, .mismatchedKind:
            _ = matches(identity, expectedKind: expectedKind, log: log)
            return .refused
        }
        guard sendSignal(
            SIGKILL,
            identity: identity,
            expectedKind: expectedKind,
            log: log
        ) else {
            switch validate(identity, expectedKind: expectedKind) {
            case .notRunning, .mismatchedPath, .mismatchedStartTime:
                return .terminatedGracefully
            case .matching, .unreadable, .mismatchedKind:
                return .failed
            }
        }

        return await waitUntilIdentityChanges(
            identity,
            expectedKind: expectedKind,
            timeout: forceTimeout
        ) ? .killed : .failed
    }

    private static func waitForExit(
        process: Process,
        latch: ServerProcessExitLatch,
        timeout: Duration
    ) async -> Bool {
        if !process.isRunning { return true }
        let signaled = await latch.wait(timeout: timeout)
        return signaled || !process.isRunning
    }

    private static func waitUntilIdentityChanges(
        _ identity: ServerProcessIdentity,
        expectedKind: String,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            switch validate(identity, expectedKind: expectedKind) {
            case .notRunning, .mismatchedPath, .mismatchedStartTime:
                return true
            case .matching, .unreadable, .mismatchedKind:
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        switch validate(identity, expectedKind: expectedKind) {
        case .notRunning, .mismatchedPath, .mismatchedStartTime:
            return true
        case .matching, .unreadable, .mismatchedKind:
            return false
        }
    }

    private static func readBSDInfo(pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let result = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(expectedSize)
        )
        guard result == Int32(expectedSize) else { return nil }
        return info
    }

    private static func isSafeTarget(_ pid: Int32) -> Bool {
        pid > 1 && pid != getpid()
    }

    private static func isZombie(_ info: proc_bsdinfo) -> Bool {
        info.pbi_status == UInt32(SZOMB)
    }
}
