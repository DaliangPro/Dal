import Carbon.HIToolbox
import Cocoa

typealias HotkeyStyle = ProcessingMode.HotkeyStyle

struct ModeBinding {
    let modeId: UUID
    let keyCode: CGKeyCode
    let modifiers: CGEventFlags  // .maskCommand etc. Use [] for no modifiers
    let style: HotkeyStyle
    let onStart: @Sendable () -> Void
    let onStop: @Sendable () -> Void
}

final class HotkeyManager: NSObject {

    // MARK: - Configuration

    private var bindings: [ModeBinding] = []
    private var holdState: [UUID: Bool] = [:]
    private var toggleState: [UUID: Bool] = [:]
    private var wasModifierDown: [UUID: Bool] = [:]
    private var holdSafetyTimers: [UUID: Timer] = [:]
    /// Which toggle mode is currently active (recording). Only one can be active at a time.
    private var activeToggleModeId: UUID?

    /// Maximum hold duration before auto-stop (seconds).
    private let maxHoldDuration: TimeInterval = 120

    // MARK: - State

    /// When true, all hotkey events pass through unhandled (used during hotkey recording).
    var isSuppressed = false

    /// When true, ESC key aborts active recording.
    var isESCAbortEnabled = true

    /// When true, LLM post-processing is in progress (ESC can also abort this).
    var isProcessing = false {
        didSet {
            updateCarbonESCAbortHotkeyRegistration()
        }
    }

    /// True while the no-focused-input copy card is visible. ESC dismisses it.
    var isCopyFallbackVisible = false {
        didSet {
            updateCarbonESCAbortHotkeyRegistration()
        }
    }

    /// True while RecognitionSession may still be active. This keeps ESC available
    /// even if toggle/hold state gets out of sync with the session lifecycle.
    var isSessionActive = false {
        didSet {
            updateCarbonESCAbortHotkeyRegistration()
        }
    }

    /// Reset all active recording/hold state. Called when session ends (completed/error/finalized)
    /// to ensure hotkeys and ESC don't remain stuck.
    func resetActiveState() {
        activeToggleModeId = nil
        for key in toggleState.keys { toggleState[key] = false }
        for key in holdState.keys { holdState[key] = false }
        isSessionActive = false
        updateCarbonESCAbortHotkeyRegistration()
    }

    /// Called when recording is stopped by a different mode's hotkey.
    /// The UUID is the new mode's ID that should be used for processing.
    var onCrossModeStop: ((UUID) -> Void)?

    /// Called when ESC is pressed during active recording or processing (abort).
    var onESCAbort: (() -> Void)?

    /// Called when ESC is pressed while the copy fallback card is visible.
    var onESCDismissCopyFallback: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthCheckTimer: Timer?
    private var carbonEventHandler: EventHandlerRef?
    private var carbonHotkeyRefs: [EventHotKeyRef] = []
    private var carbonBindingsById: [UInt32: ModeBinding] = [:]
    private var carbonESCAbortHotkeyRef: EventHotKeyRef?
    private let carbonESCAbortHotkeyId: UInt32 = 0x455343 // ESC
    private var carbonHandledModeIds: Set<UUID> = []
    private var lastESCAbortAt: Date?
    private var escLocalMonitor: Any?
    private var escGlobalMonitor: Any?
    /// Timestamp of the last event received by the tap callback.
    fileprivate var lastEventTime: Date?

    // MARK: - Registration

    func registerBindings(_ newBindings: [ModeBinding]) {
        let shouldRestartCarbon = carbonEventHandler != nil
            || !carbonHotkeyRefs.isEmpty
            || carbonESCAbortHotkeyRef != nil

        if shouldRestartCarbon {
            stopCarbonHotkeys()
        }

        bindings = newBindings.map(Self.runtimeBinding)
        holdState = [:]
        toggleState = [:]
        wasModifierDown = [:]
        holdSafetyTimers.values.forEach { $0.invalidate() }
        holdSafetyTimers = [:]

        if shouldRestartCarbon {
            let restarted = startCarbonHotkeys()
            DebugFileLogger.log("hotkey carbon reconfigured bindings=\(newBindings.count) \(restarted ? "OK" : "FAILED")")
        }
    }

    // MARK: - Start / Stop

    @discardableResult
    func start() -> Bool {
        if eventTap != nil || runLoopSource != nil {
            stop()
        }
        stopCarbonHotkeys()
        let carbonStarted = startCarbonHotkeys()
        startESCEventMonitors()

        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: userInfo
        ) else {
            DebugFileLogger.log("hotkey carbon fallback \(carbonStarted ? "OK" : "FAILED")")
            return carbonStarted
        }

        eventTap = tap
        lastEventTime = nil

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        startHealthCheck()
        if carbonStarted {
            DebugFileLogger.log("hotkey carbon parallel OK")
        }
        return true
    }

    func stop() {
        stop(resetBusinessState: true)
    }

    /// 只拆除事件 tap 与 Carbon 注册，不改变录音业务状态。
    /// 健康检查重建 tap 时必须走这条路径，否则活动 hold/toggle 会在
    /// 松键前被清空，后续 keyUp 无法触发 onStop。
    private func stop(resetBusinessState: Bool) {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        stopESCEventMonitors()
        stopCarbonHotkeys()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        lastEventTime = nil
        guard resetBusinessState else { return }
        isSessionActive = false
        holdState = [:]
        toggleState = [:]
        wasModifierDown = [:]
        holdSafetyTimers.values.forEach { $0.invalidate() }
        holdSafetyTimers = [:]
    }

    // MARK: - Carbon fallback

    private func startCarbonHotkeys() -> Bool {
        carbonBindingsById = [:]
        carbonHotkeyRefs = []

        let supportedBindings = bindings.filter { !isModifierKeyCode($0.keyCode) }
        guard !supportedBindings.isEmpty else { return false }

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotkeyCallback,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &carbonEventHandler
        )
        guard installStatus == noErr else {
            carbonEventHandler = nil
            return false
        }

        var nextId: UInt32 = 1

        for binding in supportedBindings {
            var hotkeyRef: EventHotKeyRef?
            let hotkeyId = EventHotKeyID(signature: 0x4D555345, id: nextId) // DAL
            let registerStatus = RegisterEventHotKey(
                UInt32(binding.keyCode),
                carbonModifiers(from: binding.modifiers),
                hotkeyId,
                GetApplicationEventTarget(),
                0,
                &hotkeyRef
            )
            if registerStatus == noErr, let hotkeyRef {
                carbonHotkeyRefs.append(hotkeyRef)
                carbonBindingsById[nextId] = binding
                carbonHandledModeIds.insert(binding.modeId)
                nextId += 1
            }
        }

        if carbonHotkeyRefs.isEmpty {
            stopCarbonHotkeys()
            return false
        }

        updateCarbonESCAbortHotkeyRegistration()
        DebugFileLogger.log("hotkey carbon registered bindings=\(carbonHotkeyRefs.count)")
        return true
    }

    private func stopCarbonHotkeys() {
        unregisterCarbonESCAbortHotkey()
        carbonHotkeyRefs.forEach { UnregisterEventHotKey($0) }
        carbonHotkeyRefs = []
        carbonBindingsById = [:]
        carbonHandledModeIds = []
        if let carbonEventHandler {
            RemoveEventHandler(carbonEventHandler)
            self.carbonEventHandler = nil
        }
    }

    fileprivate func handleCarbonHotkey(id: UInt32, eventKind: UInt32) -> OSStatus {
        lastEventTime = Date()
        guard !isSuppressed else { return noErr }

        if id == carbonESCAbortHotkeyId {
            if eventKind == UInt32(kEventHotKeyPressed) {
                handleESCAction(source: "carbon-esc")
            }
            return noErr
        }

        guard let binding = carbonBindingsById[id] else { return noErr }

        switch eventKind {
        case UInt32(kEventHotKeyPressed):
            DebugFileLogger.log("hotkey carbon pressed modeId=\(binding.modeId.uuidString)")
            handleCarbonHotkeyPressed(binding)
        case UInt32(kEventHotKeyReleased):
            if binding.style == .hold {
                handleBindingEvent(binding: binding, pressed: false)
            }
        default:
            break
        }

        return noErr
    }

    private func handleCarbonHotkeyPressed(_ binding: ModeBinding) {
        switch binding.style {
        case .hold:
            handleBindingEvent(binding: binding, pressed: true)
        case .toggle:
            handleTogglePress(binding)
        }
    }

    /// 切换式快捷键按下：录音中按另一模式的键为跨模式停止，否则开关本模式。
    /// Carbon、事件 tap 与修饰键三条输入路径共用此逻辑。
    private func handleTogglePress(_ binding: ModeBinding) {
        let id = binding.modeId
        if let activeId = activeToggleModeId, activeId != id {
            // Cross-mode stop: different mode's key pressed while recording
            toggleState[activeId] = false
            activeToggleModeId = nil
            updateCarbonESCAbortHotkeyRegistration()
            onCrossModeStop?(id)
        } else {
            let isOn = toggleState[id] ?? false
            toggleState[id] = !isOn
            if !isOn {
                activeToggleModeId = id
                updateCarbonESCAbortHotkeyRegistration()
                binding.onStart()
            } else {
                activeToggleModeId = nil
                updateCarbonESCAbortHotkeyRegistration()
                binding.onStop()
            }
        }
    }

    private func updateCarbonESCAbortHotkeyRegistration() {
        guard carbonEventHandler != nil else { return }
        let shouldRegister = isESCAbortEnabled
            && (activeToggleModeId != nil || holdState.values.contains(true) || isSessionActive || isProcessing || isCopyFallbackVisible)

        if shouldRegister {
            registerCarbonESCAbortHotkey()
        } else {
            unregisterCarbonESCAbortHotkey()
        }
    }

    private func registerCarbonESCAbortHotkey() {
        guard carbonESCAbortHotkeyRef == nil else { return }

        var hotkeyRef: EventHotKeyRef?
        let hotkeyId = EventHotKeyID(signature: 0x4D555345, id: carbonESCAbortHotkeyId) // DAL
        let status = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            hotkeyId,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        if status == noErr, let hotkeyRef {
            carbonESCAbortHotkeyRef = hotkeyRef
            DebugFileLogger.log("hotkey carbon ESC abort registered")
        } else {
            DebugFileLogger.log("hotkey carbon ESC abort register failed status=\(status)")
        }
    }

    private func unregisterCarbonESCAbortHotkey() {
        guard let hotkeyRef = carbonESCAbortHotkeyRef else { return }
        UnregisterEventHotKey(hotkeyRef)
        carbonESCAbortHotkeyRef = nil
        DebugFileLogger.log("hotkey carbon ESC abort unregistered")
    }

    private func triggerESCAbort(source: String) {
        let isRecording = activeToggleModeId != nil || holdState.values.contains(true) || isSessionActive
        let shouldAbort = isESCAbortEnabled && (isRecording || isProcessing)
        guard shouldAbort else { return }

        let now = Date()
        if let lastESCAbortAt, now.timeIntervalSince(lastESCAbortAt) < 0.4 {
            return
        }
        lastESCAbortAt = now

        DebugFileLogger.log("hotkey ESC abort pressed source=\(source) recording=\(isRecording) processing=\(isProcessing)")
        activeToggleModeId = nil
        for key in toggleState.keys { toggleState[key] = false }
        for key in holdState.keys { holdState[key] = false }
        isSessionActive = false
        isProcessing = false
        updateCarbonESCAbortHotkeyRegistration()
        onESCAbort?()
    }

    private func startESCEventMonitors() {
        stopESCEventMonitors()

        escLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            guard self?.handleESCMonitorEvent(source: "local-esc-monitor") == true else {
                return event
            }
            return nil
        }

        escGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            _ = self?.handleESCMonitorEvent(source: "global-esc-monitor")
        }

        DebugFileLogger.log("hotkey ESC monitors registered")
    }

    private func stopESCEventMonitors() {
        if let escLocalMonitor {
            NSEvent.removeMonitor(escLocalMonitor)
            self.escLocalMonitor = nil
        }
        if let escGlobalMonitor {
            NSEvent.removeMonitor(escGlobalMonitor)
            self.escGlobalMonitor = nil
        }
    }

    private func handleESCMonitorEvent(source: String) -> Bool {
        handleESCAction(source: source)
    }

    @discardableResult
    private func handleESCAction(source: String) -> Bool {
        let isRecording = activeToggleModeId != nil || holdState.values.contains(true) || isSessionActive
        guard isESCAbortEnabled else { return false }
        if isRecording || isProcessing {
            triggerESCAbort(source: source)
            return true
        }
        if isCopyFallbackVisible {
            triggerESCDismissCopyFallback(source: source)
            return true
        }
        return false
    }

    private func triggerESCDismissCopyFallback(source: String) {
        DebugFileLogger.log("hotkey ESC dismiss copy fallback source=\(source)")
        isCopyFallbackVisible = false
        onESCDismissCopyFallback?()
    }

    // MARK: - Health check

    /// Periodically verify the event tap is actually alive.
    /// Detects the "silent disable" race where tapCreate succeeds but the tap is dead.
    private func startHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self, let tap = self.eventTap else { return }

            // Check 1: Is the tap still enabled at the Mach port level?
            if !CGEvent.tapIsEnabled(tap: tap) {
                AppLogger.log("[Dal] Health check: tap disabled, re-enabling...")
                CGEvent.tapEnable(tap: tap, enable: true)
            }

            // Check 2: If we haven't received ANY event in 30s, the tap may be silently dead.
            // (User is almost certainly pressing keys within 30s of normal use.)
            // Only flag this if the tap has been alive for at least 30s (give it time to warm up).
            if let lastEvent = self.lastEventTime,
               Date().timeIntervalSince(lastEvent) > 30 {
                AppLogger.log("[Dal] Health check: no events for 30s, reinstalling tap...")
                self.reinstallTap()
            }
        }
    }

    /// Tear down and recreate the event tap from scratch.
    private func reinstallTap() {
        // 只重建底层输入通道，保留正在录音的 hold/toggle 和安全计时器。
        stop(resetBusinessState: false)
        let ok = start()
        AppLogger.log("[Dal] Tap reinstall: \(ok ? "OK" : "FAILED")")
    }

    // MARK: - Event handling

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        lastEventTime = Date()

        // Re-enable tap if system disabled it, and recover any stuck hold states.
        // When macOS disables the tap (main thread blocked >1s), keyUp events are lost.
        // We must check if held keys are still physically down; if not, fire onStop.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            recoverStuckHolds()
            return Unmanaged.passUnretained(event)
        }

        // Pass all events through when suppressed (hotkey recording in progress)
        if isSuppressed {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        for binding in bindings {
            if isModifierComboBinding(binding) {
                // 修饰键组合（如 fn+⌃）与按键顺序无关：按住的修饰键恰好等于绑定集合即触发，
                // 集合中任一键松开即释放。事件照常放行。
                guard type == .flagsChanged, isModifierKeyCode(keyCode) else { continue }
                let required = comboFlags(for: binding)
                let current = modifierComboFlags(event.flags)
                if isModifierPressed(keyCode: keyCode, flags: event.flags) {
                    guard current == required else { continue }
                    handleBindingEvent(binding: binding, pressed: true)
                    return Unmanaged.passUnretained(event)
                } else if isModifierBindingActive(binding), !current.isSuperset(of: required) {
                    handleBindingEvent(binding: binding, pressed: false)
                    return Unmanaged.passUnretained(event)
                }
                continue
            }

            guard binding.keyCode == keyCode else { continue }

            // Normal key combinations are handled by Carbon when available.
            // Keep the event tap for modifier-only shortcuts and ESC so the
            // same shortcut cannot fire twice when both systems are active.
            if carbonHandledModeIds.contains(binding.modeId),
               !isModifierKeyCode(binding.keyCode) {
                continue
            }

            if isModifierKeyCode(keyCode) {
                // Single modifier keys: handle via flagsChanged only, don't swallow.
                guard type == .flagsChanged else { continue }
                let pressed = isModifierPressed(keyCode: keyCode, flags: event.flags)

                if pressed {
                    let currentMods = otherModifierFlags(for: keyCode, flags: event.flags)
                    guard currentMods.isEmpty else { continue }
                    handleBindingEvent(binding: binding, pressed: true)
                    return Unmanaged.passUnretained(event)
                } else if isModifierBindingActive(binding) {
                    // Always release active state even if other modifiers were released first.
                    handleBindingEvent(binding: binding, pressed: false)
                    return Unmanaged.passUnretained(event)
                }
                continue
            } else {
                switch binding.style {
                case .hold:
                    if type == .keyDown {
                        let requiredMods = normalizedModifierFlags(binding.modifiers)
                        let currentMods = normalizedModifierFlags(event.flags)
                        guard currentMods == requiredMods else { continue }
                        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
                        if isRepeat != 0 { return nil }
                        handleBindingEvent(binding: binding, pressed: true)
                        return nil
                    } else if type == .keyUp {
                        // Release active hold even if modifier keys were already lifted.
                        // Fast tap sequences often deliver keyUp after the modifier state changed.
                        guard holdState[binding.modeId] == true else { continue }
                        handleBindingEvent(binding: binding, pressed: false)
                        return nil
                    }
                case .toggle:
                    let requiredMods = normalizedModifierFlags(binding.modifiers)
                    let currentMods = normalizedModifierFlags(event.flags)
                    guard currentMods == requiredMods else { continue }
                    if type == .keyDown {
                        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
                        if isRepeat != 0 { return nil }
                        handleTogglePress(binding)
                        return nil
                    }
                }
                continue
            }
        }

        // ESC key (keyCode 53) - abort active recording or processing
        if isESCAbortEnabled && type == .keyDown && keyCode == 53 {
            if handleESCAction(source: "event-tap") {
                return nil  // Swallow ESC
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Binding dispatch

    private func handleBindingEvent(binding: ModeBinding, pressed: Bool) {
        let id = binding.modeId

        switch binding.style {
        case .hold:
            let wasHolding = holdState[id] ?? false
            if pressed && !wasHolding {
                holdState[id] = true
                updateCarbonESCAbortHotkeyRegistration()
                startSafetyTimer(for: binding)
                binding.onStart()
            } else if !pressed && wasHolding {
                holdState[id] = false
                updateCarbonESCAbortHotkeyRegistration()
                cancelSafetyTimer(for: id)
                binding.onStop()
            }

        case .toggle:
            let wasDown = wasModifierDown[id] ?? false
            if pressed && !wasDown {
                wasModifierDown[id] = true
                handleTogglePress(binding)
            } else if !pressed {
                wasModifierDown[id] = false
            }
        }
    }

    // MARK: - Safety Timer

    private func startSafetyTimer(for binding: ModeBinding) {
        cancelSafetyTimer(for: binding.modeId)
        let id = binding.modeId
        holdSafetyTimers[id] = Timer.scheduledTimer(
            timeInterval: maxHoldDuration,
            target: self,
            selector: #selector(handleHoldSafetyTimer(_:)),
            userInfo: id,
            repeats: false
        )
    }

    private func cancelSafetyTimer(for id: UUID) {
        holdSafetyTimers[id]?.invalidate()
        holdSafetyTimers[id] = nil
    }

    @objc
    private func handleHoldSafetyTimer(_ timer: Timer) {
        guard let id = timer.userInfo as? UUID else { return }
        guard holdState[id] == true else { return }
        guard let binding = bindings.first(where: { $0.modeId == id }) else { return }

        AppLogger.log("[HotkeyManager] Safety timer fired for mode \(id.uuidString), auto-stopping")
        holdState[id] = false
        updateCarbonESCAbortHotkeyRegistration()
        binding.onStop()
    }

    // MARK: - Stuck Hold Recovery

    /// After a tap re-enable, check if any held keys were released while the tap was disabled.
    private func recoverStuckHolds() {
        let currentFlags = CGEventSource.flagsState(.combinedSessionState)

        for binding in bindings where binding.style == .hold {
            let id = binding.modeId
            guard holdState[id] == true else { continue }

            let stillDown: Bool
            if isModifierKeyCode(binding.keyCode) {
                stillDown = isModifierPressed(keyCode: binding.keyCode, flags: currentFlags)
            } else {
                stillDown = CGEventSource.keyState(.combinedSessionState, key: binding.keyCode)
            }

            if !stillDown {
                AppLogger.log("[HotkeyManager] Recovering stuck hold for mode \(id.uuidString)")
                holdState[id] = false
                updateCarbonESCAbortHotkeyRegistration()
                cancelSafetyTimer(for: id)
                binding.onStop()
            }
        }
    }

    // MARK: - Helpers

    private func isModifierKeyCode(_ keyCode: CGKeyCode) -> Bool {
        [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(keyCode)
    }

    private func normalizedModifierFlags(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
    }

    private func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
        let normalized = normalizedModifierFlags(flags)
        var modifiers: UInt32 = 0
        if normalized.contains(.maskCommand) {
            modifiers |= UInt32(cmdKey)
        }
        if normalized.contains(.maskShift) {
            modifiers |= UInt32(shiftKey)
        }
        if normalized.contains(.maskAlternate) {
            modifiers |= UInt32(optionKey)
        }
        if normalized.contains(.maskControl) {
            modifiers |= UInt32(controlKey)
        }
        return modifiers
    }

    private func modifierEventFlag(for keyCode: CGKeyCode) -> CGEventFlags? {
        switch keyCode {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 63: return .maskSecondaryFn
        default: return nil
        }
    }

    /// 修饰键组合匹配用的标志集合：在常规修饰键之外计入 fn。
    private func modifierComboFlags(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn])
    }

    private func isModifierComboBinding(_ binding: ModeBinding) -> Bool {
        isModifierKeyCode(binding.keyCode) && !modifierComboFlags(binding.modifiers).isEmpty
    }

    /// 组合的完整修饰键集合：录制时的主键加其余修饰键，左右键不区分。
    private func comboFlags(for binding: ModeBinding) -> CGEventFlags {
        var flags = modifierComboFlags(binding.modifiers)
        if let ownFlag = modifierEventFlag(for: binding.keyCode) {
            flags.insert(ownFlag)
        }
        return flags
    }

    /// 单按 fn 在 🌐 键盘上存为 179（松开时补发，Carbon 可注册且不与 fn 组合冲突）；
    /// 但 179 的按下与松开同时到达，按住式改由 fn 本身的 flagsChanged 驱动。
    private static func runtimeBinding(_ binding: ModeBinding) -> ModeBinding {
        guard binding.keyCode == CGKeyCode(HotkeyDisplay.globeKeyCode), binding.style == .hold else { return binding }
        return ModeBinding(modeId: binding.modeId, keyCode: 63, modifiers: binding.modifiers,
                           style: binding.style, onStart: binding.onStart, onStop: binding.onStop)
    }

    private func otherModifierFlags(for keyCode: CGKeyCode, flags: CGEventFlags) -> CGEventFlags {
        var mods = modifierComboFlags(flags)
        if let ownFlag = modifierEventFlag(for: keyCode) {
            mods.remove(ownFlag)
        }
        return mods
    }

    private func isModifierBindingActive(_ binding: ModeBinding) -> Bool {
        switch binding.style {
        case .hold:
            return holdState[binding.modeId] ?? false
        case .toggle:
            return wasModifierDown[binding.modeId] ?? false
        }
    }

    private func isModifierPressed(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case 54, 55: return flags.contains(.maskCommand)
        case 56, 60: return flags.contains(.maskShift)
        case 58, 61: return flags.contains(.maskAlternate)
        case 59, 62: return flags.contains(.maskControl)
        case 63: return flags.contains(.maskSecondaryFn)
        default: return false
        }
    }
}

#if DEBUG
extension HotkeyManager {
    /// 测试健康检查的保留语义，不触碰真实系统 event tap。
    func stopTransportPreservingStateForTesting() {
        stop(resetBusinessState: false)
    }

    @discardableResult
    func handleEventForTesting(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags = [],
        isRepeat: Bool = false
    ) -> Bool {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: keyCode,
            keyDown: type != .keyUp
        ) else {
            return false
        }
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: isRepeat ? 1 : 0)
        return handleEvent(type: type, event: event) == nil
    }

    func isHoldingForTesting(_ id: UUID) -> Bool {
        holdState[id] ?? false
    }

    func isToggleOnForTesting(_ id: UUID) -> Bool {
        toggleState[id] ?? false
    }

    var activeToggleModeIdForTesting: UUID? {
        activeToggleModeId
    }
}
#endif

// MARK: - C callback

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handleEvent(type: type, event: event)
}

private func carbonHotkeyCallback(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return noErr }

    var hotkeyId = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyId
    )
    guard status == noErr else { return status }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    return manager.handleCarbonHotkey(id: hotkeyId.id, eventKind: GetEventKind(event))
}
