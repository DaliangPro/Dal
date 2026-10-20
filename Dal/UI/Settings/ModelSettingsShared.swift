import SwiftUI

enum ModelSettingsStyle {
    static let outerCardCornerRadius: CGFloat = TF.settingsPrimaryCardCornerRadius
    static let inspectorLabelWidth: CGFloat = 84
    static let inspectorControlWidth: CGFloat = 240
    static let inspectorRowHeight: CGFloat = 34
    static let inspectorFieldHeight: CGFloat = 28
    static let inspectorRowSpacing: CGFloat = 4
    static let cardSpacing: CGFloat = TF.settingsCardSpacing
    static let headerBottomSpacing: CGFloat = 10
    static let footerTopSpacing: CGFloat = 12
    static let cardFillColor: Color = TF.settingsCardAlt
    static let summaryCardMinHeight: CGFloat = 92
    static let summaryCardMinWidth: CGFloat = 188
    static let resourceStripMinHeight: CGFloat = 72
    static let localInventoryRowHeight: CGFloat = 44
}

@MainActor
enum ModelConnectivityCache {
    static var asr: (provider: ASRProvider, status: SettingsTestStatus)?
    static var polish: [PolishModelRole: LLMConnectivityCacheEntry] = [:]
    static var llm: LLMConnectivityCacheEntry?
    static var asset: LLMConnectivityCacheEntry?
}

struct LLMConnectivityCacheEntry {
    let signature: LLMConnectivitySignature
    let status: SettingsTestStatus
    let validationGeneration: UInt64

    init(
        signature: LLMConnectivitySignature,
        status: SettingsTestStatus
    ) {
        self.signature = signature
        self.status = status
        if status == .success {
            LLMThinkingRuntimeState.markValidated(signature)
        }
        self.validationGeneration = LLMThinkingRuntimeState.validationGeneration(
            for: signature
        )
    }

    var isCurrent: Bool {
        validationGeneration == LLMThinkingRuntimeState.validationGeneration(
            for: signature
        )
    }
}

struct LLMThinkingModePicker: View {
    @Binding var mode: LLMThinkingMode
    let width: CGFloat
    var isLocked = false

    var body: some View {
        SettingsSwitchGroup(
            width: width,
            height: ModelSettingsStyle.inspectorFieldHeight
        ) {
            ForEach(LLMThinkingMode.allCases, id: \.self) { candidate in
                SettingsSwitchOption(
                    title: candidate.displayName,
                    isSelected: mode == candidate
                ) {
                    mode = candidate
                }
            }
        }
        .disabled(isLocked)
        .opacity(isLocked ? 0.65 : 1)
    }
}

struct LLMThinkingFeedbackText: View {
    let message: String
    let isFailure: Bool

    var body: some View {
        Text(message)
            .font(TF.settingsFontMetadata)
            .foregroundStyle(isFailure ? TF.settingsAccentRed : TF.settingsAccentAmber)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
