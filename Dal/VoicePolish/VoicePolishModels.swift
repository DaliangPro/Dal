import Foundation

enum WritingScene: String, Codable, Sendable, CaseIterable {
    case chat
    case workChat
    case email
    case document
    case note
    case aiPrompt
    case code
    case socialPost
    case customerSupport
    case unknown
}

enum ContextSafety: String, Codable, Sendable, Equatable {
    case safe
    case secure
    case unknown
}

enum WritingContextLevel: String, Codable, Sendable, Equatable {
    case metadataOnly
    case selectedText
    case nearbyText
}

struct WritingContext: Sendable, Equatable, Codable {
    let applicationBundleID: String?
    let applicationName: String?
    let focusedRole: String?
    let scene: WritingScene
    let level: WritingContextLevel
    let safety: ContextSafety
    let selectedText: String?
    let textBeforeCursor: String?
    let textAfterCursor: String?
    /// 仅包含 Dal 自己在同一应用内近期完成的输入；由可选的内存 Store 注入，
    /// 不读取第三方页面，也不跨应用、不持久化。
    let recentDalInputs: [String]
    let localeIdentifier: String?

    init(
        applicationBundleID: String? = nil,
        applicationName: String? = nil,
        focusedRole: String? = nil,
        scene: WritingScene = .unknown,
        level: WritingContextLevel = .metadataOnly,
        safety: ContextSafety = .unknown,
        selectedText: String? = nil,
        textBeforeCursor: String? = nil,
        textAfterCursor: String? = nil,
        recentDalInputs: [String] = [],
        localeIdentifier: String? = nil
    ) {
        self.applicationBundleID = applicationBundleID
        self.applicationName = applicationName
        self.focusedRole = focusedRole
        self.scene = scene
        self.level = level
        self.safety = safety
        self.localeIdentifier = localeIdentifier
        self.recentDalInputs = recentDalInputs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if safety == .safe, level != .metadataOnly {
            self.selectedText = selectedText
            self.textBeforeCursor = level == .nearbyText ? textBeforeCursor : nil
            self.textAfterCursor = level == .nearbyText ? textAfterCursor : nil
        } else {
            self.selectedText = nil
            self.textBeforeCursor = nil
            self.textAfterCursor = nil
        }
    }

    static let phaseOneUnknown = WritingContext()

    private enum CodingKeys: String, CodingKey {
        case applicationBundleID, applicationName, focusedRole, scene, level, safety
        case selectedText, textBeforeCursor, textAfterCursor, localeIdentifier
        case recentDalInputs = "recentMuseInputs"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            applicationBundleID: try container.decodeIfPresent(String.self, forKey: .applicationBundleID),
            applicationName: try container.decodeIfPresent(String.self, forKey: .applicationName),
            focusedRole: try container.decodeIfPresent(String.self, forKey: .focusedRole),
            scene: try container.decodeIfPresent(WritingScene.self, forKey: .scene) ?? .unknown,
            level: try container.decodeIfPresent(WritingContextLevel.self, forKey: .level) ?? .metadataOnly,
            safety: try container.decodeIfPresent(ContextSafety.self, forKey: .safety) ?? .unknown,
            selectedText: try container.decodeIfPresent(String.self, forKey: .selectedText),
            textBeforeCursor: try container.decodeIfPresent(String.self, forKey: .textBeforeCursor),
            textAfterCursor: try container.decodeIfPresent(String.self, forKey: .textAfterCursor),
            recentDalInputs: try container.decodeIfPresent([String].self, forKey: .recentDalInputs) ?? [],
            localeIdentifier: try container.decodeIfPresent(String.self, forKey: .localeIdentifier)
        )
    }

    func includingRecentDalInputs(_ inputs: [String]) -> WritingContext {
        WritingContext(
            applicationBundleID: applicationBundleID,
            applicationName: applicationName,
            focusedRole: focusedRole,
            scene: scene,
            level: level,
            safety: safety,
            selectedText: selectedText,
            textBeforeCursor: textBeforeCursor,
            textAfterCursor: textAfterCursor,
            recentDalInputs: inputs,
            localeIdentifier: localeIdentifier
        )
    }
}

enum VoicePolishQualityMode: String, Codable, CaseIterable, Sendable, Equatable {
    /// 当前润色固定使用标准能力；light 仅用于旧调用和历史数据兼容。
    case light
    case standard
    /// 以下值仅保留旧数据与既有管线回归兼容，生产入口按输入模式传递新档位。
    case automatic
    case fast
    case balanced
    case quality
}

enum VoicePolishRoute: String, Codable, Sendable, Equatable {
    case fast
    case structured
    case deep
}

/// Voice Polish 当前正在执行的可见阶段。只描述处理步骤，不携带用户正文。
enum VoicePolishStage: String, Sendable, Equatable {
    case polishing
    case analyzing
    case rendering
    case repairing
}

struct UserPolishPreferences: Sendable, Equatable {
    let additionalRequirements: String
    let styleProfile: StyleProfile?

    init(
        additionalRequirements: String,
        styleProfile: StyleProfile? = nil
    ) {
        self.additionalRequirements = additionalRequirements
            .removingPromptTextPlaceholder()
        self.styleProfile = styleProfile
    }
}

enum EntityCandidateSource: String, Codable, Sendable, Equatable {
    case personalLexicon
    case snippet
    case hotword
    case authorizedContext

    var priority: Int {
        switch self {
        case .personalLexicon: return 4
        case .snippet: return 3
        case .hotword: return 2
        case .authorizedContext: return 1
        }
    }
}

struct ResolvedEntity: Codable, Sendable, Equatable {
    let surfaceText: String
    let canonical: String
    let sourceSegmentIDs: [String]
    let candidateSource: EntityCandidateSource
    let confidence: Double
}

struct VoicePolishRequest: Sendable, Equatable {
    let input: VoiceInputEnvelope
    let context: WritingContext
    let preferences: UserPolishPreferences
    let qualityMode: VoicePolishQualityMode
    let resolvedEntities: [ResolvedEntity]

    init(
        input: VoiceInputEnvelope,
        context: WritingContext,
        preferences: UserPolishPreferences,
        qualityMode: VoicePolishQualityMode,
        resolvedEntities: [ResolvedEntity] = []
    ) {
        self.input = input
        self.context = context
        self.preferences = preferences
        self.qualityMode = qualityMode
        self.resolvedEntities = resolvedEntities
    }

    var fallbackText: String {
        EntityResolver.applying(resolvedEntities, to: input.fallbackText)
    }
}

struct VoicePolishResult: Sendable, Equatable {
    let text: String
    let detectedRoute: VoicePolishRoute
    let executedRoute: VoicePolishRoute
    let llmAttemptCount: Int
    let validationCodes: [VoicePolishValidationCode]
    let usedFallback: Bool
    let failureReason: VoicePolishFailureReason?
    /// 仅供显式质量跑测诊断校验拒绝原因；普通成功与请求失败均为空，且不会
    /// 写入用户历史或性能统计。
    let rejectedDraft: String?
    /// 实际尝试应用的管线局部修复；旧路径未提供时保持未知。
    let repairAttemptCount: Int?

    init(
        text: String,
        detectedRoute: VoicePolishRoute,
        executedRoute: VoicePolishRoute,
        llmAttemptCount: Int,
        validationCodes: [VoicePolishValidationCode],
        usedFallback: Bool,
        failureReason: VoicePolishFailureReason?,
        rejectedDraft: String? = nil,
        repairAttemptCount: Int? = nil
    ) {
        self.text = text
        self.detectedRoute = detectedRoute
        self.executedRoute = executedRoute
        self.llmAttemptCount = llmAttemptCount
        self.validationCodes = validationCodes
        self.usedFallback = usedFallback
        self.failureReason = failureReason
        self.rejectedDraft = rejectedDraft
        self.repairAttemptCount = repairAttemptCount
    }
}

enum VoicePolishFailureReason: String, Sendable, Equatable {
    case timeout
    case requestFailed
    case validationFailed
    case setupFailed
}

enum VoicePolishValidationCode: String, Codable, Sendable, Equatable, CaseIterable {
    case emptyOutput
    case explanationOnly
    case promptLeakage
    case missingProtectedFact
    case supersededFactRetained
    case excludedSideNoteLeaked
    case invalidStructuredResponse
    case ambiguousStructuredResponse
    case abnormalLength
    case unsafeCharacters
    case planIntegrityFailure
    case layoutRequirementUnmet
    case excessiveParagraphs
    case sceneStyleMismatch
    case harmlessRepetition
    case semanticDecisionUnverified
    case unchangedDraft

    var isHardFailure: Bool {
        switch self {
        case .excessiveParagraphs, .sceneStyleMismatch, .harmlessRepetition,
             .semanticDecisionUnverified:
            return false
        default:
            return true
        }
    }
}
