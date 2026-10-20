import AppKit
@testable import Dal
import XCTest

final class TextInjectionEngineIntegrationTests: XCTestCase {
    func testCurrentProcessTargetBypassesAccessibility() {
        let currentPID = ProcessInfo.processInfo.processIdentifier

        XCTAssertTrue(
            TextInjectionEngine.shouldBypassAccessibility(
                targetProcessIdentifier: currentPID,
                currentProcessIdentifier: currentPID
            )
        )
        XCTAssertFalse(
            TextInjectionEngine.shouldBypassAccessibility(
                targetProcessIdentifier: currentPID + 1,
                currentProcessIdentifier: currentPID
            )
        )
    }

    @MainActor
    func testClipboardInjectionIntoTextEdit() throws {
        guard ProcessInfo.processInfo.environment["DAL_RUN_UI_INJECTION_TEST"] == "1" else {
            throw XCTSkip("Set DAL_RUN_UI_INJECTION_TEST=1 to run the TextEdit injection test.")
        }

        try ensureTextEditIsRunning()
        let marker = "DAL_ENGINE_INJECTION_TEST_\(UUID().uuidString)"
        try prepareTextEditDocument()
        defer {
            _ = try? closeFrontTextEditDocument()
        }

        try activateTextEdit()

        // REPAIR_PLAN J16：AX 直插零剪贴板占用——注入全程剪贴板保持原内容
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("剪贴板原有内容", forType: .string)

        let engine = TextInjectionEngine()
        engine.preserveClipboard = false

        XCTAssertEqual(engine.inject(marker), .inserted)

        let documentText = try waitForFrontTextEditDocument(containing: marker)
        XCTAssertTrue(
            documentText.contains(marker),
            "Expected TextEdit document to contain injected marker, got: \(documentText)"
        )

        let clipboardText = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertEqual(
            clipboardText,
            "剪贴板原有内容",
            "AX direct insertion must not touch the clipboard at all (REPAIR_PLAN J16)."
        )
    }

    @MainActor
    func testClipboardInjectionLeavesCaretAfterInsertedTextInTextEdit() throws {
        guard ProcessInfo.processInfo.environment["DAL_RUN_UI_INJECTION_TEST"] == "1" else {
            throw XCTSkip("Set DAL_RUN_UI_INJECTION_TEST=1 to run the TextEdit injection test.")
        }

        try ensureTextEditIsRunning()
        let prefix = "prefix-"
        let marker = "dalinjection\(Int(Date().timeIntervalSince1970))"
        let suffix = "-suffix"
        try prepareTextEditDocument()
        defer {
            _ = try? closeFrontTextEditDocument()
        }

        try activateTextEdit()
        try runAppleScript("""
        tell application "System Events"
            keystroke "\(prefix)"
        end tell
        """)
        _ = try waitForFrontTextEditDocument(containing: prefix)

        let engine = TextInjectionEngine()
        engine.preserveClipboard = false

        XCTAssertEqual(engine.inject(marker), .inserted)
        _ = try waitForFrontTextEditDocument(containing: prefix + marker)
        try runAppleScript("""
        tell application "System Events"
            keystroke "\(suffix)"
        end tell
        """)

        let documentText = try waitForFrontTextEditDocument(containing: prefix + marker + suffix)
        XCTAssertTrue(
            documentText.contains(prefix + marker + suffix),
            "Expected caret to remain after injected text. Got: \(documentText)"
        )
    }

    // REPAIR_PLAN K6：nonactivatingPanel 输入框（ProNotch 闪问同配置）——键盘焦点
    // 在面板、宿主永不是 frontmost。修复后 systemwide 焦点识别 + 剪贴板 Cmd+V
    // 应把文本注入面板输入框（端到端）。
    @MainActor
    func testNonactivatingPanelReceivesInjection() throws {
        guard ProcessInfo.processInfo.environment["DAL_RUN_UI_INJECTION_TEST"] == "1" else {
            throw XCTSkip("Set DAL_RUN_UI_INJECTION_TEST=1 to run the panel injection test.")
        }

        final class KeyablePanel: NSPanel {
            override var canBecomeKey: Bool { true }
        }
        let panel = KeyablePanel(
            contentRect: NSRect(x: 500, y: 500, width: 320, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 300, height: 28))
        panel.contentView?.addSubview(field)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        defer { panel.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        guard let target = TextInjectionEngine.systemwideFocusedTarget(),
              target.ownerPid == ProcessInfo.processInfo.processIdentifier else {
            throw XCTSkip("systemwide focus did not land on test panel (environment-dependent); skipping")
        }

        let marker = "DAL_PANEL_INJECTION_\(Int(Date().timeIntervalSince1970))"
        let engine = TextInjectionEngine()
        engine.preserveClipboard = false

        // inject 禁止主线程调用（B6）；后台执行 + 主线程 spin runloop 处理 Cmd+V
        let done = expectation(description: "inject finished")
        nonisolated(unsafe) var outcome: InjectionOutcome?
        DispatchQueue.global(qos: .userInitiated).async {
            outcome = engine.inject(marker)
            done.fulfill()
        }
        wait(for: [done], timeout: 8)

        XCTAssertEqual(outcome, .inserted, "panel-focused input must be injectable (REPAIR_PLAN K6)")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !field.stringValue.contains(marker) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(
            field.stringValue.contains(marker),
            "Expected panel text field to receive injected text, got: '\(field.stringValue)'"
        )
    }

    // REPAIR_PLAN K5：Electron（Chromium）AX 树懒激活——冷启动的 Obsidian 焦点元素
    // 恒不可查，修复后焦点检测应自动设置 AXManualAccessibility 并等树建成。
    @MainActor
    func testElectronColdStartFocusDetectionActivatesAXTree() throws {
        guard ProcessInfo.processInfo.environment["DAL_RUN_UI_INJECTION_TEST"] == "1" else {
            throw XCTSkip("Set DAL_RUN_UI_INJECTION_TEST=1 to run the Electron AX activation test.")
        }
        let obsidianBundleID = "md.obsidian"
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: obsidianBundleID) != nil else {
            throw XCTSkip("Obsidian not installed; Electron AX activation test needs it.")
        }

        // 冷启动：先退出确保 AX 树回到未激活状态（K5 的必现前置条件）
        _ = try? runAppleScript("tell application id \"\(obsidianBundleID)\" to quit")
        let quitDeadline = Date().addingTimeInterval(8)
        while Date() < quitDeadline,
              NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == obsidianBundleID }) {
            usleep(200_000)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", obsidianBundleID]
        try process.run()
        process.waitUntilExit()
        guard let obsidian = waitForRunningApplication(bundleIdentifier: obsidianBundleID, timeout: 10) else {
            throw XCTSkip("Obsidian did not launch; cannot exercise Electron AX activation.")
        }
        defer {
            _ = try? runAppleScript("tell application id \"\(obsidianBundleID)\" to quit")
        }

        // 等窗口就绪并置前台（焦点检测要求目标为 frontmost 且窗口有键盘焦点）
        Thread.sleep(forTimeInterval: 5)
        let activateDeadline = Date().addingTimeInterval(5)
        while Date() < activateDeadline,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier != obsidianBundleID {
            _ = obsidian.activate(options: [.activateAllWindows])
            usleep(200_000)
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == obsidianBundleID else {
            throw XCTSkip("Obsidian did not become frontmost; cannot exercise focus detection.")
        }

        // K5 修复点：冷启动 Electron 上本调用应内部激活 AX 树并最终返回 true
        XCTAssertTrue(
            TextInjectionEngine.frontmostApplicationHasFocusedEditableElement(),
            "Cold-started Electron app should pass focus detection after AXManualAccessibility activation (REPAIR_PLAN K5)."
        )
    }

    private func waitForRunningApplication(
        bundleIdentifier: String,
        timeout: TimeInterval = 3
    ) -> NSRunningApplication? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let application = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleIdentifier
            }) {
                return application
            }
            usleep(50_000)
        }
        return nil
    }

    private func ensureTextEditIsRunning() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", "com.apple.TextEdit"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "TextInjectionEngineIntegrationTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to launch TextEdit via open."]
            )
        }
        guard waitForRunningApplication(bundleIdentifier: "com.apple.TextEdit") != nil else {
            throw NSError(
                domain: "TextInjectionEngineIntegrationTests",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "TextEdit did not become available after open."]
            )
        }
    }

    private func prepareTextEditDocument() throws {
        try runAppleScript("""
        tell application id "com.apple.TextEdit"
            activate
            make new document with properties {text:""}
        end tell
        """)
    }

    private func closeFrontTextEditDocument() throws {
        try runAppleScript("""
        tell application id "com.apple.TextEdit"
            if exists document 1 then close front document saving no
        end tell
        """)
    }

    private func readFrontTextEditDocument() throws -> String {
        try runAppleScript("""
        tell application id "com.apple.TextEdit"
            if exists document 1 then return text of front document
            return ""
        end tell
        """)
    }

    private func waitForFrontTextEditDocument(
        containing expectedText: String,
        timeout: TimeInterval = 3
    ) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var latestText = ""
        while Date() < deadline {
            latestText = try readFrontTextEditDocument()
            if latestText.contains(expectedText) {
                return latestText
            }
            usleep(100_000)
        }
        return latestText
    }

    private func activateTextEdit(timeout: TimeInterval = 3) throws {
        guard let textEdit = waitForRunningApplication(bundleIdentifier: "com.apple.TextEdit") else {
            throw NSError(
                domain: "TextInjectionEngineIntegrationTests",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "TextEdit did not launch."]
            )
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            _ = textEdit.activate(options: [.activateAllWindows])
            usleep(100_000)
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" {
                return
            }
        }

        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        throw NSError(
            domain: "TextInjectionEngineIntegrationTests",
            code: -1,
            userInfo: [
                NSLocalizedDescriptionKey: "TextEdit did not become frontmost. Current frontmost app: \(frontmost)."
            ]
        )
    }

    @discardableResult
    private func runAppleScript(_ source: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let errorOutput = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "TextInjectionEngineIntegrationTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errorOutput]
            )
        }

        return output
    }
}
