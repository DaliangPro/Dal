import Foundation

// MARK: - Models

enum UpdateArtifactKind: String, Codable, Equatable, Sendable {
    case cloud
    case local
}

struct UpdateArtifact: Codable, Equatable, Sendable {
    let url: String?
    let sha256: String?
}

struct UpdateArtifacts: Codable, Equatable, Sendable {
    let cloud: UpdateArtifact?
    let local: UpdateArtifact?

    subscript(kind: UpdateArtifactKind) -> UpdateArtifact? {
        switch kind {
        case .cloud: cloud
        case .local: local
        }
    }
}

struct ResolvedUpdateArtifact: Equatable, Sendable {
    let kind: UpdateArtifactKind
    let url: URL
    let sha256: String
}

enum UpdateArtifactResolutionError: LocalizedError, Equatable {
    case invalidVersion
    case missingArtifact(UpdateArtifactKind)
    case invalidURL(UpdateArtifactKind)
    case missingSHA256(UpdateArtifactKind)
    case invalidSHA256(UpdateArtifactKind)

    var errorDescription: String? {
        switch self {
        case .invalidVersion:
            "更新清单中的版本号格式无效。"
        case .missingArtifact(let kind):
            "更新清单缺少 \(kind.rawValue) 制品。"
        case .invalidURL(let kind):
            "更新清单中的 \(kind.rawValue) 制品 URL 无效或不安全。"
        case .missingSHA256(let kind):
            "更新清单中的 \(kind.rawValue) 制品缺少 SHA256。"
        case .invalidSHA256(let kind):
            "更新清单中的 \(kind.rawValue) 制品 SHA256 格式无效。"
        }
    }
}

struct UpdateInfo: Codable, Identifiable, Equatable, Sendable {
    let version: String
    let date: String
    let notes: String
    let artifacts: UpdateArtifacts

    var id: String { version }

    func resolvedArtifact(isLocalInstallation: Bool) throws -> ResolvedUpdateArtifact {
        let versionParts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !versionParts.isEmpty,
              versionParts.allSatisfy({ part in
                  !part.isEmpty
                      && part.utf8.allSatisfy { (48...57).contains($0) }
                      && Int(part) != nil
              }) else {
            throw UpdateArtifactResolutionError.invalidVersion
        }

        let kind: UpdateArtifactKind = isLocalInstallation ? .local : .cloud
        guard let artifact = artifacts[kind] else {
            throw UpdateArtifactResolutionError.missingArtifact(kind)
        }

        let rawURL = artifact.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: rawURL),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil,
              url.path.lowercased().hasSuffix(".dmg") else {
            throw UpdateArtifactResolutionError.invalidURL(kind)
        }

        let sha256 = artifact.sha256?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sha256.isEmpty else {
            throw UpdateArtifactResolutionError.missingSHA256(kind)
        }
        guard sha256.count == 64, sha256.allSatisfy({ $0.hexDigitValue != nil }) else {
            throw UpdateArtifactResolutionError.invalidSHA256(kind)
        }

        return ResolvedUpdateArtifact(kind: kind, url: url, sha256: sha256.lowercased())
    }
}

struct UpdateManifest: Codable, Equatable, Sendable {
    let latest: String
    let releases: [UpdateInfo]
}

// MARK: - Update Checker

@MainActor
final class UpdateChecker {

    static let shared = UpdateChecker()

    private let url = URL(string: "https://raw.githubusercontent.com/DaliangPro/Dal/main/updates.json")!
    private let checkIntervalKey = "tf_lastUpdateCheck"
    private let seenVersionKey = "tf_lastSeenVersion"
    private let checkInterval: TimeInterval = 24 * 60 * 60 // 24 hours
    private var timer: Timer?

    /// 更新通道开关（REPAIR_PLAN A1）：URL 已指向本项目新仓库 DaliangPro/Dal，
    /// 但在新仓库建立并发布首个版本（含 updates.json）之前保持下线，
    /// 防止任何外部源向用户推送安装包。发布体系就绪后改回 true。
    static let updateChannelEnabled = false

    private init() {}

    // MARK: - Public

    /// Start periodic checking: immediate check + 24h timer.
    func startPeriodicChecking(appState: AppState) {
        guard Self.updateChannelEnabled else {
            AppLogger.log("[UpdateChecker] 更新通道已下线（见 REPAIR_PLAN A1），跳过检查")
            return
        }
        Task {
            await check(appState: appState)
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.check(appState: appState)
            }
        }
    }

    /// Mark the latest available version as "seen" so the red badge clears.
    func markAsSeen(appState: AppState) {
        guard let latest = appState.availableUpdates.first else { return }
        UserDefaults.standard.set(latest.version, forKey: seenVersionKey)
        appState.hasUnseenUpdate = false
    }

    var lastSeenVersion: String {
        UserDefaults.standard.string(forKey: seenVersionKey) ?? currentVersion
    }

    // MARK: - Private

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Check with 24h cooldown.
    private func check(appState: AppState) async {
        let lastCheck = UserDefaults.standard.double(forKey: checkIntervalKey)
        let now = Date().timeIntervalSince1970
        if lastCheck > 0 && (now - lastCheck) < checkInterval {
            return
        }
        await fetch(appState: appState)
    }

    private func fetch(appState: AppState) async {
        // 双保险：除定时入口外，任何手动触发路径同样被通道开关拦截
        guard Self.updateChannelEnabled else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: checkIntervalKey)

            let current = currentVersion
            let newer = manifest.releases
                .filter { compareVersions($0.version, isGreaterThan: current) }
                .sorted { compareVersions($0.version, isGreaterThan: $1.version) }

            appState.availableUpdates = newer

            if let latest = newer.first {
                appState.hasUnseenUpdate = compareVersions(latest.version, isGreaterThan: lastSeenVersion)
            } else {
                appState.hasUnseenUpdate = false
            }
        } catch {
            AppLogger.log("[UpdateChecker] fetch failed: \(error)")
        }
    }

    /// Semantic version comparison: "1.2.0" > "1.1.0"
    private func compareVersions(_ a: String, isGreaterThan b: String) -> Bool {
        let partsA = a.split(separator: ".").compactMap { Int($0) }
        let partsB = b.split(separator: ".").compactMap { Int($0) }
        let count = max(partsA.count, partsB.count)
        for i in 0..<count {
            let va = i < partsA.count ? partsA[i] : 0
            let vb = i < partsB.count ? partsB[i] : 0
            if va != vb { return va > vb }
        }
        return false
    }
}
