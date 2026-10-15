import Foundation

enum TerminologyRepositoryError: Error, LocalizedError {
    case unsupportedSchemaVersion(Int)
    case recoveryRequired(URL)
    case entryNotFound(UUID)
    case invalidEntry
    case builtInReadOnly
    case rollbackFailed(operation: Error, rollback: Error)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return L(
                "术语文件版本过新（\(version)），当前 Muse 无法安全写入",
                "Terminology schema \(version) is newer than this Muse version"
            )
        case .recoveryRequired(let url):
            return L(
                "请先恢复或处理词库备份 \(url.lastPathComponent)",
                "Restore or resolve vocabulary backup \(url.lastPathComponent) first"
            )
        case .entryNotFound(let id):
            return L("没有找到术语 \(id.uuidString)", "Terminology entry not found: \(id.uuidString)")
        case .invalidEntry:
            return L("标准写法、错误写法和来源记录不能为空", "Canonical text, alias and source record are required")
        case .builtInReadOnly:
            return L("内置术语正文为只读，只能启用或停用", "Built-in terminology is read-only and can only be enabled or disabled")
        case .rollbackFailed(let operation, let rollback):
            return L(
                "术语保存失败，且回滚未完整完成：\(operation.localizedDescription)；回滚：\(rollback.localizedDescription)",
                "Terminology save failed and rollback was incomplete: \(operation.localizedDescription); rollback: \(rollback.localizedDescription)"
            )
        }
    }
}

struct TerminologyRepositorySnapshot: Sendable, Equatable {
    let myTerms: [TerminologyEntry]
    let builtInTerms: [TerminologyEntry]
    let conflicts: [TerminologyConflict]
    let projections: TerminologyProjectionBundle
}

/// 单条历史记录在术语库中的证据快照。只用于跨 JSON / SQLite 操作失败后的
/// 增量补偿，不把整份术语文档回写覆盖其他已经成功的修改。
struct TerminologyEvidenceSnapshot: Sendable {
    let sourceRecordID: String
    fileprivate let document: TerminologyDocument
}

enum TerminologyRepository {
    private static let lock = NSRecursiveLock()

    static func fileURL(in context: VocabularyStorageContext = .production) -> URL {
        context.supportDirectory.appendingPathComponent("terminology.json")
    }

    /// 只反映统一术语文件自身的状态；兼容窗口的旧文件回流由 `load` 负责。
    static func loadResult(
        context: VocabularyStorageContext = .production
    ) -> JSONFileReadResult<TerminologyDocument> {
        lock.lock()
        defer { lock.unlock() }
        return storedDocumentResult(context: context).map(TerminologyDocumentNormalizer.normalized)
    }

    /// 兼容窗口 read-through：统一文件优先，同时临时合并旧词典中新出现且未被屏蔽的术语。
    /// 读取不会自动落盘或推进迁移版本，避免一次普通 UI 打开触发不可见的数据迁移。
    static func load(context: VocabularyStorageContext = .production) -> TerminologyDocument {
        lock.lock()
        defer { lock.unlock() }
        let stored: TerminologyDocument
        switch storedDocumentResult(context: context) {
        case .value(let document):
            stored = TerminologyDocumentNormalizer.normalized(document)
        case .missing, .corrupt:
            stored = .empty
        }
        return (try? TerminologyMigration.readThrough(stored, context: context)) ?? stored
    }

    static func save(
        _ document: TerminologyDocument,
        context: VocabularyStorageContext = .production,
        compatibilityHooks: TerminologyCompatibilityProjectionHooks = .live
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        let previousEffective = load(context: context)

        let storedBefore: TerminologyDocument?
        let storedMigrationVersion: Int
        switch storedDocumentResult(context: context) {
        case .missing:
            storedBefore = nil
            storedMigrationVersion = 0
        case .value(let stored):
            guard stored.schemaVersion <= TerminologyDocument.currentSchemaVersion else {
                throw TerminologyRepositoryError.unsupportedSchemaVersion(stored.schemaVersion)
            }
            let normalizedStored = TerminologyDocumentNormalizer.normalized(stored)
            storedBefore = normalizedStored
            storedMigrationVersion = normalizedStored.migrationVersion
        case .corrupt(let url, _):
            throw TerminologyRepositoryError.recoveryRequired(url)
        }

        var normalized = TerminologyDocumentNormalizer.normalized(document)
        normalized.migrationVersion = max(normalized.migrationVersion, storedMigrationVersion)
        try validateBuiltInContent(previous: previousEffective, proposed: normalized)
        try writeStoredDocument(normalized, context: context)
        do {
            try TerminologyMigration.writeCompatibilityProjections(
                normalized,
                context: context,
                hooks: compatibilityHooks
            )
        } catch {
            // 统一文件先写入、兼容投影后写入。投影内部会恢复旧文件；
            // 这里同步恢复唯一事实来源，让调用方看到失败时不会留下半完成修改。
            let rollbackDocument = storedBefore ?? previousEffective
            do {
                try writeStoredDocument(rollbackDocument, context: context)
            } catch let rollbackError {
                throw TerminologyRepositoryError.rollbackFailed(
                    operation: error,
                    rollback: rollbackError
                )
            }
            throw error
        }
    }

    @discardableResult
    static func migrateIfNeeded(
        context: VocabularyStorageContext = .production,
        hooks: TerminologyMigrationHooks = .live
    ) throws -> TerminologyMigrationOutcome {
        lock.lock()
        defer { lock.unlock() }
        return try TerminologyMigration.migrateIfNeeded(context: context, hooks: hooks)
    }

    static func upsert(
        _ entry: TerminologyEntry,
        context: VocabularyStorageContext = .production
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        var document = load(context: context)
        if entry.origin == .builtIn
            || document.entries.contains(where: {
                $0.origin == .builtIn
                    && $0.id == entry.id
            }) {
            throw TerminologyRepositoryError.builtInReadOnly
        }
        if let index = document.entries.firstIndex(where: { $0.id == entry.id }) {
            document.entries[index] = entry
        } else {
            document.entries.append(entry)
        }
        try save(document, context: context)
    }

    /// 用户明确纠正一次即生效，并记录 historyID 以支持语义完整的撤销。
    @discardableResult
    static func confirmCorrection(
        alias rawAlias: String,
        canonical rawCanonical: String,
        sourceRecordID rawSourceRecordID: String,
        context: VocabularyStorageContext = .production
    ) throws -> TerminologyEntry {
        try addConfirmedEvidence(
            alias: rawAlias,
            canonical: rawCanonical,
            sourceRecordID: rawSourceRecordID,
            context: context
        )
    }

    /// 为一条历史记录增量添加一组已确认术语证据。
    ///
    /// 这个 API 不会移除同一 historyID 已有的其他术语；只有
    /// `replaceEvidence` 表示“以本次完整候选集替换旧集合”。
    @discardableResult
    static func addConfirmedEvidence(
        alias rawAlias: String,
        canonical rawCanonical: String,
        sourceRecordID rawSourceRecordID: String,
        scope: TerminologyScope = .global,
        context: VocabularyStorageContext = .production
    ) throws -> TerminologyEntry {
        try addConfirmedEvidence(
            alias: rawAlias,
            canonical: rawCanonical,
            sourceRecordIDs: [rawSourceRecordID],
            scope: scope,
            context: context
        )
    }

    /// 一次性追加同一术语的多条已确认证据，只执行一次 Repository save。
    /// 所有输入会在读取和写入前完成校验，避免一批证据只保存一部分。
    @discardableResult
    static func addConfirmedEvidence(
        alias rawAlias: String,
        canonical rawCanonical: String,
        sourceRecordIDs rawSourceRecordIDs: [String],
        scope: TerminologyScope = .global,
        context: VocabularyStorageContext = .production
    ) throws -> TerminologyEntry {
        let alias = TerminologyText.cleaned(rawAlias)
        let canonical = TerminologyText.cleaned(rawCanonical)
        let sourceRecordIDs = rawSourceRecordIDs.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !alias.isEmpty,
              !canonical.isEmpty,
              !sourceRecordIDs.isEmpty,
              sourceRecordIDs.allSatisfy({ !$0.isEmpty }),
              TerminologyText.displayKey(alias) != TerminologyText.displayKey(canonical)
        else {
            throw TerminologyRepositoryError.invalidEntry
        }

        var seenSourceRecordIDs = Set<String>()
        let uniqueSourceRecordIDs = sourceRecordIDs.filter {
            seenSourceRecordIDs.insert($0).inserted
        }

        lock.lock()
        defer { lock.unlock() }
        let normalizedScope = normalizedScope(scope)
        var document = load(context: context)
        for sourceRecordID in uniqueSourceRecordIDs {
            applyConfirmedEvidence(
                sourceRecordID: sourceRecordID,
                alias: alias,
                canonical: canonical,
                scope: normalizedScope,
                to: &document
            )
        }
        try save(document, context: context)
        let saved = load(context: context)
        guard let entry = document.entries.first(where: {
            $0.origin != .builtIn
                && TerminologyText.entryIdentityKey(canonicalText: $0.canonicalText, scope: $0.scope)
                == TerminologyText.entryIdentityKey(canonicalText: canonical, scope: normalizedScope)
        }) else { throw TerminologyRepositoryError.invalidEntry }
        return saved.entries.first(where: { $0.id == entry.id }) ?? entry
    }

    /// 捕获一条 historyID 的术语证据，供跨存储事务协调器做增量补偿。
    static func evidenceSnapshot(
        sourceRecordID rawSourceRecordID: String,
        context: VocabularyStorageContext = .production
    ) throws -> TerminologyEvidenceSnapshot {
        let sourceRecordID = rawSourceRecordID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceRecordID.isEmpty else { throw TerminologyRepositoryError.invalidEntry }
        lock.lock()
        defer { lock.unlock() }
        return TerminologyEvidenceSnapshot(
            sourceRecordID: sourceRecordID,
            document: load(context: context)
        )
    }

    /// 只恢复快照 historyID 对应的证据。当前文档中其他 historyID 的新增、删除或
    /// 手工术语修改都会保留，避免整库快照回滚覆盖并发成功操作。
    static func restoreEvidence(
        _ snapshot: TerminologyEvidenceSnapshot,
        context: VocabularyStorageContext = .production
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        var restored = removingEvidence(
            snapshot.sourceRecordID,
            from: load(context: context)
        ).document
        let originalEntries = snapshot.document.entries.compactMap { entry -> TerminologyEntry? in
            let evidenceAliases = entry.aliases.filter {
                $0.sourceRecordIDs.contains(snapshot.sourceRecordID)
            }
            guard !evidenceAliases.isEmpty else { return nil }
            var evidenceEntry = entry
            evidenceEntry.aliases = evidenceAliases
            return evidenceEntry
        }

        for originalEntry in originalEntries {
            let identityKey = TerminologyText.entryIdentityKey(
                canonicalText: originalEntry.canonicalText,
                scope: originalEntry.scope
            )
            if let entryIndex = restored.entries.firstIndex(where: {
                $0.origin != .builtIn && ($0.id == originalEntry.id
                    || TerminologyText.entryIdentityKey(
                        canonicalText: $0.canonicalText,
                        scope: $0.scope
                    ) == identityKey)
            }) {
                for originalAlias in originalEntry.aliases {
                    let aliasKey = TerminologyText.aliasStorageKey(originalAlias.text)
                    if let aliasIndex = restored.entries[entryIndex].aliases.firstIndex(where: {
                        TerminologyText.aliasStorageKey($0.text) == aliasKey
                    }) {
                        let currentAlias = restored.entries[entryIndex].aliases[aliasIndex]
                        var mergedAlias = originalAlias
                        var sourceIDs = originalAlias.sourceRecordIDs
                        for currentID in currentAlias.sourceRecordIDs where !sourceIDs.contains(currentID) {
                            sourceIDs.append(currentID)
                        }
                        mergedAlias.sourceRecordIDs = sourceIDs
                        if mergedAlias.source == .confirmedCorrection {
                            mergedAlias.evidenceCount = max(1, sourceIDs.count)
                        }
                        if let currentLastSeen = currentAlias.lastSeenAt {
                            mergedAlias.lastSeenAt = max(
                                mergedAlias.lastSeenAt ?? currentLastSeen,
                                currentLastSeen
                            )
                        }
                        restored.entries[entryIndex].aliases[aliasIndex] = mergedAlias
                    } else {
                        restored.entries[entryIndex].aliases.append(originalAlias)
                    }
                }
                restored.entries[entryIndex].updatedAt = max(
                    restored.entries[entryIndex].updatedAt,
                    originalEntry.updatedAt
                )
            } else {
                restored.entries.append(originalEntry)
            }
        }

        try save(TerminologyDocumentNormalizer.normalized(restored), context: context)
    }

    /// 同一把锁内完成“移除旧 historyID 证据 + 写入本次全部候选 + 一次落盘”。
    /// 若兼容投影失败，会尽力把统一术语文件与旧投影恢复为调用前快照。
    @discardableResult
    static func replaceEvidence(
        sourceRecordID rawSourceRecordID: String,
        with candidates: [TerminologyCorrectionCandidate],
        scope: TerminologyScope = .global,
        context: VocabularyStorageContext = .production
    ) throws -> TerminologyDocument {
        lock.lock()
        defer { lock.unlock() }
        let sourceRecordID = rawSourceRecordID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceRecordID.isEmpty else { throw TerminologyRepositoryError.invalidEntry }

        let effectiveBefore = load(context: context)
        var proposed = removingEvidence(sourceRecordID, from: effectiveBefore).document
        let normalizedScope = normalizedScope(scope)
        var seenPairs = Set<String>()
        for candidate in candidates {
            let alias = TerminologyText.cleaned(candidate.alias)
            let canonical = TerminologyText.cleaned(candidate.canonical)
            guard !alias.isEmpty, !canonical.isEmpty,
                  TerminologyText.displayKey(alias) != TerminologyText.displayKey(canonical)
            else { continue }
            let pairKey = TerminologyText.entryIdentityKey(
                canonicalText: canonical,
                scope: normalizedScope
            ) + "|" + TerminologyText.aliasStorageKey(alias)
            guard seenPairs.insert(pairKey).inserted else { continue }
            applyConfirmedEvidence(
                sourceRecordID: sourceRecordID,
                alias: alias,
                canonical: canonical,
                scope: normalizedScope,
                to: &proposed
            )
        }
        proposed = TerminologyDocumentNormalizer.normalized(proposed)

        try save(proposed, context: context)
        return load(context: context)
    }

    /// 撤销历史纠正对应的术语证据。手工词条与其他 historyID 的证据不受影响。
    @discardableResult
    static func removeEvidence(
        sourceRecordID rawSourceRecordID: String,
        context: VocabularyStorageContext = .production
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let sourceRecordID = rawSourceRecordID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceRecordID.isEmpty else { return false }

        let result = removingEvidence(sourceRecordID, from: load(context: context))
        guard result.didChange else { return false }
        try save(result.document, context: context)
        return true
    }

    static func remove(
        id: UUID,
        context: VocabularyStorageContext = .production
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        var document = load(context: context)
        guard let index = document.entries.firstIndex(where: { $0.id == id }) else {
            throw TerminologyRepositoryError.entryNotFound(id)
        }
        guard document.entries[index].origin != .builtIn else {
            throw TerminologyRepositoryError.builtInReadOnly
        }
        document.entries.remove(at: index)
        try save(document, context: context)
    }

    static func setEnabled(
        _ isEnabled: Bool,
        id: UUID,
        context: VocabularyStorageContext = .production
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        var document = load(context: context)
        guard let index = document.entries.firstIndex(where: { $0.id == id }) else {
            throw TerminologyRepositoryError.entryNotFound(id)
        }
        document.entries[index].isEnabled = isEnabled
        document.entries[index].updatedAt = Date()
        try save(document, context: context)
    }

    static func projections(
        applicationBundleIdentifier: String? = nil,
        context: VocabularyStorageContext = .production
    ) -> TerminologyProjectionBundle {
        TerminologyProjections.make(
            from: load(context: context),
            applicationBundleIdentifier: applicationBundleIdentifier
        )
    }

    /// “我的术语 / 内置术语 / 冲突”三个 Repository 区域的一次性一致快照。
    /// “待确认发现”来自 TerminologyCorrectionExtractor，“固定替换”继续来自 SnippetStorage。
    static func snapshot(
        applicationBundleIdentifier: String? = nil,
        context: VocabularyStorageContext = .production
    ) -> TerminologyRepositorySnapshot {
        let document = load(context: context)
        return TerminologyRepositorySnapshot(
            myTerms: document.entries.filter {
                $0.origin != .builtIn && $0.origin != .contextCandidate
            },
            builtInTerms: document.entries.filter { $0.origin == .builtIn },
            conflicts: document.conflicts,
            projections: TerminologyProjections.make(
                from: document,
                applicationBundleIdentifier: applicationBundleIdentifier
            )
        )
    }

    // MARK: - Mutation helpers

    private struct EvidenceRemovalResult {
        var document: TerminologyDocument
        var didChange: Bool
    }

    private static func removingEvidence(
        _ sourceRecordID: String,
        from input: TerminologyDocument
    ) -> EvidenceRemovalResult {
        var document = input
        var didChange = false
        for entryIndex in document.entries.indices.reversed() {
            for aliasIndex in document.entries[entryIndex].aliases.indices.reversed() {
                let oldCount = document.entries[entryIndex].aliases[aliasIndex].sourceRecordIDs.count
                document.entries[entryIndex].aliases[aliasIndex].sourceRecordIDs.removeAll {
                    $0 == sourceRecordID
                }
                guard document.entries[entryIndex].aliases[aliasIndex].sourceRecordIDs.count != oldCount else {
                    continue
                }
                didChange = true
                let alias = document.entries[entryIndex].aliases[aliasIndex]
                if alias.source == .confirmedCorrection, alias.sourceRecordIDs.isEmpty {
                    document.entries[entryIndex].aliases.remove(at: aliasIndex)
                } else if alias.source == .confirmedCorrection {
                    document.entries[entryIndex].aliases[aliasIndex].evidenceCount = max(
                        1,
                        alias.sourceRecordIDs.count
                    )
                }
            }
            if document.entries[entryIndex].origin == .confirmedCorrection,
               document.entries[entryIndex].aliases.isEmpty {
                document.entries.remove(at: entryIndex)
            }
        }
        return EvidenceRemovalResult(document: document, didChange: didChange)
    }

    private static func applyConfirmedEvidence(
        sourceRecordID: String,
        alias: String,
        canonical: String,
        scope: TerminologyScope,
        to document: inout TerminologyDocument
    ) {
        let canonicalKey = TerminologyText.entryIdentityKey(
            canonicalText: canonical,
            scope: scope
        )
        let aliasKey = TerminologyText.aliasStorageKey(alias)
        let now = Date()
        if let entryIndex = document.entries.firstIndex(where: {
            $0.origin != .builtIn
                && TerminologyText.entryIdentityKey(canonicalText: $0.canonicalText, scope: $0.scope)
                == canonicalKey
        }) {
            if let aliasIndex = document.entries[entryIndex].aliases.firstIndex(where: {
                TerminologyText.aliasStorageKey($0.text) == aliasKey
            }) {
                if !document.entries[entryIndex].aliases[aliasIndex].sourceRecordIDs.contains(sourceRecordID) {
                    document.entries[entryIndex].aliases[aliasIndex].sourceRecordIDs.append(sourceRecordID)
                }
                if document.entries[entryIndex].aliases[aliasIndex].source == .confirmedCorrection {
                    document.entries[entryIndex].aliases[aliasIndex].evidenceCount = max(
                        1,
                        document.entries[entryIndex].aliases[aliasIndex].sourceRecordIDs.count
                    )
                }
                document.entries[entryIndex].aliases[aliasIndex].lastSeenAt = now
            } else {
                document.entries[entryIndex].aliases.append(TerminologyAlias(
                    text: alias,
                    source: .confirmedCorrection,
                    evidenceCount: 1,
                    lastSeenAt: now,
                    sourceRecordIDs: [sourceRecordID]
                ))
            }
            document.entries[entryIndex].updatedAt = now
        } else {
            document.entries.append(TerminologyEntry(
                canonicalText: canonical,
                aliases: [TerminologyAlias(
                    text: alias,
                    source: .confirmedCorrection,
                    evidenceCount: 1,
                    lastSeenAt: now,
                    sourceRecordIDs: [sourceRecordID]
                )],
                origin: .confirmedCorrection,
                scope: scope,
                createdAt: now,
                updatedAt: now
            ))
        }
    }

    private static func normalizedScope(_ scope: TerminologyScope) -> TerminologyScope {
        guard scope.kind == .application,
              let bundleIdentifier = scope.applicationBundleIdentifier?.trimmingCharacters(
                in: .whitespacesAndNewlines
              ),
              !bundleIdentifier.isEmpty
        else { return .global }
        return .application(bundleIdentifier)
    }

    private static func validateBuiltInContent(
        previous: TerminologyDocument,
        proposed: TerminologyDocument
    ) throws {
        let previousBuiltIns = previous.entries.filter { $0.origin == .builtIn }
        let previousIDs = Set(previousBuiltIns.map(\.id))
        guard proposed.entries.filter({ $0.origin == .builtIn }).allSatisfy({
            previousIDs.contains($0.id)
        }) else {
            throw TerminologyRepositoryError.builtInReadOnly
        }
        for oldEntry in previousBuiltIns {
            guard let newEntry = proposed.entries.first(where: { $0.id == oldEntry.id }),
                  newEntry.origin == .builtIn,
                  newEntry.canonicalText == oldEntry.canonicalText,
                  newEntry.aliases == oldEntry.aliases,
                  newEntry.scope == oldEntry.scope,
                  newEntry.createdAt == oldEntry.createdAt,
                  newEntry.isEnabled != oldEntry.isEnabled
                    ? newEntry.updatedAt >= oldEntry.updatedAt
                    : newEntry.updatedAt == oldEntry.updatedAt
            else {
                throw TerminologyRepositoryError.builtInReadOnly
            }
        }
    }

    // MARK: - Migration support

    static func storedDocumentResult(
        context: VocabularyStorageContext
    ) -> JSONFileReadResult<TerminologyDocument> {
        JSONFileStore.read(
            TerminologyDocument.self,
            from: fileURL(in: context),
            fileManager: context.fileManager
        )
    }

    static func writeStoredDocument(
        _ document: TerminologyDocument,
        context: VocabularyStorageContext
    ) throws {
        try JSONFileStore.writeOrThrow(document, to: fileURL(in: context))
    }
}
