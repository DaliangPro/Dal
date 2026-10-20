import AppKit
import ApplicationServices
import Foundation
import os

enum WritingContextCapture {
    static let timeout: Duration = .milliseconds(400)
    static let nearbyCharacterLimit = 400

    private final class CompletionGate: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: false)
        private let continuation: CheckedContinuation<WritingContext, Never>

        init(_ continuation: CheckedContinuation<WritingContext, Never>) {
            self.continuation = continuation
        }

        func finish(_ context: WritingContext) {
            let shouldResume = lock.withLock { finished in
                guard !finished else { return false }
                finished = true
                return true
            }
            if shouldResume { continuation.resume(returning: context) }
        }
    }

    /// AX IPC 在独立队列执行；400ms 后返回无正文的 unknown，迟到结果由 gate 丢弃。
    static func capture(
        level: WritingContextLevel,
        userOverrides: [String: WritingScene] = VoicePolishSettings.sceneOverrides()
    ) async -> WritingContext {
        await withCheckedContinuation { continuation in
            let gate = CompletionGate(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                gate.finish(captureSynchronously(level: level, userOverrides: userOverrides))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(400)) {
                gate.finish(WritingContext(level: level, safety: .unknown))
            }
        }
    }

    static func captureSynchronously(
        level: WritingContextLevel,
        userOverrides: [String: WritingScene] = [:]
    ) -> WritingContext {
        guard AXIsProcessTrusted() else {
            return WritingContext(level: level, safety: .unknown)
        }
        let systemWide = AXUIElementCreateSystemWide()
        guard let focused = elementAttribute(systemWide, kAXFocusedUIElementAttribute as CFString) else {
            return WritingContext(level: level, safety: .unknown)
        }

        var pid: pid_t = 0
        let hasPID = AXUIElementGetPid(focused, &pid) == .success && pid > 0
        let app = hasPID ? NSRunningApplication(processIdentifier: pid) : nil
        let bundleID = app?.bundleIdentifier
        let appName = app?.localizedName
        let role = stringAttribute(focused, kAXRoleAttribute as CFString)
        let scene = AppSceneClassifier.classify(
            bundleID: bundleID,
            focusedRole: role,
            userOverrides: userOverrides
        )
        let safety = safety(of: focused, role: role)

        guard level != .metadataOnly, safety == .safe else {
            return WritingContext(
                applicationBundleID: bundleID,
                applicationName: appName,
                focusedRole: role,
                scene: scene,
                level: level,
                safety: safety,
                localeIdentifier: Locale.current.identifier
            )
        }

        let selected = stringAttribute(focused, kAXSelectedTextAttribute as CFString)
        var before: String?
        var after: String?
        if level == .nearbyText,
           let value = stringAttribute(focused, kAXValueAttribute as CFString),
           let selectedRange = cfRangeAttribute(focused, kAXSelectedTextRangeAttribute as CFString),
           let range = Range(NSRange(location: selectedRange.location, length: selectedRange.length), in: value) {
            before = String(value[..<range.lowerBound].suffix(nearbyCharacterLimit))
            after = String(value[range.upperBound...].prefix(nearbyCharacterLimit))
        }

        return WritingContext(
            applicationBundleID: bundleID,
            applicationName: appName,
            focusedRole: role,
            scene: scene,
            level: level,
            safety: safety,
            selectedText: selected,
            textBeforeCursor: before,
            textAfterCursor: after,
            localeIdentifier: Locale.current.identifier
        )
    }

    static func safetyForTesting(
        role: String?,
        subrole: String?,
        editable: Bool?,
        protectedContent: Bool?
    ) -> ContextSafety {
        if protectedContent == true || subrole == "AXSecureTextField" { return .secure }
        guard protectedContent == false else { return .unknown }
        guard subrole != nil else { return .unknown }
        if role == "AXTextField" || role == "AXTextArea" { return .safe }
        if role == "AXComboBox", editable == true { return .safe }
        return .unknown
    }

    private static func safety(of element: AXUIElement, role: String?) -> ContextSafety {
        safetyForTesting(
            role: role,
            subrole: stringAttribute(element, kAXSubroleAttribute as CFString),
            editable: boolAttribute(element, "AXEditable" as CFString),
            protectedContent: boolAttribute(element, "AXProtectedContent" as CFString)
        )
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? Bool
    }

    private static func cfRangeAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }
        return range
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
