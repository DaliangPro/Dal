import AppKit
import SwiftUI

enum ModelSettingsEditor: String, Identifiable {
    case asr
    case standardPolish

    var id: String { rawValue }
}

struct ModelSettingsEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let editor: ModelSettingsEditor
    private let editorWidth: CGFloat = 432

    var body: some View {
        Group {
            switch editor {
            case .asr:
                ASRSettingsCard(onClose: { dismiss() })
            case .standardPolish:
                LLMSettingsCard(role: .standard, onClose: { dismiss() })
            }
        }
        .frame(width: editorWidth, alignment: .topLeading)
        .settingsPopupHost()
        .frame(width: editorWidth, alignment: .topLeading)
        .background(TF.settingsCard)
        .onAppear {
            // 弹窗自动聚焦首个输入框时 AppKit 默认全选其内容，一次误敲即清空。
            // 正解：打开时不聚焦任何输入框——鼠标点进字段光标落在点击处，
            // 永不全选（Tab 切换的全选是系统标准行为，保留）。
            for delay in [0.05, 0.25, 0.6] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    Self.clearInitialFieldFocus()
                }
            }
        }
    }

    private static func clearInitialFieldFocus() {
        for window in NSApp.windows where window.isKeyWindow || window.isSheet {
            if window.firstResponder is NSTextView {
                window.makeFirstResponder(nil)
            }
        }
    }
}
