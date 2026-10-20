import SwiftUI

struct ASRCredentialRows: View, SettingsCardHelpers {
    let selectedProvider: ASRProvider
    let fields: [CredentialField]
    @Binding var credentialValues: [String: String]
    let savedValues: [String: String]
    @Binding var editedFields: Set<String>
    let hasCredentials: Bool
    let isEditing: Bool
    let isZeroCredentialProvider: Bool
    let controlWidth: CGFloat

    var body: some View {
        if selectedProvider.isLocal {
            localProviderRow
        } else if isZeroCredentialProvider {
            zeroCredentialRow
        } else {
            credentialFieldRows
        }
    }
}

private extension ASRCredentialRows {
    var localProviderRow: some View {
        readOnlyRow(
            label: L("运行方式", "Mode"),
            value: L("本地模型由下方卡片统一管理", "Managed in the local models card below")
        )
    }

    var zeroCredentialRow: some View {
        readOnlyRow(
            label: L("接入方式", "Access"),
            value: L("无需 API 凭证", "No credentials required")
        )
    }

    var credentialFieldRows: some View {
        ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
            VStack(spacing: 0) {
                settingsInspectorDivider()
                CredentialFieldRow(
                    field: field,
                    credentialValues: $credentialValues,
                    savedValues: savedValues,
                    editedFields: $editedFields,
                    hasCredentials: hasCredentials,
                    isEditing: isEditing,
                    controlWidth: controlWidth,
                    labelOverride: { field in
                        selectedProvider == .volcano && field.key == "resourceId"
                            ? L("模型", "Model") : nil
                    }
                )
            }
            .zIndex(Double(fields.count - index))
        }
    }

    func readOnlyRow(label: String, value: String) -> some View {
        VStack(spacing: 0) {
            settingsInspectorDivider()
            settingsInspectorRow(
                label,
                labelWidth: ModelSettingsStyle.inspectorLabelWidth,
                rowHeight: ModelSettingsStyle.inspectorRowHeight,
                horizontalPadding: 0
            ) {
                settingsInspectorReadOnlyValue(
                    value,
                    width: controlWidth
                )
            }
        }
    }
}
