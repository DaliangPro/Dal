import Foundation

/// 旧轻度 ID 只在此兼容；活动入口始终指向已保存的润色模式。
enum VoiceInputModes {
    static func resolve(_ mode: ProcessingMode, in modes: [ProcessingMode] = []) -> ProcessingMode {
        guard mode.id == ProcessingMode.lightPolishId else { return mode }
        return modes.first { $0.id == ProcessingMode.formalWriting.id } ?? .formalWriting
    }
}
