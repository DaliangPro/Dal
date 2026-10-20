import SwiftUI

struct ModesSettingsTab: View, SettingsCardHelpers {
    @Environment(AppState.self) private var appState
    @AppStorage(DefaultsKeys.selectedASRProvider) var selectedASRProviderRaw = ASRProvider.volcano.rawValue
    @AppStorage(DefaultsKeys.selectedLLMProvider) var selectedLLMProviderRaw = LLMProvider.doubao.rawValue
    @State private var modes: [ProcessingMode] = ModeStorage().load()
    @State private var selectedModeId: UUID?
    @State private var deletingModeId: UUID?
    @State private var isModePickerOpen = false
    @State private var modePickerTriggerFrame = CGRect.zero
    @State private var modePickerPopoverFrame = CGRect.zero
    @State private var configuringModeId: UUID?
    @State private var saveError: String?

    var body: some View {
        // 2026-07-08 大梁老师：工作区高度改按实际几何现场计算（隐藏标题栏窗口的
        // 真实内容高比窗口常量多一截，写死常量会在页尾留出死白）
        GeometryReader { proxy in
            let workbenchHeight = max(
                proxy.size.height - ModeSettingsLayout.modeToolbarHeight - ModeSettingsLayout.modeWorkbenchGap,
                0
            )
            VStack(alignment: .leading, spacing: 0) {
                modeWorkspace(workbenchHeight: workbenchHeight)
            }
        }
        .onAppear {
            if selectedModeId == nil {
                selectedModeId = visibleModes.first?.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectMode)) { note in
            guard let modeId = note.object as? UUID else { return }
            selectedModeId = modeId
            isModePickerOpen = false
        }
        .alert(L("保存失败", "Save failed"), isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) { Button(L("知道了", "OK")) { saveError = nil } }
        message: { Text(saveError ?? "") }
        .sheet(isPresented: isModeSettingsPresented) {
            modeSettingsSheet
        }
        .alert(
            L("删除模式", "Delete Mode"),
            isPresented: Binding(
                get: { deletingModeId != nil },
                set: { if !$0 { deletingModeId = nil } }
            )
        ) {
            Button(L("取消", "Cancel"), role: .cancel) { deletingModeId = nil }
            Button(L("删除", "Delete"), role: .destructive) {
                if let id = deletingModeId {
                    deleteMode(id)
                    deletingModeId = nil
                }
            }
        } message: {
            if let id = deletingModeId, let mode = modes.first(where: { $0.id == id }) {
                Text(L("确定要删除「\(mode.name)」吗？此操作不可撤销。", "Delete \"\(mode.name)\"? This cannot be undone."))
            }
        }
    }
}

private extension ModesSettingsTab {
    var visibleModes: [ProcessingMode] {
        modes
    }

    var selectedMode: ProcessingMode? {
        guard let mode = modes.first(where: { $0.id == selectedModeId }) else { return nil }
        return VoiceInputModes.resolve(mode, in: modes)
    }

    func modeWorkspace(workbenchHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: ModeSettingsLayout.modeWorkbenchGap) {
                Color.clear
                    .frame(
                        width: ModeSettingsLayout.modeWorkspaceWidth,
                        height: ModeSettingsLayout.modeToolbarHeight
                    )
                    .allowsHitTesting(false)

                modeWorkspaceDetail(workbenchHeight: workbenchHeight)
            }

            modeWorkspaceToolbar
                .zIndex(30)

            if isModePickerOpen {
                ModePickerPopover(
                    modes: visibleModes,
                    selectedModeId: selectedMode?.id,
                    popoverFrame: $modePickerPopoverFrame,
                    hotkeyTitle: hotkeyDisplayTitle,
                    onSelect: selectMode,
                    onCreate: {
                        addMode()
                        isModePickerOpen = false
                    }
                )
                .offset(
                    x: ModeSettingsLayout.modeToolbarLeadingInset,
                    y: ModeSettingsLayout.modePickerPopoverTopOffset
                )
                .zIndex(60)
            }
        }
        .frame(width: ModeSettingsLayout.modeWorkspaceWidth, alignment: .topLeading)
        .settingsDismissOnOutsideClick(
            isActive: isModePickerOpen,
            allowedFrames: modePickerAllowedFrames
        ) {
            isModePickerOpen = false
        }
        .onChange(of: isModePickerOpen) { _, newValue in
            if !newValue {
                modePickerPopoverFrame = .zero
            }
        }
    }

    @ViewBuilder
    func modeWorkspaceDetail(workbenchHeight: CGFloat) -> some View {
        if let mode = selectedMode {
            ModeDetailInner(
                mode: mode,
                workbenchHeight: workbenchHeight,
                onSave: { updated in
                    var stored = modes.first(where: { $0.id == updated.id }) ?? updated
                    stored.prompt = updated.prompt
                    updateMode(stored)
                }
            )
        } else {
            emptyDetailCard
                .frame(width: ModeSettingsLayout.modeWorkspaceWidth, alignment: .topLeading)
        }
    }

    var modeWorkspaceToolbar: some View {
        HStack(alignment: .center, spacing: 12) {
            modeWorkspaceLeft
                .zIndex(20)

            if let mode = selectedMode {
                ModeSettingsButton(modeName: mode.name) {
                    configuringModeId = mode.id
                }
                if mode.isUserDeletable {
                    ModeDeleteButton(modeName: mode.name) { deletingModeId = mode.id }
                }
            }

            Spacer(minLength: 16)
        }
        .padding(.leading, ModeSettingsLayout.modeToolbarLeadingInset)
        .padding(.trailing, ModeSettingsLayout.modeToolbarTrailingInset)
        .frame(width: ModeSettingsLayout.modeWorkspaceWidth, height: ModeSettingsLayout.modeToolbarHeight)
        .zIndex(30)
    }

    var modeWorkspaceLeft: some View {
        HStack(alignment: .center, spacing: 8) {
            ModePickerControl(
                selectedMode: selectedMode,
                isOpen: $isModePickerOpen,
                triggerFrame: $modePickerTriggerFrame
            )


        }
    }

    var emptyDetailCard: some View {
        modeSettingsCard(L("模式详情", "Mode Detail")) {
            Text(L("选择一个模式后，在右侧编辑它的快捷键、按键方式和 Prompt。", "Select a mode to edit its hotkey, key behavior, and prompt."))
                .font(TF.settingsFontBody)
                .foregroundStyle(TF.settingsTextTertiary)
                .lineSpacing(3)
        }
    }

    func updateMode(_ updated: ProcessingMode) {
        if let index = modes.firstIndex(where: { $0.id == updated.id }) {
            modes[index] = updated
            persistModes()
        }
    }

    func selectMode(_ id: UUID) {
        selectedModeId = id
        isModePickerOpen = false
    }

    func modeIndex(matchingHotkeyCode code: Int, modifiers: UInt64?, excluding excludedModeId: UUID) -> Int? {
        let normalizedModifiers = modifiers ?? 0
        return modes.firstIndex { mode in
            mode.id != excludedModeId &&
            mode.hotkeyCode == code &&
            (mode.hotkeyModifiers ?? 0) == normalizedModifiers
        }
    }

    func addMode() {
        let name = ModeNameEditing.uniqueName(
            base: L("新模式", "New Mode"),
            existingNames: modes.map(\.name)
        )
        let mode = ProcessingMode.newCustomMode(name: name)
        modes.append(mode)
        selectedModeId = mode.id
        persistModes()
    }

    func saveModeSettings(_ updated: ProcessingMode) {
        if let code = updated.hotkeyCode,
           let conflictIndex = modeIndex(
                matchingHotkeyCode: code,
                modifiers: updated.hotkeyModifiers,
                excluding: updated.id
           ) {
            modes[conflictIndex].hotkeyCode = nil
            modes[conflictIndex].hotkeyModifiers = nil
        }
        updateMode(updated)
    }

    func persistModes() {
        do {
            try ModeStorage().save(modes)
        } catch {
            AppLogger.log("[ModesSettings] Failed to save modes: \(String(describing: error))")
            saveError = L("模式保存失败，请重试。", "Could not save modes. Please try again.")
            modes = appState.availableModes
            return
        }
        appState.availableModes = modes
        NotificationCenter.default.post(name: .modesDidChange, object: nil)

        if let updatedCurrentMode = modes.first(where: { $0.id == appState.currentMode.id }) {
            appState.currentMode = updatedCurrentMode
        } else if let fallback = modes.first {
            appState.currentMode = fallback
        }
    }

    func deleteMode(_ id: UUID) {
        guard let mode = modes.first(where: { $0.id == id }), mode.isUserDeletable else { return }
        modes.removeAll { $0.id == id }
        if selectedModeId == id {
            selectedModeId = modes.first(where: { $0.id == ProcessingMode.directId })?.id
                ?? modes.first?.id
        }
        persistModes()
    }

    var modePickerAllowedFrames: [CGRect] {
        [
            modePickerTriggerFrame,
            modePickerPopoverFrame,
            estimatedModePickerPopoverFrame,
        ]
    }

    var estimatedModePickerPopoverFrame: CGRect {
        guard !modePickerTriggerFrame.isNull, !modePickerTriggerFrame.isEmpty else {
            return .zero
        }

        let popoverHeight = ModePickerControlMetrics.popoverHeight(optionCount: visibleModes.count)
        let width = max(
            ModeSettingsLayout.modePickerPopoverWidth,
            modePickerTriggerFrame.width
        )

        return CGRect(
            x: modePickerTriggerFrame.minX - 4,
            y: modePickerTriggerFrame.minY - popoverHeight - 12,
            width: width + 8,
            height: popoverHeight + modePickerTriggerFrame.height + 24
        )
    }

    var isModeSettingsPresented: Binding<Bool> {
        Binding(
            get: { configuringModeId != nil },
            set: { if !$0 { configuringModeId = nil } }
        )
    }

    @ViewBuilder
    var modeSettingsSheet: some View {
        if let modeId = configuringModeId,
           let mode = modes.first(where: { $0.id == modeId }) {
            ModeSettingsSheet(
                mode: mode,
                existingModeNames: modes
                    .filter { $0.id != mode.id }
                    .map(\.name),
                checkConflict: { code, modifiers in
                    guard let code,
                          let conflictIndex = modeIndex(
                            matchingHotkeyCode: code,
                            modifiers: modifiers,
                            excluding: mode.id
                          )
                    else { return nil }
                    return modes[conflictIndex]
                },
                onSave: { updated in
                    saveModeSettings(updated)
                    configuringModeId = nil
                },
                onCancel: {
                    configuringModeId = nil
                }
            )
        }
    }
}
