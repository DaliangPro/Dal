import Foundation
import os

enum VoicePolishCapturedContextKind: String, Sendable, Equatable {
    case metadataOnly
    case selectedText
    case nearbyText
    case unavailable
}

/// 最近一次正式 Voice Polish 请求实际取得的上下文摘要。
/// 只记录类型、字符数和安全状态，不保存任何正文。
struct VoicePolishContextDiagnosticSnapshot: Sendable, Equatable {
    let capturedAt: Date
    let applicationName: String?
    let applicationBundleID: String?
    let requestedLevel: WritingContextLevel
    let safety: ContextSafety
    let capturedKind: VoicePolishCapturedContextKind
    let selectedCharacterCount: Int
    let nearbyCharacterCount: Int
    let recentDalInputCount: Int
}

enum VoicePolishContextDiagnostics {
    private static let state = OSAllocatedUnfairLock<VoicePolishContextDiagnosticSnapshot?>(
        initialState: nil
    )

    static func record(_ context: WritingContext, at date: Date = Date()) {
        let selectedCount = context.selectedText?.count ?? 0
        let nearbyCount = (context.textBeforeCursor?.count ?? 0)
            + (context.textAfterCursor?.count ?? 0)
        let capturedKind: VoicePolishCapturedContextKind
        if context.level == .metadataOnly {
            capturedKind = .metadataOnly
        } else if context.safety != .safe {
            capturedKind = .unavailable
        } else if context.level == .selectedText, selectedCount > 0 {
            capturedKind = .selectedText
        } else if context.level == .nearbyText, selectedCount + nearbyCount > 0 {
            capturedKind = .nearbyText
        } else {
            capturedKind = .unavailable
        }

        state.withLock {
            $0 = VoicePolishContextDiagnosticSnapshot(
                capturedAt: date,
                applicationName: context.applicationName,
                applicationBundleID: context.applicationBundleID,
                requestedLevel: context.level,
                safety: context.safety,
                capturedKind: capturedKind,
                selectedCharacterCount: selectedCount,
                nearbyCharacterCount: nearbyCount,
                recentDalInputCount: context.recentDalInputs.count
            )
        }
        NotificationCenter.default.post(
            name: .voicePolishContextDiagnosticsDidChange,
            object: nil
        )
    }

    static func latest() -> VoicePolishContextDiagnosticSnapshot? {
        state.withLock { $0 }
    }

    static func clearForTesting() {
        state.withLock { $0 = nil }
    }
}

extension Notification.Name {
    static let voicePolishContextDiagnosticsDidChange = Notification.Name(
        "DalVoicePolishContextDiagnosticsDidChange"
    )
}
