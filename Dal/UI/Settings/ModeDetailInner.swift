import AppKit
import SwiftUI

struct ModeDetailInner: View, SettingsCardHelpers {
    let mode: ProcessingMode
    /// 工作区实际可用高度（由 ModesSettingsTab 现场几何计算传入，2026-07-08：
    /// 不再用窗口常量预算，消除隐藏标题栏窗口下的页尾死白）
    let workbenchHeight: CGFloat
    let onSave: (ProcessingMode) -> Void

    /// Prompt 块占工作区一半（2026-06-13 拍板比例不变），测试区拿剩余
    private var promptBlockHeight: CGFloat {
        (workbenchHeight * 0.5).rounded()
    }

    private var trialBlockHeight: CGFloat {
        max(workbenchHeight - promptBlockHeight - ModeSettingsLayout.modeWorkbenchGap, 0)
    }

    @State private var prompt = ""

    // 输入即保存（2026-07-08 大梁老师）：停顿 0.6s 落盘；切模式/离开页面前兜底 flush
    @State private var pendingSaveTask: Task<Void, Never>?
    @State private var pendingPrompt: String?
    @State private var pendingMode: ProcessingMode?

    // 渐隐只在对应方向真有被裁内容时出现（未滚动时不得盖住第一行字）
    @State private var promptHasContentAbove = false
    @State private var promptHasContentBelow = false

    var body: some View {
        VStack(alignment: .leading, spacing: ModeSettingsLayout.modeWorkbenchGap) {
            modePromptBlock
            ModeTrialCard(
                mode: mode, name: mode.name, processingLabel: mode.processingLabel,
                prompt: prompt, hotkeyStyle: mode.hotkeyStyle, blockHeight: trialBlockHeight
            )
        }
        .frame(width: ModeSettingsLayout.modeWorkspaceWidth, alignment: .topLeading)
        .frame(minHeight: workbenchHeight, alignment: .topLeading)
        .onAppear(perform: syncFields)
        .onChange(of: mode.id) { _, _ in
            flushPendingSave()
            syncFields()
        }
        .onChange(of: prompt) { _, newPrompt in
            scheduleAutoSave(newPrompt)
        }
        .onDisappear {
            flushPendingSave()
        }
    }

    private var isDirectMode: Bool {
        mode.id == ProcessingMode.directId
    }


}

private extension ModeDetailInner {
    var modePromptBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            modePromptHeader

            // 标题与内容只用一条横线区分（2026-07-08 大梁老师）
            Rectangle()
                .fill(modeFieldStroke)
                .frame(height: 1)
                .padding(.horizontal, ModeSettingsLayout.modeGutter)

            modePromptEditor
                .padding(.top, 10)
        }
        // Prompt 块占工作区一半（2026-06-13 用户拍板重构；高度改由实际几何现场计算），
        // 剩余归下方测试区(输入/输出左右对照、各撑满)
        .frame(
            width: ModeSettingsLayout.modeWorkspaceWidth,
            height: promptBlockHeight,
            alignment: .topLeading
        )
        .background {
            RoundedRectangle(
                cornerRadius: ModeSettingsLayout.modeFieldCornerRadius,
                style: .continuous
            )
            .fill(modeFieldFill)
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: ModeSettingsLayout.modeFieldCornerRadius,
                style: .continuous
            )
            .stroke(modeFieldStroke, lineWidth: 1)
        }
    }

    /// 标题行：处理要求 + 恢复默认（靠右）。保存按钮已撤——输入即自动保存（2026-07-08 大梁老师）
    var modePromptHeader: some View {
        HStack(spacing: ModeSettingsLayout.modePromptActionSpacing) {
            Text(mode.kind == .voicePolish
                ? L("附加润色要求", "Additional polishing requirements")
                : L("提示词", "Prompt"))
                .font(TF.settingsFontBodyLarge)
                .foregroundStyle(TF.settingsTextTertiary)
                .lineLimit(1)

            Spacer(minLength: 12)

            SettingsIconButton(
                systemName: "arrow.counterclockwise",
                accessibilityLabel: L("恢复默认", "Restore default"),
                variant: .ghost,
                size: ModeSettingsLayout.modePromptRestoreButtonSize
            ) {
                restoreDefaults()
            }
            .help(mode.kind == .voicePolish
                ? L("恢复默认附加要求", "Restore default requirements")
                : L("恢复默认 Prompt", "Restore the default prompt"))
            .disabled(isDirectMode)
        }
        .padding(.horizontal, ModeSettingsLayout.modeGutter)
        .padding(.vertical, 8)
    }

    var modePromptEditor: some View {
        ZStack(alignment: .topLeading) {
            ModeTextArea(
                text: $prompt,
                isEditable: !isDirectMode,
                onScrollEdges: { above, below in
                    promptHasContentAbove = above
                    promptHasContentBelow = below
                }
            )
            .settingsVerticalScrollFade(
                color: modeInputAreaFill,
                // 12pt 浅渐隐：只作「下面还有内容」的提示，不吞掉折叠处整行文字
                // （2026-07-08 大梁老师：默认状态最后一行被晕影盖住必须下拉才能读）
                height: 12,
                showsTop: promptHasContentAbove,
                showsBottom: promptHasContentBelow
            )

            if shouldShowPromptPlaceholder || isDirectMode {
                Text(isDirectMode
                    ? L("直出不使用提示词，识别文字直接输出。", "Direct output does not use a prompt.")
                    : mode.kind == .voicePolish
                    ? L("可选：填写语气、简洁度或格式偏好...", "Optional: add tone, brevity, or format preferences...")
                    : L("在这里编辑当前模式的 Prompt...", "Edit the current mode prompt here..."))
                    .font(TF.settingsFontReading)
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.58))
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .padding(.leading, 1)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, ModeSettingsLayout.modeGutter)
        .padding(.bottom, ModeSettingsLayout.modePromptVerticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var modeFieldFill: Color {
        TF.settingsCardAlt
    }

    /// Prompt 输入框上下渐隐用的底色（输入区已无自身色块，渐变到卡片底色即"文字淡出"）
    var modeInputAreaFill: Color {
        TF.settingsCardAlt
    }

    var modeFieldStroke: Color {
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

    var shouldShowPromptPlaceholder: Bool {
        mode.id != ProcessingMode.directId
            && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var usesLegacyNewModePromptTemplate: Bool {
        !mode.isBuiltin
            && ["新模式", "New Mode", L("新模式", "New Mode")].contains(mode.name)
            && mode.prompt.trimmingCharacters(in: .whitespacesAndNewlines) == "{text}"
    }

    func restoreDefaults() {
        guard let defaultMode = ProcessingMode.defaults.first(where: { $0.id == mode.id })
            ?? ProcessingMode.defaults.first(where: { $0.name == mode.name })
        else {
            return
        }

        prompt = defaultMode.prompt
    }

    /// 输入停顿 0.6s 自动落盘；编辑归属的模式在此刻捕获，防抖期间切模式也不会存错对象
    func scheduleAutoSave(_ newPrompt: String) {
        guard !isDirectMode, newPrompt != mode.prompt else {
            // 与已保存内容一致（含 syncFields 的程序性赋值）：撤销未落盘任务
            pendingSaveTask?.cancel()
            pendingSaveTask = nil
            pendingPrompt = nil
            pendingMode = nil
            return
        }
        pendingPrompt = newPrompt
        pendingMode = mode
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            flushPendingSave()
        }
    }

    /// 把未落盘的编辑立即保存（防抖到点、切换模式、离开页面三处调用）
    func flushPendingSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        guard var updated = pendingMode, let newPrompt = pendingPrompt else { return }
        pendingPrompt = nil
        pendingMode = nil
        updated.prompt = newPrompt
        onSave(updated)
    }

    func syncFields() {
        prompt = isDirectMode || usesLegacyNewModePromptTemplate ? "" : mode.prompt
    }
}
