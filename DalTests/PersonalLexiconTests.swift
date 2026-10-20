import XCTest
@testable import Dal

final class PersonalLexiconTests: XCTestCase {
    func testStorageRoundTripExportAndAtomicClear() throws {
        let fixture = try StorageFixture()
        defer { fixture.cleanup() }
        let document = PersonalLexiconDocument(
            schemaVersion: 1,
            entries: [PersonalLexiconEntry(
                canonical: "Claude Code",
                aliases: ["Cloud Code", "Cloud Code"],
                source: .manual
            )]
        )

        try PersonalLexiconStorage.save(
            document,
            syncToASR: false,
            context: fixture.context
        )

        let loaded = PersonalLexiconStorage.load(context: fixture.context)
        XCTAssertEqual(loaded.entries.count, 1)
        XCTAssertEqual(loaded.entries[0].aliases, ["Cloud Code"])
        let exported = try PersonalLexiconStorage.exportData(context: fixture.context)
        XCTAssertEqual(
            try JSONDecoder().decode(PersonalLexiconDocument.self, from: exported),
            loaded
        )

        try PersonalLexiconStorage.clear(context: fixture.context)
        XCTAssertTrue(PersonalLexiconStorage.load(context: fixture.context).entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: PersonalLexiconStorage.fileURL(in: fixture.context).path
        ))
    }

    func testSnippetCopyIsExplicitSelectiveAndNonDestructive() throws {
        let fixture = try StorageFixture()
        defer { fixture.cleanup() }
        let snippets = [
            (trigger: "Cloud Code", value: "Claude Code"),
            (trigger: "这是一整句错误规则。", value: "这是一整句正确文字。"),
            (trigger: SnippetStorage.draftTriggerPrefix + "1", value: "Draft"),
        ]
        try SnippetStorage.save(snippets, context: fixture.context)

        let copied = try PersonalLexiconStorage.copyEligibleSnippets(context: fixture.context)

        XCTAssertEqual(copied, 1)
        XCTAssertEqual(SnippetStorage.load(context: fixture.context).map(\.trigger), snippets.map(\.trigger))
        let entries = PersonalLexiconStorage.load(context: fixture.context).entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].canonical, "Claude Code")
        XCTAssertEqual(entries[0].aliases, ["Cloud Code"])
    }

    func testConfirmedEntriesSynchronizeCanonicalAndAliasesToASRStores() throws {
        let fixture = try StorageFixture()
        defer { fixture.cleanup() }
        try HotwordStorage.save([], context: fixture.context)
        try SnippetStorage.save([], context: fixture.context)
        let entry = PersonalLexiconEntry(
            canonical: "Kubernetes",
            aliases: ["Kubernetez"]
        )

        try PersonalLexiconStorage.save(
            PersonalLexiconDocument(schemaVersion: 1, entries: [entry]),
            context: fixture.context
        )

        XCTAssertTrue(HotwordStorage.load(context: fixture.context).contains("Kubernetes"))
        XCTAssertTrue(SnippetStorage.load(context: fixture.context).contains {
            $0.trigger == "Kubernetez" && $0.value == "Kubernetes"
        })
    }

    func testClearRemovesOnlyASRItemsOwnedByPersonalLexicon() throws {
        let fixture = try StorageFixture()
        defer { fixture.cleanup() }
        try HotwordStorage.save(["Existing"], context: fixture.context)
        try SnippetStorage.save(
            [(trigger: "Existing Alias", value: "Existing")],
            context: fixture.context
        )
        try PersonalLexiconStorage.save(
            PersonalLexiconDocument(
                schemaVersion: 1,
                entries: [
                    PersonalLexiconEntry(canonical: "Existing", aliases: ["Existing Alias"]),
                    PersonalLexiconEntry(canonical: "Kubernetes", aliases: ["Kubernetez"]),
                ]
            ),
            context: fixture.context
        )

        try PersonalLexiconStorage.clear(context: fixture.context)

        XCTAssertEqual(HotwordStorage.load(context: fixture.context), ["Existing"])
        let snippets = SnippetStorage.load(context: fixture.context)
        XCTAssertTrue(snippets.contains { $0.trigger == "Existing Alias" && $0.value == "Existing" })
        XCTAssertFalse(snippets.contains { $0.trigger == "Kubernetez" })
        XCTAssertTrue(PersonalLexiconStorage.load(context: fixture.context).entries.isEmpty)
    }

    func testResolverUsesPriorityThresholdAndConflictMargin() {
        let lexicon = PersonalLexiconDocument(
            schemaVersion: 1,
            entries: [PersonalLexiconEntry(
                canonical: "Claude Code",
                aliases: ["Cloud Code"]
            )]
        )
        let exact = EntityResolver.resolve(
            segments: [segment("请用 Cloud Code 修改。")],
            lexicon: lexicon,
            snippets: [(trigger: "Cloud Code", value: "Other Tool")],
            hotwords: [],
            context: WritingContext()
        )
        XCTAssertEqual(exact.first?.canonical, "Claude Code")
        XCTAssertEqual(exact.first?.candidateSource, .personalLexicon)
        XCTAssertEqual(
            EntityResolver.applying(exact, to: "请用 Cloud Code 修改。"),
            "请用 Claude Code 修改。"
        )

        let fuzzy = EntityResolver.resolve(
            segments: [segment("Kubernetez")],
            lexicon: .empty,
            snippets: [],
            hotwords: ["Kubernetes"],
            context: WritingContext()
        )
        XCTAssertEqual(fuzzy.first?.canonical, "Kubernetes")
        XCTAssertGreaterThanOrEqual(fuzzy.first?.confidence ?? 0, 0.88)

        let ambiguous = EntityResolver.resolve(
            segments: [segment("Kubernetez")],
            lexicon: .empty,
            snippets: [],
            hotwords: ["Kubernetes", "Kuberneter"],
            context: WritingContext()
        )
        XCTAssertTrue(ambiguous.isEmpty)
    }

    func testResolverMatchesKnownAliasAcrossCaseSpacesAndHyphensWithoutSubstringDamage() {
        let lexicon = PersonalLexiconDocument(
            schemaVersion: 1,
            entries: [PersonalLexiconEntry(
                canonical: "Typeless",
                aliases: ["Type less"]
            )]
        )
        let source = "Type less、type-less、typeless 都是术语，prototype-less 保持原样。"

        let resolutions = EntityResolver.resolve(
            segments: [segment(source)],
            lexicon: lexicon,
            snippets: [],
            hotwords: [],
            context: WritingContext()
        )

        XCTAssertTrue(resolutions.contains { $0.surfaceText == "Type less" })
        XCTAssertTrue(resolutions.contains { $0.surfaceText == "type-less" })
        XCTAssertTrue(resolutions.contains { $0.surfaceText == "typeless" })
        XCTAssertEqual(
            EntityResolver.applying(resolutions, to: source),
            "Typeless、Typeless、Typeless 都是术语，prototype-less 保持原样。"
        )
    }

    func testResolverOnlyAppliesKnownAliasAtEntityBoundaries() {
        let lexicon = PersonalLexiconDocument(
            schemaVersion: 1,
            entries: [PersonalLexiconEntry(
                canonical: "CAT",
                aliases: ["Cat"]
            )]
        )
        let source = "Cat catalog concatenate"
        let resolutions = EntityResolver.resolve(
            segments: [segment(source)],
            lexicon: lexicon,
            snippets: [],
            hotwords: [],
            context: WritingContext()
        )

        XCTAssertEqual(
            EntityResolver.applying(resolutions, to: source),
            "CAT catalog concatenate"
        )
    }

    func testResolverUsesEnglishPhoneticChannelOnlyForWhitelistedTerminology() {
        let lexicon = PersonalLexiconDocument(
            schemaVersion: 1,
            entries: [PersonalLexiconEntry(canonical: "Night Shift", aliases: [])]
        )
        let source = "Please enable Nite Shift today."

        XCTAssertLessThan(
            EntityResolver.editSimilarity("Nite Shift", "Night Shift"),
            EntityResolver.similarityThreshold
        )
        let resolutions = EntityResolver.resolve(
            segments: [segment(source)],
            lexicon: lexicon,
            snippets: [],
            hotwords: [],
            context: WritingContext()
        )

        XCTAssertTrue(resolutions.contains {
            $0.surfaceText == "Nite Shift" && $0.canonical == "Night Shift"
        })
        XCTAssertEqual(
            EntityResolver.applying(resolutions, to: source),
            "Please enable Night Shift today."
        )
    }

    func testResolverFindsChinesePinyinCandidateInsideContinuousSentence() {
        let lexicon = PersonalLexiconDocument(
            schemaVersion: 1,
            entries: [PersonalLexiconEntry(canonical: "飞书", aliases: [])]
        )
        let source = "我们用菲书沟通"

        let resolutions = EntityResolver.resolve(
            segments: [segment(source)],
            lexicon: lexicon,
            snippets: [],
            hotwords: [],
            context: WritingContext()
        )

        XCTAssertTrue(resolutions.contains {
            $0.surfaceText == "菲书" && $0.canonical == "飞书"
        })
        XCTAssertEqual(
            EntityResolver.applying(resolutions, to: source),
            "我们用飞书沟通"
        )
    }

    func testResolverPreservesAmbiguousChinesePinyinSurface() {
        let lexicon = PersonalLexiconDocument(
            schemaVersion: 1,
            entries: [
                PersonalLexiconEntry(canonical: "飞书", aliases: []),
                PersonalLexiconEntry(canonical: "非书", aliases: []),
            ]
        )
        let source = "我们用菲书沟通"

        let resolutions = EntityResolver.resolve(
            segments: [segment(source)],
            lexicon: lexicon,
            snippets: [],
            hotwords: [],
            context: WritingContext()
        )

        XCTAssertFalse(resolutions.contains { $0.surfaceText == "菲书" })
        XCTAssertEqual(EntityResolver.applying(resolutions, to: source), source)
    }

    func testResolverDoesNotIgnoreChineseTonesForLowConfidenceCandidate() {
        let lexicon = PersonalLexiconDocument(
            schemaVersion: 1,
            entries: [PersonalLexiconEntry(canonical: "飞书", aliases: [])]
        )
        let source = "这不是非数值类型"

        let resolutions = EntityResolver.resolve(
            segments: [segment(source)],
            lexicon: lexicon,
            snippets: [],
            hotwords: [],
            context: WritingContext()
        )

        XCTAssertFalse(resolutions.contains { $0.surfaceText == "非数" })
        XCTAssertEqual(EntityResolver.applying(resolutions, to: source), source)
    }

    func testWrittenFormNameDeclarationDoesNotAuthorizeRejectedOrUnconfirmedNames() {
        for context in [
            "错误名称为“成川计划”，不要使用。",
            "正式名称为“成川计划”还没确认。",
        ] {
            let resolutions = EntityResolver.resolve(
                segments: [segment("澄川计划今天上线。")],
                lexicon: .empty,
                snippets: [],
                hotwords: [],
                context: WritingContext(
                    scene: .workChat, level: .metadataOnly, safety: .safe,
                    recentDalInputs: [context]
                )
            )
            XCTAssertFalse(
                resolutions.contains { $0.canonical == "成川计划" },
                "context=\(context), resolutions=\(resolutions)"
            )
        }
    }

    func testResolverUsesOnlySafeAuthorizedContextForUniqueEntityCorrections() {
        let cases: [(String, String, WritingContext)] = [
            (
                "灵建这次更新先发测试组。",
                "灵简这次更新先发测试组。",
                WritingContext(
                    scene: .workChat,
                    level: .nearbyText,
                    safety: .safe,
                    textBeforeCursor: "项目统一名称是“灵简”，上一条也使用了“灵简”。"
                )
            ),
            (
                "戴量老师确认以后我再发。",
                "大梁老师确认以后我再发。",
                WritingContext(
                    scene: .workChat,
                    level: .metadataOnly,
                    safety: .safe,
                    recentDalInputs: ["大梁老师刚确认了课程结构。"]
                )
            ),
            (
                "飞数文档里的目录先别改。",
                "飞书文档里的目录先别改。",
                WritingContext(
                    scene: .document,
                    level: .metadataOnly,
                    safety: .safe,
                    recentDalInputs: ["飞书文档中的课程目录已经锁定。"]
                )
            ),
            (
                "达尔这次构建通过以后覆盖安装。",
                "Dal这次构建通过以后覆盖安装。",
                WritingContext(
                    scene: .workChat,
                    level: .metadataOnly,
                    safety: .safe,
                    recentDalInputs: ["Dal 构建已经通过，等待覆盖安装。"]
                )
            ),
            (
                "我最近重新用达尔录长语音。",
                "我最近重新用Dal录长语音。",
                WritingContext(
                    scene: .socialPost,
                    level: .metadataOnly,
                    safety: .safe,
                    recentDalInputs: ["Dal 的长语音测试刚刚结束。"]
                )
            ),
            (
                // 书面“正式名称为”与“是”同义；确认语在逗号后的下一分句也不影响。
                "项目名字我口述成成川计划，刚才已经输入过正式写法，按那个名称写。",
                "项目名字我口述成澄川计划，刚才已经输入过正式写法，按那个名称写。",
                WritingContext(
                    scene: .workChat,
                    level: .metadataOnly,
                    safety: .safe,
                    recentDalInputs: ["本次服务项目正式名称为“澄川计划”，已确认此写法。"]
                )
            ),
            (
                "项目名我口述成北城研究，但选中的标题是准的，按标题写。",
                "项目名我口述成北辰研究，但选中的标题是准的，按标题写。",
                WritingContext(
                    scene: .aiPrompt,
                    level: .selectedText,
                    safety: .safe,
                    selectedText: "北辰研究：个人语音输入产品对比 如果客户选择紫色包装，交付日期可能是九月三日。"
                )
            ),
        ]

        for (source, expected, context) in cases {
            let resolutions = EntityResolver.resolve(
                segments: [segment(source)],
                lexicon: .empty,
                snippets: [],
                hotwords: [],
                context: context
            )
            XCTAssertEqual(
                EntityResolver.applying(resolutions, to: source),
                expected,
                "source=\(source), resolutions=\(resolutions)"
            )
            XCTAssertTrue(resolutions.contains { $0.candidateSource == .authorizedContext })
        }
    }

    func testResolverRejectsNonAssertedContextCandidateWithoutDisablingOtherCorrection() {
        let cases: [(context: String, source: String, expected: String, rejectedCanonical: String)] = [
            (
                "旧项目曾叫“灵简”；“飞书”文档已经确认。",
                "灵建和飞数文档都要检查。",
                "灵建和飞书文档都要检查。",
                "灵简"
            ),
            (
                "如果名称定为“灵简”，目前还未确认；“飞书”文档已经确认。",
                "灵建和飞数文档都要检查。",
                "灵建和飞书文档都要检查。",
                "灵简"
            ),
            (
                "错误候选是“灵简”；“飞书”文档已经确认。",
                "灵建和飞数文档都要检查。",
                "灵建和飞书文档都要检查。",
                "灵简"
            ),
            (
                "这是同名的另一位“大梁老师”，与本次无关；“飞书”文档已经确认。",
                "戴量老师和飞数文档都要检查。",
                "戴量老师和飞书文档都要检查。",
                "大梁老师"
            ),
            (
                "旧产品 Dal 已停用，与本次无关；“飞书”文档已经确认。",
                "达尔和飞数文档都要检查。",
                "达尔和飞书文档都要检查。",
                "Dal"
            ),
            (
                "假设以后改名 Dal，目前没有确认；“飞书”文档已经确认。",
                "达尔和飞数文档都要检查。",
                "达尔和飞书文档都要检查。",
                "Dal"
            ),
            (
                "听说 Dal 的长语音测试刚刚结束；“飞书”文档已经确认。",
                "达尔和飞数文档都要检查。",
                "达尔和飞书文档都要检查。",
                "Dal"
            ),
            (
                "错误候选 Dal 的长语音测试刚刚结束；“飞书”文档已经确认。",
                "达尔和飞数文档都要检查。",
                "达尔和飞书文档都要检查。",
                "Dal"
            ),
        ]

        for item in cases {
            let resolutions = EntityResolver.resolve(
                segments: [segment(item.source)],
                lexicon: .empty,
                snippets: [],
                hotwords: [],
                context: WritingContext(
                    scene: .workChat,
                    level: .metadataOnly,
                    safety: .safe,
                    recentDalInputs: [item.context]
                )
            )
            XCTAssertEqual(
                EntityResolver.applying(resolutions, to: item.source),
                item.expected,
                "context=\(item.context), resolutions=\(resolutions)"
            )
            XCTAssertFalse(
                resolutions.contains {
                    $0.candidateSource == .authorizedContext
                        && $0.canonical == item.rejectedCanonical
                },
                "context=\(item.context), resolutions=\(resolutions)"
            )
            XCTAssertTrue(resolutions.contains {
                $0.candidateSource == .authorizedContext && $0.canonical == "飞书"
            })
        }
    }

    func testResolverAcceptsCandidateWhenSameContextAlsoHasCurrentConfirmedProvenance() {
        let source = "灵建这次更新先发测试组。"
        let resolutions = EntityResolver.resolve(
            segments: [segment(source)],
            lexicon: .empty,
            snippets: [],
            hotwords: [],
            context: WritingContext(
                scene: .workChat,
                level: .metadataOnly,
                safety: .safe,
                recentDalInputs: [
                    "旧项目曾叫“灵简”；当前项目的名称已确认为“灵简”。",
                ]
            )
        )

        XCTAssertEqual(
            EntityResolver.applying(resolutions, to: source),
            "灵简这次更新先发测试组。"
        )
    }

    func testResolverRequiresAffirmedContextEvidenceBeforeApplyingOwnedAlias() {
        let source = "达尔和飞数文档都要检查。"
        let resolutions = EntityResolver.resolve(
            segments: [segment(source)],
            lexicon: .empty,
            snippets: [],
            hotwords: [],
            context: WritingContext(
                scene: .workChat,
                level: .metadataOnly,
                safety: .safe,
                recentDalInputs: [
                    "Dal 不是本次产品名，不要用于当前消息；“飞书”文档已经确认。",
                ]
            )
        )

        XCTAssertEqual(
            EntityResolver.applying(resolutions, to: source),
            "达尔和飞书文档都要检查。"
        )
        XCTAssertFalse(resolutions.contains {
            $0.candidateSource == .authorizedContext && $0.canonical == "Dal"
        })
        XCTAssertTrue(resolutions.contains {
            $0.candidateSource == .authorizedContext && $0.canonical == "飞书"
        })
    }

    func testResolverPreservesUnconfirmedOrUnauthorizedContextGuess() {
        let source = "灵建这个名字我还没确认，先保留，别替我猜。"
        for context in [
            WritingContext(
                scene: .workChat,
                level: .nearbyText,
                safety: .safe,
                textBeforeCursor: "上文有人写“灵简”。",
                textAfterCursor: "下文另一处写“灵境”。"
            ),
            WritingContext(
                scene: .workChat,
                level: .nearbyText,
                safety: .secure,
                textBeforeCursor: "项目统一名称是“灵简”。"
            ),
            WritingContext(
                scene: .workChat,
                level: .nearbyText,
                safety: .unknown,
                textBeforeCursor: "项目统一名称是“灵简”。"
            ),
        ] {
            let resolutions = EntityResolver.resolve(
                segments: [segment(source)],
                lexicon: .empty,
                snippets: [],
                hotwords: [],
                context: context
            )
            XCTAssertEqual(EntityResolver.applying(resolutions, to: source), source)
        }
    }

    func testResolverDoesNotApplyOwnedAliasWhenUserExplicitlyRejectsTheMapping() {
        let context = WritingContext(
            scene: .workChat,
            level: .metadataOnly,
            safety: .safe,
            recentDalInputs: ["Dal 构建已经通过。"]
        )
        for source in [
            "不要把达尔改成 Dal。",
            "别把达尔换成 Dal。",
            "达尔不是 Dal，别改写。",
            "这里说的是达尔，不是 Dal，先按原词保留。",
            "这里的达尔并非 Dal，请原样保留。",
            "这里的达尔与 Dal 无关，维持原词。",
            "这里的达尔和 Dal 不是一个东西，请保留原文。",
            "这里的 Dal 不是达尔，后一个词保持原样。",
            "Dal 与达尔无关，请保留两个写法。",
            "不要把 Dal 改成达尔，请保留两个写法。",
            "达尔不是产品名，保持原样。",
            "达尔这个写法有歧义，暂时别替换。",
            "请照录达尔，不要纠正为 Dal。",
        ] {
            let resolutions = EntityResolver.resolve(
                segments: [segment(source)],
                lexicon: .empty,
                snippets: [],
                hotwords: [],
                context: context
            )
            XCTAssertEqual(EntityResolver.applying(resolutions, to: source), source)
        }

        for contextTerm in ["dal", "DAL", "Mu-se", "Mu se", "DalScore"] {
            let resolutions = EntityResolver.resolve(
                segments: [segment("达尔这次构建通过以后覆盖安装。")],
                lexicon: .empty,
                snippets: [],
                hotwords: [],
                context: WritingContext(
                    scene: .workChat,
                    level: .metadataOnly,
                    safety: .safe,
                    recentDalInputs: ["\(contextTerm) 构建已经通过。"]
                )
            )
            XCTAssertEqual(
                EntityResolver.applying(resolutions, to: "达尔这次构建通过以后覆盖安装。"),
                "达尔这次构建通过以后覆盖安装。"
            )
        }
    }

    func testResolverDoesNotLetUnrelatedNegativeInstructionDisableOwnedAlias() {
        let context = WritingContext(
            scene: .workChat,
            level: .metadataOnly,
            safety: .safe,
            recentDalInputs: ["Dal 构建已经通过。"]
        )
        for source in [
            "达尔这次构建完成，不要把日志发给客户。",
            "达尔这次构建完成，截图保持原样。",
            "达尔这次构建完成，代码先保留，别改写说明。",
        ] {
            let resolutions = EntityResolver.resolve(
                segments: [segment(source)],
                lexicon: .empty,
                snippets: [],
                hotwords: [],
                context: context
            )
            XCTAssertEqual(
                EntityResolver.applying(resolutions, to: source),
                source.replacingOccurrences(of: "达尔", with: "Dal"),
                "source=\(source), resolutions=\(resolutions)"
            )
        }
    }

    func testResolverDoesNotTurnSharedAffixIntoContextCorrection() {
        for pair in [
            ("小林老师稍后确认。", "大梁老师刚确认了课程结构。"),
            ("登录失败仍在排查。", "登录流程刚更新。"),
            ("登录失败仍在排查。", "登录流程刚完成排查。"),
            ("发布失败仍在复盘。", "发布流程刚完成复盘。"),
            ("接口调试完成以后再定时间。", "接口联调排期与上线检查。"),
        ] {
            let context = WritingContext(
                scene: .workChat,
                level: .selectedText,
                safety: .safe,
                selectedText: pair.1
            )
            let resolutions = EntityResolver.resolve(
                segments: [segment(pair.0)],
                lexicon: .empty,
                snippets: [],
                hotwords: [],
                context: context
            )
            XCTAssertEqual(EntityResolver.applying(resolutions, to: pair.0), pair.0)
        }
    }

    func testResolverUsesSelectedContextAnchorsForUniqueCanonicalMappings() {
        let cases: [(source: String, expected: String, context: String, scene: WritingScene)] = [
            (
                "接口调试完成以后再定上线时间",
                "接口联调完成以后再定上线时间",
                "接口联调排期与上线检查。",
                .workChat
            ),
            (
                "克劳德桌面版的配置说明下午补一下",
                "Claude Desktop的配置说明下午补一下",
                "Claude Desktop 配置与第三方推理说明。",
                .workChat
            ),
            (
                "赛博沃斯服务重启以后再跑 health 检查",
                "CyberVoice服务重启以后再跑 health 检查",
                "CyberVoice 服务部署记录。",
                .code
            ),
        ]

        for item in cases {
            let context = WritingContext(
                scene: item.scene,
                level: .selectedText,
                safety: .safe,
                selectedText: item.context
            )
            let resolutions = EntityResolver.resolve(
                segments: [segment(item.source)],
                lexicon: .empty,
                snippets: [],
                hotwords: [],
                context: context
            )
            XCTAssertEqual(
                EntityResolver.applying(resolutions, to: item.source),
                item.expected,
                "context=\(item.context) resolutions=\(resolutions)"
            )
            XCTAssertTrue(resolutions.contains { $0.candidateSource == .authorizedContext })
        }
    }

    func testResolverRejectsConflictingOrUnrelatedContextAnchors() {
        let cases: [(source: String, context: String)] = [
            (
                "克劳德桌面版的配置说明下午补一下",
                "Claude Desktop 配置已经确认；Cloud Desktop 配置也已经确认。"
            ),
            (
                "Chrome 的配置说明下午补一下",
                "Claude Desktop 配置已经确认。"
            ),
            (
                "大梁老师的配置说明下午补一下",
                "Claude Desktop 配置已经确认。"
            ),
            (
                "克劳德手机版的配置说明下午补一下",
                "Claude Desktop 配置已经确认。"
            ),
            (
                "小林老师稍后确认。",
                "大梁老师刚确认了课程结构。"
            ),
            (
                "登录失败仍在排查。",
                "登录流程刚更新。"
            ),
            (
                "登录失败仍在排查。",
                "登录流程刚完成排查。"
            ),
            (
                "发布失败仍在复盘。",
                "发布流程刚完成复盘。"
            ),
        ]

        for item in cases {
            let context = WritingContext(
                scene: .workChat,
                level: .selectedText,
                safety: .safe,
                selectedText: item.context
            )
            let resolutions = EntityResolver.resolve(
                segments: [segment(item.source)],
                lexicon: .empty,
                snippets: [],
                hotwords: [],
                context: context
            )
            XCTAssertEqual(
                EntityResolver.applying(resolutions, to: item.source),
                item.source,
                "context=\(item.context) resolutions=\(resolutions)"
            )
        }
    }

    private func segment(_ text: String) -> RecognitionSegment {
        RecognitionSegment(
            id: "s1",
            text: text,
            startTimeMs: nil,
            endTimeMs: nil,
            confidence: nil,
            isFinal: true
        )
    }
}

private final class StorageFixture {
    let directory: URL
    let suiteName: String
    let context: VocabularyStorageContext

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DalPersonalLexiconTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "DalPersonalLexiconTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        context = VocabularyStorageContext(
            supportDirectory: directory,
            userDefaults: defaults,
            fileManager: .default,
            hotwordsDidChange: {},
            revealFile: { _ in }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}
