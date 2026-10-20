import Foundation

/// 启动参数调试开关（REPAIR_PLAN D7）：仅 debug 构建生效，
/// release 构建中全部恒为 false，调试入口不随正式版分发
enum AppLaunchDebug {
    #if DEBUG
    static let hudDemoEnabled = ProcessInfo.processInfo.arguments.contains("--hud-debug-demo")
    static let hudDemoDarkBackground = ProcessInfo.processInfo.arguments.contains("--hud-debug-dark")
    static let hudDemoStaticBackground = ProcessInfo.processInfo.arguments.contains("--hud-debug-static")
    static let hudDemoFrozenRecording = ProcessInfo.processInfo.arguments.contains("--hud-debug-recording")
    static let hudDemoSpacingCompare = ProcessInfo.processInfo.arguments.contains("--hud-debug-spacing-compare")
    static let floatingHUDDemoEnabled = ProcessInfo.processInfo.arguments.contains("--floating-hud-debug")
    static let floatingHUDProcessingPhase = ProcessInfo.processInfo.arguments.contains("--floating-hud-processing")
    static let floatingHUDDonePhase = ProcessInfo.processInfo.arguments.contains("--floating-hud-done")
    static let settingsGeneralRefinePreviewEnabled = ProcessInfo.processInfo.arguments.contains("--settings-general-refine-preview")
    static let settingsLanguageSidebarPreviewEnabled = ProcessInfo.processInfo.arguments.contains("--settings-language-sidebar-preview")
    static let settingsModesPreviewEnabled = ProcessInfo.processInfo.arguments.contains("--settings-modes-preview")
    static let settingsPreviewEnabled =
        settingsGeneralRefinePreviewEnabled
            || settingsLanguageSidebarPreviewEnabled
            || settingsModesPreviewEnabled
    #else
    static let hudDemoEnabled = false
    static let hudDemoDarkBackground = false
    static let hudDemoStaticBackground = false
    static let hudDemoFrozenRecording = false
    static let hudDemoSpacingCompare = false
    static let floatingHUDDemoEnabled = false
    static let floatingHUDProcessingPhase = false
    static let floatingHUDDonePhase = false
    static let settingsGeneralRefinePreviewEnabled = false
    static let settingsLanguageSidebarPreviewEnabled = false
    static let settingsModesPreviewEnabled = false
    static let settingsPreviewEnabled = false
    #endif
}
