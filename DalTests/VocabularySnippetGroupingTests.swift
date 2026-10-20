import XCTest
@testable import Dal

final class VocabularySnippetGroupingTests: XCTestCase {
    func testOwnedPunctuatedCompatibilityCopiesAreNotListedTwice() {
        let entries = ["Agents", "Skill"].map { word in
            TerminologyEntry(canonicalText: "\(word).md", aliases: [TerminologyAlias(text: "\(word) 点 MD。")])
        }
        let copies = entries.map { (trigger: $0.aliases[0].text, value: $0.canonicalText) }
        let owned = Dictionary(uniqueKeysWithValues: copies.map {
            (TerminologyText.normalizedKey($0.trigger), TerminologyText.normalizedKey($0.value))
        })
        let standalone = VocabularySnippetGrouping.standaloneReplacements(
            in: copies + [(trigger: "发邮件。", value: "请通过邮件联系我。")], terms: entries, ownedCorrections: owned
        )
        XCTAssertEqual(VocabularySnippetGrouping.groups(for: standalone), [
            VocabularySnippetGroup(replacement: "请通过邮件联系我。", triggers: ["发邮件。"])
        ])
    }

    func testUnownedExternallyChangedAndOrphanedRulesRemainVisible() {
        let term = TerminologyEntry(canonicalText: "Agents.md", aliases: [TerminologyAlias(text: "Agents 点 MD。")])
        let rule = (trigger: "Agents 点 MD。", value: "Agents.md")
        let key = TerminologyText.normalizedKey(rule.trigger)
        for (terms, owned) in [
            ([term], [:]),
            ([], [key: "agents.md"]),
            ([term], [key: "other.md"])
        ] as [([TerminologyEntry], [String: String])] {
            XCTAssertEqual(VocabularySnippetGrouping.standaloneReplacements(
                in: [rule], terms: terms, ownedCorrections: owned
            ).count, 1, "来源或对应关系不明确时，不能隐藏独立规则")
        }
    }

    func testApplicationTermDoesNotHideIndependentGlobalReplacement() {
        let term = TerminologyEntry(
            canonicalText: "Skill.md", aliases: [TerminologyAlias(text: "Skill 点 MD。")],
            scope: .application("pro.example.editor")
        )
        let rule = (trigger: "Skill 点 MD。", value: "Skill.md")
        XCTAssertEqual(VocabularySnippetGrouping.standaloneReplacements(
            in: [rule], terms: [term], ownedCorrections: [TerminologyText.normalizedKey(rule.trigger): "skill.md"]
        ).count, 1)
    }

    func testGroupsSnippetsByReplacementPreservingFirstReplacementOrder() {
        let groups = VocabularySnippetGrouping.groups(for: [
            (trigger: "ty", value: "thank you"),
            (trigger: "brb", value: "be right back"),
            (trigger: "thx", value: "thank you"),
            (trigger: "omw", value: "on my way")
        ])

        XCTAssertEqual(groups, [
            VocabularySnippetGroup(replacement: "thank you", triggers: ["ty", "thx"]),
            VocabularySnippetGroup(replacement: "be right back", triggers: ["brb"]),
            VocabularySnippetGroup(replacement: "on my way", triggers: ["omw"])
        ])
    }

    func testEmptySnippetsReturnNoGroups() {
        XCTAssertEqual(VocabularySnippetGrouping.groups(for: []), [])
    }
}
