import SwiftUI

struct LLMCredentialRows: View, SettingsCardHelpers {
    let selectedProvider: LLMProvider
    let fields: [CredentialField]
    @Binding var credentialValues: [String: String]
    let savedValues: [String: String]
    @Binding var editedFields: Set<String>
    let hasCredentials: Bool
    let isEditing: Bool
    let localModelDisplayName: String
    let localStatusText: String
    let localStatusColor: Color
    let controlWidth: CGFloat

    var body: some View {
        if selectedProvider == .localQwen {
            localProviderRows
        } else {
            credentialFieldRows
        }
    }
}

private extension LLMCredentialRows {
    var localProviderRows: some View {
        VStack(spacing: 0) {
            localModelRow
            localStatusRow
        }
    }

    var localModelRow: some View {
        readOnlyRow(
            label: L("本地模型", "Local Model"),
            value: localModelDisplayName
        )
    }

    var localStatusRow: some View {
        VStack(spacing: 0) {
            settingsInspectorDivider()
            settingsInspectorRow(
                L("运行状态", "Status"),
                labelWidth: ModelSettingsStyle.inspectorLabelWidth,
                rowHeight: ModelSettingsStyle.inspectorRowHeight,
                horizontalPadding: 0
            ) {
                settingsHeaderStatus(title: localStatusText, color: localStatusColor)
            }
        }
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
                    controlWidth: controlWidth
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
                    width: controlWidth,
                    alignment: .trailing
                )
            }
        }
    }
}
