import SwiftUI

@MainActor
extension SettingsCardHelpers {
    func settingsMiniButton(
        _ title: String,
        variant: SettingsButtonVariant = .secondary,
        action: @escaping () -> Void
    ) -> some View {
        SettingsTextButton(
            title,
            variant: variant,
            action: action
        )
    }

    func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        SettingsTextButton(
            title,
            variant: .secondary,
            action: action
        )
    }

    /// 测试按钮：状态在按钮本体上流转（测试中→✓/✗ 短暂驻留后回弹），
    /// 不再在按钮旁另起徽章（2026-06-11 用户拍板的交互方案）
    func testButton(_ title: String, status: SettingsTestStatus, action: @escaping () -> Void) -> some View {
        SettingsStatusActionButton(
            title: title,
            status: status,
            variant: .secondary,
            reactsTo: [.testing, .success, .failure],
            action: action
        )
    }

    /// 保存按钮：同款状态进按钮（✓ 已保存短暂驻留后回弹）
    func saveButton(_ title: String, status: SettingsTestStatus, action: @escaping () -> Void) -> some View {
        SettingsStatusActionButton(
            title: title,
            status: status,
            variant: .primary,
            reactsTo: [.savedFlash],
            action: action
        )
    }
}

/// 状态进按钮：根据外部状态在按钮本体上呈现进行中/成功/失败，
/// 结果态短暂驻留（1.8s）后自动回弹为原标题；失败详情挂在悬停提示上
struct SettingsStatusActionButton: View {
    enum Reaction: Hashable { case testing, success, failure, savedFlash }

    let title: String
    let status: SettingsTestStatus
    let variant: SettingsButtonVariant
    let reactsTo: Set<Reaction>
    let action: () -> Void

    @State private var flash: SettingsTestStatus?
    @State private var revertTask: Task<Void, Never>?

    var body: some View {
        SettingsButton(variant: variant, fillOverride: displayFill, action: action) {
            // 纯文字 + 隐形占位定宽：状态切换时按钮大小和位置都不变（2026-06-11 用户拍板）
            ZStack {
                ForEach(sizerTitles, id: \.self) { candidate in
                    Text(candidate).hidden()
                }
                Text(displayTitle)
                    .foregroundStyle(displayColor)
            }
        }
        .disabled(displayState == .testing)
        .help(failureMessage ?? "")
        .fixedSize(horizontal: true, vertical: false)
        .onChange(of: status) { _, newStatus in
            handle(newStatus)
        }
    }

    private var displayTitle: String {
        switch displayState {
        case .testing: return L("测试中…", "Testing…")
        case .success: return L("连接正常", "Connected")
        case .saved: return L("已保存", "Saved")
        case .failed: return L("失败", "Failed")
        case .idle: return title
        }
    }

    /// 该按钮可能呈现的全部文案，用于撑出固定宽度
    private var sizerTitles: [String] {
        var titles = [title]
        if reactsTo.contains(.testing) { titles.append(L("测试中…", "Testing…")) }
        if reactsTo.contains(.success) { titles.append(L("连接正常", "Connected")) }
        if reactsTo.contains(.failure) { titles.append(L("失败", "Failed")) }
        if reactsTo.contains(.savedFlash) { titles.append(L("已保存", "Saved")) }
        // 去重，避免 ForEach id 冲突
        return titles.reduce(into: [String]()) { result, candidate in
            if !result.contains(candidate) { result.append(candidate) }
        }
    }

    private var displayState: SettingsTestStatus {
        if let flash { return flash }
        if status == .testing, reactsTo.contains(.testing) { return .testing }
        return .idle
    }

    /// 成功/失败时整个按钮换底色（2026-06-11 用户拍板）：
    /// 深底+亮字，沿用主按钮范式保证文字对比度
    private var displayFill: Color? {
        switch displayState {
        case .success, .saved: return TF.settingsSuccessActionFill
        case .failed: return TF.settingsDangerActionFill
        default: return nil
        }
    }

    private var displayColor: Color {
        switch displayState {
        case .success, .saved: return TF.settingsSuccessActionText
        case .failed: return TF.settingsDangerActionText
        default: return variant == .primary ? TF.settingsPrimaryActionText : TF.settingsTextSecondary
        }
    }

    private var failureMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    private func handle(_ newStatus: SettingsTestStatus) {
        revertTask?.cancel()
        switch newStatus {
        case .success where reactsTo.contains(.success):
            flashThenRevert(.success)
        case .failed where reactsTo.contains(.failure):
            flashThenRevert(newStatus)
        case .saved where reactsTo.contains(.savedFlash):
            flashThenRevert(.saved)
        default:
            flash = nil
        }
    }

    private func flashThenRevert(_ state: SettingsTestStatus) {
        flash = state
        revertTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            flash = nil
        }
    }
}
