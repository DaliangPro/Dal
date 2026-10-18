import Foundation

enum TerminologyHistoryTransactionError: LocalizedError {
    case rollbackFailed(operation: String, rollback: String)
    case correctionChanged

    var errorDescription: String? {
        switch self {
        case .correctionChanged:
            return L("这条纠正记录已更新，请到记录中检查", "This correction has changed; check History")
        case .rollbackFailed(let operation, let rollback):
            return L(
                "操作失败，术语证据回滚也失败。原始错误：\(operation)；回滚错误：\(rollback)",
                "The operation failed, and terminology evidence rollback also failed. Original error: \(operation); rollback error: \(rollback)"
            )
        }
    }
}

/// 串行协调“术语 JSON + 历史 SQLite”的复合操作。
///
/// Swift actor 在 `await` 处默认可重入，因此这里额外使用 FIFO 门闩；后一项操作
/// 会等前一项完成补偿后才开始。协调器不回调 MainActor，UI 只在方法返回后刷新，
/// 避免跨 actor 持锁等待界面而形成死锁。
actor TerminologyHistoryTransactionCoordinator {
    static let shared = TerminologyHistoryTransactionCoordinator()

    private let context: VocabularyStorageContext
    private var isOperationActive = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(context: VocabularyStorageContext = .production) {
        self.context = context
    }

    @discardableResult
    func confirmCorrection(
        historyStore: HistoryStore,
        historyID: String,
        candidates: [TerminologyCorrectionCandidate],
        correctedText: String,
        scene: WritingScene,
        personalizationEnabled: Bool,
        retentionLimit: Int,
        learnStyle: Bool,
        learnTerminology: Bool,
        expectedUncorrectedHistory: HistoryRecord? = nil
    ) async throws -> VoicePolishCorrectionRecord {
        await acquireExclusiveOperation()
        defer { releaseExclusiveOperation() }

        // 延后点击的候选不能覆盖已更新、已纠正或已删除的历史。
        if let expectedUncorrectedHistory {
            let current = try await historyStore.fetchOrThrow(ids: [historyID]).first
            let alreadyCorrected = try await historyStore.fetchVoicePolishCorrections().contains { $0.historyID == historyID }
            guard current == expectedUncorrectedHistory, !alreadyCorrected else {
                throw TerminologyHistoryTransactionError.correctionChanged
            }
        }

        let snapshot = try TerminologyRepository.evidenceSnapshot(
            sourceRecordID: historyID,
            context: context
        )
        _ = try TerminologyRepository.replaceEvidence(
            sourceRecordID: historyID,
            with: candidates,
            context: context
        )

        do {
            return try await historyStore.confirmVoicePolishCorrection(
                historyID: historyID,
                correctedText: correctedText,
                scene: scene,
                personalizationEnabled: personalizationEnabled,
                retentionLimit: retentionLimit,
                learnStyle: learnStyle,
                learnTerminology: learnTerminology
            )
        } catch let operationError {
            try restoreEvidence(snapshot, after: operationError)
            throw operationError
        }
    }

    func deleteHistory(
        historyStore: HistoryStore,
        historyID: String
    ) async throws {
        await acquireExclusiveOperation()
        defer { releaseExclusiveOperation() }

        let snapshot = try TerminologyRepository.evidenceSnapshot(
            sourceRecordID: historyID,
            context: context
        )
        let removedEvidence = try TerminologyRepository.removeEvidence(
            sourceRecordID: historyID,
            context: context
        )
        do {
            try await historyStore.deleteOrThrow(id: historyID)
        } catch let operationError {
            if removedEvidence {
                try restoreEvidence(snapshot, after: operationError)
            }
            throw operationError
        }
    }

    func undoCorrection(
        historyStore: HistoryStore,
        historyID: String,
        expectedCorrection: VoicePolishCorrectionRecord? = nil
    ) async throws {
        await acquireExclusiveOperation()
        defer { releaseExclusiveOperation() }

        if let expectedCorrection {
            let current = try await historyStore.fetchVoicePolishCorrections().first { $0.historyID == historyID }
            guard current?.id == expectedCorrection.id else {
                throw TerminologyHistoryTransactionError.correctionChanged
            }
        }
        let snapshot = try TerminologyRepository.evidenceSnapshot(
            sourceRecordID: historyID,
            context: context
        )
        let removedEvidence = try TerminologyRepository.removeEvidence(
            sourceRecordID: historyID,
            context: context
        )
        do {
            try await historyStore.deleteVoicePolishCorrection(historyID: historyID)
        } catch let operationError {
            if removedEvidence {
                try restoreEvidence(snapshot, after: operationError)
            }
            throw operationError
        }
    }

    private func restoreEvidence(
        _ snapshot: TerminologyEvidenceSnapshot,
        after operationError: Error
    ) throws {
        do {
            try TerminologyRepository.restoreEvidence(snapshot, context: context)
        } catch let rollbackError {
            throw TerminologyHistoryTransactionError.rollbackFailed(
                operation: operationError.localizedDescription,
                rollback: rollbackError.localizedDescription
            )
        }
    }

    private func acquireExclusiveOperation() async {
        guard isOperationActive else {
            isOperationActive = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func releaseExclusiveOperation() {
        guard !waiters.isEmpty else {
            isOperationActive = false
            return
        }
        waiters.removeFirst().resume()
    }
}
