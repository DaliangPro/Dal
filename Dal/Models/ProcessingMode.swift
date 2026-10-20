import Foundation

enum ProcessingKind: String, Codable, CaseIterable, Sendable {
    case direct
    case smartDirect
    case voicePolish
    case translate
    case promptOptimize
    case command
    case custom
}

// MARK: - Processing Mode
// 2026-07-09 J14：从 AppState.swift 迁出——领域模型不属于 UI 层。
// Prompt 模板见 ProcessingMode+Prompts.swift，LLM 结果清洗见 ProcessingMode+LLMCleanup.swift。

struct ProcessingMode: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var prompt: String
    var kind: ProcessingKind
    var isBuiltin: Bool
    var processingLabel: String
    var hotkeyCode: Int?
    var hotkeyModifiers: UInt64?
    var hotkeyStyle: HotkeyStyle

    enum HotkeyStyle: String, Codable, CaseIterable {
        case hold    // press and hold to record
        case toggle  // press once to start, again to stop
    }

    /// Global default hotkey style, stored in UserDefaults.
    /// All new modes and built-in fallbacks read from here.
    static var defaultHotkeyStyle: HotkeyStyle {
        get {
            guard let raw = UserDefaults.standard.string(forKey: DefaultsKeys.defaultHotkeyStyle),
                  let style = HotkeyStyle(rawValue: raw)
            else { return .toggle }
            return style
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: DefaultsKeys.defaultHotkeyStyle)
        }
    }

    init(
        id: UUID,
        name: String,
        prompt: String,
        kind: ProcessingKind? = nil,
        isBuiltin: Bool,
        processingLabel: String = L("处理中", "Processing"),
        hotkeyCode: Int? = nil,
        hotkeyModifiers: UInt64? = nil,
        hotkeyStyle: HotkeyStyle? = nil
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.kind = Self.kind(forStableID: id) ?? kind ?? .custom
        self.isBuiltin = isBuiltin
        self.processingLabel = processingLabel
        self.hotkeyCode = hotkeyCode
        self.hotkeyModifiers = hotkeyModifiers
        self.hotkeyStyle = hotkeyStyle ?? Self.defaultHotkeyStyle
    }

    static func newCustomMode(id: UUID = UUID(), name: String = L("新模式", "New Mode")) -> ProcessingMode {
        ProcessingMode(
            id: id,
            name: name,
            prompt: "",
            isBuiltin: false
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, name, prompt, kind, isBuiltin, processingLabel
        case hotkeyCode, hotkeyModifiers, hotkeyStyle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        prompt = try container.decode(String.self, forKey: .prompt)
        // 业务类型只由稳定 ID 决定。旧数据没有 kind 时在内存兼容；未知 ID
        // 一律保持 custom，避免用户改名或手改 JSON 获得内置模式语义。
        kind = Self.kind(forStableID: id) ?? .custom
        isBuiltin = try container.decode(Bool.self, forKey: .isBuiltin)
        processingLabel = try container.decodeIfPresent(String.self, forKey: .processingLabel) ?? L("处理中", "Processing")
        hotkeyCode = try container.decodeIfPresent(Int.self, forKey: .hotkeyCode)
        hotkeyModifiers = try container.decodeIfPresent(UInt64.self, forKey: .hotkeyModifiers)
        hotkeyStyle = try container.decodeIfPresent(HotkeyStyle.self, forKey: .hotkeyStyle) ?? Self.defaultHotkeyStyle
    }

    // MARK: - Built-in Mode IDs (stable, never change)
    static let directId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let smartDirectId = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
    static let lightPolishId = UUID(uuidString: "7F3A2D91-106E-4FA6-9122-08CC34D1B9A5")!
    static let translateId = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static var direct: ProcessingMode {
        ProcessingMode(
            id: directId,
            name: L("直出", "Direct"), prompt: "", isBuiltin: true,
            // 默认触发键（2026-07-06 大梁老师）：右 Option 单击开始、再单击结束（toggle）
            hotkeyCode: 61, hotkeyModifiers: 0, hotkeyStyle: .toggle
        )
    }

    static var smartDirect: ProcessingMode {
        ProcessingMode(
            id: smartDirectId,
            name: L("智能模式", "Smart Mode"), prompt: smartDirectPromptTemplate, isBuiltin: false
        )
    }

    /// 产品档位由录音时冻结的模式决定，不读取全局旧质量设置。
    var voicePolishQualityMode: VoicePolishQualityMode? {
        guard kind == .voicePolish else { return nil }
        return .standard
    }
    var isPromptOptimizeMode: Bool {
        kind == .promptOptimize
    }
    var isTranslateMode: Bool {
        kind == .translate
    }

    /// 稳定系统模式不能被设置页删除。它与 `isBuiltin` 分开表达：
    /// 旧版本可能已把 Voice Polish 持久化为非 builtin，但稳定 ID 仍必须受保护。
    var isProtectedSystemMode: Bool {
        id == Self.directId || kind == .voicePolish
    }

    var isUserDeletable: Bool {
        !isProtectedSystemMode
    }

    var requiresLLM: Bool {
        switch kind {
        case .direct:
            return false
        case .smartDirect, .voicePolish, .translate, .promptOptimize, .command:
            return true
        case .custom:
            return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Default Custom Mode IDs (stable, for fresh installs)
    private static let formalWritingId = UUID(uuidString: "7FC0076F-A85E-454B-8789-47A2F15A6E2F")!
    private static let promptOptimizeId = UUID(uuidString: "5D0A24D4-ECE9-4C13-9FC5-F9C81BD6B1C3")!
    private static let defaultTranslateId = UUID(uuidString: "87AF4048-83C3-4306-8AF8-1E52DB7CA2F5")!
    private static let commandModeId = UUID(uuidString: "A3B1D9E7-6F42-4C8A-B5E0-9D3F7A2C1E84")!

    private static func kind(forStableID id: UUID) -> ProcessingKind? {
        switch id {
        case directId:
            return .direct
        case smartDirectId:
            return .smartDirect
        case formalWritingId, lightPolishId:
            return .voicePolish
        case translateId, defaultTranslateId:
            return .translate
        case promptOptimizeId:
            return .promptOptimize
        case commandModeId:
            return .command
        default:
            return nil
        }
    }

    static var formalWriting: ProcessingMode {
        ProcessingMode(
            id: formalWritingId,
            name: L("润色", "Polish"),
            // V2 起，默认规则由 VoicePolishPrompts 版本化维护；这里仅保存用户
            // 的附加润色要求，因此新装默认为空。
            prompt: "",
            isBuiltin: true,
            processingLabel: L("正在润色", "Polishing"),
            hotkeyCode: 18, hotkeyModifiers: 524288, hotkeyStyle: .toggle
        )
    }

    #if DEBUG
    /// 旧配置回归夹具，不属于活动模式。
    static var lightPolish: ProcessingMode {
        ProcessingMode(
            id: lightPolishId,
            name: L("轻度润色", "Light Polish"),
            prompt: "",
            isBuiltin: true,
            processingLabel: L("轻度润色中", "Light polishing"),
            // 保留旧模式的 Option+1/2/3；加载旧配置时由 ModeStorage 检查冲突。
            hotkeyCode: 21, hotkeyModifiers: 524288, hotkeyStyle: .toggle
        )
    }

    #endif

    static var promptOptimize: ProcessingMode {
        ProcessingMode(
            id: promptOptimizeId,
            name: L("提示词优化", "Prompt Optimizer"),
            prompt: promptOptimizePromptTemplate,
            isBuiltin: false,
            processingLabel: L("优化中", "Optimizing"),
            hotkeyCode: 19, hotkeyModifiers: 524288, hotkeyStyle: .toggle
        )
    }

    static var translate: ProcessingMode {
        ProcessingMode(
            id: defaultTranslateId,
            name: L("英文翻译", "Translation"),
            prompt: translatePromptTemplate,
            isBuiltin: false,
            processingLabel: L("翻译中", "Translating"),
            hotkeyCode: 20, hotkeyModifiers: 524288, hotkeyStyle: .toggle
        )
    }

    static var commandMode: ProcessingMode {
        ProcessingMode(
            id: commandModeId,
            name: L("命令模式", "Command Mode"),
            prompt: commandModePromptTemplate,
            isBuiltin: false,
            processingLabel: L("执行中", "Executing"),
            hotkeyStyle: .toggle
        )
    }

    static var builtins: [ProcessingMode] { [.direct, .formalWriting] }
    static var defaults: [ProcessingMode] { [.direct, .formalWriting, .promptOptimize, .translate, .commandMode] }
}
