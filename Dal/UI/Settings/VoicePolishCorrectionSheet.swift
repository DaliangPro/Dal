import SwiftUI

struct VoicePolishCorrectionConfirmationResult: Sendable {
    let rememberedTerms: [TerminologyCorrectionCandidate]
    let learnedStyle: Bool
}

/// 纠正弹窗的可测试初始值。再次打开已纠正记录时必须恢复上一次保存的正文、
/// 场景和两项独立授权，不能退回原始成稿或套用当前全局默认值。
struct VoicePolishCorrectionInitialValues: Equatable {
    let correctedText: String
    let scene: WritingScene
    let learnTerminology: Bool
    let learnStyle: Bool

    init(
        record: HistoryRecord,
        existingCorrection: VoicePolishCorrectionRecord?,
        defaultLearnTerminology: Bool,
        defaultLearnStyle: Bool
    ) {
        correctedText = existingCorrection?.correctedText ?? record.finalText
        scene = existingCorrection?.scene ?? .unknown
        learnTerminology = existingCorrection?.learnTerminology ?? defaultLearnTerminology
        learnStyle = existingCorrection?.learnStyle ?? defaultLearnStyle
    }
}

/// 用户主动确认一次纠正时，分别决定是否记术语、是否学表达风格。
/// 两类学习互不绑定；没有可安全抽取的术语时不会伪造词条。
struct VoicePolishCorrectionSheet: View {
    let record: HistoryRecord
    let existingCorrection: VoicePolishCorrectionRecord?
    let onConfirm: (String, WritingScene, Bool, Bool) async throws -> VoicePolishCorrectionConfirmationResult
    let onCancel: () -> Void

    @State private var correctedText: String
    @State private var scene = WritingScene.unknown
    @State private var learnTerminology: Bool
    @State private var learnStyle: Bool
    @State private var isSaving = false
    @State private var errorMessage = ""
    @State private var confirmationResult: VoicePolishCorrectionConfirmationResult?

    init(
        record: HistoryRecord,
        existingCorrection: VoicePolishCorrectionRecord? = nil,
        onConfirm: @escaping (String, WritingScene, Bool, Bool) async throws -> VoicePolishCorrectionConfirmationResult,
        onCancel: @escaping () -> Void
    ) {
        let initialValues = VoicePolishCorrectionInitialValues(
            record: record,
            existingCorrection: existingCorrection,
            defaultLearnTerminology: VoicePolishSettings.terminologyLearningEnabled(),
            defaultLearnStyle: VoicePolishSettings.personalizationEnabled()
        )
        self.record = record
        self.existingCorrection = existingCorrection
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _correctedText = State(initialValue: initialValues.correctedText)
        _scene = State(initialValue: initialValues.scene)
        _learnTerminology = State(initialValue: initialValues.learnTerminology)
        _learnStyle = State(initialValue: initialValues.learnStyle)
    }

    var body: some View {
        Group {
            if let confirmationResult {
                successContent(confirmationResult)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    currentResult
                    correctionEditor
                    learningChoices

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(TF.settingsFontCaption)
                            .foregroundStyle(TF.settingsAccentRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 8) {
                        Spacer()
                        SettingsTextButton(L("取消", "Cancel"), variant: .secondary, width: 72) {
                            onCancel()
                        }
                        .keyboardShortcut(.cancelAction)
                        SettingsTextButton(
                            isSaving ? L("保存中", "Saving") : L("确认纠正", "Confirm Correction"),
                            variant: .primary,
                            minWidth: 92
                        ) {
                            Task { await confirm() }
                        }
                        .disabled(!canConfirm || isSaving)
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 520)
        .background(TF.settingsCanvas)
    }
}

private extension VoicePolishCorrectionSheet {
    func successContent(_ result: VoicePolishCorrectionConfirmationResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(TF.settingsAccentGreen)
                    .accessibilityHidden(true)
                Text(L("纠正已保存", "Correction saved"))
                    .font(TF.settingsFontSectionTitle)
                    .foregroundStyle(TF.settingsText)
            }

            if !result.rememberedTerms.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(result.rememberedTerms.enumerated()), id: \.offset) { _, candidate in
                        Text(L(
                            "已记住 \(candidate.alias) → \(candidate.canonical)",
                            "Remembered \(candidate.alias) → \(candidate.canonical)"
                        ))
                        .font(TF.settingsFontBodyStrong)
                        .foregroundStyle(TF.settingsText)
                    }
                    Text(L(
                        "从下次开始，它会用于支持的识别增强和识别后纠错，可在“我的词库”中管理。",
                        "It will be used for supported ASR boosting and post-ASR correction. Manage it in My Vocabulary."
                    ))
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(TF.settingsSuccessFill, in: RoundedRectangle(cornerRadius: 9))
            }

            if result.learnedStyle {
                Text(L(
                    "本次修改也已加入表达风格学习，只影响简洁度、正式度、分段和列表偏好。",
                    "This edit was also added to style learning and affects only brevity, formality, paragraphing, and list preferences."
                ))
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                SettingsTextButton(L("完成", "Done"), variant: .primary, width: 82) {
                    onCancel()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("纠正语音润色结果", "Correct Voice Polish result"))
                .font(TF.settingsFontSectionTitle)
                .foregroundStyle(TF.settingsText)
            Text(L(
                "这里用于补充或调整历史纠正。标准输入框中的本次成稿修改也可在短时间内自动学习；密码框、网页/自绘输入区与后续无关内容不会被观察。",
                "Use this page to add or revise a past correction. Edits to the latest dictation in a standard text field can also be learned briefly; password fields, web or custom inputs, and unrelated later content are never observed."
            ))
            .font(TF.settingsFontBody)
            .foregroundStyle(TF.settingsTextTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    var currentResult: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("当前结果", "Current result"))
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)
            Text(record.finalText)
                .font(TF.settingsFontReading)
                .foregroundStyle(TF.settingsTextSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(TF.settingsCardAlt, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    var correctionEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("你的正确版本", "Your corrected version"))
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                Spacer()
                Picker(L("写作场景", "Writing scene"), selection: $scene) {
                    ForEach(WritingScene.allCases, id: \.self) { value in
                        Text(sceneTitle(value)).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

            TextEditor(text: $correctedText)
                .font(TF.settingsFontReading)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 124)
                .background(TF.settingsCardAlt, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(L("你的正确版本", "Your corrected version"))
        }
    }

    var learningChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("这次纠正要记住什么", "What to learn from this correction"))
                .font(TF.settingsFontBodyStrong)
                .foregroundStyle(TF.settingsText)

            Toggle(isOn: $learnTerminology) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("记住术语修改", "Remember terminology changes"))
                        .font(TF.settingsFontBody)
                        .foregroundStyle(TF.settingsText)
                    Text(terminologyChoiceDescription)
                        .font(TF.settingsFontCaption)
                        .foregroundStyle(TF.settingsTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!canChooseTerminologyLearning || terminologyCandidates.isEmpty)

            if !terminologyCandidates.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(terminologyCandidates.enumerated()), id: \.offset) { _, candidate in
                        HStack(spacing: 6) {
                            Text(candidate.alias)
                                .foregroundStyle(TF.settingsTextTertiary)
                            Image(systemName: "arrow.right")
                                .font(TF.settingsFontIconMicro)
                                .foregroundStyle(TF.settingsTextTertiary)
                                .accessibilityHidden(true)
                            Text(candidate.canonical)
                                .foregroundStyle(TF.settingsText)
                        }
                        .font(TF.settingsFontCaption)
                    }
                }
                .padding(.leading, 22)
            }

            Toggle(isOn: $learnStyle) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("学习表达风格", "Learn writing style"))
                        .font(TF.settingsFontBody)
                        .foregroundStyle(TF.settingsText)
                    Text(L(
                        "只更新简洁度、正式度、分段和列表偏好，不会把整段文字当成术语。",
                        "Updates only brevity, formality, paragraph, and list preferences; it never treats the whole passage as a term."
                    ))
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!canChooseStyleLearning)

            if !hasAnyLearningChoice {
                Text(L(
                    "至少选择一种学习方式；如开关不可用，请到“语音润色”设置中开启对应功能。",
                    "Choose at least one learning option. If an option is unavailable, enable it in Voice Polish settings."
                ))
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsAccentAmber)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(TF.settingsCard, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(TF.settingsStroke, lineWidth: 1)
        }
    }

    var terminologyCandidates: [TerminologyCorrectionCandidate] {
        TerminologyCorrectionExtractor.candidates(
            generatedText: record.finalText,
            correctedText: correctedText
        )
    }

    var terminologyLearningGloballyEnabled: Bool {
        VoicePolishSettings.terminologyLearningEnabled()
    }

    var styleLearningGloballyEnabled: Bool {
        VoicePolishSettings.personalizationEnabled()
    }

    /// 已有记录的授权可以在全局开关关闭后继续查看、保留或主动取消；
    /// 全局关闭只阻止新授权，不应因一次编辑静默抹掉旧记录。
    var canChooseTerminologyLearning: Bool {
        terminologyLearningGloballyEnabled || existingCorrection?.learnTerminology == true
    }

    var canChooseStyleLearning: Bool {
        styleLearningGloballyEnabled || existingCorrection?.learnStyle == true
    }

    var effectiveLearnTerminology: Bool {
        learnTerminology && canChooseTerminologyLearning && !terminologyCandidates.isEmpty
    }

    var effectiveLearnStyle: Bool {
        learnStyle && canChooseStyleLearning
    }

    var hasAnyLearningChoice: Bool {
        effectiveLearnTerminology || effectiveLearnStyle
    }

    var terminologyChoiceDescription: String {
        if existingCorrection?.learnTerminology == true,
           !terminologyLearningGloballyEnabled {
            return L(
                "这条记录此前已授权术语记忆；你可以保留或取消，不会因全局开关关闭而被静默删除。",
                "This correction already authorized term memory. You can keep or remove it; turning off the global switch does not silently delete it."
            )
        }
        if !terminologyLearningGloballyEnabled {
            return L("全局术语学习已关闭；本次不会新增术语。", "Global terminology learning is off; no term will be added.")
        }
        if terminologyCandidates.isEmpty {
            return L("编辑后若检测到明确的错词 → 正确术语，这里会显示并允许记住。", "After editing, a clear misheard term → correct term will appear here and can be remembered.")
        }
        return L("只保存下方明确检测到的对应关系，可随时到“我的词库”管理。", "Saves only the explicit mappings shown below; manage them anytime in Terminology.")
    }

    var canConfirm: Bool {
        let cleaned = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleaned.isEmpty
            && cleaned != record.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            && hasAnyLearningChoice
    }

    @MainActor
    func confirm() async {
        guard canConfirm else { return }
        isSaving = true
        errorMessage = ""
        defer { isSaving = false }
        do {
            confirmationResult = try await onConfirm(
                correctedText,
                scene,
                effectiveLearnTerminology,
                effectiveLearnStyle
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sceneTitle(_ scene: WritingScene) -> String {
        switch scene {
        case .chat: return L("聊天", "Chat")
        case .workChat: return L("工作沟通", "Work chat")
        case .email: return L("邮件", "Email")
        case .document: return L("文档", "Document")
        case .note: return L("笔记", "Note")
        case .aiPrompt: return "AI Prompt"
        case .code: return L("代码", "Code")
        case .socialPost: return L("社交发布", "Social post")
        case .customerSupport: return L("客户支持", "Customer support")
        case .unknown: return L("未指定", "Unspecified")
        }
    }
}
