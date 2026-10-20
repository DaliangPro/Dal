import SwiftUI

struct HUDStylePicker: View {
    @AppStorage(DefaultsKeys.hudStyle) private var savedStyle = HUDStyle.appleNative.rawValue
    @Environment(\.dismiss) private var dismiss
    @State private var preview = DemoState()

    private var selectedStyle: HUDStyle { HUDStyle.resolved(savedStyle) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(L("HUD 样式", "HUD Style"))
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(L("完成", "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            HStack(spacing: 12) {
                ForEach(HUDStyle.allCases) { style in
                    Button {
                        savedStyle = style.rawValue
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(style.title).font(.system(size: 14, weight: .semibold))
                                Text(style.subtitle).font(.system(size: 12))
                                    .foregroundStyle(TF.settingsTextSecondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: selectedStyle == style ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedStyle == style ? TF.amber : TF.settingsTextSecondary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(selectedStyle == style ? TF.amber.opacity(0.08) : TF.settingsCard))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(selectedStyle == style ? TF.amber : TF.settingsTextSecondary.opacity(0.2), lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(style.title)
                    .accessibilityValue(selectedStyle == style ? L("已选择", "Selected") : L("未选择", "Not selected"))
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(red: 0.24, green: 0.29, blue: 0.34))
                FloatingBarView(state: preview, styleOverride: selectedStyle)
                    .padding(.bottom, 16)
            }
            .frame(height: 112)
            .clipped()
            .accessibilityLabel(L("HUD 样式预览", "HUD style preview"))

            HStack {
                Text(L("切换即生效，自动保存", "Applied immediately and saved automatically"))
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextSecondary)
                Spacer()
                Button(L("播放动画", "Play animation")) { preview.playQuickModeDemoOnce() }
            }
        }
        .padding(24)
        .frame(width: 584)
        .foregroundStyle(TF.settingsText)
        .background(TF.settingsCanvas)
        .background(WindowActivityObserver { active in
            if active {
                preview.showFrozenRecordingPreview(text: L("把此刻的想法，清晰留下来", "Keep this thought, clearly"))
            } else {
                preview.stop()
            }
        })
        .onDisappear { preview.stop() }
    }
}
