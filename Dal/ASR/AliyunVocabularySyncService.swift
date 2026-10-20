import Foundation

enum AliyunVocabularySyncError: Error, LocalizedError, Equatable {
    case emptyVocabulary
    case invalidResponse
    case responseTooLarge
    case server(statusCode: Int, code: String?, message: String?)

    var errorDescription: String? {
        switch self {
        case .emptyVocabulary:
            return L("没有可同步到百炼的有效热词", "No valid hotwords to sync to Model Studio")
        case .invalidResponse:
            return L("百炼热词服务返回了无效响应", "Model Studio vocabulary service returned an invalid response")
        case .responseTooLarge:
            return L("百炼热词服务响应过大", "Model Studio vocabulary response was too large")
        case .server(let statusCode, let code, let message):
            let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = detail?.isEmpty == false
                ? detail!
                : L("百炼热词同步失败", "Model Studio vocabulary sync failed")
            let suffix = code.map { " (\($0))" } ?? " (HTTP \(statusCode))"
            return base + suffix
        }
    }
}

struct AliyunVocabularyHTTPResult: Sendable {
    let data: Data
    let statusCode: Int
}

struct AliyunVocabularyEntry: Sendable, Equatable {
    let text: String
    let weight: Int
}

struct AliyunVocabularySyncOutcome: Sendable, Equatable {
    enum Operation: Sendable, Equatable {
        case created
        case updated
    }

    let vocabularyID: String
    let operation: Operation
    let wordCount: Int
    let skippedWordCount: Int
}

struct AliyunVocabularySyncNotice: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case syncing
        case success
        case failed
    }

    let state: State
    let message: String
}

extension Notification.Name {
    static let aliyunVocabularySyncStatusDidChange = Notification.Name(
        "Dal.AliyunVocabularySyncStatusDidChange"
    )
}

struct AliyunVocabularySyncService: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> AliyunVocabularyHTTPResult

    static let defaultWeight = 5
    static let vocabularyPrefix = "dal"
    static let maximumResponseBytes = 1_048_576

    private let transport: Transport

    init(transport: @escaping Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AliyunVocabularySyncError.invalidResponse
        }
        return AliyunVocabularyHTTPResult(
            data: data,
            statusCode: httpResponse.statusCode
        )
    }) {
        self.transport = transport
    }

    func synchronize(
        config: AliyunASRConfig,
        words: [String]
    ) async throws -> AliyunVocabularySyncOutcome {
        let entries = Self.entries(from: words)
        guard !entries.isEmpty else {
            throw AliyunVocabularySyncError.emptyVocabulary
        }
        let skippedWordCount = max(0, words.count - entries.count)

        if let vocabularyID = config.vocabularyId {
            do {
                let descriptor = try await queryVocabulary(
                    vocabularyID: vocabularyID,
                    config: config
                )
                if descriptor.targetModel == config.model.rawValue {
                    try await updateVocabulary(
                        vocabularyID: vocabularyID,
                        entries: entries,
                        config: config
                    )
                    return AliyunVocabularySyncOutcome(
                        vocabularyID: vocabularyID,
                        operation: .updated,
                        wordCount: entries.count,
                        skippedWordCount: skippedWordCount
                    )
                }
            } catch let error as AliyunVocabularySyncError {
                guard error.canReplaceWithNewVocabulary else { throw error }
            }
        }

        let vocabularyID = try await createVocabulary(entries: entries, config: config)
        return AliyunVocabularySyncOutcome(
            vocabularyID: vocabularyID,
            operation: .created,
            wordCount: entries.count,
            skippedWordCount: skippedWordCount
        )
    }

    static func entries(from words: [String]) -> [AliyunVocabularyEntry] {
        var seen = Set<String>()
        var entries: [AliyunVocabularyEntry] = []
        for word in words {
            let text = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, isSupportedHotword(text) else { continue }
            let key = text.lowercased()
            guard seen.insert(key).inserted else { continue }
            entries.append(AliyunVocabularyEntry(text: text, weight: defaultWeight))
        }
        return entries
    }
}

private extension AliyunVocabularySyncService {
    struct VocabularyDescriptor {
        let targetModel: String?
    }

    static func isSupportedHotword(_ text: String) -> Bool {
        let isASCII = text.unicodeScalars.allSatisfy(\.isASCII)
        if isASCII {
            return text.split(whereSeparator: \Character.isWhitespace).count <= 7
        }
        return text.count <= 15
    }

    func queryVocabulary(
        vocabularyID: String,
        config: AliyunASRConfig
    ) async throws -> VocabularyDescriptor {
        let root = try await perform(
            input: [
                "action": "query_vocabulary",
                "vocabulary_id": vocabularyID,
            ],
            config: config
        )
        let output = root["output"] as? [String: Any]
        return VocabularyDescriptor(targetModel: output?["target_model"] as? String)
    }

    func createVocabulary(
        entries: [AliyunVocabularyEntry],
        config: AliyunASRConfig
    ) async throws -> String {
        let root = try await perform(
            input: [
                "action": "create_vocabulary",
                "target_model": config.model.rawValue,
                "prefix": Self.vocabularyPrefix,
                "vocabulary": jsonEntries(entries),
            ],
            config: config
        )
        guard let output = root["output"] as? [String: Any],
              let vocabularyID = output["vocabulary_id"] as? String,
              !vocabularyID.isEmpty
        else {
            throw AliyunVocabularySyncError.invalidResponse
        }
        return vocabularyID
    }

    func updateVocabulary(
        vocabularyID: String,
        entries: [AliyunVocabularyEntry],
        config: AliyunASRConfig
    ) async throws {
        _ = try await perform(
            input: [
                "action": "update_vocabulary",
                "vocabulary_id": vocabularyID,
                "vocabulary": jsonEntries(entries),
            ],
            config: config
        )
    }

    func perform(
        input: [String: Any],
        config: AliyunASRConfig
    ) async throws -> [String: Any] {
        var request = URLRequest(url: config.vocabularyEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Dal", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "speech-biasing",
            "input": input,
        ], options: [.sortedKeys])

        let result = try await transport(request)
        guard result.data.count <= Self.maximumResponseBytes else {
            throw AliyunVocabularySyncError.responseTooLarge
        }
        let root = (try? JSONSerialization.jsonObject(with: result.data)) as? [String: Any]
        guard (200...299).contains(result.statusCode) else {
            throw AliyunVocabularySyncError.server(
                statusCode: result.statusCode,
                code: root?["code"] as? String,
                message: root?["message"] as? String
            )
        }
        guard let root else {
            throw AliyunVocabularySyncError.invalidResponse
        }
        return root
    }

    func jsonEntries(_ entries: [AliyunVocabularyEntry]) -> [[String: Any]] {
        entries.map { ["text": $0.text, "weight": $0.weight] }
    }
}

private extension AliyunVocabularySyncError {
    var canReplaceWithNewVocabulary: Bool {
        guard case .server(let statusCode, _, _) = self else { return false }
        return statusCode == 400 || statusCode == 404
    }
}

actor AliyunVocabularySyncCoordinator {
    static let shared = AliyunVocabularySyncCoordinator()

    private var pendingTask: Task<Void, Never>?
    private let service = AliyunVocabularySyncService()

    static func schedule(after delay: Duration = .milliseconds(700)) {
        guard !KeychainService.isUsingIsolatedTestStorage else { return }
        Task {
            await shared.enqueue(after: delay)
        }
    }

    private func enqueue(after delay: Duration) {
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.synchronizeLatestHotwords()
        }
    }

    private func synchronizeLatestHotwords() async {
        guard KeychainService.selectedASRProvider == .aliyun,
              let credentials = KeychainService.loadASRCredentials(for: .aliyun),
              AliyunASRConfig(credentials: credentials) != nil
        else { return }

        let words = HotwordStorage.loadEffectiveForASR().words
        await postNotice(
            AliyunVocabularySyncNotice(
                state: .syncing,
                message: L(
                    "正在同步 Fun-ASR 与 Paraformer 热词表…",
                    "Syncing Fun-ASR and Paraformer vocabularies…"
                )
            )
        )
        var outcomes: [(AliyunASRModel, AliyunVocabularySyncOutcome)] = []
        var failures: [(AliyunASRModel, Error)] = []

        for model in AliyunASRModel.allCases {
            guard !Task.isCancelled else { return }
            var modelCredentials = credentials
            modelCredentials["model"] = model.rawValue
            guard let modelConfig = AliyunASRConfig(credentials: modelCredentials) else {
                continue
            }
            do {
                let outcome = try await service.synchronize(config: modelConfig, words: words)
                try persistVocabularyIDIfCredentialsAreCurrent(
                    outcome.vocabularyID,
                    expectedConfig: modelConfig
                )
                outcomes.append((model, outcome))
                AppLogger.log(
                    "[AliyunVocabulary] 同步成功 model=\(model.rawValue) operation=\(outcome.operation) words=\(outcome.wordCount) skipped=\(outcome.skippedWordCount) weight=\(AliyunVocabularySyncService.defaultWeight)"
                )
            } catch is CancellationError {
                return
            } catch {
                failures.append((model, error))
                AppLogger.log(
                    "[AliyunVocabulary] 同步失败 model=\(model.rawValue): \(error.localizedDescription)"
                )
            }
        }

        if failures.isEmpty, let outcome = outcomes.first?.1 {
            let skippedSuffix = outcome.skippedWordCount > 0
                ? L("，跳过 \(outcome.skippedWordCount) 个超长词", ", skipped \(outcome.skippedWordCount) overlong words")
                : ""
            await postNotice(
                AliyunVocabularySyncNotice(
                    state: .success,
                    message: L(
                        "两个模型已同步 \(outcome.wordCount) 个热词，权重 5\(skippedSuffix)",
                        "Synced \(outcome.wordCount) hotwords to both models at weight 5\(skippedSuffix)"
                    )
                )
            )
        } else if let failure = failures.first {
            let succeededSuffix = outcomes.isEmpty
                ? ""
                : L("（另一模型已同步）", " (the other model synced)")
            await postNotice(
                AliyunVocabularySyncNotice(
                    state: .failed,
                    message: L(
                        "\(failure.0.displayName) 热词同步失败：\(failure.1.localizedDescription)\(succeededSuffix)",
                        "\(failure.0.displayName) vocabulary sync failed: \(failure.1.localizedDescription)\(succeededSuffix)"
                    )
                )
            )
        }
    }

    private func postNotice(_ notice: AliyunVocabularySyncNotice) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .aliyunVocabularySyncStatusDidChange,
                object: notice
            )
        }
    }

    private func persistVocabularyIDIfCredentialsAreCurrent(
        _ vocabularyID: String,
        expectedConfig: AliyunASRConfig
    ) throws {
        guard var latestCredentials = KeychainService.loadASRCredentials(for: .aliyun),
              let latestConfig = AliyunASRConfig(credentials: latestCredentials),
              latestConfig.apiKey == expectedConfig.apiKey,
              latestConfig.workspaceId == expectedConfig.workspaceId
        else { return }
        let key = expectedConfig.model.vocabularyCredentialKey
        let needsDefaultModelMigration = latestCredentials["model"] == nil
        guard latestCredentials[key] != vocabularyID || needsDefaultModelMigration else { return }

        latestCredentials[key] = vocabularyID
        if needsDefaultModelMigration {
            latestCredentials["model"] = AliyunASRModel.defaultModel.rawValue
        }
        try KeychainService.saveASRCredentials(for: .aliyun, values: latestCredentials)
    }
}
