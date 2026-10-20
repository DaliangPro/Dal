import SwiftUI

/// 测试 Prompt 卡（2026-06-13 重构为左右对照）：顶部工具行（测试/恢复/保存样例）
/// + 下方左右两列——左「输入」原文、右「输出结果」,各撑满下半高度,润色/翻译
/// 前后一眼对照。与上方 Prompt 块同款设计语言、等宽。
struct ModeTrialCard: View {
    let mode: ProcessingMode
    let name: String
    let processingLabel: String
    let prompt: String
    let hotkeyStyle: ProcessingMode.HotkeyStyle
    /// 测试区高度（由 ModeDetailInner 按实际工作区几何传入）
    let blockHeight: CGFloat

    @State private var trialInput = ""
    @State private var trialOutput = ""
    @State private var trialError = ""
    @State private var trialDiagnostics = ""
    @State private var isRunningTrial = false
    @State private var activeTrialID: UUID?
    @State private var didSaveSampleFlash = false

    /// 标准测试文案（2026-06-12 用户拍板定稿）：真实语音输入的口语原文
    /// （带口头重复、补充改口），清理/润色效果一测便知
    static var standardSampleText: String { L(
        "今天我有三件事要做。第一个是我要给自己买一个沙发套。第二个是我希望 把我下一周的稿子都集中写完，至少也要把选题写完。第三个就是就是 就是把快递都拿了。哦，再补充一个事吧，就是 给自己选一身适合健身穿的衣服。",
        "I have three things to do today. First, um, I need to buy a sofa cover. Second I want to, like, finish all of next week's drafts, or at least the topic outlines. Third is just just, just pick up the packages. Oh, one more thing, get myself an outfit that works for the gym."
    ) }

    /// Prompt 优化模式：给一段粗糙指令，优化效果立现
    static var promptOptimizeSampleText: String { L(
        "帮我写一篇关于时间管理的文章，要求写得好一点，吸引人一些，最好能让读者看完就想转发。",
        "Write me an article about time management, make it good and engaging, ideally something readers want to share."
    ) }

    /// 翻译模式：一段书面中文，译文质量一目了然
    static var translateSampleText: String { L(
        "这款输入法可以把口述内容变成文字，日常输入更快，需要时还能整理内容结构。",
        "这款输入法可以把口述内容变成文字，日常输入更快，需要时还能整理内容结构。"
    ) }

    /// 分模式默认样例（2026-06-12 用户拍板）
    static func defaultSample(for mode: ProcessingMode) -> String {
        if mode.isPromptOptimizeMode { return promptOptimizeSampleText }
        if mode.isTranslateMode { return translateSampleText }
        return standardSampleText
    }

    private static func savedSampleKey(for mode: ProcessingMode) -> String {
        "tf_modeTrialSample_\(mode.id.uuidString)"
    }

    /// 用户保存过的自定义样例优先，否则用该模式的默认样例
    static func effectiveSample(for mode: ProcessingMode) -> String {
        UserDefaults.standard.string(forKey: savedSampleKey(for: mode)) ?? defaultSample(for: mode)
    }

    static func saveSample(_ text: String, for mode: ProcessingMode) {
        UserDefaults.standard.set(text, forKey: savedSampleKey(for: mode))
    }

    var body: some View {
        // 无标题行（2026-07-08 大梁老师）：左右两列各自「标签 → 横线 → 内容」，
        // 两条横线随列间距在中间断开；测试按钮在输出列右下角。
        // 中间用间隙分栏（不画竖线，沿用「不靠线条勾勒」的设计语言）
        HStack(alignment: .top, spacing: 0) {
            trialInputColumn
            trialOutputColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(
            width: ModeSettingsLayout.modeWorkspaceWidth,
            height: blockHeight,
            alignment: .topLeading
        )
        .background {
            RoundedRectangle(
                cornerRadius: ModeSettingsLayout.modeFieldCornerRadius,
                style: .continuous
            )
            .fill(fieldFill)
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: ModeSettingsLayout.modeFieldCornerRadius,
                style: .continuous
            )
            .stroke(fieldStroke, lineWidth: 1)
        }
        .onAppear {
            trialInput = Self.effectiveSample(for: mode)
        }
        .onChange(of: mode.id) { _, _ in
            activeTrialID = nil
            isRunningTrial = false
            trialInput = Self.effectiveSample(for: mode)
            clearResult()
        }
    }
}

private extension ModeTrialCard {
    /// 列内「标签 → 横线」，与 Prompt 块同款分隔语言
    func columnDivider() -> some View {
        Rectangle()
            .fill(fieldStroke)
            .frame(height: 1)
    }

    /// 左列：输入原文（可编辑），与 Prompt 编辑器同组件同字号
    var trialInputColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("输入", "Input"))
                .font(TF.settingsFontBodyLarge)
                .foregroundStyle(TF.settingsTextTertiary)
                .padding(.bottom, 2)

            columnDivider()

            ZStack(alignment: .topLeading) {
                ModeTextArea(
                    text: $trialInput,
                    isEditable: true
                )
                .id(mode.id)
                .accessibilityLabel(L("试跑输入", "Trial input"))

                if trialInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(L("输入一段测试文本...", "Enter sample text..."))
                        .font(TF.settingsFontReading)
                        .foregroundStyle(TF.settingsTextTertiary.opacity(0.58))
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .padding(.leading, 1)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .layoutPriority(1)

            // 保存样例 + 恢复 钉在输入框左下角（2026-06-13 用户拍板）；
            // 保存样例与顶部「测试」按钮等大（同 width、同尺寸,只靠主次色区分）
            HStack(spacing: 8) {
                SettingsTextButton(
                    didSaveSampleFlash ? L("已保存", "Saved") : L("保存样例", "Save"),
                    variant: .secondary,
                    width: ModeSettingsLayout.modePromptSaveButtonWidth
                ) {
                    Self.saveSample(trialInput, for: mode)
                    didSaveSampleFlash = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.2))
                        didSaveSampleFlash = false
                    }
                }
                .disabled(trialInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                SettingsIconButton(
                    systemName: "arrow.counterclockwise",
                    accessibilityLabel: L("恢复测试文案", "Restore sample text"),
                    variant: .ghost,
                    size: ModeSettingsLayout.modePromptRestoreButtonSize
                ) {
                    trialInput = Self.effectiveSample(for: mode)
                    clearResult()
                }
                .help(L("恢复测试样例", "Restore the sample text"))

                Spacer(minLength: 0)
            }
        }
        .padding(.leading, ModeSettingsLayout.modeGutter)
        .padding(.trailing, ModeSettingsLayout.modeGutter / 2)
        .padding(.vertical, ModeSettingsLayout.modeSampleVerticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 右列：输出结果（只读，常驻占位）。标题右侧挂调用状态/错误提示，不占额外行
    var trialOutputColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L("输出结果", "Output"))
                    .font(TF.settingsFontBodyLarge)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .fixedSize()

                Spacer(minLength: 8)

                if isRunningTrial || !trialError.isEmpty || !trialDiagnostics.isEmpty {
                    trialStatusLine
                }
            }
            .padding(.bottom, 2)

            columnDivider()

            ZStack(alignment: .topLeading) {
                ModeTextArea(
                    text: .constant(trialOutput),
                    isEditable: false
                )
                .accessibilityLabel(L("试跑输出", "Trial output"))

                if trialOutput.isEmpty {
                    Text(L("测试输出会显示在这里...", "Output will appear here..."))
                        .font(TF.settingsFontReading)
                        .foregroundStyle(TF.settingsTextTertiary.opacity(0.58))
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .padding(.leading, 1)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .layoutPriority(1)

            // 测试 + ✕清空 靠左，与左列「保存样例 + ↺」同构；测试与其他按钮同色
            // （2026-07-08 大梁老师）
            HStack(spacing: 8) {
                SettingsTextButton(
                    isRunningTrial ? L("测试中", "Testing") : L("测试", "Test"),
                    variant: .secondary,
                    width: ModeSettingsLayout.modePromptSaveButtonWidth
                ) {
                    Task { await runTrial() }
                }
                .disabled(!canRunTrial || isRunningTrial)
                .opacity((canRunTrial && !isRunningTrial) ? 1 : 0.62)
                .accessibilityHint(trialButtonAccessibilityHint)

                SettingsIconButton(
                    systemName: "xmark",
                    accessibilityLabel: L("清空输出", "Clear output"),
                    variant: .ghost,
                    size: ModeSettingsLayout.modePromptRestoreButtonSize
                ) {
                    clearResult()
                }
                .disabled(trialOutput.isEmpty && trialError.isEmpty && trialDiagnostics.isEmpty)
                .help(L("清空输出", "Clear the output"))

                Spacer(minLength: 0)
            }
        }
        .padding(.leading, ModeSettingsLayout.modeGutter / 2)
        .padding(.trailing, ModeSettingsLayout.modeGutter)
        .padding(.vertical, ModeSettingsLayout.modeSampleVerticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 调用状态/错误提示，挂在「输出结果」标题右侧：不单独占行
    var trialStatusLine: some View {
        HStack(spacing: 6) {
            if isRunningTrial {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
            Text(trialStatusText)
                .font(TF.settingsFontMetadata)
                .foregroundStyle(trialError.isEmpty ? TF.settingsTextTertiary : TF.settingsAccentAmber)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(trialStatusText)
    }

    var canRunTrial: Bool {
        !trialInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var trialStatusText: String {
        if isRunningTrial { return L("调用中...", "Calling...") }
        if !trialError.isEmpty { return trialError }
        return trialDiagnostics
    }

    var trialButtonAccessibilityHint: String {
        if mode.kind == .voicePolish {
            return L(
                "只测试文字润色链路，不包含麦克风和语音识别。真实语音请使用语音润色快捷键。",
                "Tests the text-polishing path only, without microphone or speech recognition. Use the Voice Polish shortcut for a real voice test."
            )
        }
        return L("使用当前设置处理左侧文字。", "Process the input with the current settings.")
    }

    var fieldFill: Color {
        TF.settingsCardAlt
    }

    var fieldStroke: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.isDark {
                return NSColor.white.withAlphaComponent(0.035)
            }
            return NSColor(
                srgbRed: 25 / 255,
                green: 31 / 255,
                blue: 41 / 255,
                alpha: 0.045
            )
        }))
    }

    func runTrial() async {
        let input = trialInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isRunningTrial else { return }

        isRunningTrial = true
        let trialID = UUID()
        activeTrialID = trialID
        clearResult()
        defer {
            if activeTrialID == trialID {
                isRunningTrial = false
                activeTrialID = nil
            }
        }

        var draftMode = mode
        draftMode.name = name
        draftMode.processingLabel = processingLabel
        draftMode.prompt = prompt
        draftMode.hotkeyStyle = hotkeyStyle

        if draftMode.kind == .direct {
            trialOutput = VoicePolishTerminologyRuntime.prepare(rawText: input, applicationBundleIdentifier: nil).canonicalText
            return
        }

        let role = PolishModelRole.resolve(draftMode.voicePolishQualityMode)
        guard let llmConfig = KeychainService.loadPolishConfig(for: role) else {
            trialError = L("当前 LLM 没有可用配置", "Current LLM is not configured")
            return
        }

        let provider = KeychainService.selectedPolishProvider(for: role)
        let client: any LLMClient = LLMProviderRegistry.makeClient(for: provider)

        if draftMode.kind == .voicePolish {
            let trialStartedAt = ContinuousClock.now
            let voicePolishConfig = llmConfig
            let asrProvider = KeychainService.selectedASRProvider
            let prepared = VoicePolishTerminologyRuntime.prepare(
                rawText: input,
                applicationBundleIdentifier: nil
            )
            let rawSegment = RecognitionSegment(
                id: "s1",
                text: input,
                startTimeMs: nil,
                endTimeMs: nil,
                confidence: nil,
                isFinal: true
            )
            let canonicalSegment = RecognitionSegment(
                id: "s1",
                text: prepared.canonicalText,
                startTimeMs: nil,
                endTimeMs: nil,
                confidence: nil,
                isFinal: true
            )
            let envelope = VoiceInputEnvelope(
                providerFinalText: input,
                rawSegments: [rawSegment],
                canonicalText: prepared.canonicalText,
                segments: [canonicalSegment],
                durationMs: 0,
                provider: asrProvider
            )
            let trialContext = WritingContext(
                scene: .unknown,
                level: .metadataOnly,
                safety: .unknown
            )
            let resolvedEntities = EntityResolver.resolve(
                segments: envelope.segments,
                lexicon: prepared.projection.personalLexicon,
                snippets: prepared.fixedSnippets,
                hotwords: [],
                context: trialContext
            )
            let voicePolishRequest = VoicePolishRequest(
                input: envelope,
                context: trialContext,
                preferences: UserPolishPreferences(
                    additionalRequirements: draftMode.prompt
                ),
                qualityMode: draftMode.voicePolishQualityMode ?? .standard,
                resolvedEntities: resolvedEntities
            )
            guard activeTrialID == trialID else { return }
            let result = await VoicePolishEditingPipeline(
                client: client,
                config: voicePolishConfig
            ).process(voicePolishRequest)
            guard activeTrialID == trialID else { return }
            let elapsedMilliseconds = milliseconds(
                ContinuousClock.now - trialStartedAt
            )
            trialOutput = result.text
            trialDiagnostics = voicePolishDiagnostics(
                result,
                elapsedMilliseconds: elapsedMilliseconds
            )
            return
        }

        guard !draftMode.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            trialOutput = input
            return
        }

        let context = PromptContext(selectedText: "", clipboardText: "")
        let expandedPrompt = draftMode.applyingLLMFormatGuard(
            to: context.expandContextVariables(draftMode.prompt)
        )

        do {
            let result = try await client.process(
                text: input,
                prompt: expandedPrompt,
                context: .processingMode,
                config: llmConfig
            )
            guard activeTrialID == trialID else { return }
            let cleaned = draftMode.applyingLLMResultCleanup(to: result)
            trialOutput = cleaned.isEmpty ? L("模型返回为空", "The model returned an empty response") : cleaned
        } catch {
            guard activeTrialID == trialID else { return }
            trialError = error.localizedDescription
        }
    }

    func clearResult() {
        trialOutput = ""
        trialError = ""
        trialDiagnostics = ""
    }

    func voicePolishDiagnostics(
        _ result: VoicePolishResult,
        elapsedMilliseconds: Int64
    ) -> String {
        let calls = L("\(result.llmAttemptCount) 次", "\(result.llmAttemptCount) call(s)")
        // 传输检查不能证明内容或版式合格，输入推断的预期也不是实际成稿版式。
        let status = result.usedFallback ? L("未完成", "Incomplete") : L("已生成", "Generated")
        let fallback = result.usedFallback ? L(" · 原文回退", " · Fallback") : ""
        return "\(calls) · \(durationText(elapsedMilliseconds)) · \(status)\(fallback)"
    }

    func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1_000
            + Int64(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    func durationText(_ milliseconds: Int64) -> String {
        if milliseconds < 1_000 {
            return "\(milliseconds) ms"
        }
        return String(format: "%.1f s", Double(milliseconds) / 1_000)
    }
}
