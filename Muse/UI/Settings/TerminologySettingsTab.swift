import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum TerminologySettingsPanel: String, CaseIterable {
    case myTerms
    case discoveries
    case builtIn

    var title: String {
        switch self {
        case .myTerms: return L("我的词汇", "My Words")
        case .discoveries: return L("待确认", "Pending")
        case .builtIn: return L("内置词汇", "Built-in Words")
        }
    }
}

/// 术语编辑器中的 Bundle ID 只接受可预测的反向域名格式，避免保存一个永远匹配不到的作用域。
enum TerminologyBundleIdentifierValidator {
    static func isValid(_ rawValue: String) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 255 else { return false }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return false }

        return components.allSatisfy { component in
            guard !component.isEmpty, component.utf8.count <= 63,
                  let first = component.unicodeScalars.first,
                  let last = component.unicodeScalars.last,
                  isASCIIAlphaNumeric(first),
                  isASCIIAlphaNumeric(last) else {
                return false
            }
            return component.unicodeScalars.allSatisfy {
                isASCIIAlphaNumeric($0) || $0.value == 45 // "-"
            }
        }
    }

    private static func isASCIIAlphaNumeric(_ scalar: UnicodeScalar) -> Bool {
        (48...57).contains(scalar.value)
            || (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
    }
}

/// 待确认候选与“已忽略”使用同一个稳定键，删除已确认术语后才能可靠阻止它立即回流。
enum TerminologyDiscoveryIdentity {
    static func id(alias: String, canonical: String) -> String {
        "\(TerminologyText.normalizedKey(alias))→\(TerminologyText.normalizedKey(canonical))"
    }

    static func ids(for entry: TerminologyEntry) -> Set<String> {
        Set(entry.aliases.map { id(alias: $0.text, canonical: entry.canonicalText) })
    }
}

private struct TerminologyEditorDraft: Identifiable {
    let id = UUID()
    let entry: TerminologyEntry?
    let discoverySourceRecordIDs: [String]

    init(entry: TerminologyEntry?, discoverySourceRecordIDs: [String] = []) {
        self.entry = entry
        self.discoverySourceRecordIDs = discoverySourceRecordIDs
    }
}

private struct PendingTerminologyDiscovery: Identifiable {
    let alias: String
    let canonical: String
    let sourceRecordIDs: [String]
    let lastSeenAt: Date

    var id: String {
        TerminologyDiscoveryIdentity.id(alias: alias, canonical: canonical)
    }
}

/// 统一术语入口：同一份数据同时投影给 ASR、确定性纠错和 Voice Polish。
struct TerminologySettingsTab: View, SettingsCardHelpers {
    private static let ignoredDiscoveriesKey = "tf_ignoredTerminologyDiscoveryIDs"

    @AppStorage(DefaultsKeys.selectedASRProvider)
    private var selectedASRProviderRaw = ASRProvider.volcano.rawValue

    @AppStorage(DefaultsKeys.voicePolishTerminologyLearningEnabled) private var automaticallyLearnTerms = true
    @State private var showsVocabularySettings = false
    @State private var legacySnippets: [(trigger: String, value: String)] = []
    @State private var legacyEditor: VocabularySnippetGroup?
    @State private var pendingLegacyDeletion: VocabularySnippetGroup?
    @State private var selectedPanel = TerminologySettingsPanel.myTerms
    @State private var document: TerminologyDocument?
    @State private var corrections: [VoicePolishCorrectionRecord] = []
    @State private var editorDraft: TerminologyEditorDraft?
    @State private var loadErrorMessage = ""
    @State private var corruptFileURL: URL?
    @State private var statusMessage = ""
    @State private var editorError = ""
    @State private var searchText = ""
    @State private var isMigrating = false
    @State private var discoveryLoadErrorMessage = ""
    @State private var ignoredDiscoveryIDs = Set(
        UserDefaults.standard.stringArray(forKey: TerminologySettingsTab.ignoredDiscoveriesKey) ?? []
    )
    @State private var pendingDeletion: TerminologyEntry?
    @State private var aliyunVocabularySyncNotice: AliyunVocabularySyncNotice?

    private let historyStore: HistoryStore
    private var loadsStoredVocabulary = true

    init() {
        historyStore = HistoryStore()
    }

    #if DEBUG
    /// 原生布局回归使用内存词表，不读取正式词库或纠正记录。
    init(previewDocument: TerminologyDocument) {
        historyStore = HistoryStore(path: ":memory:")
        loadsStoredVocabulary = false
        _document = State(initialValue: previewDocument)
        _selectedPanel = State(initialValue: .builtIn)
    }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelSwitch
            HStack(spacing: 10) {
                SettingsSearchField(
                    text: $searchText,
                    prompt: L("搜索原文字或替换内容", "Search words or replacements"),
                    fill: TF.settingsCard
                )
                .frame(width: 280)
                .accessibilityLabel(L("搜索词库", "Search vocabulary"))
                if selectedPanel == .myTerms {
                    SettingsTextButton(L("新增", "Add"), variant: .primary) {
                        editorError = ""
                        editorDraft = TerminologyEditorDraft(entry: nil)
                    }
                }
                Spacer(minLength: 0)
            }
            .animation(nil, value: selectedPanel)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !loadErrorMessage.isEmpty { failureCard }
                    else {
                        conflictCard
                        aliyunSyncStatusCard
                        panelContent
                    }
                }
            }
            .settingsThinScrollIndicators()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // 筛选或切换后回到首屏，避免惰性词表沿用上一页的可见范围。
            .id(searchText)
            .id(selectedPanel)
            // 只让选中块滑动，避免整张词表随段切换一起布局和淡入淡出。
            .animation(nil, value: selectedPanel)
            HStack(spacing: 12) {
                Toggle(L("自动记住我改正的词", "Remember corrected words"), isOn: $automaticallyLearnTerms)
                    .toggleStyle(.switch)
                    .font(TF.settingsFontCaption)
                    .help(L("直出或润色上屏后短时观察支持的输入框，把明确的词语修改记入词库。", "Remembers word corrections shortly after Direct or Polish output in supported text fields."))
                Spacer(minLength: 8)
                SettingsTextButton(L("词库设置", "Options"), controlSize: .compact) { showsVocabularySettings = true }
            }
            learningResult
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showsVocabularySettings) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("词库设置", "Vocabulary Options")).font(TF.settingsFontBodyStrong)
                    Spacer()
                    SettingsTextButton(L("完成", "Done")) { showsVocabularySettings = false }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        providerStatusCard
                        migrationCard
                        Text(L("自动记词在直出或润色上屏后的约 20 秒内观察支持的安全输入框。GPT 桌面端需支持安全的文字范围读取；其他网页输入框不观察。继续追加不算纠错，直出只记词，不学习表达习惯。最近的学习结果显示在本页底部。", "Word learning observes supported safe fields for about 20 seconds after Direct or Polish output. GPT desktop requires safe text-range access; other web fields are excluded. Appended text is ignored. Direct learns words only. The latest result appears at the bottom of this page."))
                            .font(TF.settingsFontCaption).foregroundStyle(TF.settingsTextSecondary)
                        SettingsTextButton(L("导出词库", "Export vocabulary")) { exportTerminology() }
                    }
                }
            }
            .padding(18).frame(width: 460, height: 360).background(TF.settingsCanvas)
        }
        .sheet(item: $legacyEditor) { group in
            TerminologyEntryEditorSheet(
                entry: TerminologyEntry(canonicalText: group.replacement, aliases: group.triggers.map { TerminologyAlias(text: $0, source: .manual) }, origin: .manual),
                requiresAlias: true, allowsScope: false, errorMessage: editorError,
                onCancel: { legacyEditor = nil },
                onSave: { entry in saveLegacyReplacement(group, updated: entry) }
            )
        }
        .alert(L("删除词条", "Delete Entry"), isPresented: Binding(
            get: { pendingLegacyDeletion != nil }, set: { if !$0 { pendingLegacyDeletion = nil } }
        )) {
            Button(L("取消", "Cancel"), role: .cancel) { pendingLegacyDeletion = nil }
            Button(L("删除", "Delete"), role: .destructive) {
                if let group = pendingLegacyDeletion { saveLegacyReplacement(group, updated: nil) }
                pendingLegacyDeletion = nil
            }
        } message: { Text(L("删除后将不再应用这条替换。", "This replacement will no longer apply.")) }
        .task { if loadsStoredVocabulary { await reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .voicePolishAutomaticLearningDidFinish)) { note in
            if let feedback = note.object as? AutomaticLearningFeedback {
                AutomaticLearningStatus.shared.update(feedback)
                if feedback.didPersist, loadsStoredVocabulary { Task { await reload() } }
            }
        }
        .sheet(item: $editorDraft) { draft in
            TerminologyEntryEditorSheet(
                entry: draft.entry,
                requiresAlias: !draft.discoverySourceRecordIDs.isEmpty,
                errorMessage: editorError,
                onCancel: { editorDraft = nil },
                onSave: { entry in
                    saveEntry(entry, discoverySourceRecordIDs: draft.discoverySourceRecordIDs)
                }
            )
        }
        .alert(
            L("删除词条", "Delete Entry"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            )
        ) {
            Button(L("取消", "Cancel"), role: .cancel) { pendingDeletion = nil }
            Button(L("删除", "Delete"), role: .destructive) {
                if let entry = pendingDeletion {
                    removeEntry(entry)
                }
                pendingDeletion = nil
            }
        } message: {
            if let entry = pendingDeletion {
                Text(L(
                    "确定删除“\(entry.canonicalText)”吗？识别增强、自动纠错都会停止使用它。",
                    "Delete “\(entry.canonicalText)”? ASR boosting, auto-correction, and Voice Polish protection will stop using it."
                ))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aliyunVocabularySyncStatusDidChange)) { note in
            guard selectedASRProvider == .aliyun,
                  let notice = note.object as? AliyunVocabularySyncNotice else { return }
            aliyunVocabularySyncNotice = notice
        }
    }

    private var learningResult: some View {
        HStack(alignment: .top, spacing: 6) {
            let feedback = AutomaticLearningStatus.shared.latest
            Image(systemName: feedback?.didPersist == true ? "checkmark.circle" : "info.circle")
            VStack(alignment: .leading, spacing: 2) {
                Text(feedback.map { L("最近记词：", "Latest learning: ") + $0.message }
                     ?? L("改词后的学习结果会显示在这里", "Learning results will appear here after an edit"))
                if let feedback, feedback.didPersist, !feedback.detail.isEmpty, feedback.detail != feedback.message {
                    Text(feedback.detail).lineLimit(2).textSelection(.enabled)
                }
            }
        }
        .font(TF.settingsFontCaption)
        .foregroundStyle(TF.settingsTextSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension TerminologySettingsTab {
    var panelSwitch: some View {
        HStack(spacing: 10) {
            SettingsSwitchGroup(fitsContent: true) {
                ForEach(TerminologySettingsPanel.allCases, id: \.rawValue) { panel in
                    SettingsSwitchOption(
                        title: panel.title,
                        isSelected: selectedPanel == panel
                    ) {
                        selectedPanel = panel
                    }
                    .accessibilityAddTraits(selectedPanel == panel ? .isSelected : [])
                    .accessibilityValue(selectedPanel == panel
                        ? L("已选择", "Selected")
                        : L("未选择", "Not selected"))
                }
            }
            Spacer(minLength: 8)
            if !statusMessage.isEmpty {
                SettingsChip(
                    statusMessage,
                    controlSize: .compact,
                    font: TF.settingsFontMetadata,
                    foreground: TF.settingsAccentGreen,
                    fill: TF.settingsSuccessFill
                )
            }
        }
    }

    @ViewBuilder
    var panelContent: some View {
        switch selectedPanel {
        case .myTerms:
            myTermsCard
        case .discoveries:
            discoveriesCard
        case .builtIn:
            builtInTermsCard
        }
    }

    var failureCard: some View {
        settingsGroupCard(
            L("术语库暂时无法读取", "Terminology library unavailable"),
            icon: "exclamationmark.triangle",
            expandVertically: false
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text(loadErrorMessage)
                    .font(TF.settingsFontBody)
                    .foregroundStyle(TF.settingsAccentRed)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L(
                    "Muse 没有把错误文件当成空词库，也不会覆盖它。请先保留或恢复备份，再重试。",
                    "Muse did not treat the damaged file as an empty library and will not overwrite it. Preserve or restore the backup, then retry."
                ))
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)
                HStack(spacing: 8) {
                    SettingsTextButton(L("重试", "Retry"), variant: .primary, controlSize: .compact) {
                        Task { await reload() }
                    }
                    if let corruptFileURL {
                        SettingsTextButton(L("在 Finder 中显示", "Show in Finder"), controlSize: .compact) {
                            NSWorkspace.shared.activateFileViewerSelecting([corruptFileURL])
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    var migrationCard: some View {
        if let document,
           document.migrationVersion < TerminologyDocument.currentMigrationVersion {
            settingsGroupCard(
                L("整合现有词汇", "Consolidate existing vocabulary"),
                icon: "arrow.triangle.merge",
                trailing: AnyView(
                    SettingsTextButton(
                        isMigrating ? L("整合中", "Consolidating") : L("重试整合", "Retry Consolidation"),
                        variant: .primary,
                        controlSize: .compact
                    ) {
                        migrateLegacyVocabulary()
                    }
                    .disabled(isMigrating)
                ),
                expandVertically: false
            ) {
                Text(L(
                    "升级时会自动整合热词、个人词典和可安全转换的错词；如果此前未完成，可在这里重试。原文件始终保留作为兼容恢复源。",
                    "Muse consolidates hotwords, personal terms, and safely convertible corrections during upgrade. Retry here if it did not finish. Original files remain as compatibility recovery sources."
                ))
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    var conflictCard: some View {
        if let document, !document.conflicts.isEmpty {
            settingsGroupCard(
                L("发现 \(document.conflicts.count) 个术语冲突", "\(document.conflicts.count) terminology conflict(s)"),
                icon: "exclamationmark.triangle",
                expandVertically: false,
                fillColor: TF.settingsWarningFill
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L(
                        "同一个错误写法指向多个标准词。冲突解决前，Muse 不会自动替换这个写法，以免改错。",
                        "The same alias points to multiple canonical terms. Muse pauses automatic replacement for that alias until you resolve it."
                    ))
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextSecondary)

                    ForEach(document.conflicts) { conflict in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(conflict.aliases.joined(separator: " / "))
                                .font(TF.settingsFontBodyStrong)
                                .foregroundStyle(TF.settingsText)
                            Image(systemName: "arrow.right")
                                .font(TF.settingsFontIconMicro)
                                .foregroundStyle(TF.settingsTextTertiary)
                            Text(conflict.candidates.map(\.canonicalText).joined(separator: "、"))
                                .font(TF.settingsFontBody)
                                .foregroundStyle(TF.settingsTextSecondary)
                            Spacer(minLength: 8)
                            if let editable = conflict.candidates.compactMap({ candidate in
                                document.entries.first(where: {
                                    $0.id == candidate.entryID && !$0.isReadOnly
                                })
                            }).first {
                                SettingsTextButton(L("编辑解决", "Resolve"), controlSize: .compact) {
                                    editorDraft = TerminologyEditorDraft(entry: editable)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    var providerStatusCard: some View {
        let capabilities = ASRTerminologyCapabilities.forProvider(selectedASRProvider)
        let enabledEntries = (document?.entries ?? []).filter(\.isEnabled)
        let globalProjections = document.map { TerminologyProjections.make(from: $0) }
            ?? TerminologyProjections.make(from: .empty)
        let hasGlobalTerms = enabledEntries.contains { $0.scope.kind == .global }
        let applicationEntries = enabledEntries.filter { $0.scope.kind == .application }
        return settingsGroupCard(
            L("生效状态", "Effect Status"),
            icon: "checkmark.shield",
            expandVertically: false
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("全部应用范围", "All-app scope"))
                    .font(TF.settingsFontBodyStrong)
                    .foregroundStyle(TF.settingsTextSecondary)
                HStack(spacing: 6) {
                    terminologyStatusChip(
                        L("识别增强", "ASR boost"),
                        active: hasGlobalTerms && capabilities.hotwordDelivery != .unsupported
                    )
                    terminologyStatusChip(
                        L("自动纠错", "Auto-correction"),
                        active: !globalProjections.corrections.isEmpty
                    )
                }

                if !applicationEntries.isEmpty {
                    Rectangle()
                        .fill(TF.settingsStroke.opacity(0.55))
                        .frame(height: 1)
                    Text(L(
                        "指定应用范围 · \(applicationEntries.count) 个术语",
                        "Specific-app scope · \(applicationEntries.count) term(s)"
                    ))
                    .font(TF.settingsFontBodyStrong)
                    .foregroundStyle(TF.settingsTextSecondary)
                    HStack(spacing: 6) {
                        terminologyStatusChip(L("识别增强", "ASR boost"), active: false)
                            .help(L(
                                "指定应用术语不会全局下发给识别引擎。",
                                "App-scoped terms are never sent globally to the recognition engine."
                            ))
                        terminologyStatusChip(
                            L("自动纠错", "Auto-correction"),
                            active: applicationEntries.contains(where: hasUnconflictedAlias)
                        )
                    }
                    Text(L(
                        "只在 Bundle ID 精确匹配的应用中进行本地纠错，不会污染其他应用的识别请求。",
                        "Local correction and polishing protection apply only when the Bundle ID matches exactly, without affecting recognition requests in other apps."
                    ))
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                DisclosureGroup(L(
                    "查看当前识别引擎的具体生效方式",
                    "Show how the current ASR applies terms"
                )) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(selectedASRProvider.displayName)
                            .font(TF.settingsFontBodyStrong)
                            .foregroundStyle(TF.settingsTextSecondary)
                        Text(providerDeliveryDescription(capabilities))
                            .font(TF.settingsFontCaption)
                            .foregroundStyle(TF.settingsTextTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 7)
                }
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextSecondary)
            }
        }
    }

    @ViewBuilder
    var aliyunSyncStatusCard: some View {
        if selectedASRProvider == .aliyun, let notice = aliyunVocabularySyncNotice {
            HStack(spacing: 8) {
                Image(systemName: notice.state == .failed ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(notice.state == .failed ? TF.settingsAccentRed : TF.settingsTextTertiary)
                    .accessibilityHidden(true)
                Text(notice.message)
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(notice.state == .failed ? TF.settingsAccentRed : TF.settingsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if notice.state == .failed {
                    SettingsTextButton(L("重试同步", "Retry Sync"), controlSize: .compact) {
                        AliyunVocabularySyncCoordinator.schedule(after: .milliseconds(50))
                    }
                }
            }
            .padding(10)
            .background(
                notice.state == .failed ? TF.settingsDangerFill : TF.settingsCard,
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9).stroke(TF.settingsStroke, lineWidth: 1)
            }
        }
    }

    var myTermsCard: some View {
        let entries = unifiedEntries
        return settingsGroupCard("", expandVertically: false, showsHeader: false, contentPadding: 12) {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(L("原文字 / 常见错法", "Original / mishearing")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(L("替换为 / 正确写法", "Replacement / correct form")).frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: 106, height: 1)
                }
                .font(TF.settingsFontCaption).foregroundStyle(TF.settingsTextSecondary).padding(.bottom, 8)
                if entries.isEmpty {
                    terminologyEmptyState(title: L("暂无匹配词条", "No matching entries"), description: L("点击“新增”，填写原文字和正确内容。", "Add the original text and its correct form."))
                }
                ForEach(entries) { item in
                    HStack(spacing: 12) {
                        Text(item.aliases.isEmpty ? L("尚未设置", "Not set") : item.aliases.joined(separator: "、"))
                            .font(TF.settingsFontBody).foregroundStyle(TF.settingsTextSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
                        Text(item.canonical).font(TF.settingsFontBodyStrong)
                            .frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
                        HStack(spacing: 8) {
                            if let term = item.term {
                                Toggle("", isOn: Binding(get: { term.isEnabled }, set: { setEntryEnabled(term, enabled: $0) }))
                                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                                    .accessibilityLabel(L("启用 \(term.canonicalText)", "Enable \(term.canonicalText)"))
                            }
                            SettingsTextButton(L("编辑", "Edit"), controlSize: .compact) {
                                editorError = ""
                                if let term = item.term {
                                    editorDraft = TerminologyEditorDraft(entry: term)
                                } else {
                                    legacyEditor = item.legacy
                                }
                            }
                            SettingsDeleteIconButton(systemName: "trash", accessibilityLabel: L("删除词条", "Delete entry")) {
                                if let term = item.term { pendingDeletion = term }
                                else { pendingLegacyDeletion = item.legacy }
                            }
                        }.frame(width: 106, alignment: .trailing)
                    }
                    .padding(.vertical, 10)
                    .opacity(item.term?.isEnabled == false ? 0.5 : 1)
                }
            }
        }
    }

    struct VocabularyListEntry: Identifiable {
        let term: TerminologyEntry?
        let legacy: VocabularySnippetGroup?
        var id: String { term?.id.uuidString ?? "legacy:" + (legacy?.id ?? "") }
        var canonical: String { term?.canonicalText ?? legacy?.replacement ?? "" }
        var aliases: [String] { term?.aliases.map(\.text) ?? legacy?.triggers ?? [] }
    }

    var unifiedEntries: [VocabularyListEntry] {
        let entries = myTerms.map { VocabularyListEntry(term: $0, legacy: nil) }
            + VocabularySnippetGrouping.groups(for: legacySnippets).map { VocabularyListEntry(term: nil, legacy: $0) }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { query.isEmpty || $0.canonical.localizedCaseInsensitiveContains(query)
            || $0.aliases.contains { $0.localizedCaseInsensitiveContains(query) } }
            .sorted { lhs, rhs in
                // 旧短语没有创建时间，排在有时间的词条之后。
                let lhsDate = lhs.term?.createdAt ?? .distantPast
                let rhsDate = rhs.term?.createdAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                let nameOrder = lhs.canonical.localizedStandardCompare(rhs.canonical)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.id < rhs.id
            }
    }

    func saveLegacyReplacement(_ group: VocabularySnippetGroup, updated: TerminologyEntry?) {
        do {
            var snippets = SnippetStorage.load().filter { !($0.value == group.replacement && group.triggers.contains($0.trigger)) }
            if let updated {
                let occupied = Set(snippets.map { TerminologyText.aliasStorageKey($0.trigger) })
                guard !updated.aliases.isEmpty,
                      !updated.aliases.contains(where: { occupied.contains(TerminologyText.aliasStorageKey($0.text)) }) else {
                    editorError = L("原文字已有其他替换，请先编辑现有词条。", "The original text already has a replacement.")
                    return
                }
                snippets += updated.aliases.map { (trigger: $0.text, value: updated.canonicalText) }
            }
            try SnippetStorage.save(snippets)
            legacyEditor = nil
            Task { await reload() }
        } catch { editorError = error.localizedDescription }
    }

    var discoveriesCard: some View {
        let discoveries = pendingDiscoveries
        return settingsGroupCard(
            L("待确认发现", "Discoveries awaiting confirmation"),
            icon: "sparkles.rectangle.stack",
            expandVertically: false
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L(
                    "仅展示在至少两次明确纠正中重复出现、但尚未进入术语库的对应关系。不会自动入库。",
                    "Shows mappings repeated in at least two explicit corrections but not yet in the terminology library. Nothing is added automatically."
                ))
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)

                if !discoveryLoadErrorMessage.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(TF.settingsAccentRed)
                        Text(discoveryLoadErrorMessage)
                            .font(TF.settingsFontCaption)
                            .foregroundStyle(TF.settingsAccentRed)
                        Spacer(minLength: 8)
                        SettingsTextButton(L("重试", "Retry"), controlSize: .compact) {
                            Task { await reload() }
                        }
                    }
                }

                if discoveries.isEmpty {
                    terminologyEmptyState(
                        title: L("没有待确认发现", "No discoveries to review"),
                        description: L("你在识别记录中点击“纠正”后，明确的术语修改可直接确认；重复候选也会汇总到这里。", "Use Correct on a Voice Polish record to confirm a clear term edit; repeated candidates also collect here.")
                    )
                } else {
                    ForEach(Array(discoveries.enumerated()), id: \.element.id) { index, discovery in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(discovery.alias)
                                        .foregroundStyle(TF.settingsTextTertiary)
                                    Image(systemName: "arrow.right")
                                        .font(TF.settingsFontIconMicro)
                                        .foregroundStyle(TF.settingsTextTertiary)
                                    Text(discovery.canonical)
                                        .foregroundStyle(TF.settingsText)
                                }
                                .font(TF.settingsFontBodyStrong)
                                Text(L("来自 \(discovery.sourceRecordIDs.count) 次明确纠正", "Seen in \(discovery.sourceRecordIDs.count) explicit corrections"))
                                    .font(TF.settingsFontCaption)
                                    .foregroundStyle(TF.settingsTextTertiary)
                                Text(L(
                                    "最近出现：\(Self.discoveryDateFormatter.string(from: discovery.lastSeenAt))",
                                    "Last seen: \(Self.discoveryDateFormatter.string(from: discovery.lastSeenAt))"
                                ))
                                .font(TF.settingsFontMetadata)
                                .foregroundStyle(TF.settingsTextTertiary)
                            }
                            Spacer(minLength: 8)
                            SettingsTextButton(L("忽略", "Ignore"), controlSize: .compact) {
                                ignoreDiscovery(discovery)
                            }
                            SettingsTextButton(L("编辑后确认", "Edit & Confirm"), controlSize: .compact) {
                                editDiscovery(discovery)
                            }
                            SettingsTextButton(L("确认加入", "Confirm"), variant: .primary, controlSize: .compact) {
                                confirmDiscovery(discovery)
                            }
                        }
                        if index < discoveries.count - 1 {
                            Rectangle().fill(TF.settingsStroke.opacity(0.5)).frame(height: 1)
                        }
                    }
                }

                if !ignoredDiscoveryIDs.isEmpty {
                    SettingsTextButton(L("恢复已忽略候选", "Restore Ignored"), controlSize: .compact) {
                        ignoredDiscoveryIDs = []
                        persistIgnoredDiscoveries()
                        statusMessage = L("已恢复待确认候选", "Ignored discoveries restored")
                    }
                }
            }
        }
    }

    var builtInTermsCard: some View {
        settingsGroupCard(
            L("内置词汇", "Built-in Words"),
            icon: "shippingbox",
            expandVertically: false
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L(
                    "内置词不可改名或删除，但可以逐项停用。你的个人术语优先级更高。",
                    "Built-in terms cannot be renamed or deleted, but each can be disabled. Your personal terms take priority."
                ))
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)
                terminologyList(
                    entries: filteredBuiltInTerms,
                    emptyTitle: searchText.isEmpty ? L("暂无内置术语", "No built-in terms") : L("没有匹配项", "No matches"),
                    emptyDescription: searchText.isEmpty ? L("当前内置词表为空。", "The built-in terminology list is empty.") : L("换一个关键词试试。", "Try another search.")
                )
            }
        }
    }

    var myTerms: [TerminologyEntry] {
        (document?.entries ?? [])
            .filter { $0.origin != .builtIn && $0.origin != .contextCandidate }
            .sorted(by: termSort)
    }

    var builtInTerms: [TerminologyEntry] {
        (document?.entries ?? [])
            .filter { $0.origin == .builtIn }
            .sorted(by: termSort)
    }

    var filteredBuiltInTerms: [TerminologyEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return builtInTerms }
        return builtInTerms.filter { entry in
            entry.canonicalText.localizedCaseInsensitiveContains(query)
                || entry.aliases.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    var pendingDiscoveries: [PendingTerminologyDiscovery] {
        struct Bucket {
            let alias: String
            let canonical: String
            var sourceRecordIDs: [String]
            var lastSeenAt: Date
        }
        var buckets: [String: Bucket] = [:]
        for correction in corrections where correction.learnTerminology {
            for candidate in TerminologyCorrectionExtractor.candidates(
                generatedText: correction.generatedText,
                correctedText: correction.correctedText
            ) {
                let key = TerminologyDiscoveryIdentity.id(
                    alias: candidate.alias,
                    canonical: candidate.canonical
                )
                var bucket = buckets[key] ?? Bucket(
                    alias: candidate.alias,
                    canonical: candidate.canonical,
                    sourceRecordIDs: [],
                    lastSeenAt: correction.createdAt
                )
                if !bucket.sourceRecordIDs.contains(correction.historyID) {
                    bucket.sourceRecordIDs.append(correction.historyID)
                }
                bucket.lastSeenAt = max(bucket.lastSeenAt, correction.createdAt)
                buckets[key] = bucket
            }
        }

        let known = Set((document?.entries ?? []).flatMap { entry in
            entry.aliases.map {
                TerminologyDiscoveryIdentity.id(alias: $0.text, canonical: entry.canonicalText)
            }
        })
        return buckets.compactMap { key, bucket -> PendingTerminologyDiscovery? in
            guard bucket.sourceRecordIDs.count >= 2,
                  !known.contains(key),
                  !ignoredDiscoveryIDs.contains(key) else { return nil }
            return PendingTerminologyDiscovery(
                alias: bucket.alias,
                canonical: bucket.canonical,
                sourceRecordIDs: bucket.sourceRecordIDs,
                lastSeenAt: bucket.lastSeenAt
            )
        }.sorted {
            if $0.sourceRecordIDs.count != $1.sourceRecordIDs.count {
                return $0.sourceRecordIDs.count > $1.sourceRecordIDs.count
            }
            return $0.canonical.localizedCaseInsensitiveCompare($1.canonical) == .orderedAscending
        }
    }

    var selectedASRProvider: ASRProvider {
        ASRProvider(rawValue: selectedASRProviderRaw) ?? .volcano
    }

    @ViewBuilder
    func terminologyList(
        entries: [TerminologyEntry],
        emptyTitle: String,
        emptyDescription: String,
        allowsEditing: Bool = false
    ) -> some View {
        if entries.isEmpty {
            terminologyEmptyState(title: emptyTitle, description: emptyDescription)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    terminologyRow(entry, allowsEditing: allowsEditing)
                    if index < entries.count - 1 {
                        Rectangle().fill(TF.settingsStroke.opacity(0.5)).frame(height: 1)
                    }
                }
            }
        }
    }

    func terminologyRow(_ entry: TerminologyEntry, allowsEditing: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(entry.canonicalText)
                        .font(TF.settingsFontBodyStrong)
                        .foregroundStyle(entry.isEnabled ? TF.settingsText : TF.settingsTextTertiary)
                    Text(originTitle(entry.origin))
                        .font(TF.settingsFontMetadata)
                        .foregroundStyle(TF.settingsTextTertiary)
                    if entry.scope.kind == .application,
                       let bundleID = entry.scope.applicationBundleIdentifier {
                        Text(bundleID)
                            .font(TF.settingsFontMetadata)
                            .foregroundStyle(TF.settingsAccentBlue)
                            .lineLimit(1)
                    }
                }

                Text(entry.aliases.isEmpty
                    ? L("暂无错误写法", "No known mishearings")
                    : L("常见错法：\(entry.aliases.map(\.text).joined(separator: "、"))", "Misheard as: \(entry.aliases.map(\.text).joined(separator: ", "))"))
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .lineLimit(2)

                HStack(spacing: 5) {
                    terminologyStatusChip(
                        L("识别增强", "ASR"),
                        active: entry.isEnabled
                            && entry.scope.kind == .global
                            && ASRTerminologyCapabilities.forProvider(selectedASRProvider).hotwordDelivery != .unsupported
                    )
                    .help(asrStatusHelp(for: entry))
                    terminologyStatusChip(
                        L("自动纠错", "Correction"),
                        active: entry.isEnabled && hasUnconflictedAlias(entry)
                    )
                }
            }
            Spacer(minLength: 12)

            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { setEntryEnabled(entry, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityLabel(entry.isEnabled ? L("停用术语", "Disable term") : L("启用术语", "Enable term"))

            if allowsEditing && !entry.isReadOnly {
                SettingsTextButton(L("编辑", "Edit"), controlSize: .compact) {
                    editorDraft = TerminologyEditorDraft(entry: entry)
                }
                SettingsDeleteIconButton(
                    systemName: "trash",
                    accessibilityLabel: L("删除术语", "Delete term")
                ) {
                    pendingDeletion = entry
                }
            }
        }
        .padding(.vertical, 10)
        .opacity(entry.isEnabled ? 1 : 0.68)
    }

    func terminologyEmptyState(title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(TF.settingsFontBodyStrong)
                .foregroundStyle(TF.settingsText)
            Text(description)
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    func terminologyStatusChip(_ title: String, active: Bool) -> some View {
        SettingsChip(
            title,
            controlSize: .compact,
            font: TF.settingsFontMetadata,
            foreground: active ? TF.settingsAccentGreen : TF.settingsTextTertiary,
            fill: active ? TF.settingsSuccessFill : TF.settingsCardAlt
        )
    }

    func providerDeliveryDescription(_ capabilities: ASRTerminologyCapabilities) -> String {
        switch capabilities.hotwordDelivery {
        case .request:
            return capabilities.aliasDelivery == .requestCorrections
                ? L("标准术语和错词映射会随每次识别请求下发；Muse 仍保留本地纠错兜底。", "Canonical terms and correction mappings are sent with each request; Muse keeps local correction as a fallback.")
                : L("标准术语会随每次识别请求下发；错词映射由 Muse 在本地确定性纠正。", "Canonical terms are sent with each request; aliases are corrected deterministically by Muse locally.")
        case .remoteVocabulary:
            return L("此引擎通过远端词表增强识别。界面保存只代表 Muse 本地词库与兼容配置已更新；远端不可用时仍由本地纠错兜底。", "This engine boosts recognition through a remote vocabulary. Saved here means Muse's local library and compatibility config were updated; local correction remains the fallback if remote sync is unavailable.")
        case .localServiceVocabulary:
            return L("标准术语提供给本地识别服务，错词映射由 Muse 本地确定性纠正。", "Canonical terms are provided to the local recognition service; aliases are corrected deterministically by Muse.")
        case .unsupported:
            return L("此引擎不支持术语下发，因此没有识别前增强；识别后的本地纠错仍然生效。", "This engine does not support terminology delivery, so there is no pre-ASR boost; local correction still applies.")
        }
    }

    func originTitle(_ origin: TerminologyOrigin) -> String {
        switch origin {
        case .confirmedCorrection: return L("纠正确认", "Confirmed")
        case .manual: return L("手动添加", "Manual")
        case .legacyPersonalLexicon: return L("个人词典", "Personal lexicon")
        case .legacySnippet: return L("旧错词", "Legacy correction")
        case .legacyHotword: return L("旧热词", "Legacy hotword")
        case .builtIn: return L("内置", "Built-in")
        case .contextCandidate: return L("候选", "Candidate")
        }
    }

    func asrStatusHelp(for entry: TerminologyEntry) -> String {
        if entry.scope.kind == .application {
            return L(
                "指定应用词不会全局下发给识别引擎；本地纠错仍在该应用生效。",
                "App-scoped terms are not sent globally to ASR; local correction still applies in that app."
            )
        }
        if ASRTerminologyCapabilities.forProvider(selectedASRProvider).hotwordDelivery == .unsupported {
            return L(
                "当前识别引擎不支持术语下发，Muse 会使用本地纠错兜底。",
                "The current ASR does not support term delivery; Muse uses local correction as the fallback."
            )
        }
        return L("该标准术语会用于识别增强。", "This canonical term is used for ASR boosting.")
    }

    func hasUnconflictedAlias(_ entry: TerminologyEntry) -> Bool {
        entry.aliases.contains { alias in
            let aliasKey = TerminologyText.normalizedKey(alias.text)
            return !(document?.conflicts.contains { conflict in
                conflict.normalizedAlias == aliasKey
                    && conflict.candidates.contains { $0.entryID == entry.id }
            } ?? false)
        }
    }

    func termSort(_ lhs: TerminologyEntry, _ rhs: TerminologyEntry) -> Bool {
        if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled && !rhs.isEnabled }
        if lhs.origin.priority != rhs.origin.priority { return lhs.origin.priority > rhs.origin.priority }
        return lhs.canonicalText.localizedCaseInsensitiveCompare(rhs.canonicalText) == .orderedAscending
    }

    @MainActor
    func reload() async {
        legacySnippets = SnippetStorage.load().filter {
            !SnippetStorage.isDraftTrigger($0.trigger)
                && !TerminologyMigration.isEligibleTerminologySnippet(trigger: $0.trigger, value: $0.value)
        }
        switch TerminologyRepository.loadResult() {
        case .corrupt(let url, let error):
            document = nil
            corruptFileURL = url
            loadErrorMessage = error.localizedDescription
            return
        case .missing, .value:
            document = TerminologyRepository.load()
            corruptFileURL = nil
            loadErrorMessage = ""
        }

        do {
            corrections = try await historyStore.fetchVoicePolishCorrections()
            discoveryLoadErrorMessage = ""
        } catch {
            // 词库本身仍可管理；候选历史不可用时明确显示状态，不伪装成已加载。
            corrections = []
            discoveryLoadErrorMessage = error.localizedDescription
        }
    }

    func migrateLegacyVocabulary() {
        guard !isMigrating else { return }
        isMigrating = true
        do {
            let outcome = try TerminologyRepository.migrateIfNeeded()
            statusMessage = outcome.didMigrate
                ? L("已整合 \(outcome.importedEntryCount) 个术语", "Consolidated \(outcome.importedEntryCount) terms")
                : L("已是最新结构", "Already up to date")
            Task { await reload() }
        } catch {
            loadErrorMessage = error.localizedDescription
        }
        isMigrating = false
    }

    func saveEntry(
        _ entry: TerminologyEntry,
        discoverySourceRecordIDs: [String] = []
    ) {
        do {
            var savedEntry = entry
            let fixedKeys = Set(legacySnippets.map { TerminologyText.aliasStorageKey($0.trigger) })
            if entry.isEnabled && entry.aliases.contains(where: {
                fixedKeys.contains(TerminologyText.aliasStorageKey($0.text))
            }) {
                editorError = L("原文字已有替换，请在列表中编辑现有词条。", "This original text already has a replacement. Edit the existing entry.")
                return
            }
            if !discoverySourceRecordIDs.isEmpty {
                savedEntry.origin = .confirmedCorrection
                savedEntry.aliases = savedEntry.aliases.map { alias in
                    TerminologyAlias(
                        id: alias.id,
                        text: alias.text,
                        source: .confirmedCorrection,
                        evidenceCount: discoverySourceRecordIDs.count,
                        lastSeenAt: Date(),
                        sourceRecordIDs: discoverySourceRecordIDs
                    )
                }
            }
            try TerminologyRepository.upsert(savedEntry)
            editorDraft = nil
            document = TerminologyRepository.load()
            statusMessage = document?.conflicts.isEmpty == false
                ? L("已保存；冲突写法已暂停自动替换", "Saved; conflicting aliases are paused")
                : L("术语已保存", "Term saved")
        } catch {
            editorError = error.localizedDescription
        }
    }

    func setEntryEnabled(_ entry: TerminologyEntry, enabled: Bool) {
        do {
            try TerminologyRepository.setEnabled(enabled, id: entry.id)
            document = TerminologyRepository.load()
            statusMessage = enabled ? L("术语已启用", "Term enabled") : L("术语已停用", "Term disabled")
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    func removeEntry(_ entry: TerminologyEntry) {
        do {
            try TerminologyRepository.remove(id: entry.id)
            if entry.origin == .confirmedCorrection {
                // 数据库中的原始纠正仍存在。同步写入忽略键，避免删除后的同一候选立即回到“待确认发现”。
                ignoredDiscoveryIDs.formUnion(TerminologyDiscoveryIdentity.ids(for: entry))
                persistIgnoredDiscoveries()
            }
            document = TerminologyRepository.load()
            statusMessage = L("术语已删除", "Term deleted")
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    func confirmDiscovery(_ discovery: PendingTerminologyDiscovery) {
        do {
            _ = try TerminologyRepository.addConfirmedEvidence(
                alias: discovery.alias,
                canonical: discovery.canonical,
                sourceRecordIDs: discovery.sourceRecordIDs
            )
            document = TerminologyRepository.load()
            statusMessage = L("发现已加入术语库", "Discovery added to terminology")
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    func editDiscovery(_ discovery: PendingTerminologyDiscovery) {
        let entry = TerminologyEntry(
            canonicalText: discovery.canonical,
            aliases: [TerminologyAlias(
                text: discovery.alias,
                source: .confirmedCorrection,
                evidenceCount: discovery.sourceRecordIDs.count,
                lastSeenAt: discovery.lastSeenAt,
                sourceRecordIDs: discovery.sourceRecordIDs
            )],
            origin: .confirmedCorrection
        )
        editorDraft = TerminologyEditorDraft(
            entry: entry,
            discoverySourceRecordIDs: discovery.sourceRecordIDs
        )
    }

    func ignoreDiscovery(_ discovery: PendingTerminologyDiscovery) {
        ignoredDiscoveryIDs.insert(discovery.id)
        persistIgnoredDiscoveries()
        statusMessage = L("候选已忽略", "Discovery ignored")
    }

    func persistIgnoredDiscoveries() {
        UserDefaults.standard.set(
            ignoredDiscoveryIDs.sorted(),
            forKey: Self.ignoredDiscoveriesKey
        )
    }

    func exportTerminology() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Muse-Terminology-\(Self.exportDateString()).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let export = VocabularyExport(
                terms: TerminologyRepository.load(),
                replacements: legacySnippets.map { .init(original: $0.trigger, replacement: $0.value) }
            )
            try encoder.encode(export).write(to: url, options: .atomic)
            statusMessage = L("术语已导出", "Terminology exported")
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    static func exportDateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    static let discoveryDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Locale.preferredLanguages.first ?? "zh-Hans")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct VocabularyExport: Encodable {
    struct Replacement: Encodable { let original: String; let replacement: String }
    let terms: TerminologyDocument
    let replacements: [Replacement]
}

private struct TerminologyAliasInput: Identifiable {
    let id = UUID()
    var text: String
}

private struct TerminologyEntryEditorSheet: View {
    let entry: TerminologyEntry?
    let requiresAlias: Bool
    let allowsScope: Bool
    let errorMessage: String
    let onCancel: () -> Void
    let onSave: (TerminologyEntry) -> Void

    @State private var canonicalText: String
    @State private var aliasInputs: [TerminologyAliasInput]
    @State private var scopeKind: TerminologyScope.Kind
    @State private var applicationBundleID: String
    @FocusState private var focusedAliasID: UUID?

    init(
        entry: TerminologyEntry?,
        requiresAlias: Bool = false,
        allowsScope: Bool = true,
        errorMessage: String = "",
        onCancel: @escaping () -> Void,
        onSave: @escaping (TerminologyEntry) -> Void
    ) {
        self.entry = entry
        self.requiresAlias = requiresAlias
        self.allowsScope = allowsScope
        self.errorMessage = errorMessage
        self.onCancel = onCancel
        self.onSave = onSave
        _canonicalText = State(initialValue: entry?.canonicalText ?? "")
        let aliases = entry?.aliases.map { TerminologyAliasInput(text: $0.text) } ?? []
        _aliasInputs = State(initialValue: aliases.isEmpty ? [TerminologyAliasInput(text: "")] : aliases)
        _scopeKind = State(initialValue: entry?.scope.kind ?? .global)
        _applicationBundleID = State(initialValue: entry?.scope.applicationBundleIdentifier ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(entry == nil ? L("新增词条", "Add Entry") : L("编辑词条", "Edit Entry"))
                .font(TF.settingsFontSectionTitle)
                .foregroundStyle(TF.settingsText)

            terminologyField(
                title: L("替换为 / 正确写法", "Replacement / correct form"),
                hint: L("例如 Typeless", "For example, Typeless"),
                text: $canonicalText
            )

            aliasFields

            if allowsScope {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("生效范围", "Scope"))
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                Picker("", selection: $scopeKind) {
                    Text(L("全部应用", "All apps")).tag(TerminologyScope.Kind.global)
                    Text(L("指定应用", "Specific app")).tag(TerminologyScope.Kind.application)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .accessibilityLabel(L("生效范围", "Scope"))
                .accessibilityValue(scopeKind == .global
                    ? L("全部应用", "All apps")
                    : L("指定应用", "Specific app"))
                if scopeKind == .application {
                    TextField(L("应用 Bundle ID，例如 com.openai.chat", "App bundle ID, e.g. com.openai.chat"), text: $applicationBundleID)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L("应用 Bundle ID", "App bundle ID"))
                        .accessibilityHint(L(
                            "请输入反向域名格式，例如 com.openai.chat",
                            "Enter a reverse-domain identifier such as com.openai.chat"
                        ))
                    if !applicationBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !TerminologyBundleIdentifierValidator.isValid(applicationBundleID) {
                        Text(L(
                            "Bundle ID 格式无效。请使用 com.company.app 这类反向域名格式，只包含英文字母、数字、连字符和点。",
                            "Invalid Bundle ID. Use reverse-domain format such as com.company.app with letters, numbers, hyphens, and dots only."
                        ))
                        .font(TF.settingsFontCaption)
                        .foregroundStyle(TF.settingsAccentRed)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            }
            Text(scopeDescription)
            .font(TF.settingsFontCaption)
            .foregroundStyle(TF.settingsTextTertiary)
            .fixedSize(horizontal: false, vertical: true)

            if !errorMessage.isEmpty {
                Text(errorMessage).font(TF.settingsFontCaption).foregroundStyle(TF.settingsAccentRed)
            }
            HStack(spacing: 8) {
                Spacer()
                SettingsTextButton(L("取消", "Cancel"), variant: .secondary, onCanvas: true, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                SettingsTextButton(L("保存", "Save"), variant: .primary) {
                    onSave(makeEntry())
                }
                .disabled(!canSave)
            }
        }
        .padding(18)
        .frame(width: 480)
        .background(TF.settingsCanvas)
    }

    private var aliasesText: String {
        aliasInputs.map(\.text).joined(separator: "\n")
    }

    private var aliasFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("原文字 / 常见错法", "Original / mishearing"))
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($aliasInputs) { $input in
                            HStack(spacing: 8) {
                                TextField(L("填写一种常见错法", "Enter one mishearing"), text: $input.text, axis: .vertical)
                                    .lineLimit(1...2)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel(L("常见错法", "Mishearing"))
                                    .focused($focusedAliasID, equals: input.id)
                                    .onSubmit { addAlias() }
                                    .onChange(of: input.text) { _, text in
                                        splitPastedAliases(text, inputID: input.id)
                                    }
                                Button { removeAlias(input.id) } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(TF.settingsTextTertiary)
                                }
                                .buttonStyle(.plain)
                                .help(L("移除这条错法", "Remove this mishearing"))
                                .accessibilityLabel(L("移除这条错法", "Remove this mishearing"))
                            }
                            .frame(minHeight: 28)
                            .id(input.id)
                        }
                    }
                    .padding(.trailing, 12)
                }
                .frame(height: min(CGFloat(aliasInputs.count) * 36 - 8, 172))
                .onChange(of: focusedAliasID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            SettingsTextButton(L("＋ 添加错法", "+ Add mishearing"), controlSize: .compact, onCanvas: true) {
                addAlias()
            }
            Text(L("每条填写一种错法，都会纠正为上方的正确写法。", "Each mishearing is corrected to the form above."))
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)
        }
    }

    private func addAlias() {
        let input = TerminologyAliasInput(text: "")
        aliasInputs.append(input)
        DispatchQueue.main.async { focusedAliasID = input.id }
    }

    private func removeAlias(_ id: UUID) {
        guard let index = aliasInputs.firstIndex(where: { $0.id == id }) else { return }
        if aliasInputs.count == 1 {
            aliasInputs[0].text = ""
        } else {
            aliasInputs.remove(at: index)
        }
    }

    /// 保留原先按行粘贴多个错法的能力，并将其展开为独立输入行。
    private func splitPastedAliases(_ text: String, inputID: UUID) {
        guard text.rangeOfCharacter(from: .newlines) != nil,
              let index = aliasInputs.firstIndex(where: { $0.id == inputID }) else { return }
        let values = splitAliases(text)
        aliasInputs[index].text = values.first ?? ""
        let added = values.dropFirst().map { TerminologyAliasInput(text: $0) }
        aliasInputs.insert(contentsOf: added, at: index + 1)
    }

    private var canSave: Bool {
        !canonicalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!requiresAlias || !splitAliases(aliasesText).isEmpty)
            && (scopeKind == .global
                || TerminologyBundleIdentifierValidator.isValid(applicationBundleID))
    }

    private var scopeDescription: String {
        if scopeKind == .application {
            return L(
                "只在 Bundle ID 精确匹配的应用中进行本地纠错；不会把该术语全局下发给识别引擎。保存后如产生冲突，Muse 会暂停该错词的自动替换。",
                "Local correction applies only in the app whose Bundle ID matches exactly. The term is not sent globally to the recognition engine. Muse pauses an alias if saving creates a conflict."
            )
        }
        return L(
            "标准写法会尽可能用于识别增强；错误写法用于识别后的确定性纠正。保存后如产生冲突，Muse 会暂停该错词的自动替换。",
            "The canonical term is used for recognition boosting where supported; aliases drive deterministic post-ASR correction. Muse pauses an alias if saving creates a conflict."
        )
    }

    private func terminologyField(
        title: String,
        hint: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)
            TextField(hint, text: text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
        }
    }

    private func makeEntry() -> TerminologyEntry {
        let canonical = canonicalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliasStrings = splitAliases(aliasesText).filter {
            TerminologyText.displayKey($0) != TerminologyText.displayKey(canonical)
        }
        var existingAliases: [String: TerminologyAlias] = [:]
        for alias in entry?.aliases ?? [] {
            existingAliases[TerminologyText.aliasStorageKey(alias.text)] = alias
        }
        let aliases = aliasStrings.map { aliasText in
            existingAliases[TerminologyText.aliasStorageKey(aliasText)]
                ?? TerminologyAlias(text: aliasText, source: .manual)
        }
        let scope = scopeKind == .global
            ? TerminologyScope.global
            : TerminologyScope.application(applicationBundleID)
        return TerminologyEntry(
            id: entry?.id ?? UUID(),
            canonicalText: canonical,
            aliases: aliases,
            isEnabled: entry?.isEnabled ?? true,
            origin: entry?.origin ?? .manual,
            scope: scope,
            createdAt: entry?.createdAt ?? Date(),
            updatedAt: Date()
        )
    }

    private func splitAliases(_ text: String) -> [String] {
        let separators = CharacterSet.newlines
        var seen = Set<String>()
        return text.components(separatedBy: separators).compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = TerminologyText.aliasStorageKey(value)
            guard !value.isEmpty, !key.isEmpty, seen.insert(key).inserted else { return nil }
            return value
        }
    }
}
