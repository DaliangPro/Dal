import Foundation
import XCTest
@testable import Muse

final class TerminologyRepositoryTests: XCTestCase {
    func testPersistentAliasSourceSurvivesMergeAndEvidenceRestoreInEitherOrder() throws {
        for reversed in [false, true] {
            let fixture = try TerminologyStorageFixture()
            defer { fixture.cleanup() }
            try fixture.seedEmptyBuiltIns()
            _ = try TerminologyRepository.migrateIfNeeded(context: fixture.context)
            let learned = TerminologyEntry(canonicalText: "Typeless", aliases: [
                .init(text: "Tablets", source: .confirmedCorrection, sourceRecordIDs: ["learned"])
            ], origin: .confirmedCorrection)
            let manual = TerminologyEntry(canonicalText: "Typeless", aliases: [
                .init(text: "Tablets", source: .manual)
            ], origin: .manual)
            try TerminologyRepository.save(TerminologyDocument(entries: reversed ? [manual, learned] : [learned, manual]), context: fixture.context)
            let snapshot = try TerminologyRepository.evidenceSnapshot(sourceRecordID: "learned", context: fixture.context)
            try TerminologyRepository.restoreEvidence(snapshot, context: fixture.context)
            try TerminologyRepository.removeEvidence(sourceRecordID: "learned", context: fixture.context)
            let entry = try XCTUnwrap(TerminologyRepository.load(context: fixture.context).entries.first { $0.canonicalText == "Typeless" })
            XCTAssertEqual(entry.origin, .manual)
            XCTAssertEqual(entry.aliases.first?.source, .manual)
            XCTAssertEqual(entry.aliases.first?.sourceRecordIDs, [])
            XCTAssertEqual(TerminologyRepository.projections(context: fixture.context).corrections["Tablets"], "Typeless")
        }
    }

    func testRestoringOlderAutomaticSnapshotKeepsLaterManualSave() throws {
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try fixture.seedEmptyBuiltIns()
        _ = try TerminologyRepository.migrateIfNeeded(context: fixture.context)
        try TerminologyRepository.replaceEvidence(sourceRecordID: "rollback", with: [.init(alias: "Tablets", canonical: "Typeless")], context: fixture.context)
        let snapshot = try TerminologyRepository.evidenceSnapshot(sourceRecordID: "rollback", context: fixture.context)
        try TerminologyRepository.upsert(TerminologyEntry(canonicalText: "Typeless", aliases: [.init(text: "Tablets")]), context: fixture.context)
        try TerminologyRepository.restoreEvidence(snapshot, context: fixture.context)
        try TerminologyRepository.removeEvidence(sourceRecordID: "rollback", context: fixture.context)
        let entry = try XCTUnwrap(TerminologyRepository.load(context: fixture.context).entries.first { $0.canonicalText == "Typeless" })
        XCTAssertEqual(entry.origin, .manual)
        XCTAssertEqual(entry.aliases.first?.source, .manual)
        XCTAssertEqual(entry.aliases.first?.sourceRecordIDs, [])
    }

    func testManualSaveMarkerDoesNotChangeBuiltInEntry() {
        let builtIn = TerminologyEntry(canonicalText: "Claude", aliases: [.init(text: "cloud", source: .builtIn)], origin: .builtIn)
        XCTAssertEqual(builtIn.markedAsManual(), builtIn)
    }

    func testDeletingMainPunctuatedTermRemovesItsCopiesAndDoesNotReappearOnNextSave() throws {
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try fixture.seedEmptyBuiltIns()
        _ = try TerminologyRepository.migrateIfNeeded(context: fixture.context)
        let targets = ["Agents", "Skill"].map { word in
            TerminologyEntry(canonicalText: "\(word).md", aliases: [TerminologyAlias(text: "\(word) 点 MD。")])
        }
        for entry in targets { try TerminologyRepository.upsert(entry, context: fixture.context) }
        let snippets = SnippetStorage.load(context: fixture.context)
        XCTAssertEqual(snippets.count, 2)
        XCTAssertTrue(snippets.allSatisfy {
            !TerminologyMigration.isEligibleTerminologySnippet(trigger: $0.trigger, value: $0.value)
        }, "句末标点使兼容副本落入旧 UI 的独立固定替换分支")
        let manifest = try TerminologyMigration.loadManifest(context: fixture.context)
        XCTAssertTrue(VocabularySnippetGrouping.standaloneReplacements(
            in: snippets, terms: TerminologyRepository.load(context: fixture.context).entries,
            ownedCorrections: manifest.ownedCorrections
        ).isEmpty)

        // 复现旧入口删除副本后，下次保存主词库又把它补回。
        try SnippetStorage.save([], context: fixture.context)
        try TerminologyRepository.save(TerminologyRepository.load(context: fixture.context), context: fixture.context)
        XCTAssertEqual(SnippetStorage.load(context: fixture.context).count, 2)

        for entry in targets { try TerminologyRepository.remove(id: entry.id, context: fixture.context) }
        try TerminologyRepository.upsert(TerminologyEntry(canonicalText: "UnrelatedTerm"), context: fixture.context)
        let loaded = TerminologyRepository.load(context: fixture.context)
        for entry in targets {
            XCTAssertFalse(loaded.entries.contains { $0.canonicalText == entry.canonicalText })
            XCTAssertFalse(HotwordStorage.load(context: fixture.context).contains(entry.canonicalText))
            XCTAssertFalse(SnippetStorage.load(context: fixture.context).contains { $0.value == entry.canonicalText })
            XCTAssertFalse(PersonalLexiconStorage.load(context: fixture.context).entries.contains {
                $0.canonical == entry.canonicalText
            })
        }
    }

    func testProjectionCorrectsTypelessAliasVariantsAndOmitsAmbiguousAlias() {
        let typeless = TerminologyEntry(
            canonicalText: "Typeless",
            aliases: [
                TerminologyAlias(text: "Type less", source: .manual),
                TerminologyAlias(text: "type list", source: .manual),
                TerminologyAlias(text: "Type-less", source: .legacySnippet),
                TerminologyAlias(text: "typeless", source: .confirmedCorrection),
            ]
        )
        let first = TerminologyEntry(
            canonicalText: "Alpha",
            aliases: [TerminologyAlias(text: "shared", source: .manual)]
        )
        let second = TerminologyEntry(
            canonicalText: "Beta",
            aliases: [TerminologyAlias(text: "Shared", source: .manual)]
        )

        let document = TerminologyDocumentNormalizer.normalized(TerminologyDocument(
            entries: [typeless, first, second]
        ))
        let projection = TerminologyProjections.make(from: document)

        XCTAssertEqual(
            document.entries.first?.aliases.map(\.text),
            ["Type less", "type list", "Type-less", "typeless"]
        )
        XCTAssertEqual(projection.corrections["Type less"], "Typeless")
        XCTAssertEqual(projection.corrections["type list"], "Typeless")
        XCTAssertEqual(projection.corrections["Type-less"], "Typeless")
        XCTAssertEqual(projection.corrections["typeless"], "Typeless")
        XCTAssertEqual(
            EntityResolver.applyingKnownCorrections(
                projection.corrections,
                to: "Type less、type list、TypeLess"
            ),
            "Typeless、Typeless、Typeless"
        )
        XCTAssertNil(projection.corrections["shared"])
        XCTAssertNil(projection.corrections["Shared"])
        XCTAssertEqual(document.conflicts.count, 1)
        XCTAssertEqual(Set(document.conflicts[0].candidates.map(\.canonicalText)), ["Alpha", "Beta"])
    }

    func testMigrationIsNonDestructiveSelectiveAndIdempotent() throws {
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try HotwordStorage.save(["Typeless"], context: fixture.context)
        try HotwordStorage.saveBuiltin([], context: fixture.context)
        try SnippetStorage.save([
            (trigger: "Cloud Code", value: "Claude Code"),
            (trigger: "发我的工作邮箱", value: "name@example.com"),
            (trigger: "这是一整句错误规则。", value: "这是一整句正确文字。"),
        ], context: fixture.context)
        try SnippetStorage.saveBuiltin([], context: fixture.context)
        try PersonalLexiconStorage.save(
            PersonalLexiconDocument(schemaVersion: 1, entries: [PersonalLexiconEntry(
                canonical: "Typeless",
                aliases: ["Type less"],
                source: .manual
            )]),
            syncToASR: false,
            context: fixture.context
        )
        let hotwordBytes = try Data(contentsOf: HotwordStorage.userFileURL(in: fixture.context))
        let snippetBytes = try Data(contentsOf: SnippetStorage.userFileURL(in: fixture.context))
        let personalBytes = try Data(contentsOf: PersonalLexiconStorage.fileURL(in: fixture.context))

        let first = try TerminologyRepository.migrateIfNeeded(context: fixture.context)
        guard case .value(let migrated) = TerminologyRepository.loadResult(context: fixture.context) else {
            return XCTFail("迁移后应生成统一术语文件")
        }
        let second = try TerminologyRepository.migrateIfNeeded(context: fixture.context)
        guard case .value(let afterRetry) = TerminologyRepository.loadResult(context: fixture.context) else {
            return XCTFail("幂等重试后统一术语文件应仍可读")
        }

        XCTAssertTrue(first.didMigrate)
        XCTAssertFalse(second.didMigrate)
        XCTAssertEqual(migrated, afterRetry)
        XCTAssertEqual(migrated.migrationVersion, TerminologyDocument.currentMigrationVersion)
        XCTAssertEqual(migrated.entries.filter {
            TerminologyText.normalizedKey($0.canonicalText) == TerminologyText.normalizedKey("Typeless")
        }.count, 1)
        XCTAssertTrue(migrated.entries.contains { $0.canonicalText == "Claude Code" })
        XCTAssertFalse(migrated.entries.contains { $0.canonicalText == "name@example.com" })
        XCTAssertFalse(migrated.entries.contains { $0.canonicalText == "这是一整句正确文字。" })
        XCTAssertEqual(try Data(contentsOf: HotwordStorage.userFileURL(in: fixture.context)), hotwordBytes)
        XCTAssertEqual(try Data(contentsOf: SnippetStorage.userFileURL(in: fixture.context)), snippetBytes)
        XCTAssertEqual(try Data(contentsOf: PersonalLexiconStorage.fileURL(in: fixture.context)), personalBytes)
        XCTAssertEqual(SnippetStorage.load(context: fixture.context).count, 3)
    }

    func testMigrationConflictDoesNotSilentlyCreateCorrection() throws {
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try fixture.seedEmptyBuiltIns()
        try PersonalLexiconStorage.save(
            PersonalLexiconDocument(schemaVersion: 1, entries: [
                PersonalLexiconEntry(canonical: "Alpha", aliases: ["shared"]),
                PersonalLexiconEntry(canonical: "Beta", aliases: ["Shared"]),
            ]),
            syncToASR: false,
            context: fixture.context
        )

        _ = try TerminologyRepository.migrateIfNeeded(context: fixture.context)
        let document = TerminologyRepository.load(context: fixture.context)
        let projection = TerminologyProjections.make(from: document)

        XCTAssertEqual(document.conflicts.count, 1)
        XCTAssertTrue(projection.corrections.isEmpty)
    }

    func testCorruptLegacySourceStopsMigrationAndPreservesRecoveryBytes() throws {
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try fixture.seedEmptyBuiltIns()
        let invalid = Data("{not-json".utf8)
        let sourceURL = PersonalLexiconStorage.fileURL(in: fixture.context)
        try invalid.write(to: sourceURL)

        XCTAssertThrowsError(try TerminologyRepository.migrateIfNeeded(context: fixture.context))
        XCTAssertFalse(fixture.context.fileManager.fileExists(
            atPath: TerminologyRepository.fileURL(in: fixture.context).path
        ))
        XCTAssertFalse(fixture.context.fileManager.fileExists(
            atPath: TerminologyMigration.manifestURL(in: fixture.context).path
        ))
        let backups = try fixture.context.fileManager.contentsOfDirectory(
            at: fixture.directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("voice-polish-lexicon.json.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), invalid)
    }

    func testFailureBeforeCommitDoesNotAdvanceMigrationVersionAndCanRetry() throws {
        enum PlannedFailure: Error { case stop }
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try fixture.seedEmptyBuiltIns()
        try HotwordStorage.save(["Typeless"], context: fixture.context)

        XCTAssertThrowsError(try TerminologyRepository.migrateIfNeeded(
            context: fixture.context,
            hooks: TerminologyMigrationHooks(beforeDocumentCommit: { throw PlannedFailure.stop })
        ))
        switch TerminologyRepository.loadResult(context: fixture.context) {
        case .missing:
            break
        case .value(let document):
            XCTAssertLessThan(document.migrationVersion, TerminologyDocument.currentMigrationVersion)
        case .corrupt:
            XCTFail("计划失败不应损坏统一术语文件")
        }

        let retried = try TerminologyRepository.migrateIfNeeded(context: fixture.context)
        XCTAssertTrue(retried.didMigrate)
        XCTAssertEqual(
            TerminologyRepository.load(context: fixture.context).migrationVersion,
            TerminologyDocument.currentMigrationVersion
        )
    }

    func testDualWriteReadThroughAndOwnedProjectionRemoval() throws {
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try fixture.seedEmptyBuiltIns()
        _ = try TerminologyRepository.migrateIfNeeded(context: fixture.context)
        let entry = TerminologyEntry(
            canonicalText: "Typeless",
            aliases: [TerminologyAlias(text: "Type less")]
        )

        try TerminologyRepository.upsert(entry, context: fixture.context)

        XCTAssertTrue(HotwordStorage.load(context: fixture.context).contains("Typeless"))
        XCTAssertTrue(SnippetStorage.load(context: fixture.context).contains {
            $0.trigger == "Type less" && $0.value == "Typeless"
        })
        XCTAssertTrue(PersonalLexiconStorage.load(context: fixture.context).entries.contains {
            $0.id == entry.id
        })

        var oldHotwords = HotwordStorage.load(context: fixture.context)
        oldHotwords.append("ExternalTerm")
        try HotwordStorage.save(oldHotwords, context: fixture.context)
        XCTAssertTrue(TerminologyRepository.load(context: fixture.context).entries.contains {
            $0.canonicalText == "ExternalTerm"
        })

        try TerminologyRepository.remove(id: entry.id, context: fixture.context)

        XCTAssertFalse(HotwordStorage.load(context: fixture.context).contains("Typeless"))
        XCTAssertTrue(HotwordStorage.load(context: fixture.context).contains("ExternalTerm"))
        XCTAssertFalse(SnippetStorage.load(context: fixture.context).contains {
            $0.trigger == "Type less"
        })
        XCTAssertFalse(TerminologyRepository.load(context: fixture.context).entries.contains {
            $0.id == entry.id
        })
    }

    func testReadThroughUsesStableIdentityBeforeMigrationIsCommitted() throws {
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try HotwordStorage.save(["Typeless"], context: fixture.context)
        try HotwordStorage.saveBuiltin(["OpenAI"], context: fixture.context)
        try SnippetStorage.save([
            (trigger: "Cloud Code", value: "Claude Code"),
        ], context: fixture.context)
        try SnippetStorage.saveBuiltin([
            (trigger: "Code X", value: "Codex"),
        ], context: fixture.context)

        let first = TerminologyRepository.load(context: fixture.context)
        let second = TerminologyRepository.load(context: fixture.context)

        XCTAssertEqual(first, second)
        XCTAssertFalse(fixture.context.fileManager.fileExists(
            atPath: TerminologyRepository.fileURL(in: fixture.context).path
        ))
    }

    func testDeletingImportedLegacyTermPreservesOldFileButSuppressesReadThrough() throws {
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try fixture.seedEmptyBuiltIns()
        try HotwordStorage.save(["LegacyTerm"], context: fixture.context)
        _ = try TerminologyRepository.migrateIfNeeded(context: fixture.context)
        let entry = try XCTUnwrap(TerminologyRepository.load(context: fixture.context).entries.first {
            $0.canonicalText == "LegacyTerm"
        })

        try TerminologyRepository.remove(id: entry.id, context: fixture.context)

        XCTAssertTrue(HotwordStorage.load(context: fixture.context).contains("LegacyTerm"))
        XCTAssertFalse(TerminologyRepository.load(context: fixture.context).entries.contains {
            $0.canonicalText == "LegacyTerm"
        })
    }

    func testConfirmedCorrectionTracksAndRevokesHistoryEvidence() throws {
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try fixture.seedEmptyBuiltIns()
        _ = try TerminologyRepository.migrateIfNeeded(context: fixture.context)

        _ = try TerminologyRepository.confirmCorrection(
            alias: "Type less",
            canonical: "Typeless",
            sourceRecordID: "history-1",
            context: fixture.context
        )
        _ = try TerminologyRepository.confirmCorrection(
            alias: "Type less",
            canonical: "Typeless",
            sourceRecordID: "history-2",
            context: fixture.context
        )
        var entry = try XCTUnwrap(TerminologyRepository.load(context: fixture.context).entries.first {
            $0.canonicalText == "Typeless"
        })
        XCTAssertEqual(entry.aliases.first?.sourceRecordIDs, ["history-1", "history-2"])

        XCTAssertTrue(try TerminologyRepository.removeEvidence(
            sourceRecordID: "history-1",
            context: fixture.context
        ))
        entry = try XCTUnwrap(TerminologyRepository.load(context: fixture.context).entries.first {
            $0.canonicalText == "Typeless"
        })
        XCTAssertEqual(entry.aliases.first?.sourceRecordIDs, ["history-2"])

        XCTAssertTrue(try TerminologyRepository.removeEvidence(
            sourceRecordID: "history-2",
            context: fixture.context
        ))
        XCTAssertFalse(TerminologyRepository.load(context: fixture.context).entries.contains {
            $0.canonicalText == "Typeless"
        })
    }

    func testProviderCapabilityMatrixReflectsCurrentDeliveryPaths() {
        let volcano = ASRTerminologyCapabilities.forProvider(.volcano)
        XCTAssertTrue(volcano.supportsRequestHotwords)
        XCTAssertTrue(volcano.supportsAliasCorrections)
        XCTAssertTrue(volcano.requiresLocalCorrectionFallback)

        let aliyun = ASRTerminologyCapabilities.forProvider(.aliyun)
        XCTAssertTrue(aliyun.supportsRemoteVocabularySync)
        XCTAssertFalse(aliyun.supportsAliasCorrections)

        let apple = ASRTerminologyCapabilities.forProvider(.apple)
        XCTAssertEqual(apple.hotwordDelivery, .unsupported)
        XCTAssertEqual(apple.aliasDelivery, .localOnly)

        let local = ASRTerminologyCapabilities.forProvider(.sherpa)
        XCTAssertTrue(local.supportsLocalServiceVocabulary)
        XCTAssertEqual(local.aliasDelivery, .localOnly)
    }

    func testProjectionFiltersGlobalAndApplicationScopes() {
        let document = TerminologyDocument(entries: [
            TerminologyEntry(
                canonicalText: "GlobalTerm",
                aliases: [
                    TerminologyAlias(text: "global alias"),
                    TerminologyAlias(text: "same alias"),
                    TerminologyAlias(text: "AppATerm"),
                ],
                scope: .global
            ),
            TerminologyEntry(
                canonicalText: "AppATerm",
                aliases: [TerminologyAlias(text: "same alias")],
                scope: .application("com.example.app-a")
            ),
            TerminologyEntry(
                canonicalText: "AppBTerm",
                aliases: [TerminologyAlias(text: "same alias")],
                scope: .application("com.example.app-b")
            ),
        ])
        XCTAssertTrue(TerminologyDocumentNormalizer.normalized(document).conflicts.isEmpty)

        let noApplication = TerminologyProjections.make(from: document)
        XCTAssertEqual(noApplication.hotwords, ["GlobalTerm"])
        XCTAssertEqual(noApplication.corrections["global alias"], "GlobalTerm")
        XCTAssertEqual(noApplication.corrections["same alias"], "GlobalTerm")
        XCTAssertEqual(noApplication.corrections["AppATerm"], "GlobalTerm")

        let appA = TerminologyProjections.make(
            from: document,
            applicationBundleIdentifier: "com.example.app-a"
        )
        XCTAssertEqual(Set(appA.hotwords), ["GlobalTerm", "AppATerm"])
        XCTAssertEqual(appA.corrections["same alias"], "AppATerm")
        XCTAssertNil(appA.corrections["AppATerm"])
        XCTAssertTrue(appA.conflicts.isEmpty)
        XCTAssertEqual(
            Set(appA.personalLexicon.entries.map(\.canonical)),
            ["GlobalTerm", "AppATerm"]
        )
        XCTAssertFalse(appA.personalLexicon.entries.first {
            $0.canonical == "GlobalTerm"
        }?.aliases.contains("same alias") == true)

        let appB = TerminologyProjections.make(
            from: document,
            applicationBundleIdentifier: "com.example.app-b"
        )
        XCTAssertEqual(Set(appB.hotwords), ["GlobalTerm", "AppBTerm"])
        XCTAssertEqual(appB.corrections["same alias"], "AppBTerm")

        let unmatched = TerminologyProjections.make(
            from: document,
            applicationBundleIdentifier: "com.example.other"
        )
        XCTAssertEqual(unmatched.hotwords, ["GlobalTerm"])
        XCTAssertEqual(unmatched.corrections["same alias"], "GlobalTerm")
    }

    func testSameApplicationScopeAliasConflictRemainsAmbiguous() {
        let document = TerminologyDocument(entries: [
            TerminologyEntry(
                canonicalText: "First",
                aliases: [TerminologyAlias(text: "shared")],
                scope: .application("com.example.app-a")
            ),
            TerminologyEntry(
                canonicalText: "Second",
                aliases: [TerminologyAlias(text: "Shared")],
                scope: .application("com.example.app-a")
            ),
        ])

        let projection = TerminologyProjections.make(
            from: document,
            applicationBundleIdentifier: "com.example.app-a"
        )

        XCTAssertEqual(projection.conflicts.count, 1)
        XCTAssertNil(projection.corrections["shared"])
        XCTAssertNil(projection.corrections["Shared"])
    }

    func testApplicationScopedTermNeverDualWritesToGlobalLegacyStores() throws {
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try fixture.seedEmptyBuiltIns()
        _ = try TerminologyRepository.migrateIfNeeded(context: fixture.context)
        let entry = TerminologyEntry(
            canonicalText: "AppSecretTerm",
            aliases: [TerminologyAlias(text: "secret alias")],
            scope: .application("com.example.app-a")
        )

        try TerminologyRepository.upsert(entry, context: fixture.context)

        XCTAssertTrue(HotwordStorage.load(context: fixture.context).isEmpty)
        XCTAssertTrue(SnippetStorage.load(context: fixture.context).isEmpty)
        XCTAssertTrue(PersonalLexiconStorage.load(context: fixture.context).entries.isEmpty)
        XCTAssertTrue(TerminologyRepository.projections(
            applicationBundleIdentifier: "com.example.app-a",
            context: fixture.context
        ).hotwords.contains("AppSecretTerm"))
        XCTAssertFalse(TerminologyRepository.projections(context: fixture.context)
            .hotwords.contains("AppSecretTerm"))
    }

    func testBuiltInContentCannotBeRemovedOrUpsertedButCanBeDisabled() throws {
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try HotwordStorage.saveBuiltin(["OpenAI"], context: fixture.context)
        try SnippetStorage.saveBuiltin([], context: fixture.context)
        _ = try TerminologyRepository.migrateIfNeeded(context: fixture.context)
        let builtIn = try XCTUnwrap(TerminologyRepository.load(context: fixture.context).entries.first {
            $0.canonicalText == "OpenAI" && $0.origin == .builtIn
        })

        XCTAssertThrowsError(try TerminologyRepository.remove(id: builtIn.id, context: fixture.context))
        var modified = builtIn
        modified.canonicalText = "Open AI"
        XCTAssertThrowsError(try TerminologyRepository.upsert(modified, context: fixture.context))
        var disguisedBuiltIn = builtIn
        disguisedBuiltIn.origin = .manual
        XCTAssertThrowsError(try TerminologyRepository.upsert(disguisedBuiltIn, context: fixture.context))
        var aliasModifiedDocument = TerminologyRepository.load(context: fixture.context)
        let aliasModifiedIndex = try XCTUnwrap(aliasModifiedDocument.entries.firstIndex {
            $0.id == builtIn.id
        })
        aliasModifiedDocument.entries[aliasModifiedIndex].aliases.append(
            TerminologyAlias(text: "Open AI")
        )
        XCTAssertThrowsError(try TerminologyRepository.save(
            aliasModifiedDocument,
            context: fixture.context
        ))

        var timestampModifiedDocument = TerminologyRepository.load(context: fixture.context)
        let timestampModifiedIndex = try XCTUnwrap(timestampModifiedDocument.entries.firstIndex {
            $0.id == builtIn.id
        })
        timestampModifiedDocument.entries[timestampModifiedIndex].updatedAt = Date().addingTimeInterval(60)
        XCTAssertThrowsError(try TerminologyRepository.save(
            timestampModifiedDocument,
            context: fixture.context
        ))

        try TerminologyRepository.setEnabled(false, id: builtIn.id, context: fixture.context)
        XCTAssertFalse(try XCTUnwrap(TerminologyRepository.load(context: fixture.context).entries.first {
            $0.id == builtIn.id
        }).isEnabled)
        XCTAssertFalse(TerminologyRepository.projections(context: fixture.context)
            .hotwords.contains("OpenAI"))
    }

    func testUserCanEditAndDeleteAliasesForBuiltInWordWithoutFalseConflicts() throws {
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try HotwordStorage.saveBuiltin(["Claude"], context: fixture.context)
        try SnippetStorage.saveBuiltin([(trigger: "Claud", value: "Claude")], context: fixture.context)
        _ = try TerminologyRepository.migrateIfNeeded(context: fixture.context)
        let builtIn = try XCTUnwrap(TerminologyRepository.load(context: fixture.context).entries.first {
            $0.origin == .builtIn && $0.canonicalText == "Claude"
        })
        var personal = TerminologyEntry(
            canonicalText: "Claude", aliases: [TerminologyAlias(text: "cloud"), TerminologyAlias(text: "Claud")]
        )
        try TerminologyRepository.upsert(personal, context: fixture.context)
        var loaded = TerminologyRepository.load(context: fixture.context)
        XCTAssertEqual(loaded.entries.first { $0.id == builtIn.id }, builtIn)
        XCTAssertTrue(loaded.conflicts.isEmpty)
        XCTAssertEqual(TerminologyRepository.projections(context: fixture.context).corrections["cloud"], "Claude")
        personal.aliases.append(TerminologyAlias(text: "cloude"))
        try TerminologyRepository.upsert(personal, context: fixture.context)
        XCTAssertEqual(TerminologyRepository.projections(context: fixture.context).corrections["cloude"], "Claude")
        try TerminologyRepository.remove(id: personal.id, context: fixture.context)
        loaded = TerminologyRepository.load(context: fixture.context)
        XCTAssertEqual(loaded.entries.first { $0.id == builtIn.id }, builtIn)
        XCTAssertFalse(loaded.entries.contains { $0.origin != .builtIn && $0.canonicalText == "Claude" })
        let projection = TerminologyRepository.projections(context: fixture.context)
        XCTAssertNil(projection.corrections["cloud"])
        XCTAssertNil(projection.corrections["cloude"])
        XCTAssertEqual(projection.corrections["Claud"], "Claude")
    }

    func testBatchEvidenceReplacementWritesOnceAndReplacesPreviousCandidates() throws {
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try fixture.seedEmptyBuiltIns()
        _ = try TerminologyRepository.migrateIfNeeded(context: fixture.context)

        _ = try TerminologyRepository.replaceEvidence(
            sourceRecordID: "history-1",
            with: [
                TerminologyCorrectionCandidate(alias: "Type less", canonical: "Typeless"),
                TerminologyCorrectionCandidate(alias: "Cloud Code", canonical: "Claude Code"),
            ],
            context: fixture.context
        )
        XCTAssertEqual(
            Set(TerminologyRepository.load(context: fixture.context).entries.map(\.canonicalText)),
            ["Typeless", "Claude Code"]
        )

        _ = try TerminologyRepository.replaceEvidence(
            sourceRecordID: "history-1",
            with: [TerminologyCorrectionCandidate(alias: "Code X", canonical: "Codex")],
            context: fixture.context
        )
        let replaced = TerminologyRepository.load(context: fixture.context)
        XCTAssertEqual(replaced.entries.map(\.canonicalText), ["Codex"])
        XCTAssertEqual(replaced.entries[0].aliases[0].sourceRecordIDs, ["history-1"])
    }

    func testBatchEvidenceReplacementRollsBackCanonicalDocumentWhenProjectionFails() throws {
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try fixture.seedEmptyBuiltIns()
        _ = try TerminologyRepository.migrateIfNeeded(context: fixture.context)
        _ = try TerminologyRepository.confirmCorrection(
            alias: "Type less",
            canonical: "Typeless",
            sourceRecordID: "history-1",
            context: fixture.context
        )
        guard case .value(let before) = TerminologyRepository.loadResult(context: fixture.context) else {
            return XCTFail("应存在事务前快照")
        }
        try Data("{broken".utf8).write(to: HotwordStorage.userFileURL(in: fixture.context))

        XCTAssertThrowsError(try TerminologyRepository.replaceEvidence(
            sourceRecordID: "history-2",
            with: [TerminologyCorrectionCandidate(alias: "Code X", canonical: "Codex")],
            context: fixture.context
        ))

        guard case .value(let after) = TerminologyRepository.loadResult(context: fixture.context) else {
            return XCTFail("投影失败后统一术语文件应恢复")
        }
        XCTAssertEqual(after, before)
    }

    func testRepositorySaveRollsBackDocumentAndAllCompatibilityFilesBeforeManifestCommit() throws {
        enum PlannedFailure: Error { case stop }
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try fixture.seedEmptyBuiltIns()
        _ = try TerminologyRepository.migrateIfNeeded(context: fixture.context)
        let entry = TerminologyEntry(
            canonicalText: "Typeless",
            aliases: [TerminologyAlias(text: "Type less")]
        )
        try TerminologyRepository.upsert(entry, context: fixture.context)

        guard case .value(let documentBefore) = TerminologyRepository.loadResult(context: fixture.context)
        else { return XCTFail("应存在回滚前的统一术语文件") }
        let manifestBefore = try TerminologyMigration.loadManifest(context: fixture.context)
        let hotwordsBefore = HotwordStorage.load(context: fixture.context)
        let snippetsBefore = SnippetStorage.load(context: fixture.context).map {
            "\($0.trigger)\u{1F}\($0.value)"
        }
        let personalBefore = PersonalLexiconStorage.load(context: fixture.context)
        var proposed = TerminologyRepository.load(context: fixture.context)
        proposed.entries.removeAll { $0.id == entry.id }

        XCTAssertThrowsError(try TerminologyRepository.save(
            proposed,
            context: fixture.context,
            compatibilityHooks: TerminologyCompatibilityProjectionHooks(
                afterHotwordWrite: {},
                afterSnippetWrite: {},
                afterPersonalLexiconWrite: {},
                beforeManifestCommit: { throw PlannedFailure.stop }
            )
        ))

        guard case .value(let documentAfter) = TerminologyRepository.loadResult(context: fixture.context)
        else { return XCTFail("兼容投影失败后应恢复统一术语文件") }
        XCTAssertEqual(documentAfter, documentBefore)
        XCTAssertEqual(try TerminologyMigration.loadManifest(context: fixture.context), manifestBefore)
        XCTAssertEqual(HotwordStorage.load(context: fixture.context), hotwordsBefore)
        XCTAssertEqual(SnippetStorage.load(context: fixture.context).map {
            "\($0.trigger)\u{1F}\($0.value)"
        }, snippetsBefore)
        XCTAssertEqual(PersonalLexiconStorage.load(context: fixture.context), personalBefore)
        XCTAssertTrue(TerminologyRepository.load(context: fixture.context).entries.contains {
            $0.id == entry.id && $0.canonicalText == "Typeless"
        })
    }

    func testExternallyChangedOwnedSnippetIsPreservedAndBecomesUnowned() throws {
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try fixture.seedEmptyBuiltIns()
        _ = try TerminologyRepository.migrateIfNeeded(context: fixture.context)
        let entry = TerminologyEntry(
            canonicalText: "Typeless",
            aliases: [TerminologyAlias(text: "Type less")]
        )
        try TerminologyRepository.upsert(entry, context: fixture.context)
        try SnippetStorage.save(
            [(trigger: "Type less", value: "TypeScript")],
            context: fixture.context
        )

        try TerminologyRepository.remove(id: entry.id, context: fixture.context)

        XCTAssertTrue(SnippetStorage.load(context: fixture.context).contains {
            $0.trigger == "Type less" && $0.value == "TypeScript"
        })
        XCTAssertFalse(SnippetStorage.load(context: fixture.context).contains {
            $0.trigger == "Type less" && $0.value == "Typeless"
        })
        let triggerKey = TerminologyText.normalizedKey("Type less")
        XCTAssertNil(try TerminologyMigration.loadManifest(context: fixture.context)
            .ownedCorrections[triggerKey])
        XCTAssertTrue(TerminologyRepository.load(context: fixture.context).entries.contains {
            $0.canonicalText == "TypeScript"
        })
    }

    func testExternallyChangedOwnedPersonalEntryIsNeverDeletedByID() throws {
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try fixture.seedEmptyBuiltIns()
        _ = try TerminologyRepository.migrateIfNeeded(context: fixture.context)
        let entry = TerminologyEntry(
            canonicalText: "Typeless",
            aliases: [TerminologyAlias(text: "Type less")]
        )
        try TerminologyRepository.upsert(entry, context: fixture.context)
        // 模拟上一版只记录 owned ID、还没有内容指纹的 manifest。
        let manifestURL = TerminologyMigration.manifestURL(in: fixture.context)
        var legacyManifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        legacyManifest.removeValue(forKey: "ownedPersonalEntryFingerprints")
        try JSONSerialization.data(withJSONObject: legacyManifest, options: [.sortedKeys])
            .write(to: manifestURL, options: .atomic)
        XCTAssertNil(try TerminologyMigration.loadManifest(context: fixture.context)
            .ownedPersonalEntryFingerprints)
        var external = PersonalLexiconStorage.load(context: fixture.context)
        let index = try XCTUnwrap(external.entries.firstIndex { $0.id == entry.id })
        external.entries[index].aliases = ["Type less", "Tai Po Les"]
        try PersonalLexiconStorage.save(
            external,
            syncToASR: false,
            context: fixture.context
        )
        let externalBeforeRemoval = PersonalLexiconStorage.load(context: fixture.context)

        try TerminologyRepository.remove(id: entry.id, context: fixture.context)

        let preserved = try XCTUnwrap(PersonalLexiconStorage.load(context: fixture.context)
            .entries.first { $0.id == entry.id })
        XCTAssertEqual(
            preserved,
            try XCTUnwrap(externalBeforeRemoval.entries.first { $0.id == entry.id })
        )
        XCTAssertFalse(TerminologyRepository.load(context: fixture.context).entries.contains {
            $0.id == entry.id
        })
    }

    func testConfirmedEvidenceIsAdditiveForTheSameHistoryRecord() throws {
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try fixture.seedEmptyBuiltIns()
        _ = try TerminologyRepository.migrateIfNeeded(context: fixture.context)

        _ = try TerminologyRepository.confirmCorrection(
            alias: "Type less",
            canonical: "Typeless",
            sourceRecordID: "history-with-two-terms",
            context: fixture.context
        )
        _ = try TerminologyRepository.addConfirmedEvidence(
            alias: "Cloud Code",
            canonical: "Claude Code",
            sourceRecordID: "history-with-two-terms",
            context: fixture.context
        )

        let entries = TerminologyRepository.load(context: fixture.context).entries
        XCTAssertEqual(Set(entries.map(\.canonicalText)), ["Typeless", "Claude Code"])
        XCTAssertTrue(entries.allSatisfy { entry in
            entry.aliases.contains { $0.sourceRecordIDs == ["history-with-two-terms"] }
        })
    }

    func testConfirmCorrectionRejectsCanonicalAliasBeforeChangingExistingEvidence() throws {
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try fixture.seedEmptyBuiltIns()
        _ = try TerminologyRepository.migrateIfNeeded(context: fixture.context)
        _ = try TerminologyRepository.confirmCorrection(
            alias: "Type less",
            canonical: "Typeless",
            sourceRecordID: "history-1",
            context: fixture.context
        )
        guard case .value(let before) = TerminologyRepository.loadResult(context: fixture.context)
        else { return XCTFail("应存在校验失败前的术语快照") }

        XCTAssertThrowsError(try TerminologyRepository.confirmCorrection(
            alias: "Typeless",
            canonical: "Typeless",
            sourceRecordID: "history-1",
            context: fixture.context
        ))

        guard case .value(let after) = TerminologyRepository.loadResult(context: fixture.context)
        else { return XCTFail("校验失败后术语文件应仍可读") }
        XCTAssertEqual(after, before)
    }

    func testBatchConfirmedEvidenceCommitsAllSourceRecordsTogether() throws {
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try fixture.seedEmptyBuiltIns()
        _ = try TerminologyRepository.migrateIfNeeded(context: fixture.context)

        _ = try TerminologyRepository.addConfirmedEvidence(
            alias: "Type less",
            canonical: "Typeless",
            sourceRecordIDs: ["history-1", "history-2", "history-1"],
            context: fixture.context
        )

        let alias = try XCTUnwrap(TerminologyRepository.load(context: fixture.context)
            .entries.first { $0.canonicalText == "Typeless" }?.aliases.first)
        XCTAssertEqual(alias.sourceRecordIDs, ["history-1", "history-2"])
        XCTAssertEqual(alias.evidenceCount, 2)

        guard case .value(let beforeInvalidBatch) = TerminologyRepository.loadResult(
            context: fixture.context
        ) else { return XCTFail("批量校验前应存在术语文件") }
        XCTAssertThrowsError(try TerminologyRepository.addConfirmedEvidence(
            alias: "Cloud Code",
            canonical: "Claude Code",
            sourceRecordIDs: ["history-3", "   "],
            context: fixture.context
        ))
        guard case .value(let afterInvalidBatch) = TerminologyRepository.loadResult(
            context: fixture.context
        ) else { return XCTFail("批量校验失败后术语文件应仍可读") }
        XCTAssertEqual(afterInvalidBatch, beforeInvalidBatch)
    }

    func testEvidenceRestoreOnlyTouchesTargetHistoryID() throws {
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try fixture.seedEmptyBuiltIns()
        _ = try TerminologyRepository.migrateIfNeeded(context: fixture.context)
        _ = try TerminologyRepository.confirmCorrection(
            alias: "Type less",
            canonical: "Typeless",
            sourceRecordID: "history-target",
            context: fixture.context
        )
        let snapshot = try TerminologyRepository.evidenceSnapshot(
            sourceRecordID: "history-target",
            context: fixture.context
        )

        _ = try TerminologyRepository.replaceEvidence(
            sourceRecordID: "history-target",
            with: [TerminologyCorrectionCandidate(alias: "Code X", canonical: "Codex")],
            context: fixture.context
        )
        _ = try TerminologyRepository.confirmCorrection(
            alias: "Cloud Code",
            canonical: "Claude Code",
            sourceRecordID: "history-concurrent",
            context: fixture.context
        )
        try TerminologyRepository.restoreEvidence(snapshot, context: fixture.context)

        let restored = TerminologyRepository.load(context: fixture.context)
        XCTAssertEqual(Set(restored.entries.map(\.canonicalText)), ["Typeless", "Claude Code"])
        XCTAssertTrue(restored.entries.contains { entry in
            entry.canonicalText == "Typeless"
                && entry.aliases.contains { $0.sourceRecordIDs.contains("history-target") }
        })
        XCTAssertTrue(restored.entries.contains { entry in
            entry.canonicalText == "Claude Code"
                && entry.aliases.contains { $0.sourceRecordIDs.contains("history-concurrent") }
        })
    }

    func testCoordinatorRestoresPreviousEvidenceWhenSQLiteConfirmationFails() async throws {
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try fixture.seedEmptyBuiltIns()
        _ = try TerminologyRepository.migrateIfNeeded(context: fixture.context)
        _ = try TerminologyRepository.confirmCorrection(
            alias: "Type less",
            canonical: "Typeless",
            sourceRecordID: "history-coordinated",
            context: fixture.context
        )
        let historyStore = HistoryStore(
            path: fixture.directory.appendingPathComponent("history.db").path
        )
        await historyStore.insert(HistoryRecord(
            id: "history-coordinated",
            createdAt: Date(),
            durationSeconds: 1,
            rawText: "Type less",
            processingMode: nil,
            processedText: nil,
            finalText: "Type less",
            status: "completed",
            characterCount: 9
        ))
        let coordinator = TerminologyHistoryTransactionCoordinator(context: fixture.context)

        do {
            _ = try await coordinator.confirmCorrection(
                historyStore: historyStore,
                historyID: "history-coordinated",
                candidates: [TerminologyCorrectionCandidate(alias: "Code X", canonical: "Codex")],
                correctedText: "Codex",
                scene: .chat,
                personalizationEnabled: true,
                retentionLimit: 200,
                learnStyle: true,
                learnTerminology: true
            )
            XCTFail("非语音润色历史必须让 SQLite 确认失败")
        } catch {
            XCTAssertEqual(error as? HistoryStoreError, .correctionNotEligible)
        }

        let restored = TerminologyRepository.load(context: fixture.context)
        XCTAssertEqual(restored.entries.map(\.canonicalText), ["Typeless"])
        XCTAssertEqual(restored.entries[0].aliases[0].sourceRecordIDs, ["history-coordinated"])
    }

    func testCoordinatorRestoresEvidenceWhenDeleteAndUndoDatabaseCallsFail() async throws {
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try fixture.seedEmptyBuiltIns()
        _ = try TerminologyRepository.migrateIfNeeded(context: fixture.context)
        for historyID in ["history-delete", "history-undo"] {
            _ = try TerminologyRepository.confirmCorrection(
                alias: "Type less \(historyID)",
                canonical: "Typeless \(historyID)",
                sourceRecordID: historyID,
                context: fixture.context
            )
        }
        let unavailableStore = HistoryStore(
            path: fixture.directory
                .appendingPathComponent("missing-parent/history.db")
                .path
        )
        let coordinator = TerminologyHistoryTransactionCoordinator(context: fixture.context)

        do {
            try await coordinator.deleteHistory(
                historyStore: unavailableStore,
                historyID: "history-delete"
            )
            XCTFail("不可用数据库必须让删除失败")
        } catch {
            XCTAssertEqual(error as? HistoryStoreError, .databaseUnavailable)
        }
        do {
            try await coordinator.undoCorrection(
                historyStore: unavailableStore,
                historyID: "history-undo"
            )
            XCTFail("不可用数据库必须让撤销失败")
        } catch {
            XCTAssertEqual(error as? HistoryStoreError, .databaseUnavailable)
        }

        let restoredSourceIDs = Set(TerminologyRepository.load(context: fixture.context)
            .entries.flatMap(\.aliases).flatMap(\.sourceRecordIDs))
        XCTAssertEqual(restoredSourceIDs, ["history-delete", "history-undo"])
    }

    func testCompatibilityRollbackAttemptsEveryLegacyStoreAndAggregatesFailures() throws {
        enum PlannedFailure: Error { case forward, hotwordRollback, snippetRollback }
        let fixture = try TerminologyStorageFixture()
        defer { fixture.cleanup() }
        try fixture.seedEmptyBuiltIns()
        _ = try TerminologyRepository.migrateIfNeeded(context: fixture.context)
        let entry = TerminologyEntry(
            canonicalText: "Typeless",
            aliases: [TerminologyAlias(text: "Type less")]
        )
        try TerminologyRepository.upsert(entry, context: fixture.context)
        let personalBefore = PersonalLexiconStorage.load(context: fixture.context)
        var proposed = TerminologyRepository.load(context: fixture.context)
        proposed.entries.removeAll { $0.id == entry.id }

        XCTAssertThrowsError(try TerminologyRepository.save(
            proposed,
            context: fixture.context,
            compatibilityHooks: TerminologyCompatibilityProjectionHooks(
                afterHotwordWrite: {},
                afterSnippetWrite: {},
                afterPersonalLexiconWrite: { throw PlannedFailure.forward },
                beforeManifestCommit: {},
                beforeHotwordRollback: { throw PlannedFailure.hotwordRollback },
                beforeSnippetRollback: { throw PlannedFailure.snippetRollback }
            )
        )) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("HotwordStorage"))
            XCTAssertTrue(message.contains("SnippetStorage"))
        }

        // 前两份回滚被计划性阻断，但第三份仍必须继续恢复。
        XCTAssertEqual(PersonalLexiconStorage.load(context: fixture.context), personalBefore)
    }
}

private final class TerminologyStorageFixture {
    let directory: URL
    let suiteName: String
    let context: VocabularyStorageContext

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseTerminologyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "MuseTerminologyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        context = VocabularyStorageContext(
            supportDirectory: directory,
            userDefaults: defaults,
            fileManager: .default,
            hotwordsDidChange: {},
            revealFile: { _ in }
        )
    }

    func seedEmptyBuiltIns() throws {
        try HotwordStorage.saveBuiltin([], context: context)
        try SnippetStorage.saveBuiltin([], context: context)
    }

    func cleanup() {
        try? FileManager.default.trashItem(at: directory, resultingItemURL: nil)
        context.userDefaults.removePersistentDomain(forName: suiteName)
    }
}
