import SwiftUI

struct ASRProviderSelectionRow: View, SettingsCardHelpers {
    let selectedProvider: ASRProvider
    @Binding var selection: String
    let options: [(value: String, label: String)]
    let isZeroCredentialProvider: Bool
    let isEditing: Bool
    let controlWidth: CGFloat

    var body: some View {
        settingsInspectorRow(
            L("服务商", "Provider"),
            labelWidth: ModelSettingsStyle.inspectorLabelWidth,
            rowHeight: ModelSettingsStyle.inspectorRowHeight,
            horizontalPadding: 0
        ) {
            if selectedProvider.isLocal || isZeroCredentialProvider || isEditing {
                settingsInspectorInlineDropdown(
                    selection: $selection,
                    options: options,
                    width: controlWidth,
                    height: ModelSettingsStyle.inspectorFieldHeight
                )
            } else {
                settingsInspectorReadOnlyValue(
                    selectedProvider.displayName,
                    width: controlWidth,
                    alignment: .trailing
                )
            }
        }
    }
}
