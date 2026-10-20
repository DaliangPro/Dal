import Foundation
import os

struct TimedValue<T: Sendable>: Sendable {
    let value: T?
    let timedOut: Bool
}

private struct AsyncTimeoutExpired: Error {}

/// 协调 operation、计时器和调用方取消，只允许一个终态恢复 continuation。
private final class AsyncTimeoutCompletion<Value: Sendable>: @unchecked Sendable {
    private struct State {
        var isCompleted = false
        var continuation: CheckedContinuation<Value, Error>?
        var deferredResult: Result<Value, Error>?
        var operationTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// 返回 false 表示取消或其他终态先于 continuation 安装发生，调用方无需再启动任务。
    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        let installation: (shouldStart: Bool, deferredResult: Result<Value, Error>?) = state.withLock { state -> (
            shouldStart: Bool,
            deferredResult: Result<Value, Error>?
        ) in
            guard state.isCompleted else {
                state.continuation = continuation
                return (true, nil)
            }
            let deferredResult = state.deferredResult
            state.deferredResult = nil
            return (false, deferredResult)
        }

        if !installation.shouldStart {
            // 只有「调用方在 continuation 安装前已取消」会走这里。
            continuation.resume(with: installation.deferredResult ?? .failure(CancellationError()))
        }
        return installation.shouldStart
    }

    func registerOperationTask(_ task: Task<Void, Never>) {
        let shouldCancel = state.withLock { state in
            guard !state.isCompleted else { return true }
            state.operationTask = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    func registerTimeoutTask(_ task: Task<Void, Never>) {
        let shouldCancel = state.withLock { state in
            guard !state.isCompleted else { return true }
            state.timeoutTask = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    func finish(
        with result: Result<Value, Error>,
        cancelOperation: Bool = false,
        cancelTimeout: Bool = false
    ) {
        let completion = state.withLock { state -> (
            didWin: Bool,
            continuation: CheckedContinuation<Value, Error>?,
            operationTask: Task<Void, Never>?,
            timeoutTask: Task<Void, Never>?
        ) in
            guard !state.isCompleted else { return (false, nil, nil, nil) }
            state.isCompleted = true
            let continuation = state.continuation
            state.continuation = nil
            if continuation == nil {
                state.deferredResult = result
            }
            let operationTask = cancelOperation ? state.operationTask : nil
            let timeoutTask = cancelTimeout ? state.timeoutTask : nil
            state.operationTask = nil
            state.timeoutTask = nil
            return (true, continuation, operationTask, timeoutTask)
        }

        guard completion.didWin else { return }
        completion.operationTask?.cancel()
        completion.timeoutTask?.cancel()
        completion.continuation?.resume(with: result)
    }
}

enum AsyncTimeout {
    /// 执行 throwing operation，并保证超时或外部取消后立即恢复调用方。
    /// operation 使用 detached task；即使底层不响应 cancellation，调用方也不会等待它退出。
    static func throwingValue<T: Sendable>(
        _ duration: Duration,
        timeoutError: @autoclosure @Sendable () -> Error,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()

        let timeoutFailure = timeoutError()
        let completion = AsyncTimeoutCompletion<T>()
        let priority = Task.currentPriority

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard completion.install(continuation) else { return }

                let operationTask = Task.detached(priority: priority) {
                    do {
                        let value = try await operation()
                        completion.finish(with: .success(value), cancelTimeout: true)
                    } catch {
                        completion.finish(with: .failure(error), cancelTimeout: true)
                    }
                }
                completion.registerOperationTask(operationTask)

                let timeoutTask = Task.detached(priority: priority) {
                    do {
                        try await Task.sleep(for: duration)
                    } catch {
                        return
                    }
                    completion.finish(
                        with: .failure(timeoutFailure),
                        cancelOperation: true
                    )
                }
                completion.registerTimeoutTask(timeoutTask)
            }
        } onCancel: {
            completion.finish(
                with: .failure(CancellationError()),
                cancelOperation: true,
                cancelTimeout: true
            )
        }
    }

    /// Run a closure with a hard deadline.
    /// Returns false if the operation throws or exceeds the deadline.
    static func run(
        _ duration: Duration,
        operation: @Sendable @escaping () async throws -> Void
    ) async -> Bool {
        do {
            try await throwingValue(
                duration,
                timeoutError: AsyncTimeoutExpired(),
                operation: operation
            )
            return true
        } catch {
            return false
        }
    }

    /// Run an async value producer with a hard deadline（REPAIR_PLAN J12）。
    /// 超时返回 `TimedValue(value: nil, timedOut: true)` 并取消底层任务。
    static func asyncValue<T: Sendable>(
        _ duration: Duration,
        operation: @Sendable @escaping () async -> T?
    ) async -> TimedValue<T> {
        do {
            let value = try await throwingValue(
                duration,
                timeoutError: AsyncTimeoutExpired()
            ) {
                await operation()
            }
            return TimedValue(value: value, timedOut: false)
        } catch {
            return TimedValue(value: nil, timedOut: true)
        }
    }

    /// Run a synchronous value loader off-actor with a hard deadline.
    static func value<T: Sendable>(
        _ duration: Duration,
        operation: @Sendable @escaping () -> T?
    ) async -> TimedValue<T> {
        do {
            let value = try await throwingValue(
                duration,
                timeoutError: AsyncTimeoutExpired()
            ) {
                operation()
            }
            return TimedValue(value: value, timedOut: false)
        } catch {
            return TimedValue(value: nil, timedOut: true)
        }
    }
}
