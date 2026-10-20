import SwiftUI

/// ASR 与 LLM 凭证字段行的统一实现。
///
/// 此前 ASRCredentialFieldRow 与 LLMCredentialFieldRow 是逐字相同的两份代码，唯一差异
/// 是 ASR 对 volcano 的 resourceId 字段要替换标签——该差异通过可选 labelOverride 闭包注入。
struct CredentialFieldRow: View, SettingsCardHelpers {
    let field: CredentialField
    @Binding var credentialValues: [String: String]
    let savedValues: [String: String]
    @Binding var editedFields: Set<String>
    let hasCredentials: Bool
    let isEditing: Bool
    let controlWidth: CGFloat
    var labelOverride: ((CredentialField) -> String?)? = nil

    var body: some View {
        settingsInspectorRow(
            labelOverride?(field) ?? field.label,
            labelWidth: ModelSettingsStyle.inspectorLabelWidth,
            rowHeight: ModelSettingsStyle.inspectorRowHeight,
            horizontalPadding: 0
        ) {
            if hasCredentials && !isEditing {
                readOnlyValue
            } else if !field.options.isEmpty {
                dropdownField
            } else if field.isSecure {
                secureField
            } else {
                plainField
            }
        }
    }
}

private extension CredentialFieldRow {
    var inlineBinding: Binding<String> {
        Binding(
            get: { credentialValues[field.key] ?? "" },
            set: {
                credentialValues[field.key] = $0
                editedFields.insert(field.key)
            }
        )
    }

    var pickerBinding: Binding<String> {
        Binding(
            get: {
                let value = credentialValues[field.key] ?? ""
                return value.isEmpty ? (savedValues[field.key] ?? field.defaultValue) : value
            },
            set: {
                credentialValues[field.key] = $0
                editedFields.insert(field.key)
            }
        )
    }

    var readOnlyValue: some View {
        let value = credentialValues[field.key] ?? ""
        let displayValue = field.options.first(where: { $0.value == value })?.label
            ?? (field.isSecure ? maskedSecret(value) : value)

        return settingsInspectorReadOnlyValue(
            displayValue,
            width: controlWidth,
            alignment: .leading
        )
    }

    var dropdownField: some View {
        settingsInspectorInlineDropdown(
            selection: pickerBinding,
            options: field.options.map { ($0.value, $0.label) },
            width: controlWidth,
            height: ModelSettingsStyle.inspectorFieldHeight
        )
    }

    var secureField: some View {
        let savedValue = savedValues[field.key] ?? ""
        let placeholder = savedValue.isEmpty ? field.placeholder : maskedSecret(savedValue)

        return settingsInspectorInlineSecureField(
            text: inlineBinding,
            prompt: placeholder,
            width: controlWidth,
            height: ModelSettingsStyle.inspectorFieldHeight
        )
    }

    var plainField: some View {
        let savedValue = savedValues[field.key] ?? ""
        let placeholder = savedValue.isEmpty ? field.placeholder : savedValue

        return settingsInspectorInlineField(
            text: inlineBinding,
            prompt: placeholder,
            width: controlWidth,
            height: ModelSettingsStyle.inspectorFieldHeight
        )
    }
}
