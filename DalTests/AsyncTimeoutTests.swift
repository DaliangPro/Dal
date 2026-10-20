import XCTest
@testable import Dal

final class AsyncTimeoutTests: XCTestCase {
    private enum TestError: Error, Equatable {
        case operationFailed
        case timedOut
    }

    func testRunReturnsTrueWhenOperationCompletesBeforeDeadline() async {
        let completed = await AsyncTimeout.run(.milliseconds(200)) {}

        XCTAssertTrue(completed)
    }

    func testRunReturnsFalseWhenOperationTimesOut() async {
        let completed = await AsyncTimeout.run(.milliseconds(10)) {
            try await Task.sleep(for: .milliseconds(200))
        }

        XCTAssertFalse(completed)
    }

    func testValueReportsLoadedValue() async {
        let result: TimedValue<String> = await AsyncTimeout.value(.milliseconds(200)) {
            "loaded"
        }

        XCTAssertEqual(result.value, "loaded")
        XCTAssertFalse(result.timedOut)
    }

    func testValueReportsTimeout() async {
        let result: TimedValue<String> = await AsyncTimeout.value(.milliseconds(10)) {
            Thread.sleep(forTimeInterval: 0.2)
            return "late"
        }

        XCTAssertNil(result.value)
        XCTAssertTrue(result.timedOut)
    }

    func testThrowingValueReturnsOperationValue() async throws {
        let value = try await AsyncTimeout.throwingValue(
            .milliseconds(200),
            timeoutError: TestError.timedOut
        ) {
            "finished"
        }

        XCTAssertEqual(value, "finished")
    }

    func testThrowingValuePropagatesOperationError() async {
        do {
            let _: String = try await AsyncTimeout.throwingValue(
                .milliseconds(200),
                timeoutError: TestError.timedOut
            ) {
                throw TestError.operationFailed
            }
            XCTFail("应透传 operation 的原始错误")
        } catch let error as TestError {
            XCTAssertEqual(error, .operationFailed)
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }
    }

    func testThrowingValueThrowsAtDeadline() async {
        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            let _: String = try await AsyncTimeout.throwingValue(
                .milliseconds(30),
                timeoutError: TestError.timedOut
            ) {
                try await Task.sleep(for: .seconds(2))
                return "late"
            }
            XCTFail("应在截止时间抛出超时错误")
        } catch let error as TestError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }

        let elapsed = startedAt.duration(to: clock.now)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(20))
        XCTAssertLessThan(elapsed, .milliseconds(300))
    }

    func testThrowingValueDoesNotWaitForNonCooperativeOperation() async {
        let suspendedOperation = SuspendedOperation<Int>()
        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            let _: Int = try await AsyncTimeout.throwingValue(
                .milliseconds(30),
                timeoutError: TestError.timedOut
            ) {
                try await suspendedOperation.value()
            }
            XCTFail("挂起的 operation 不应阻止硬超时返回")
        } catch let error as TestError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }

        let elapsed = startedAt.duration(to: clock.now)
        XCTAssertLessThan(elapsed, .milliseconds(300))
        let hasWaiter = await suspendedOperation.hasWaiter
        XCTAssertTrue(hasWaiter)

        await suspendedOperation.resume(returning: 42)
    }

    func testThrowingValueIgnoresLateCompletionAfterTimeout() async {
        let suspendedOperation = SuspendedOperation<Int>()

        do {
            let _: Int = try await AsyncTimeout.throwingValue(
                .milliseconds(30),
                timeoutError: TestError.timedOut
            ) {
                try await suspendedOperation.value()
            }
            XCTFail("应先以超时结束")
        } catch let error as TestError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }

        await suspendedOperation.resume(returning: 42)
        try? await Task.sleep(for: .milliseconds(20))
        let hasWaiter = await suspendedOperation.hasWaiter
        XCTAssertFalse(hasWaiter)
    }

    func testThrowingValuePropagatesExternalCancellation() async {
        let suspendedOperation = SuspendedOperation<Int>()
        let task = Task {
            try await AsyncTimeout.throwingValue(
                .seconds(5),
                timeoutError: TestError.timedOut
            ) {
                try await suspendedOperation.value()
            }
        }

        await suspendedOperation.waitUntilSuspended()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("外部取消应向调用方传播 CancellationError")
        } catch is CancellationError {
            // 预期路径
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }

        await suspendedOperation.resume(returning: 42)
    }
}

private actor SuspendedOperation<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var suspensionObservers: [CheckedContinuation<Void, Never>] = []

    var hasWaiter: Bool {
        continuation != nil
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let observers = suspensionObservers
            suspensionObservers.removeAll()
            observers.forEach { $0.resume() }
        }
    }

    func waitUntilSuspended() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { continuation in
            suspensionObservers.append(continuation)
        }
    }

    func resume(returning value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
