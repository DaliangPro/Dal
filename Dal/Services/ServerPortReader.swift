import Foundation

/// 按行增量解析本地服务输出的 `PORT:<number>` 标记。
///
/// Pipe 的数据块边界与文本行边界无关，因此必须保留未换行的尾部，
/// 直到收到换行符后才尝试解析。
struct PortLineParser {
    private static let marker = Data("PORT:".utf8)

    private var pending = Data()

    mutating func feed(_ data: Data) -> Int? {
        pending.append(data)

        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            var line = Data(pending[..<newlineIndex])
            let nextLineIndex = pending.index(after: newlineIndex)
            pending.removeSubrange(..<nextLineIndex)

            // 兼容 Python 在特定环境下输出的 CRLF。
            if line.last == 0x0D {
                line.removeLast()
            }

            guard line.starts(with: Self.marker) else { continue }

            let portBytes = line.dropFirst(Self.marker.count)
            guard !portBytes.isEmpty else { continue }

            var port = 0
            var isValid = true
            for byte in portBytes {
                guard (0x30...0x39).contains(byte) else {
                    isValid = false
                    break
                }
                port = port * 10 + Int(byte - 0x30)
                guard port <= 65_535 else {
                    isValid = false
                    break
                }
            }

            if isValid, (1...65_535).contains(port) {
                return port
            }
        }

        return nil
    }
}

enum ServerPortReader {
    static func discoverPort(from pipe: Pipe, timeout: Duration) async -> Int? {
        await withCheckedContinuation { continuation in
            let handle = pipe.fileHandleForReading
            let state = ServerPortReadState(
                handle: handle,
                continuation: continuation
            )

            handle.readabilityHandler = { readableHandle in
                state.consume(readableHandle.availableData)
            }

            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                state.resolve(nil)
            }
            state.installTimeoutTask(timeoutTask)
        }
    }
}

private final class ServerPortReadState: @unchecked Sendable {
    private struct Completion {
        let continuation: CheckedContinuation<Int?, Never>
        let result: Int?
        let timeoutTask: Task<Void, Never>?
    }

    private let lock = NSLock()
    private let handle: FileHandle
    private var parser = PortLineParser()
    private var continuation: CheckedContinuation<Int?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var isResolved = false

    init(
        handle: FileHandle,
        continuation: CheckedContinuation<Int?, Never>
    ) {
        self.handle = handle
        self.continuation = continuation
    }

    func installTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        if isResolved {
            lock.unlock()
            task.cancel()
            return
        }
        timeoutTask = task
        lock.unlock()
    }

    func consume(_ data: Data) {
        let completion: Completion?

        lock.lock()
        if isResolved {
            completion = nil
        } else if data.isEmpty {
            completion = claimCompletion(result: nil)
        } else if let port = parser.feed(data) {
            completion = claimCompletion(result: port)
        } else {
            completion = nil
        }
        lock.unlock()

        complete(completion)
    }

    func resolve(_ result: Int?) {
        lock.lock()
        let completion = claimCompletion(result: result)
        lock.unlock()

        complete(completion)
    }

    /// 调用时必须已持有 `lock`。
    private func claimCompletion(result: Int?) -> Completion? {
        guard !isResolved, let continuation else { return nil }

        isResolved = true
        self.continuation = nil
        let task = timeoutTask
        timeoutTask = nil
        return Completion(
            continuation: continuation,
            result: result,
            timeoutTask: task
        )
    }

    private func complete(_ completion: Completion?) {
        guard let completion else { return }

        // 在 continuation 恢复前先摘除 handler，使调用方看到的状态已经收敛。
        handle.readabilityHandler = nil
        completion.timeoutTask?.cancel()
        completion.continuation.resume(returning: completion.result)
    }
}
