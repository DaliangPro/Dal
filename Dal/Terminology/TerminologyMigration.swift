import Foundation

struct TerminologyMigrationHooks {
    var beforeDocumentCommit: () throws -> Void

    static let live = TerminologyMigrationHooks(beforeDocumentCommit: {})
}

/// 兼容投影的失败注入点。生产环境全部为空操作；测试用它验证
/// Hotword / Snippet / PersonalLexicon 任一阶段失败都不会留下半完成状态。
struct TerminologyCompatibilityProjectionHooks {
    var afterHotwordWrite: () throws -> Void
    var afterSnippetWrite: () throws -> Void
    var afterPersonalLexiconWrite: () throws -> Void
    var beforeManifestCommit: () throws -> Void
    var beforeHotwordRollback: () throws -> Void
    var beforeSnippetRollback: () throws -> Void
    var beforePersonalLexiconRollback: () throws -> Void

    init(
        afterHotwordWrite: @escaping () throws -> Void,
        afterSnippetWrite: @escaping () throws -> Void,
        afterPersonalLexiconWrite: @escaping () throws -> Void,
        beforeManifestCommit: @escaping () throws -> Void,
        beforeHotwordRollback: @escaping () throws -> Void = {},
        beforeSnippetRollback: @escaping () throws -> Void = {},
        beforePersonalLexiconRollback: @escaping () throws -> Void = {}
    ) {
        self.afterHotwordWrite = afterHotwordWrite
        self.afterSnippetWrite = afterSnippetWrite
        self.afterPersonalLexiconWrite = afterPersonalLexiconWrite
        self.beforeManifestCommit = beforeManifestCommit
        self.beforeHotwordRollback = beforeHotwordRollback
        self.beforeSnippetRollback = beforeSnippetRollback
        self.beforePersonalLexiconRollback = beforePersonalLexiconRollback
    }

    static let live = TerminologyCompatibilityProjectionHooks(
        afterHotwordWrite: {},
        afterSnippetWrite: {},
        afterPersonalLexiconWrite: {},
        beforeManifestCommit: {}
    )
}

struct TerminologyMigrationOutcome: Sendable, Equatable {
    let didMigrate: Bool
    let importedEntryCount: Int
    let importedAliasCount: Int
    let skippedSnippetCount: Int
    let conflictCount: Int
}

struct TerminologyLegacySourceSummary: Codable, Sendable, Equatable {
    var personalLexiconEntryCount: Int
    var userHotwordCount: Int
    var userSnippetCount: Int
    var builtInHotwordCount: Int
    var builtInSnippetCount: Int
}

struct TerminologyMigrationManifest: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    /// 这是准备提交的目标版本；迁移是否完成只以 TerminologyDocument.migrationVersion 为准。
    var targetMigrationVersion: Int
    var sourceSummary: TerminologyLegacySourceSummary

    /// Repository 新增到旧存储的投影。删除时只允许移除这些拥有明确所有权的项。
    var ownedHotwordKeys: Set<String>
    var ownedCorrections: [String: String]
    var ownedPersonalEntryIDs: Set<UUID>
    /// ID 只能证明来源，不能证明内容仍属于 Repository。内容指纹用于
    /// 识别旧入口对正文、aliases 或启用状态的外部改写。Optional 用于兼容 v1 manifest。
    var ownedPersonalEntryFingerprints: [String: String]?

    /// 用户从新 Repository 删除旧数据导入项时，不删除恢复源，只在 read-through 中屏蔽。
    var suppressedHotwordKeys: Set<String>
    var suppressedCorrectionPairs: Set<String>
    var suppressedPersonalEntryIDs: Set<UUID>

    static let empty = TerminologyMigrationManifest(
        schemaVersion: currentSchemaVersion,
        targetMigrationVersion: 0,
        sourceSummary: TerminologyLegacySourceSummary(
            personalLexiconEntryCount: 0,
            userHotwordCount: 0,
            userSnippetCount: 0,
            builtInHotwordCount: 0,
            builtInSnippetCount: 0
        ),
        ownedHotwordKeys: [],
        ownedCorrections: [:],
        ownedPersonalEntryIDs: [],
        ownedPersonalEntryFingerprints: [:],
        suppressedHotwordKeys: [],
        suppressedCorrectionPairs: [],
        suppressedPersonalEntryIDs: []
    )
}

enum TerminologyMigration {
    private struct LegacySnapshot {
        let personalLexicon: PersonalLexiconDocument
        let userHotwords: [String]
        let userSnippets: [(trigger: String, value: String)]
        let builtInHotwords: [String]
        let builtInSnippets: [(trigger: String, value: String)]

        var summary: TerminologyLegacySourceSummary {
            TerminologyLegacySourceSummary(
                personalLexiconEntryCount: personalLexicon.entries.count,
                userHotwordCount: userHotwords.count,
                userSnippetCount: userSnippets.count,
                builtInHotwordCount: builtInHotwords.count,
                builtInSnippetCount: builtInSnippets.count
            )
        }
    }

    static func manifestURL(in context: VocabularyStorageContext = .production) -> URL {
        context.supportDirectory.appendingPathComponent("terminology-migration-manifest.json")
    }

    static func loadManifest(
        context: VocabularyStorageContext = .production
    ) throws -> TerminologyMigrationManifest {
        switch JSONFileStore.read(
            TerminologyMigrationManifest.self,
            from: manifestURL(in: context),
            fileManager: context.fileManager
        ) {
        case .missing:
            return .empty
        case .value(let manifest):
            guard manifest.schemaVersion <= TerminologyMigrationManifest.currentSchemaVersion else {
                throw TerminologyRepositoryError.unsupportedSchemaVersion(manifest.schemaVersion)
            }
            return manifest
        case .corrupt(let url, _):
            throw TerminologyRepositoryError.recoveryRequired(url)
        }
    }

    static func migrateIfNeeded(
        context: VocabularyStorageContext,
        hooks: TerminologyMigrationHooks
    ) throws -> TerminologyMigrationOutcome {
        let existing: TerminologyDocument
        switch TerminologyRepository.storedDocumentResult(context: context) {
        case .missing:
            existing = .empty
        case .value(let document):
            guard document.schemaVersion <= TerminologyDocument.currentSchemaVersion else {
                throw TerminologyRepositoryError.unsupportedSchemaVersion(document.schemaVersion)
            }
            existing = TerminologyDocumentNormalizer.normalized(document)
        case .corrupt(let url, _):
            throw TerminologyRepositoryError.recoveryRequired(url)
        }

        if existing.migrationVersion >= TerminologyDocument.currentMigrationVersion {
            return TerminologyMigrationOutcome(
                didMigrate: false,
                importedEntryCount: 0,
                importedAliasCount: 0,
                skippedSnippetCount: 0,
                conflictCount: existing.conflicts.count
            )
        }

        let snapshot = try loadLegacySnapshot(context: context)
        var manifest = try loadManifest(context: context)
        let imported = importedEntries(
            from: snapshot,
            manifest: manifest,
            applyCompatibilityExclusions: false
        )
        var migrated = TerminologyDocumentNormalizer.normalized(TerminologyDocument(
            migrationVersion: TerminologyDocument.currentMigrationVersion,
            entries: existing.entries + imported.entries
        ))
        migrated.migrationVersion = TerminologyDocument.currentMigrationVersion

        // 先准备 manifest，再提交带新 migrationVersion 的唯一事实来源。
        // 后一步失败时文档版本仍未推进；下次启动会幂等重试。
        manifest.targetMigrationVersion = TerminologyDocument.currentMigrationVersion
        manifest.sourceSummary = snapshot.summary
        try writeManifest(manifest, context: context)
        try hooks.beforeDocumentCommit()
        try TerminologyRepository.writeStoredDocument(migrated, context: context)

        return TerminologyMigrationOutcome(
            didMigrate: true,
            importedEntryCount: max(0, migrated.entries.count - existing.entries.count),
            importedAliasCount: max(
                0,
                migrated.entries.reduce(0) { $0 + $1.aliases.count }
                    - existing.entries.reduce(0) { $0 + $1.aliases.count }
            ),
            skippedSnippetCount: imported.skippedSnippetCount,
            conflictCount: migrated.conflicts.count
        )
    }

    static func readThrough(
        _ document: TerminologyDocument,
        context: VocabularyStorageContext
    ) throws -> TerminologyDocument {
        let snapshot = try loadLegacySnapshot(context: context)
        let manifest = try loadManifest(context: context)
        let imported = importedEntries(
            from: snapshot,
            manifest: manifest,
            applyCompatibilityExclusions: true
        )
        return TerminologyDocumentNormalizer.normalized(TerminologyDocument(
            migrationVersion: document.migrationVersion,
            entries: document.entries + imported.entries
        ))
    }

    /// Repository 的兼容窗口 dual-write。只删除上次由 Repository 自己投影的项；
    /// 对旧文件原有内容只做保留或 read-through 屏蔽，绝不把恢复源当临时缓存清空。
    static func writeCompatibilityProjections(
        _ document: TerminologyDocument,
        context: VocabularyStorageContext,
        hooks: TerminologyCompatibilityProjectionHooks = .live
    ) throws {
        let normalized = TerminologyDocumentNormalizer.normalized(document)
        // 旧三套存储都是全局作用域，绝不能把 App 专属术语写入其中造成跨 App 泄漏。
        let globalEntries = normalized.entries.filter { $0.scope.kind == .global }
        // 内置词已有独立 builtin 文件；兼容投影只写全局用户术语。
        let compatibilityDocument = TerminologyDocument(
            migrationVersion: normalized.migrationVersion,
            entries: globalEntries.filter {
                $0.origin != .builtIn && $0.origin != .contextCandidate
            }
        )
        let projections = TerminologyProjections.make(from: compatibilityDocument)
        let currentPersonal = try requiredValue(
            PersonalLexiconStorage.loadResult(context: context),
            missing: .empty
        )
        let currentHotwords = try requiredValue(
            HotwordStorage.loadResult(context: context),
            missing: []
        )
        let currentSnippets = try requiredValue(
            SnippetStorage.loadResult(context: context),
            missing: []
        )
        let manifest = try loadManifest(context: context)

        let desiredAllCanonicalKeys = Set(globalEntries.map {
            TerminologyText.normalizedKey($0.canonicalText)
        })
        let desiredAllCorrectionPairs = Set(globalEntries.flatMap { entry in
            entry.aliases.map { correctionPairKey(alias: $0.text, canonical: entry.canonicalText) }
        })

        let hotwordPlan = makeHotwordPlan(
            current: currentHotwords,
            desired: projections.hotwords,
            desiredAllCanonicalKeys: desiredAllCanonicalKeys,
            manifest: manifest
        )
        let correctionPlan = makeCorrectionPlan(
            current: currentSnippets,
            desired: projections.corrections,
            desiredAllCorrectionPairs: desiredAllCorrectionPairs,
            manifest: manifest
        )
        let personalPlan = makePersonalPlan(
            current: currentPersonal,
            desiredEntries: globalEntries.filter {
                $0.origin != .builtIn && $0.origin != .contextCandidate
            },
            desiredAllCanonicalKeys: desiredAllCanonicalKeys,
            manifest: manifest
        )

        var proposedManifest = manifest
        proposedManifest.ownedHotwordKeys = hotwordPlan.ownedKeys
        proposedManifest.ownedCorrections = correctionPlan.ownedCorrections
        proposedManifest.ownedPersonalEntryIDs = personalPlan.ownedIDs
        proposedManifest.ownedPersonalEntryFingerprints = personalPlan.ownedFingerprints
        proposedManifest.suppressedHotwordKeys = hotwordPlan.suppressedKeys
        proposedManifest.suppressedCorrectionPairs = correctionPlan.suppressedPairs
        proposedManifest.suppressedPersonalEntryIDs = personalPlan.suppressedIDs

        do {
            // ownership 必须最后提交。如果删除旧投影时先清空 manifest，
            // 任一旧文件写失败都会让未删掉的项被 read-through 当成新外部数据复活。
            try HotwordStorage.save(hotwordPlan.words, context: context)
            try hooks.afterHotwordWrite()
            try SnippetStorage.save(correctionPlan.snippets, context: context)
            try hooks.afterSnippetWrite()
            try PersonalLexiconStorage.save(
                personalPlan.document,
                syncToASR: false,
                context: context
            )
            try hooks.afterPersonalLexiconWrite()
            try hooks.beforeManifestCommit()
            try writeManifest(proposedManifest, context: context)
        } catch let operationError {
            // manifest 在成功的最后一步才更新，因此这里只需恢复三份旧数据。
            // 每份恢复独立尝试：第一份失败不能阻止后两份回滚。
            var rollbackFailures: [TerminologyCompatibilityRollbackFailure] = []
            do {
                try hooks.beforeHotwordRollback()
                try HotwordStorage.save(currentHotwords, context: context)
            } catch {
                rollbackFailures.append(.init(storage: "HotwordStorage", error: error))
            }
            do {
                try hooks.beforeSnippetRollback()
                try SnippetStorage.save(currentSnippets, context: context)
            } catch {
                rollbackFailures.append(.init(storage: "SnippetStorage", error: error))
            }
            do {
                try hooks.beforePersonalLexiconRollback()
                try PersonalLexiconStorage.save(
                    currentPersonal,
                    syncToASR: false,
                    context: context
                )
            } catch {
                rollbackFailures.append(.init(storage: "PersonalLexiconStorage", error: error))
            }
            if !rollbackFailures.isEmpty {
                throw TerminologyRepositoryError.rollbackFailed(
                    operation: operationError,
                    rollback: TerminologyCompatibilityRollbackError(failures: rollbackFailures)
                )
            }
            throw operationError
        }
    }

    /// 旧 Snippet 没有类型字段，因此迁移必须保守：只接受短、无模板特征、无句末标点的映射。
    /// 被拒规则继续完整留在 SnippetStorage，作为固定/整句替换运行。
    static func isEligibleTerminologySnippet(trigger rawTrigger: String, value rawValue: String) -> Bool {
        let trigger = TerminologyText.cleaned(rawTrigger)
        let value = TerminologyText.cleaned(rawValue)
        guard !SnippetStorage.isDraftTrigger(trigger),
              (2...64).contains(trigger.count),
              (2...64).contains(value.count),
              TerminologyText.displayKey(trigger) != TerminologyText.displayKey(value),
              !trigger.contains("\n"), !trigger.contains("\r"),
              !value.contains("\n"), !value.contains("\r")
        else { return false }

        let sentenceMarks = CharacterSet(charactersIn: "。！？；!?;，,：:")
        guard trigger.rangeOfCharacter(from: sentenceMarks) == nil,
              value.rangeOfCharacter(from: sentenceMarks) == nil
        else { return false }

        let lowerTrigger = trigger.lowercased()
        let lowerValue = value.lowercased()
        let templateSignals = ["http://", "https://", "www.", "@"]
        guard !templateSignals.contains(where: { lowerTrigger.contains($0) || lowerValue.contains($0) })
        else { return false }

        let triggerWordCount = trigger.split(whereSeparator: \.isWhitespace).count
        let valueWordCount = value.split(whereSeparator: \.isWhitespace).count
        return triggerWordCount <= 6 && valueWordCount <= 6
    }
}

private extension TerminologyMigration {
    struct TerminologyCompatibilityRollbackFailure {
        let storage: String
        let error: Error
    }

    struct TerminologyCompatibilityRollbackError: LocalizedError {
        let failures: [TerminologyCompatibilityRollbackFailure]

        var errorDescription: String? {
            failures.map {
                "\($0.storage): \($0.error.localizedDescription)"
            }.joined(separator: "; ")
        }
    }

    struct ImportedEntries {
        let entries: [TerminologyEntry]
        let skippedSnippetCount: Int
    }

    struct HotwordPlan {
        let words: [String]
        let ownedKeys: Set<String>
        let suppressedKeys: Set<String>
    }

    struct CorrectionPlan {
        let snippets: [(trigger: String, value: String)]
        let ownedCorrections: [String: String]
        let suppressedPairs: Set<String>
    }

    struct PersonalPlan {
        let document: PersonalLexiconDocument
        let ownedIDs: Set<UUID>
        let ownedFingerprints: [String: String]
        let suppressedIDs: Set<UUID>
    }

    private static func loadLegacySnapshot(context: VocabularyStorageContext) throws -> LegacySnapshot {
        LegacySnapshot(
            personalLexicon: try requiredValue(
                PersonalLexiconStorage.loadResult(context: context),
                missing: .empty
            ),
            userHotwords: try requiredValue(
                HotwordStorage.loadResult(context: context),
                missing: []
            ),
            userSnippets: try requiredValue(
                SnippetStorage.loadResult(context: context),
                missing: []
            ),
            builtInHotwords: try requiredValue(
                HotwordStorage.loadBuiltinResult(context: context),
                missing: []
            ),
            builtInSnippets: try requiredValue(
                SnippetStorage.loadBuiltinResult(context: context),
                missing: []
            )
        )
    }

    static func requiredValue<T>(
        _ result: JSONFileReadResult<T>,
        missing: @autoclosure () -> T
    ) throws -> T {
        switch result {
        case .missing:
            return missing()
        case .value(let value):
            return value
        case .corrupt(let url, _):
            throw TerminologyRepositoryError.recoveryRequired(url)
        }
    }

    private static func importedEntries(
        from snapshot: LegacySnapshot,
        manifest: TerminologyMigrationManifest,
        applyCompatibilityExclusions: Bool
    ) -> ImportedEntries {
        var entries: [TerminologyEntry] = []
        let legacyTimestamp = Date(timeIntervalSinceReferenceDate: 0)

        for legacy in snapshot.personalLexicon.entries {
            if applyCompatibilityExclusions,
               manifest.ownedPersonalEntryIDs.contains(legacy.id)
                || manifest.suppressedPersonalEntryIDs.contains(legacy.id) {
                continue
            }
            let origin = terminologyOrigin(for: legacy.source)
            let aliasSource = terminologyAliasSource(for: legacy.source)
            entries.append(TerminologyEntry(
                id: legacy.id,
                canonicalText: legacy.canonical,
                aliases: legacy.aliases.map {
                    TerminologyAlias(
                        id: stableUUID("personal-alias|\(legacy.id.uuidString)|\(TerminologyText.aliasStorageKey($0))"),
                        text: $0,
                        source: aliasSource
                    )
                },
                isEnabled: legacy.isEnabled,
                origin: origin,
                createdAt: legacy.createdAt,
                updatedAt: legacy.createdAt
            ))
        }

        for hotword in snapshot.userHotwords {
            let key = TerminologyText.normalizedKey(hotword)
            if applyCompatibilityExclusions,
               manifest.ownedHotwordKeys.contains(key) || manifest.suppressedHotwordKeys.contains(key) {
                continue
            }
            entries.append(TerminologyEntry(
                id: stableUUID("user-hotword|\(key)"),
                canonicalText: hotword,
                origin: .legacyHotword,
                createdAt: legacyTimestamp,
                updatedAt: legacyTimestamp
            ))
        }

        var skippedSnippetCount = 0
        for snippet in snapshot.userSnippets {
            guard isEligibleTerminologySnippet(trigger: snippet.trigger, value: snippet.value) else {
                skippedSnippetCount += 1
                continue
            }
            let triggerKey = TerminologyText.normalizedKey(snippet.trigger)
            let canonicalKey = TerminologyText.normalizedKey(snippet.value)
            let pair = correctionPairKey(alias: snippet.trigger, canonical: snippet.value)
            if applyCompatibilityExclusions,
               manifest.ownedCorrections[triggerKey] == canonicalKey
                || manifest.suppressedCorrectionPairs.contains(pair) {
                continue
            }
            entries.append(TerminologyEntry(
                id: stableUUID("user-snippet-canonical|\(canonicalKey)"),
                canonicalText: snippet.value,
                aliases: [TerminologyAlias(
                    id: stableUUID("user-snippet-alias|\(pair)"),
                    text: snippet.trigger,
                    source: .legacySnippet
                )],
                origin: .legacySnippet,
                createdAt: legacyTimestamp,
                updatedAt: legacyTimestamp
            ))
        }

        for snippet in snapshot.builtInSnippets {
            guard isEligibleTerminologySnippet(trigger: snippet.trigger, value: snippet.value) else {
                skippedSnippetCount += 1
                continue
            }
            entries.append(TerminologyEntry(
                id: stableUUID("builtin-canonical|\(TerminologyText.normalizedKey(snippet.value))"),
                canonicalText: snippet.value,
                aliases: [TerminologyAlias(
                    id: stableUUID("builtin-alias|\(correctionPairKey(alias: snippet.trigger, canonical: snippet.value))"),
                    text: snippet.trigger,
                    source: .builtIn
                )],
                origin: .builtIn,
                createdAt: legacyTimestamp,
                updatedAt: legacyTimestamp
            ))
        }
        for hotword in snapshot.builtInHotwords {
            entries.append(TerminologyEntry(
                id: stableUUID("builtin-canonical|\(TerminologyText.normalizedKey(hotword))"),
                canonicalText: hotword,
                origin: .builtIn,
                createdAt: legacyTimestamp,
                updatedAt: legacyTimestamp
            ))
        }

        return ImportedEntries(entries: entries, skippedSnippetCount: skippedSnippetCount)
    }

    static func terminologyOrigin(for source: PersonalLexiconEntrySource) -> TerminologyOrigin {
        switch source {
        case .manual: return .manual
        case .snippetCopy: return .legacySnippet
        case .correctionCandidate: return .confirmedCorrection
        }
    }

    static func terminologyAliasSource(for source: PersonalLexiconEntrySource) -> TerminologyAliasSource {
        switch source {
        case .manual: return .manual
        case .snippetCopy: return .legacySnippet
        case .correctionCandidate: return .confirmedCorrection
        }
    }

    static func makeHotwordPlan(
        current: [String],
        desired: [String],
        desiredAllCanonicalKeys: Set<String>,
        manifest: TerminologyMigrationManifest
    ) -> HotwordPlan {
        let desiredByKey = Dictionary(uniqueKeysWithValues: desired.map {
            (TerminologyText.normalizedKey($0), $0)
        })
        var words = current
        words.removeAll { word in
            let key = TerminologyText.normalizedKey(word)
            return manifest.ownedHotwordKeys.contains(key) && desiredByKey[key] == nil
        }

        var currentKeys = Set(words.map(TerminologyText.normalizedKey))
        var ownedKeys = Set<String>()
        for word in desired {
            let key = TerminologyText.normalizedKey(word)
            if manifest.ownedHotwordKeys.contains(key) {
                ownedKeys.insert(key)
                if currentKeys.insert(key).inserted { words.append(word) }
            } else if currentKeys.insert(key).inserted {
                words.append(word)
                ownedKeys.insert(key)
            }
        }

        let originalUnowned = Set(current.map(TerminologyText.normalizedKey))
            .subtracting(manifest.ownedHotwordKeys)
        var suppressed = manifest.suppressedHotwordKeys
        suppressed.formUnion(originalUnowned.subtracting(desiredAllCanonicalKeys))
        suppressed.subtract(desiredAllCanonicalKeys)
        return HotwordPlan(words: words, ownedKeys: ownedKeys, suppressedKeys: suppressed)
    }

    static func makeCorrectionPlan(
        current: [(trigger: String, value: String)],
        desired: [String: String],
        desiredAllCorrectionPairs: Set<String>,
        manifest: TerminologyMigrationManifest
    ) -> CorrectionPlan {
        var desiredByNormalizedTrigger: [String: (
            alias: String,
            canonical: String,
            triggerKey: String,
            canonicalKey: String
        )] = [:]
        for (alias, canonical) in desired.sorted(by: { $0.key < $1.key }) {
            let item = (
                alias: alias,
                canonical: canonical,
                triggerKey: TerminologyText.normalizedKey(alias),
                canonicalKey: TerminologyText.normalizedKey(canonical)
            )
            if desiredByNormalizedTrigger[item.triggerKey] == nil {
                desiredByNormalizedTrigger[item.triggerKey] = item
            }
        }
        let desiredItems = desiredByNormalizedTrigger.values.sorted { $0.triggerKey < $1.triggerKey }
        let desiredByTrigger = Dictionary(uniqueKeysWithValues: desiredItems.map {
            ($0.triggerKey, $0.canonicalKey)
        })

        var snippets = current.filter { snippet in
            let key = TerminologyText.normalizedKey(snippet.trigger)
            guard let previouslyOwnedCanonical = manifest.ownedCorrections[key] else { return true }
            let currentCanonical = TerminologyText.normalizedKey(snippet.value)
            // 只有值仍与 manifest 记录一致时，这条规则才仍属于 Repository。
            // 用户在旧文件中改过值后，它已是外部数据，不得按旧 ownership 删除。
            guard currentCanonical == previouslyOwnedCanonical else { return true }
            return desiredByTrigger[key] == previouslyOwnedCanonical
        }
        var currentByTrigger: [String: Set<String>] = [:]
        for snippet in snippets {
            let key = TerminologyText.normalizedKey(snippet.trigger)
            currentByTrigger[key, default: []].insert(TerminologyText.normalizedKey(snippet.value))
        }
        var owned: [String: String] = [:]

        for item in desiredItems {
            if let previousCanonical = manifest.ownedCorrections[item.triggerKey] {
                let hasExternallyChangedValue = currentByTrigger[item.triggerKey]?.contains(where: {
                    $0 != previousCanonical
                }) == true
                if hasExternallyChangedValue {
                    // 外部改值代表用户已经接管这个 trigger。移除仍存在的旧投影，
                    // 保留外部值，并放弃 ownership，不用文件顺序决定谁生效。
                    snippets.removeAll {
                        TerminologyText.normalizedKey($0.trigger) == item.triggerKey
                            && TerminologyText.normalizedKey($0.value) == previousCanonical
                    }
                    currentByTrigger[item.triggerKey] = Set(snippets.compactMap {
                        TerminologyText.normalizedKey($0.trigger) == item.triggerKey
                            ? TerminologyText.normalizedKey($0.value)
                            : nil
                    })
                } else if let index = snippets.firstIndex(where: {
                    TerminologyText.normalizedKey($0.trigger) == item.triggerKey
                        && TerminologyText.normalizedKey($0.value) == previousCanonical
                }) {
                    snippets[index] = (trigger: item.alias, value: item.canonical)
                    currentByTrigger[item.triggerKey] = [item.canonicalKey]
                    owned[item.triggerKey] = item.canonicalKey
                } else if currentByTrigger[item.triggerKey]?.isEmpty != false {
                    snippets.append((trigger: item.alias, value: item.canonical))
                    currentByTrigger[item.triggerKey] = [item.canonicalKey]
                    owned[item.triggerKey] = item.canonicalKey
                }
            } else if currentByTrigger[item.triggerKey]?.isEmpty != false {
                snippets.append((trigger: item.alias, value: item.canonical))
                currentByTrigger[item.triggerKey] = [item.canonicalKey]
                owned[item.triggerKey] = item.canonicalKey
            }
        }

        let originalUnownedPairs = Set(current.compactMap { snippet -> String? in
            let triggerKey = TerminologyText.normalizedKey(snippet.trigger)
            let canonicalKey = TerminologyText.normalizedKey(snippet.value)
            let isStillOwned = manifest.ownedCorrections[triggerKey] == canonicalKey
            guard !isStillOwned,
                  isEligibleTerminologySnippet(trigger: snippet.trigger, value: snippet.value)
            else { return nil }
            return correctionPairKey(alias: snippet.trigger, canonical: snippet.value)
        })
        var suppressed = manifest.suppressedCorrectionPairs
        suppressed.formUnion(originalUnownedPairs.subtracting(desiredAllCorrectionPairs))
        suppressed.subtract(desiredAllCorrectionPairs)
        return CorrectionPlan(
            snippets: snippets,
            ownedCorrections: owned,
            suppressedPairs: suppressed
        )
    }

    static func makePersonalPlan(
        current: PersonalLexiconDocument,
        desiredEntries: [TerminologyEntry],
        desiredAllCanonicalKeys: Set<String>,
        manifest: TerminologyMigrationManifest
    ) -> PersonalPlan {
        let desiredIDs = Set(desiredEntries.map(\.id))
        let previousFingerprints = manifest.ownedPersonalEntryFingerprints ?? [:]
        var desiredLegacyByID: [UUID: PersonalLexiconEntry] = [:]
        for desired in desiredEntries where desiredLegacyByID[desired.id] == nil {
            desiredLegacyByID[desired.id] = personalLexiconEntry(from: desired)
        }

        func isUnmodifiedOwnedEntry(_ entry: PersonalLexiconEntry) -> Bool {
            guard manifest.ownedPersonalEntryIDs.contains(entry.id) else { return false }
            let currentFingerprint = personalEntryFingerprint(entry)
            if let previousFingerprint = previousFingerprints[entry.id.uuidString] {
                return currentFingerprint == previousFingerprint
            }
            // v1 manifest 只有 ID。存在同 ID 的期望投影时，仅在内容仍完全一致时
            // 升级并重新认领；删除场景没有可比对目标，必须保守保留。
            guard let desired = desiredLegacyByID[entry.id] else { return false }
            return currentFingerprint == personalEntryFingerprint(desired)
        }

        var entries = current.entries.filter {
            !isUnmodifiedOwnedEntry($0) || desiredIDs.contains($0.id)
        }
        var ownedIDs = Set<UUID>()
        var ownedFingerprints: [String: String] = [:]

        for desired in desiredEntries {
            let desiredLegacy = personalLexiconEntry(from: desired)
            if let index = entries.firstIndex(where: { $0.id == desired.id }) {
                if isUnmodifiedOwnedEntry(entries[index]) {
                    entries[index] = desiredLegacy
                    ownedIDs.insert(desired.id)
                    ownedFingerprints[desired.id.uuidString] = personalEntryFingerprint(desiredLegacy)
                }
            } else if let index = entries.firstIndex(where: {
                TerminologyText.normalizedKey($0.canonical)
                    == TerminologyText.normalizedKey(desired.canonicalText)
            }) {
                let existingID = entries[index].id
                if isUnmodifiedOwnedEntry(entries[index]) {
                    let replacement = PersonalLexiconEntry(
                        id: existingID,
                        canonical: desired.canonicalText,
                        aliases: desired.aliases.map(\.text),
                        source: personalLexiconSource(from: desired.origin),
                        isEnabled: desired.isEnabled,
                        createdAt: min(entries[index].createdAt, desired.createdAt)
                    )
                    entries[index] = replacement
                    ownedIDs.insert(existingID)
                    ownedFingerprints[existingID.uuidString] = personalEntryFingerprint(replacement)
                }
            } else {
                entries.append(desiredLegacy)
                ownedIDs.insert(desired.id)
                ownedFingerprints[desired.id.uuidString] = personalEntryFingerprint(desiredLegacy)
            }
        }

        // 未被本轮确认为“内容未变的 Repository 投影”的项都是外部数据。
        // 即使 ID 在旧 manifest 中，内容被改写后也不得再用 ID 删除。
        let originalUnowned = current.entries.filter { !ownedIDs.contains($0.id) }
        var suppressed = manifest.suppressedPersonalEntryIDs
        for entry in originalUnowned where
            !desiredAllCanonicalKeys.contains(TerminologyText.normalizedKey(entry.canonical)) {
            suppressed.insert(entry.id)
        }
        for entry in originalUnowned where
            desiredAllCanonicalKeys.contains(TerminologyText.normalizedKey(entry.canonical)) {
            suppressed.remove(entry.id)
        }

        return PersonalPlan(
            document: PersonalLexiconDocument(schemaVersion: 1, entries: entries),
            ownedIDs: ownedIDs,
            ownedFingerprints: ownedFingerprints,
            suppressedIDs: suppressed
        )
    }

    static func personalEntryFingerprint(_ entry: PersonalLexiconEntry) -> String {
        struct Payload: Encodable {
            let canonical: String
            let aliases: [String]
            let source: String
            let isEnabled: Bool
            let createdAtBits: UInt64
        }
        let payload = Payload(
            canonical: entry.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCompatibilityMapping,
            aliases: entry.aliases.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .precomposedStringWithCompatibilityMapping
            }.sorted(),
            source: entry.source.rawValue,
            isEnabled: entry.isEnabled,
            createdAtBits: entry.createdAt.timeIntervalSinceReferenceDate.bitPattern
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(payload).base64EncodedString()) ?? ""
    }

    static func personalLexiconEntry(from entry: TerminologyEntry) -> PersonalLexiconEntry {
        PersonalLexiconEntry(
            id: entry.id,
            canonical: entry.canonicalText,
            aliases: entry.aliases.map(\.text),
            source: personalLexiconSource(from: entry.origin),
            isEnabled: entry.isEnabled,
            createdAt: entry.createdAt
        )
    }

    static func personalLexiconSource(from origin: TerminologyOrigin) -> PersonalLexiconEntrySource {
        switch origin {
        case .confirmedCorrection:
            return .correctionCandidate
        case .legacySnippet:
            return .snippetCopy
        case .manual, .legacyPersonalLexicon, .legacyHotword, .builtIn, .contextCandidate:
            return .manual
        }
    }

    static func correctionPairKey(alias: String, canonical: String) -> String {
        TerminologyText.normalizedKey(alias) + "→" + TerminologyText.normalizedKey(canonical)
    }

    /// 旧列表没有 ID；使用固定 UUID 让未落盘的 read-through 在多次读取间仍保持稳定。
    static func stableUUID(_ value: String) -> UUID {
        func fnv1a(_ bytes: [UInt8], seed: UInt64) -> UInt64 {
            var hash = seed
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            return hash
        }
        let bytes = Array(value.utf8)
        let high = fnv1a(bytes, seed: 14_695_981_039_346_656_037)
        let low = fnv1a(Array(bytes.reversed()), seed: 10_995_116_282_111)
        var output = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            output[index] = UInt8(truncatingIfNeeded: high >> UInt64((7 - index) * 8))
            output[index + 8] = UInt8(truncatingIfNeeded: low >> UInt64((7 - index) * 8))
        }
        output[6] = (output[6] & 0x0F) | 0x50
        output[8] = (output[8] & 0x3F) | 0x80
        return UUID(uuid: (
            output[0], output[1], output[2], output[3],
            output[4], output[5], output[6], output[7],
            output[8], output[9], output[10], output[11],
            output[12], output[13], output[14], output[15]
        ))
    }

    static func writeManifest(
        _ manifest: TerminologyMigrationManifest,
        context: VocabularyStorageContext
    ) throws {
        try JSONFileStore.writeOrThrow(manifest, to: manifestURL(in: context))
    }
}
