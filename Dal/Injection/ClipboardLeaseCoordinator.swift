import AppKit
import Foundation

protocol ClipboardRestoreTask: AnyObject {
    func cancel()
}

protocol ClipboardRestoreScheduling: AnyObject {
    func schedule(
        after delay: TimeInterval,
        operation: @escaping () -> Void
    ) -> any ClipboardRestoreTask
}

private final class DispatchClipboardRestoreTask: ClipboardRestoreTask {
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

private final class DispatchClipboardRestoreScheduler: ClipboardRestoreScheduling {
    static let shared = DispatchClipboardRestoreScheduler()

    func schedule(
        after delay: TimeInterval,
        operation: @escaping () -> Void
    ) -> any ClipboardRestoreTask {
        let workItem = DispatchWorkItem(block: operation)
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
        return DispatchClipboardRestoreTask(workItem: workItem)
    }
}

/// 进程内所有 TextInjectionEngine 实例共享同一租约，确保重叠注入只保存首份原始快照。
final class ClipboardLeaseCoordinator: @unchecked Sendable {
    static let shared = ClipboardLeaseCoordinator()

    struct Ticket: Equatable {
        let generation: UInt64
        let pasteboardName: NSPasteboard.Name
    }

    private struct Lease {
        let pasteboardName: NSPasteboard.Name
        let originalSnapshot: TextInjectionEngine.ClipboardSnapshot
        var generation: UInt64
        var lastInjectedText: String
        var expectedChangeCount: Int
        var pendingRestore: (any ClipboardRestoreTask)?
    }

    private let stateLock = NSLock()
    private let injectionLock = NSRecursiveLock()
    private let scheduler: any ClipboardRestoreScheduling
    private let logger: (String) -> Void
    private var nextGeneration: UInt64 = 0
    private var lease: Lease?

    init(
        scheduler: (any ClipboardRestoreScheduling)? = nil,
        logger: @escaping (String) -> Void = DebugFileLogger.log
    ) {
        self.scheduler = scheduler ?? DispatchClipboardRestoreScheduler.shared
        self.logger = logger
    }

    var hasActiveLease: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lease != nil
    }

    /// 将进程内“临时写入 → Cmd+V → 注册恢复”串成单一事务，避免并发 engine 互相粘贴错文本。
    func performInjectionTransaction<Result>(
        _ operation: () throws -> Result
    ) rethrows -> Result {
        injectionLock.lock()
        defer { injectionLock.unlock() }
        return try operation()
    }

    /// 捕获或复用唯一原始快照，并在同一把锁内完成 generation 更新与 transient 写入。
    func stageInjection(
        text: String,
        on pasteboard: NSPasteboard,
        write: () -> Void
    ) -> Ticket {
        var taskToCancel: (any ClipboardRestoreTask)?
        var abandonedPreviousLease = false
        stateLock.lock()

        if let activeLease = lease,
           activeLease.pasteboardName != pasteboard.name
            || !clipboardIsStillOwned(by: activeLease, on: pasteboard) {
            taskToCancel = activeLease.pendingRestore
            lease = nil
            abandonedPreviousLease = true
        }

        let originalSnapshot: TextInjectionEngine.ClipboardSnapshot
        if let activeLease = lease {
            taskToCancel = activeLease.pendingRestore
            originalSnapshot = activeLease.originalSnapshot
        } else {
            originalSnapshot = TextInjectionEngine.ClipboardSnapshot.capture(
                from: pasteboard,
                logger: logger
            )
        }

        nextGeneration &+= 1
        if nextGeneration == 0 {
            // 2^64 次注入才可能发生；保留 0 作为无效代，避免与默认值混淆。
            nextGeneration &+= 1
        }
        let generation = nextGeneration

        write()
        let ticket = Ticket(generation: generation, pasteboardName: pasteboard.name)
        lease = Lease(
            pasteboardName: pasteboard.name,
            originalSnapshot: originalSnapshot,
            generation: generation,
            lastInjectedText: text,
            expectedChangeCount: pasteboard.changeCount,
            pendingRestore: nil
        )
        stateLock.unlock()

        // generation 已先失效；cancel 只负责节省迟到工作，不能作为正确性边界。
        taskToCancel?.cancel()
        if abandonedPreviousLease {
            logger("clipboard lease: abandon previous lease before new injection")
        }
        return ticket
    }

    func scheduleRestore(
        for ticket: Ticket,
        on pasteboard: NSPasteboard,
        after delay: TimeInterval
    ) {
        var previousTask: (any ClipboardRestoreTask)?
        stateLock.lock()
        guard leaseMatches(ticket) else {
            stateLock.unlock()
            return
        }
        previousTask = lease?.pendingRestore
        lease?.pendingRestore = nil
        stateLock.unlock()
        previousTask?.cancel()

        // 调度器是可注入边界，严禁持 stateLock 调用；即使同步执行回调也不会重入死锁。
        let task = scheduler.schedule(after: delay) { [weak self] in
            self?.performRestore(for: ticket, on: pasteboard)
        }

        var displacedTask: (any ClipboardRestoreTask)?
        var registered = false
        stateLock.lock()
        if leaseMatches(ticket) {
            displacedTask = lease?.pendingRestore
            lease?.pendingRestore = task
            registered = true
        }
        stateLock.unlock()

        displacedTask?.cancel()
        if !registered {
            task.cancel()
        }
    }

    /// 粘贴失败或永久复制时仅允许当前 generation 放弃；迟到旧代不能清理新租约。
    func abandon(_ ticket: Ticket) {
        var taskToCancel: (any ClipboardRestoreTask)?
        stateLock.lock()
        guard leaseMatches(ticket) else {
            stateLock.unlock()
            return
        }
        taskToCancel = lease?.pendingRestore
        lease = nil
        stateLock.unlock()
        taskToCancel?.cancel()
    }

    /// 在同一进程级事务中失效租约并永久写入，迟到旧任务只能看到无匹配 generation。
    func writePermanently(on pasteboard: NSPasteboard, write: () -> Void) {
        performInjectionTransaction {
            var taskToCancel: (any ClipboardRestoreTask)?
            stateLock.lock()
            if lease?.pasteboardName == pasteboard.name {
                taskToCancel = lease?.pendingRestore
                lease = nil
            }
            write()
            stateLock.unlock()
            taskToCancel?.cancel()
        }
    }

    func writeTextPermanently(
        _ text: String,
        on pasteboard: NSPasteboard = .general
    ) {
        writePermanently(on: pasteboard) {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    private func performRestore(for ticket: Ticket, on pasteboard: NSPasteboard) {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard let activeLease = lease, leaseMatches(ticket) else { return }
        _ = activeLease.originalSnapshot.restore(
            expectedChangeCount: activeLease.expectedChangeCount,
            injectedText: activeLease.lastInjectedText,
            on: pasteboard,
            logger: logger
        )
        // 无论恢复成功、第三方内容导致放弃，还是原快照不可恢复，都结束当前租约。
        lease = nil
    }

    private func leaseMatches(_ ticket: Ticket) -> Bool {
        lease?.generation == ticket.generation
            && lease?.pasteboardName == ticket.pasteboardName
    }

    private func clipboardIsStillOwned(
        by activeLease: Lease,
        on pasteboard: NSPasteboard
    ) -> Bool {
        pasteboard.changeCount == activeLease.expectedChangeCount
            || pasteboard.string(forType: .string) == activeLease.lastInjectedText
    }
}
