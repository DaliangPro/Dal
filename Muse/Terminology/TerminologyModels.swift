import Foundation

enum TerminologyOrigin: String, Codable, Sendable, Equatable, CaseIterable {
    case confirmedCorrection
    case manual
    case legacyPersonalLexicon
    case legacySnippet
    case legacyHotword
    case builtIn
    case contextCandidate

    var priority: Int {
        switch self {
        case .confirmedCorrection: return 700
        case .manual: return 600
        case .legacyPersonalLexicon: return 500
        case .legacySnippet: return 400
        case .legacyHotword: return 300
        case .builtIn: return 200
        case .contextCandidate: return 100
        }
    }
}

enum TerminologyAliasSource: String, Codable, Sendable, Equatable, CaseIterable {
    case confirmedCorrection
    case manual
    case legacyPersonalLexicon
    case legacySnippet
    case builtIn
    case contextCandidate

    var priority: Int {
        switch self {
        case .confirmedCorrection: return 600
        case .manual: return 500
        case .legacyPersonalLexicon: return 400
        case .legacySnippet: return 300
        case .builtIn: return 200
        case .contextCandidate: return 100
        }
    }
}

struct TerminologyScope: Codable, Sendable, Equatable, Hashable {
    enum Kind: String, Codable, Sendable {
        case global
        case application
    }

    var kind: Kind
    var applicationBundleIdentifier: String?

    static let global = TerminologyScope(kind: .global, applicationBundleIdentifier: nil)

    static func application(_ bundleIdentifier: String) -> TerminologyScope {
        TerminologyScope(
            kind: .application,
            applicationBundleIdentifier: bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var identityKey: String {
        switch kind {
        case .global:
            return "global"
        case .application:
            return "application:" + (applicationBundleIdentifier ?? "")
        }
    }
}

struct TerminologyAlias: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var text: String
    var source: TerminologyAliasSource
    var evidenceCount: Int
    var lastSeenAt: Date?
    /// 显式纠正对应的历史记录 ID。只保存引用，不保存用户正文。
    var sourceRecordIDs: [String]

    init(
        id: UUID = UUID(),
        text: String,
        source: TerminologyAliasSource = .manual,
        evidenceCount: Int = 1,
        lastSeenAt: Date? = nil,
        sourceRecordIDs: [String] = []
    ) {
        self.id = id
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source
        self.evidenceCount = max(1, evidenceCount)
        self.lastSeenAt = lastSeenAt
        self.sourceRecordIDs = sourceRecordIDs
    }
}

struct TerminologyEntry: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var canonicalText: String
    var aliases: [TerminologyAlias]
    var isEnabled: Bool
    var origin: TerminologyOrigin
    var scope: TerminologyScope
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        canonicalText: String,
        aliases: [TerminologyAlias] = [],
        isEnabled: Bool = true,
        origin: TerminologyOrigin = .manual,
        scope: TerminologyScope = .global,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.canonicalText = canonicalText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.aliases = aliases
        self.isEnabled = isEnabled
        self.origin = origin
        self.scope = scope
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    var isReadOnly: Bool { origin == .builtIn }

    /// 词库界面的明确保存形成独立手工来源，撤销历史学习不能删去它。
    func markedAsManual() -> TerminologyEntry {
        guard !isReadOnly else { return self }
        var entry = self
        entry.origin = .manual
        entry.aliases = aliases.map { original in
            var alias = original
            alias.source = .manual
            return alias
        }
        return entry
    }

}

struct TerminologyConflictCandidate: Codable, Sendable, Equatable, Hashable {
    let entryID: UUID
    let canonicalText: String
    let origin: TerminologyOrigin
}

struct TerminologyConflict: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let normalizedAlias: String
    let aliases: [String]
    let candidates: [TerminologyConflictCandidate]
}

struct TerminologyDocument: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1
    static let currentMigrationVersion = 1

    let schemaVersion: Int
    var migrationVersion: Int
    var entries: [TerminologyEntry]
    var conflicts: [TerminologyConflict]

    init(
        schemaVersion: Int = currentSchemaVersion,
        migrationVersion: Int = 0,
        entries: [TerminologyEntry] = [],
        conflicts: [TerminologyConflict] = []
    ) {
        self.schemaVersion = schemaVersion
        self.migrationVersion = migrationVersion
        self.entries = entries
        self.conflicts = conflicts
    }

    static let empty = TerminologyDocument()
}

enum TerminologyText {
    private static let flexibleSeparators = CharacterSet(
        charactersIn: "-_‐‑‒–—―﹘﹣－"
    )

    static func cleaned(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 用于实体身份、alias 冲突和灵活匹配。大小写、全半角、空白与常见连字符不影响结果。
    static func normalizedKey(_ text: String) -> String {
        let mapped = cleaned(text).precomposedStringWithCompatibilityMapping.lowercased()
        return String(mapped.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !flexibleSeparators.contains(scalar)
        })
    }

    /// 用于判断是否只是同一展示写法；保留空格与连字符，避免丢弃 `Type less → Typeless`。
    static func displayKey(_ text: String) -> String {
        let mapped = cleaned(text).precomposedStringWithCompatibilityMapping
        var result = ""
        var pendingWhitespace = false
        for character in mapped {
            if character.isWhitespace {
                pendingWhitespace = !result.isEmpty
            } else {
                if pendingWhitespace { result.append(" ") }
                result.append(character)
                pendingWhitespace = false
            }
        }
        return result
    }

    static func aliasStorageKey(_ text: String) -> String {
        displayKey(text).lowercased()
    }

    static func entryIdentityKey(canonicalText: String, scope: TerminologyScope) -> String {
        scope.identityKey + "|" + normalizedKey(canonicalText)
    }
}

enum TerminologyDocumentNormalizer {
    static func normalized(_ document: TerminologyDocument) -> TerminologyDocument {
        let entries = mergedEntries(document.entries)
        return TerminologyDocument(
            schemaVersion: TerminologyDocument.currentSchemaVersion,
            migrationVersion: max(0, document.migrationVersion),
            entries: entries,
            conflicts: conflicts(
                for: entries,
                separateScopes: true,
                ignoredGlobalCanonicalKeys: []
            )
        )
    }

    static func mergedEntries(_ input: [TerminologyEntry]) -> [TerminologyEntry] {
        var positions: [String: Int] = [:]
        var result: [TerminologyEntry] = []

        for rawEntry in input {
            guard let entry = cleanedEntry(rawEntry) else { continue }
            let key = TerminologyText.entryIdentityKey(
                canonicalText: entry.canonicalText,
                scope: entry.scope
            ) + (entry.origin == .builtIn ? "|builtin" : "|user")
            if let index = positions[key] {
                result[index] = merge(result[index], entry)
            } else {
                positions[key] = result.count
                result.append(entry)
            }
        }
        return result
    }

    private static func cleanedEntry(_ rawEntry: TerminologyEntry) -> TerminologyEntry? {
        let canonical = TerminologyText.cleaned(rawEntry.canonicalText)
        guard !canonical.isEmpty else { return nil }

        let canonicalDisplayKey = TerminologyText.displayKey(canonical)
        var aliasPositions: [String: Int] = [:]
        var aliases: [TerminologyAlias] = []
        for var alias in rawEntry.aliases {
            alias.text = TerminologyText.cleaned(alias.text)
            alias.evidenceCount = max(1, alias.evidenceCount)
            var seenRecordIDs = Set<String>()
            alias.sourceRecordIDs = alias.sourceRecordIDs.compactMap { rawID in
                let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, seenRecordIDs.insert(id).inserted else { return nil }
                return id
            }
            guard !alias.text.isEmpty,
                  TerminologyText.displayKey(alias.text) != canonicalDisplayKey
            else { continue }

            let key = TerminologyText.aliasStorageKey(alias.text)
            guard !key.isEmpty else { continue }
            if let index = aliasPositions[key] {
                aliases[index] = merge(aliases[index], alias)
            } else {
                aliasPositions[key] = aliases.count
                aliases.append(alias)
            }
        }

        return TerminologyEntry(
            id: rawEntry.id,
            canonicalText: canonical,
            aliases: aliases,
            isEnabled: rawEntry.isEnabled,
            origin: rawEntry.origin,
            scope: normalizedScope(rawEntry.scope),
            createdAt: rawEntry.createdAt,
            updatedAt: max(rawEntry.createdAt, rawEntry.updatedAt)
        )
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

    private static func merge(_ existing: TerminologyEntry, _ incoming: TerminologyEntry) -> TerminologyEntry {
        // 同一词条的持久来源不能被可撤销的历史来源覆盖；冲突排序仍用原优先级。
        let differentLifetime = (existing.origin == .confirmedCorrection) != (incoming.origin == .confirmedCorrection)
        let incomingWins = differentLifetime
            ? existing.origin == .confirmedCorrection
            : incoming.origin.priority > existing.origin.priority
        let preferred = incomingWins ? incoming : existing
        let other = incomingWins ? existing : incoming
        let aliases = mergeAliases(preferred.aliases + other.aliases)
        return TerminologyEntry(
            id: existing.id,
            canonicalText: preferred.canonicalText,
            aliases: aliases,
            isEnabled: preferred.isEnabled,
            origin: preferred.origin,
            scope: preferred.scope,
            createdAt: min(existing.createdAt, incoming.createdAt),
            updatedAt: max(existing.updatedAt, incoming.updatedAt)
        )
    }

    private static func mergeAliases(_ input: [TerminologyAlias]) -> [TerminologyAlias] {
        var positions: [String: Int] = [:]
        var result: [TerminologyAlias] = []
        for alias in input {
            let key = TerminologyText.aliasStorageKey(alias.text)
            guard !key.isEmpty else { continue }
            if let index = positions[key] {
                result[index] = merge(result[index], alias)
            } else {
                positions[key] = result.count
                result.append(alias)
            }
        }
        return result
    }

    private static func merge(_ existing: TerminologyAlias, _ incoming: TerminologyAlias) -> TerminologyAlias {
        let differentLifetime = (existing.source == .confirmedCorrection) != (incoming.source == .confirmedCorrection)
        let incomingWins = differentLifetime
            ? existing.source == .confirmedCorrection
            : incoming.source.priority > existing.source.priority
        let preferred = incomingWins ? incoming : existing
        return TerminologyAlias(
            id: existing.id,
            text: preferred.text,
            source: preferred.source,
            evidenceCount: max(existing.evidenceCount, incoming.evidenceCount),
            lastSeenAt: [existing.lastSeenAt, incoming.lastSeenAt].compactMap { $0 }.max(),
            sourceRecordIDs: orderedUnion(existing.sourceRecordIDs, incoming.sourceRecordIDs)
        )
    }

    private static func orderedUnion(_ lhs: [String], _ rhs: [String]) -> [String] {
        var seen = Set<String>()
        return (lhs + rhs).filter { seen.insert($0).inserted }
    }

    static func runtimeConflicts(for entries: [TerminologyEntry]) -> [TerminologyConflict] {
        let applicationSurfaceKeys = Set(entries.filter {
            $0.scope.kind == .application
        }.flatMap { entry in
            [TerminologyText.normalizedKey(entry.canonicalText)]
                + entry.aliases.map { TerminologyText.normalizedKey($0.text) }
        })
        let effectiveEntries = entries.map { entry -> TerminologyEntry in
            guard entry.scope.kind == .global else { return entry }
            var filtered = entry
            filtered.aliases.removeAll {
                applicationSurfaceKeys.contains(TerminologyText.normalizedKey($0.text))
            }
            return filtered
        }
        return conflicts(
            for: effectiveEntries,
            separateScopes: false,
            ignoredGlobalCanonicalKeys: applicationSurfaceKeys
        )
    }

    private static func conflicts(
        for entries: [TerminologyEntry],
        separateScopes: Bool,
        ignoredGlobalCanonicalKeys: Set<String>
    ) -> [TerminologyConflict] {
        struct Bucket {
            var aliases = Set<String>()
            var candidates: [String: TerminologyConflictCandidate] = [:]
        }

        var canonicalOwners: [String: TerminologyEntry] = [:]
        for entry in entries {
            let keyPrefix = separateScopes ? entry.scope.identityKey + "|" : ""
            let canonicalKey = TerminologyText.normalizedKey(entry.canonicalText)
            if !separateScopes,
               entry.scope.kind == .global,
               ignoredGlobalCanonicalKeys.contains(canonicalKey) {
                continue
            }
            canonicalOwners[keyPrefix + canonicalKey] = entry
        }
        var buckets: [String: Bucket] = [:]

        for entry in entries {
            for alias in entry.aliases {
                let aliasKey = TerminologyText.normalizedKey(alias.text)
                guard !aliasKey.isEmpty else { continue }
                let keyPrefix = separateScopes ? entry.scope.identityKey + "|" : ""
                let bucketKey = keyPrefix + aliasKey
                var bucket = buckets[bucketKey, default: Bucket()]
                bucket.aliases.insert(alias.text)
                bucket.candidates[TerminologyText.normalizedKey(entry.canonicalText)] = TerminologyConflictCandidate(
                    entryID: entry.id,
                    canonicalText: entry.canonicalText,
                    origin: entry.origin
                )
                if let canonicalOwner = canonicalOwners[keyPrefix + aliasKey],
                   TerminologyText.normalizedKey(canonicalOwner.canonicalText)
                    != TerminologyText.normalizedKey(entry.canonicalText) {
                    bucket.candidates[TerminologyText.normalizedKey(canonicalOwner.canonicalText)] = TerminologyConflictCandidate(
                        entryID: canonicalOwner.id,
                        canonicalText: canonicalOwner.canonicalText,
                        origin: canonicalOwner.origin
                    )
                }
                buckets[bucketKey] = bucket
            }
        }

        return buckets.compactMap { key, bucket in
            guard bucket.candidates.count > 1 else { return nil }
            let normalizedAlias = separateScopes
                ? String(key.split(separator: "|", maxSplits: 1).last ?? Substring(key))
                : key
            return TerminologyConflict(
                id: key,
                normalizedAlias: normalizedAlias,
                aliases: bucket.aliases.sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                },
                candidates: bucket.candidates.values.sorted {
                    if $0.canonicalText != $1.canonicalText {
                        return $0.canonicalText.localizedCaseInsensitiveCompare($1.canonicalText)
                            == .orderedAscending
                    }
                    return $0.entryID.uuidString < $1.entryID.uuidString
                }
            )
        }.sorted { $0.normalizedAlias < $1.normalizedAlias }
    }
}
