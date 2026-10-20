import AppKit
import Carbon.HIToolbox

/// 快捷键显示工具：将 keyCode + modifiers 转为可读字符串。
/// 由原 HotkeyRecorderView 的静态方法抽出（交互式录制视图已废弃删除），仅保留仍在使用的展示能力。
enum HotkeyDisplay {

    static let modifierKeyCodes: Set<Int> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

    /// 带 🌐 键的键盘单按 fn 松开时，系统在 fn 的 flagsChanged 之后补发该键码。
    static let globeKeyCode = 179

    /// 修饰键对应的标志位；fn 也计入，供修饰键组合（如 fn+⌃）录制与显示。
    static func modifierFlag(for keyCode: Int) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        case 63: return .function
        default: return nil
        }
    }

    static func keyDisplayName(keyCode: Int, modifiers: UInt64?) -> String {
        var flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers ?? 0))
        // 修饰键组合与按键顺序无关，按固定顺序显示整组，不区分主键。
        if !flags.isEmpty, let ownFlag = modifierFlag(for: keyCode) {
            flags.insert(ownFlag)
            return modifierNames(flags).joined(separator: "+")
        }
        return (modifierNames(flags) + [singleKeyName(keyCode)]).joined(separator: "+")
    }

    private static func modifierNames(_ flags: NSEvent.ModifierFlags) -> [String] {
        var parts: [String] = []
        if flags.contains(.function) { parts.append("fn") }
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        return parts
    }

    static func singleKeyName(_ keyCode: Int) -> String {
        switch keyCode {
        // Modifier keys
        case 54, 55: return "⌘"
        case 56, 60: return "⇧"
        case 58, 61: return "⌥"
        case 59, 62: return "⌃"
        case 63, globeKeyCode: return "fn"

        // Special keys
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Escape"
        case 76: return "Enter"
        case 117: return "Forward Delete"

        // Arrows
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"

        // F-keys
        case 122: return "F1"
        case 120: return "F2"
        case 99:  return "F3"
        case 118: return "F4"
        case 96:  return "F5"
        case 97:  return "F6"
        case 98:  return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"

        default:
            return ucKeyTranslateName(keyCode) ?? "Key \(keyCode)"
        }
    }

    // MARK: - UCKeyTranslate Fallback

    private static func ucKeyTranslateName(_ keyCode: Int) -> String? {
        guard let source = (TISCopyCurrentASCIICapableKeyboardInputSource() ?? TISCopyCurrentKeyboardInputSource())?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = unsafeBitCast(layoutPtr, to: CFData.self)
        let layout = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)

        var deadKeyState: UInt32 = 0
        var length: Int = 0
        var chars = [UniChar](repeating: 0, count: 4)

        let status = UCKeyTranslate(
            layout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
