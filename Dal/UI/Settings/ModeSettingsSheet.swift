import AppKit
import SwiftUI

struct ModeSettingsSheet: View, SettingsCardHelpers {
    let mode: ProcessingMode
    let existingModeNames: [String]
    let checkConflict: (Int?, UInt64?) -> ProcessingMode?
    let onSave: (ProcessingMode) -> Void
    let onCancel: () -> Void

    @State private var modeName: String
    @State private var processingLabel: String
    @State private var hotkeyCode: Int?
    @State private var hotkeyModifiers: UInt64?
    @State private var hotkeyStyle: ProcessingMode.HotkeyStyle
    @State private var isListening = false
    @State private var isShortcutTileHovered = false
    @State private var eventMonitor: Any?
    @State private var captureTap = ModeHotkeyCaptureTap()
    @State private var pendingModifierCode: Int?
    @State private var pendingModifierModifiers: UInt64 = 0
    @State private var pendingGlobeFallback: DispatchWorkItem?
    @State private var contextRaw = VoicePolishSettings.contextLevel().rawValue
    @State private var recentInput = VoicePolishSettings.recentInputContextEnabled()

    init(
        mode: ProcessingMode,
        existingModeNames: [String],
        checkConflict: @escaping (Int?, UInt64?) -> ProcessingMode?,
        onSave: @escaping (ProcessingMode) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.mode = mode
        self.existingModeNames = existingModeNames
        self.checkConflict = checkConflict
        self.onSave = onSave
        self.onCancel = onCancel
        _modeName = State(initialValue: mode.name)
        _processingLabel = State(initialValue: mode.processingLabel)
        _hotkeyCode = State(initialValue: mode.hotkeyCode)
        _hotkeyModifiers = State(initialValue: mode.hotkeyModifiers)
        _hotkeyStyle = State(initialValue: mode.hotkeyStyle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if mode.isUserDeletable {
                fieldsSection
            } else {
                Text(mode.name)
                    .font(TF.settingsFontBodyStrong)
                    .foregroundStyle(TF.settingsText)
                if mode.kind == .voicePolish {
                    compactFieldRow(
                        title: L("润色文案", "Status"),
                        text: $processingLabel,
                        prompt: L("正在润色", "Polishing")
                    )
                }
            }
            shortcutSection
            triggerSection
            if (mode.kind == .direct) || mode.kind == .voicePolish {
                DisclosureGroup(L("上下文与隐私", "Context & privacy")) {
                    OutputContextSettings(context: $contextRaw, recentInput: $recentInput)
                        .padding(.top, 8)
                }
                .font(TF.settingsFontCaption)
            }

            if let conflict {
                conflictWarning(conflict)
            }

            footer
        }
        .padding(ModeSettingsSheetLayout.padding)
        .frame(width: ModeSettingsSheetLayout.width)
        .background(TF.settingsCanvas)
        .onAppear {
            clearInitialFocus()
        }
        .onDisappear {
            stopListening()
        }
    }
}

private enum ModeSettingsSheetLayout {
    static let width: CGFloat = 252
    static let padding: CGFloat = 12
    static let labelWidth: CGFloat = 58
    static let fieldWidth: CGFloat = 158
    static let fieldHeight: CGFloat = 28
    static let shortcutTileHeight: CGFloat = 74
    static let tileCornerRadius: CGFloat = 8
}

private extension ModeSettingsSheet {
    var sanitizedModeName: String {
        ModeNameEditing.uniqueName(
            base: ModeNameEditing.sanitizedName(modeName, fallback: mode.name),
            existingNames: existingModeNames
        )
    }

    var sanitizedProcessingLabel: String {
        ModeNameEditing.sanitizedName(
            processingLabel,
            fallback: mode.processingLabel.isEmpty ? L("处理中", "Processing") : mode.processingLabel
        )
    }

    var hotkeyTitle: String {
        guard let hotkeyCode else {
            return L("未设置", "Not set")
        }
        return HotkeyDisplay.keyDisplayName(keyCode: hotkeyCode, modifiers: hotkeyModifiers)
    }

    var conflict: ProcessingMode? {
        guard hotkeyCode != nil else { return nil }
        return checkConflict(hotkeyCode, hotkeyModifiers)
    }

    var fieldsSection: some View {
        VStack(spacing: 8) {
            compactFieldRow(
                title: L("模式名称", "Name"),
                text: $modeName,
                prompt: L("模式名称", "Mode name")
            )

            compactFieldRow(
                title: L("提示名称", "Status"),
                text: $processingLabel,
                prompt: L("处理中", "Processing")
            )
        }
    }

    var shortcutSection: some View {
        Button(action: handleShortcutTileTap) {
            shortcutTile
        }
        .buttonStyle(.plain)
        .onHover { isShortcutTileHovered = $0 }
        .accessibilityLabel(L("快捷键", "Shortcut") + " \(hotkeyTitle)")
    }

    var triggerSection: some View {
        SettingsSwitchGroup(width: nil) {
            SettingsSwitchOption(
                title: L("按住时录音", "Hold to record"),
                isSelected: hotkeyStyle == .hold
            ) {
                hotkeyStyle = .hold
            }

            SettingsSwitchOption(
                title: L("按一下启停", "Press once"),
                isSelected: hotkeyStyle == .toggle
            ) {
                hotkeyStyle = .toggle
            }
        }
    }

    func conflictWarning(_ conflict: ProcessingMode) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsAccentAmber)
            Text(L("「\(conflict.name)」正在使用此快捷键，保存后将移除其绑定",
                   "\"\(conflict.name)\" is using this shortcut. Saving will unbind it."))
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var footer: some View {
        HStack(spacing: 8) {
            Spacer()

            SettingsTextButton(L("取消", "Cancel"), variant: .secondary, width: 64, onCanvas: true) {
                stopListening()
                onCancel()
            }

            SettingsTextButton(L("保存", "Save"), variant: .primary, width: 64) {
                stopListening()
                var updated = mode
                if mode.isUserDeletable {
                    updated.name = sanitizedModeName
                }
                if mode.isUserDeletable || mode.kind == .voicePolish {
                    updated.processingLabel = sanitizedProcessingLabel
                }
                updated.hotkeyCode = hotkeyCode
                updated.hotkeyModifiers = hotkeyModifiers
                updated.hotkeyStyle = hotkeyStyle
                if (mode.kind == .direct) || mode.kind == .voicePolish {
                    VoicePolishSettings.setContextLevel(WritingContextLevel(rawValue: contextRaw) ?? .nearbyText)
                    VoicePolishSettings.setRecentInputContextEnabled(recentInput)
                }
                onSave(updated)
            }
        }
    }

    func compactFieldRow(title: String, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(TF.settingsFontBody)
                .foregroundStyle(TF.settingsText)
                .lineLimit(1)
                .frame(width: ModeSettingsSheetLayout.labelWidth, alignment: .leading)

            settingsInspectorInlineField(
                text: text,
                prompt: prompt,
                width: ModeSettingsSheetLayout.fieldWidth,
                height: ModeSettingsSheetLayout.fieldHeight
            )
            .accessibilityLabel(title)
        }
        .frame(height: ModeSettingsSheetLayout.fieldHeight)
    }

    var shortcutTile: some View {
        ZStack {
            if isListening {
                HStack(spacing: 6) {
                    Circle()
                        .fill(TF.settingsAccentGreen)
                        .frame(width: 7, height: 7)
                    Text(L("录制中", "Recording"))
                        .font(TF.settingsFontBody)
                        .foregroundStyle(TF.settingsText)
                }
            } else {
                Text(hotkeyTitle)
                    .font(shortcutTileTitleFont)
                    .foregroundStyle(shortcutTileTitleColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .allowsTightening(true)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: ModeSettingsSheetLayout.shortcutTileHeight)
        .overlay(alignment: .topLeading) {
            if !isListening {
                Text(L("快捷键", "Shortcut"))
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .padding(.leading, 9)
                    .padding(.top, 7)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: ModeSettingsSheetLayout.tileCornerRadius, style: .continuous)
                .fill(shortcutTileFill)
                .overlay {
                    RoundedRectangle(cornerRadius: ModeSettingsSheetLayout.tileCornerRadius, style: .continuous)
                        .stroke(shortcutTileStroke, lineWidth: 1)
                }
        }
        .contentShape(RoundedRectangle(cornerRadius: ModeSettingsSheetLayout.tileCornerRadius, style: .continuous))
    }

    var shortcutTileTitleFont: Font {
        if hotkeyCode == nil {
            return TF.settingsFontBodyLarge
        }
        return Font.system(size: 23, weight: .medium, design: .rounded)
    }

    var shortcutTileTitleColor: Color {
        return hotkeyCode == nil ? TF.settingsTextTertiary : TF.settingsText
    }

    var shortcutTileFill: Color {
        if isListening {
            return TF.settingsAccentGreen.opacity(0.14)
        }
        return isShortcutTileHovered ? TF.settingsSelectionFill.opacity(0.72) : TF.settingsCardAlt
    }

    var shortcutTileStroke: Color {
        if isListening {
            return TF.settingsAccentGreen.opacity(0.5)
        }
        return isShortcutTileHovered ? TF.settingsAccentBlue.opacity(0.26) : TF.settingsStroke
    }

    func handleShortcutTileTap() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }

    func clearInitialFocus() {
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }

    func startListening() {
        stopListening()
        hotkeyCode = nil
        hotkeyModifiers = nil
        isListening = true
        clearInitialFocus()
        NotificationCenter.default.post(name: .hotkeyRecordingDidStart, object: nil)

        _ = captureTap.start(
            onCapture: { code, modifiers in
                DispatchQueue.main.async {
                    hotkeyCode = code
                    hotkeyModifiers = modifiers
                    stopListening()
                }
            },
            onCancel: {
                DispatchQueue.main.async {
                    stopListening()
                }
            }
        )

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            if event.type == .flagsChanged {
                let keyCode = Int(event.keyCode)
                guard HotkeyDisplay.modifierKeyCodes.contains(keyCode) else { return event }
                let pressed = isModifierPressed(keyCode: keyCode, flags: event.modifierFlags)

                if pressed {
                    pendingModifierCode = keyCode
                    pendingModifierModifiers = modifierComboModifiers(for: keyCode, flags: event.modifierFlags)
                } else if let pendingModifierCode {
                    let modifiers = pendingModifierModifiers
                    self.pendingModifierCode = nil
                    pendingModifierModifiers = 0
                    if pendingModifierCode == 63, modifiers == 0 {
                        // 单按 fn：🌐 键盘紧接着补发 179，由 keyDown 或事件 tap 收下；
                        // 没有 🌐 键的键盘等不到 179，短暂等待后按 fn 本身记录。
                        pendingGlobeFallback = DispatchWorkItem {
                            hotkeyCode = 63
                            hotkeyModifiers = 0
                            stopListening()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: pendingGlobeFallback!)
                    } else {
                        hotkeyCode = pendingModifierCode
                        hotkeyModifiers = modifiers
                        stopListening()
                    }
                }
                return event
            }

            if event.type == .keyDown {
                let keyCode = Int(event.keyCode)
                pendingModifierCode = nil

                if keyCode == 53 &&
                    event.modifierFlags
                        .intersection(.deviceIndependentFlagsMask)
                        .subtracting([.capsLock, .numericPad, .function])
                        .isEmpty {
                    stopListening()
                    return nil
                }

                hotkeyCode = keyCode
                let clean = sanitizedModifierFlags(event.modifierFlags)
                hotkeyModifiers = clean.isEmpty ? 0 : UInt64(clean.rawValue)
                stopListening()
                return nil
            }

            return event
        }
    }

    func stopListening() {
        pendingModifierCode = nil
        pendingModifierModifiers = 0
        pendingGlobeFallback?.cancel()
        pendingGlobeFallback = nil
        captureTap.stop()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if isListening {
            isListening = false
            NotificationCenter.default.post(name: .hotkeyRecordingDidEnd, object: nil)
        }
    }

    func sanitizedModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .shift, .option, .control])
    }

    /// 修饰键组合（如 fn+⌃）：除本键外按住的修饰键，fn 也计入。
    func modifierComboModifiers(for keyCode: Int, flags: NSEvent.ModifierFlags) -> UInt64 {
        var clean = flags.intersection([.command, .shift, .option, .control, .function])
        if let ownFlag = HotkeyDisplay.modifierFlag(for: keyCode) {
            clean.remove(ownFlag)
        }
        return UInt64(clean.rawValue)
    }

    func isModifierPressed(keyCode: Int, flags: NSEvent.ModifierFlags) -> Bool {
        guard let modifierFlag = HotkeyDisplay.modifierFlag(for: keyCode) else { return false }
        return flags.contains(modifierFlag)
    }
}

private final class ModeHotkeyCaptureTap {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onCapture: ((Int, UInt64?) -> Void)?
    private var onCancel: (() -> Void)?
    private var pendingModifierCode: Int?
    private var pendingModifierModifiers: UInt64 = 0
    private var pendingGlobeFallback: DispatchWorkItem?

    func start(
        onCapture: @escaping (Int, UInt64?) -> Void,
        onCancel: @escaping () -> Void
    ) -> Bool {
        stop()
        self.onCapture = onCapture
        self.onCancel = onCancel

        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: modeHotkeyCaptureTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        pendingModifierCode = nil
        pendingModifierModifiers = 0
        pendingGlobeFallback?.cancel()
        pendingGlobeFallback = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        onCapture = nil
        onCancel = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .flagsChanged:
            handleFlagsChanged(event)
            return Unmanaged.passUnretained(event)
        case .keyDown:
            return handleKeyDown(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard HotkeyDisplay.modifierKeyCodes.contains(keyCode) else { return }

        if Self.isModifierPressed(keyCode: keyCode, flags: event.flags) {
            pendingModifierCode = keyCode
            pendingModifierModifiers = Self.modifierComboModifiers(for: keyCode, flags: event.flags)
        } else if let pendingModifierCode {
            let modifiers = pendingModifierModifiers
            self.pendingModifierCode = nil
            pendingModifierModifiers = 0
            if pendingModifierCode == 63, modifiers == 0 {
                // 单按 fn：等 🌐 键盘补发的 179（见 handleKeyDown），等不到再记 fn 本身。
                let fallback = DispatchWorkItem { [weak self] in
                    self?.onCapture?(63, 0)
                }
                pendingGlobeFallback = fallback
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: fallback)
            } else {
                onCapture?(pendingModifierCode, modifiers)
            }
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        pendingModifierCode = nil
        pendingGlobeFallback?.cancel()
        pendingGlobeFallback = nil

        let clean = Self.sanitizedModifierFlags(event.flags)
        if keyCode == 53, clean.isEmpty {
            onCancel?()
            return nil
        }

        onCapture?(keyCode, clean.isEmpty ? 0 : UInt64(clean.rawValue))
        return nil
    }

    private static func sanitizedModifierFlags(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
    }

    private static func modifierEventFlag(for keyCode: Int) -> CGEventFlags? {
        switch keyCode {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 63: return .maskSecondaryFn
        default: return nil
        }
    }

    /// 修饰键组合（如 fn+⌃）：除本键外按住的修饰键，fn 也计入。
    private static func modifierComboModifiers(for keyCode: Int, flags: CGEventFlags) -> UInt64 {
        var clean = flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn])
        if let ownFlag = modifierEventFlag(for: keyCode) {
            clean.remove(ownFlag)
        }
        return UInt64(clean.rawValue)
    }

    private static func isModifierPressed(keyCode: Int, flags: CGEventFlags) -> Bool {
        guard let modifierFlag = modifierEventFlag(for: keyCode) else { return false }
        return flags.contains(modifierFlag)
    }
}

private func modeHotkeyCaptureTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let monitor = Unmanaged<ModeHotkeyCaptureTap>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}
