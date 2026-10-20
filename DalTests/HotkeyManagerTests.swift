import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import Dal

final class HotkeyManagerTests: XCTestCase {

    private var manager: HotkeyManager!

    override func setUp() {
        manager = HotkeyManager()
    }

    override func tearDown() {
        manager.stop()
        manager = nil
    }

    func testHoldBindingStartsOnKeyDownAndStopsOnKeyUp() {
        let modeId = UUID()
        let calls = HotkeyCallRecorder()
        manager.registerBindings([
            binding(modeId: modeId, keyCode: CGKeyCode(kVK_ANSI_A), style: .hold, calls: calls)
        ])

        let keyDownHandled = manager.handleEventForTesting(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_ANSI_A),
            flags: .maskControl
        )
        let repeatHandled = manager.handleEventForTesting(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_ANSI_A),
            flags: .maskControl,
            isRepeat: true
        )
        let keyUpHandled = manager.handleEventForTesting(
            type: .keyUp,
            keyCode: CGKeyCode(kVK_ANSI_A)
        )

        XCTAssertTrue(keyDownHandled)
        XCTAssertTrue(repeatHandled)
        XCTAssertTrue(keyUpHandled)
        XCTAssertEqual(calls.starts, 1)
        XCTAssertEqual(calls.stops, 1)
        XCTAssertFalse(manager.isHoldingForTesting(modeId))
    }

    func testTransportRebuildPreservesActiveHoldUntilKeyUp() {
        let modeId = UUID()
        let calls = HotkeyCallRecorder()
        manager.registerBindings([
            binding(modeId: modeId, keyCode: CGKeyCode(kVK_ANSI_A), style: .hold, calls: calls)
        ])
        manager.isSessionActive = true

        manager.handleEventForTesting(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_ANSI_A),
            flags: .maskControl
        )
        manager.stopTransportPreservingStateForTesting()

        XCTAssertTrue(manager.isHoldingForTesting(modeId))
        XCTAssertTrue(manager.isSessionActive)
        XCTAssertEqual(calls.stops, 0)

        manager.handleEventForTesting(
            type: .keyUp,
            keyCode: CGKeyCode(kVK_ANSI_A)
        )

        XCTAssertEqual(calls.stops, 1)
        XCTAssertFalse(manager.isHoldingForTesting(modeId))
    }

    func testTransportRebuildPreservesActiveToggle() {
        let modeId = UUID()
        let calls = HotkeyCallRecorder()
        manager.registerBindings([
            binding(modeId: modeId, keyCode: CGKeyCode(kVK_ANSI_B), style: .toggle, calls: calls)
        ])

        manager.handleEventForTesting(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_ANSI_B),
            flags: .maskControl
        )
        manager.stopTransportPreservingStateForTesting()

        XCTAssertTrue(manager.isToggleOnForTesting(modeId))
        XCTAssertEqual(manager.activeToggleModeIdForTesting, modeId)
        XCTAssertEqual(calls.starts, 1)
        XCTAssertEqual(calls.stops, 0)
    }

    func testHoldBindingIgnoresWrongModifiers() {
        let modeId = UUID()
        let calls = HotkeyCallRecorder()
        manager.registerBindings([
            binding(modeId: modeId, keyCode: CGKeyCode(kVK_ANSI_A), style: .hold, calls: calls)
        ])

        let handled = manager.handleEventForTesting(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_ANSI_A),
            flags: .maskCommand
        )

        XCTAssertFalse(handled)
        XCTAssertEqual(calls.starts, 0)
        XCTAssertFalse(manager.isHoldingForTesting(modeId))
    }

    func testToggleBindingTogglesOnNonRepeatKeyDownOnly() {
        let modeId = UUID()
        let calls = HotkeyCallRecorder()
        manager.registerBindings([
            binding(modeId: modeId, keyCode: CGKeyCode(kVK_ANSI_B), style: .toggle, calls: calls)
        ])

        manager.handleEventForTesting(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_ANSI_B),
            flags: .maskControl
        )
        manager.handleEventForTesting(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_ANSI_B),
            flags: .maskControl,
            isRepeat: true
        )
        XCTAssertEqual(calls.starts, 1)
        XCTAssertEqual(calls.stops, 0)
        XCTAssertTrue(manager.isToggleOnForTesting(modeId))
        XCTAssertEqual(manager.activeToggleModeIdForTesting, modeId)

        manager.handleEventForTesting(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_ANSI_B),
            flags: .maskControl
        )

        XCTAssertEqual(calls.starts, 1)
        XCTAssertEqual(calls.stops, 1)
        XCTAssertFalse(manager.isToggleOnForTesting(modeId))
        XCTAssertNil(manager.activeToggleModeIdForTesting)
    }

    func testToggleCrossModeStopHandsOffToNewModeWithoutStartingIt() {
        let firstId = UUID()
        let secondId = UUID()
        let firstCalls = HotkeyCallRecorder()
        let secondCalls = HotkeyCallRecorder()
        let crossModeStops = UUIDRecorder()
        manager.onCrossModeStop = { crossModeStops.append($0) }
        manager.registerBindings([
            binding(modeId: firstId, keyCode: CGKeyCode(kVK_ANSI_A), style: .toggle, calls: firstCalls),
            binding(modeId: secondId, keyCode: CGKeyCode(kVK_ANSI_B), style: .toggle, calls: secondCalls),
        ])

        manager.handleEventForTesting(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_ANSI_A),
            flags: .maskControl
        )
        manager.handleEventForTesting(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_ANSI_B),
            flags: .maskControl
        )

        XCTAssertEqual(firstCalls.starts, 1)
        XCTAssertEqual(firstCalls.stops, 0)
        XCTAssertEqual(secondCalls.starts, 0)
        XCTAssertEqual(secondCalls.stops, 0)
        XCTAssertEqual(crossModeStops.values, [secondId])
        XCTAssertFalse(manager.isToggleOnForTesting(firstId))
        XCTAssertFalse(manager.isToggleOnForTesting(secondId))
        XCTAssertNil(manager.activeToggleModeIdForTesting)
    }

    func testESCAbortResetsActiveSessionAndProcessingState() {
        let calls = HotkeyCallRecorder()
        manager.onESCAbort = { calls.start() }
        manager.isSessionActive = true
        manager.isProcessing = true

        let handled = manager.handleEventForTesting(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_Escape)
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(calls.starts, 1)
        XCTAssertFalse(manager.isSessionActive)
        XCTAssertFalse(manager.isProcessing)
        XCTAssertNil(manager.activeToggleModeIdForTesting)
    }

    func testDisabledESCAbortPassesThrough() {
        let calls = HotkeyCallRecorder()
        manager.onESCAbort = { calls.start() }
        manager.isESCAbortEnabled = false
        manager.isSessionActive = true

        let handled = manager.handleEventForTesting(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_Escape)
        )

        XCTAssertFalse(handled)
        XCTAssertEqual(calls.starts, 0)
        XCTAssertTrue(manager.isSessionActive)
    }

    func testESCDismissesCopyFallbackWhenVisible() {
        let calls = HotkeyCallRecorder()
        manager.onESCDismissCopyFallback = { calls.start() }
        manager.isCopyFallbackVisible = true

        let handled = manager.handleEventForTesting(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_Escape)
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(calls.starts, 1)
        XCTAssertFalse(manager.isCopyFallbackVisible)
    }

    // MARK: - fn 与修饰键组合

    func testFnControlComboFiresInEitherPressOrder() {
        let modeId = UUID()
        let calls = HotkeyCallRecorder()
        // 录制时先按 fn 再按 ⌃：主键为 ⌃，其余修饰键为 fn。
        manager.registerBindings([
            binding(modeId: modeId, keyCode: 59, modifiers: .maskSecondaryFn, style: .hold, calls: calls)
        ])

        // 先 fn 后 ⌃
        manager.handleEventForTesting(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn)
        XCTAssertEqual(calls.starts, 0)
        manager.handleEventForTesting(type: .flagsChanged, keyCode: 59, flags: [.maskSecondaryFn, .maskControl])
        XCTAssertEqual(calls.starts, 1)
        manager.handleEventForTesting(type: .flagsChanged, keyCode: 63, flags: .maskControl)
        XCTAssertEqual(calls.stops, 1)
        manager.handleEventForTesting(type: .flagsChanged, keyCode: 59, flags: [])

        // 先 ⌃ 后 fn
        manager.handleEventForTesting(type: .flagsChanged, keyCode: 59, flags: .maskControl)
        XCTAssertEqual(calls.starts, 1)
        manager.handleEventForTesting(type: .flagsChanged, keyCode: 63, flags: [.maskControl, .maskSecondaryFn])
        XCTAssertEqual(calls.starts, 2)
        manager.handleEventForTesting(type: .flagsChanged, keyCode: 59, flags: .maskSecondaryFn)
        XCTAssertEqual(calls.stops, 2)
    }

    func testFnControlComboIgnoresExtraModifiers() {
        let modeId = UUID()
        let calls = HotkeyCallRecorder()
        manager.registerBindings([
            binding(modeId: modeId, keyCode: 63, modifiers: .maskControl, style: .toggle, calls: calls)
        ])

        manager.handleEventForTesting(type: .flagsChanged, keyCode: 59, flags: .maskControl)
        manager.handleEventForTesting(type: .flagsChanged, keyCode: 56, flags: [.maskControl, .maskShift])
        manager.handleEventForTesting(type: .flagsChanged, keyCode: 63, flags: [.maskControl, .maskShift, .maskSecondaryFn])

        XCTAssertEqual(calls.starts, 0)
    }

    func testSingleModifierIgnoredWhileFnHeld() {
        let modeId = UUID()
        let calls = HotkeyCallRecorder()
        manager.registerBindings([
            binding(modeId: modeId, keyCode: 61, modifiers: [], style: .toggle, calls: calls)
        ])

        manager.handleEventForTesting(type: .flagsChanged, keyCode: 61, flags: [.maskAlternate, .maskSecondaryFn])
        XCTAssertEqual(calls.starts, 0)
        manager.handleEventForTesting(type: .flagsChanged, keyCode: 61, flags: [.maskSecondaryFn])
        manager.handleEventForTesting(type: .flagsChanged, keyCode: 61, flags: .maskAlternate)
        XCTAssertEqual(calls.starts, 1)
    }

    func testGlobeKeyHoldBindingRunsOnFnFlags() {
        let modeId = UUID()
        let calls = HotkeyCallRecorder()
        manager.registerBindings([
            binding(modeId: modeId, keyCode: 179, modifiers: [], style: .hold, calls: calls)
        ])

        manager.handleEventForTesting(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn)
        XCTAssertTrue(manager.isHoldingForTesting(modeId))
        manager.handleEventForTesting(type: .flagsChanged, keyCode: 63, flags: [])
        XCTAssertEqual(calls.starts, 1)
        XCTAssertEqual(calls.stops, 1)
    }

    func testFnDisplayNames() {
        XCTAssertEqual(HotkeyDisplay.keyDisplayName(keyCode: 179, modifiers: 0), "fn")
        XCTAssertEqual(HotkeyDisplay.keyDisplayName(keyCode: 63, modifiers: nil), "fn")
        let fn = UInt64(CGEventFlags.maskSecondaryFn.rawValue)
        let control = UInt64(CGEventFlags.maskControl.rawValue)
        XCTAssertEqual(HotkeyDisplay.keyDisplayName(keyCode: 59, modifiers: fn), "fn+⌃")
        XCTAssertEqual(HotkeyDisplay.keyDisplayName(keyCode: 63, modifiers: control), "fn+⌃")
        XCTAssertEqual(HotkeyDisplay.keyDisplayName(keyCode: 61, modifiers: 0), "⌥")
    }

    private func binding(
        modeId: UUID,
        keyCode: CGKeyCode,
        modifiers: CGEventFlags = .maskControl,
        style: HotkeyStyle,
        calls: HotkeyCallRecorder
    ) -> ModeBinding {
        ModeBinding(
            modeId: modeId,
            keyCode: keyCode,
            modifiers: modifiers,
            style: style,
            onStart: { calls.start() },
            onStop: { calls.stop() }
        )
    }
}

private final class HotkeyCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var startCount = 0
    private var stopCount = 0

    var starts: Int {
        lock.withLock { startCount }
    }

    var stops: Int {
        lock.withLock { stopCount }
    }

    func start() {
        lock.withLock { startCount += 1 }
    }

    func stop() {
        lock.withLock { stopCount += 1 }
    }
}

private final class UUIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID] = []

    var values: [UUID] {
        lock.withLock { storage }
    }

    func append(_ value: UUID) {
        lock.withLock { storage.append(value) }
    }
}
