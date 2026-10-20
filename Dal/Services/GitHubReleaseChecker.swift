import Foundation
import Observation

enum GitHubReleaseCheckState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(installedVersion: String, latestVersion: String)
    case aheadOfRelease(installedVersion: String, latestVersion: String)
    case versionMismatch(
        installedVersion: String,
        latestVersion: String,
        releaseURL: URL
    )
    case failed(message: String)

    var isChecking: Bool {
        self == .checking
    }
}

struct DalSemanticVersion: Comparable, Sendable {
    let displayValue: String
    private let components: [Int]

    init?(_ rawValue: String) {
        var normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.first == "v" || normalized.first == "V" {
            normalized.removeFirst()
        }
        guard !normalized.isEmpty, normalized.count <= 64 else { return nil }

        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 8 else { return nil }

        var parsed: [Int] = []
        parsed.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part)
            else { return nil }
            parsed.append(value)
        }
        while parsed.count > 1, parsed.last == 0 {
            parsed.removeLast()
        }

        displayValue = normalized
        components = parsed
    }

    static func == (lhs: DalSemanticVersion, rhs: DalSemanticVersion) -> Bool {
        lhs.components == rhs.components
    }

    static func < (lhs: DalSemanticVersion, rhs: DalSemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

struct GitHubLatestRelease: Equatable, Sendable {
    let version: String
    let releaseURL: URL

    init(finalURL: URL) throws {
        guard finalURL.scheme?.lowercased() == "https",
              finalURL.host?.lowercased() == "github.com",
              finalURL.user == nil,
              finalURL.password == nil,
              finalURL.port == nil || finalURL.port == 443
        else {
            throw GitHubReleaseCheckError.invalidReleaseURL
        }

        let path = finalURL.pathComponents.filter { $0 != "/" }
        guard path.count == 5,
              path[0].lowercased() == "daliangpro",
              path[1].lowercased() == "dal",
              path[2].lowercased() == "releases",
              path[3].lowercased() == "tag",
              let tag = path[4].removingPercentEncoding,
              let parsedVersion = DalSemanticVersion(tag)
        else {
            throw GitHubReleaseCheckError.invalidReleaseURL
        }

        version = parsedVersion.displayValue
        releaseURL = URL(string: "https://github.com/DaliangPro/Dal/releases/tag")!
            .appendingPathComponent(tag, isDirectory: false)
    }
}

enum GitHubReleaseCheckError: LocalizedError, Equatable {
    case invalidInstalledVersion
    case invalidReleaseURL
    case noPublishedRelease
    case temporarilyLimited(retryAfter: TimeInterval?)
    case requestFailed(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidInstalledVersion:
            return L("当前安装版本号格式无效", "The installed version number is invalid")
        case .invalidReleaseURL:
            return L(
                "无法识别 GitHub 返回的最新版本",
                "The latest version returned by GitHub could not be recognized"
            )
        case .noPublishedRelease:
            return L(
                "GitHub 上还没有正式发布版本",
                "No published release is available on GitHub"
            )
        case .temporarilyLimited:
            return L(
                "GitHub 暂时限制访问，请稍后再试",
                "GitHub temporarily limited access. Please try again later."
            )
        case .requestFailed(let statusCode):
            return L(
                "GitHub 返回异常状态（\(statusCode)）",
                "GitHub returned an unexpected status (\(statusCode))"
            )
        case .invalidResponse:
            return L("GitHub 返回了无效响应", "GitHub returned an invalid response")
        }
    }
}

enum GitHubLatestReleaseEndpoint {
    /// 使用 GitHub 普通网页的 Latest Release 重定向，不调用受未认证额度限制的 REST API。
    static let latestReleaseURL = URL(
        string: "https://github.com/DaliangPro/Dal/releases/latest"
    )!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    static func fetch() async throws -> GitHubLatestRelease {
        do {
            return try await request(method: "HEAD")
        } catch GitHubReleaseCheckError.requestFailed(let statusCode)
            where statusCode == 405 || statusCode == 501 {
            // 极少数代理不支持 HEAD；只在明确的方法不支持时退回一次轻量 GET。
            return try await request(method: "GET")
        }
    }

    private static func request(method: String) async throws -> GitHubLatestRelease {
        var request = URLRequest(url: latestReleaseURL)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("Dal-Update-Checker/2.0", forHTTPHeaderField: "User-Agent")
        if method == "GET" {
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        }

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubReleaseCheckError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            guard let finalURL = http.url else {
                throw GitHubReleaseCheckError.invalidResponse
            }
            return try GitHubLatestRelease(finalURL: finalURL)
        case 404:
            throw GitHubReleaseCheckError.noPublishedRelease
        case 403, 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
            throw GitHubReleaseCheckError.temporarilyLimited(
                retryAfter: retryAfter
            )
        default:
            throw GitHubReleaseCheckError.requestFailed(http.statusCode)
        }
    }
}

@Observable
@MainActor
final class GitHubReleaseChecker {
    typealias FetchLatest = @Sendable () async throws -> GitHubLatestRelease

    static let shared = GitHubReleaseChecker()

    private(set) var state: GitHubReleaseCheckState = .idle

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let currentVersion: () -> String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let fetchLatest: FetchLatest
    @ObservationIgnored private let successCacheLifetime: TimeInterval
    @ObservationIgnored private let failureCooldown: TimeInterval
    @ObservationIgnored private var lastAttemptAt: Date?
    @ObservationIgnored private var retryBlockedUntil: Date?

    private let cacheKey = "tf_githubLatestReleaseCacheV1"

    init(
        userDefaults: UserDefaults = .standard,
        currentVersion: @escaping () -> String = {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        },
        now: @escaping () -> Date = { Date() },
        successCacheLifetime: TimeInterval = 5 * 60,
        failureCooldown: TimeInterval = 10,
        fetchLatest: @escaping FetchLatest = {
            try await GitHubLatestReleaseEndpoint.fetch()
        }
    ) {
        self.userDefaults = userDefaults
        self.currentVersion = currentVersion
        self.now = now
        self.successCacheLifetime = successCacheLifetime
        self.failureCooldown = failureCooldown
        self.fetchLatest = fetchLatest
    }

    func checkForUpdates() async {
        guard !state.isChecking else { return }

        let installedRaw = currentVersion()
        guard let installed = DalSemanticVersion(installedRaw) else {
            state = .failed(
                message: GitHubReleaseCheckError.invalidInstalledVersion.localizedDescription
            )
            return
        }

        let currentDate = now()
        if let cached = cachedRelease(at: currentDate) {
            apply(release: cached, installed: installed)
            return
        }

        if let retryBlockedUntil, currentDate < retryBlockedUntil {
            return
        }

        if let lastAttemptAt,
           currentDate.timeIntervalSince(lastAttemptAt) >= 0,
           currentDate.timeIntervalSince(lastAttemptAt) < failureCooldown {
            return
        }

        state = .checking
        lastAttemptAt = currentDate
        do {
            let release = try await fetchLatest()
            retryBlockedUntil = nil
            saveCache(release: release, checkedAt: currentDate)
            apply(release: release, installed: installed)
        } catch is CancellationError {
            state = .idle
        } catch let error as URLError {
            AppLogger.log("[GitHubReleaseChecker] 网络检查失败: \(error.code.rawValue)")
            state = .failed(message: L(
                "无法连接 GitHub，请检查网络后重试",
                "Could not connect to GitHub. Check your network and try again."
            ))
        } catch let error as GitHubReleaseCheckError {
            if case .temporarilyLimited(let retryAfter) = error {
                // GitHub 对 403/429 要求遵守 Retry-After；缺失时至少等待一分钟。
                retryBlockedUntil = currentDate.addingTimeInterval(
                    max(60, retryAfter ?? 60)
                )
            }
            AppLogger.log("[GitHubReleaseChecker] 检查失败: \(error.localizedDescription)")
            state = .failed(message: error.localizedDescription)
        } catch {
            AppLogger.log("[GitHubReleaseChecker] 检查失败: \(error.localizedDescription)")
            state = .failed(message: error.localizedDescription)
        }
    }

    private func apply(
        release: GitHubLatestRelease,
        installed: DalSemanticVersion
    ) {
        guard let latest = DalSemanticVersion(release.version) else {
            state = .failed(
                message: GitHubReleaseCheckError.invalidReleaseURL.localizedDescription
            )
            return
        }

        if installed == latest {
            state = .upToDate(
                installedVersion: installed.displayValue,
                latestVersion: latest.displayValue
            )
        } else if latest < installed {
            state = .aheadOfRelease(
                installedVersion: installed.displayValue,
                latestVersion: latest.displayValue
            )
        } else {
            state = .versionMismatch(
                installedVersion: installed.displayValue,
                latestVersion: latest.displayValue,
                releaseURL: release.releaseURL
            )
        }
    }

    private struct CacheRecord: Codable {
        let checkedAt: TimeInterval
        let version: String
        let releaseURL: String
    }

    private func cachedRelease(at date: Date) -> GitHubLatestRelease? {
        guard let data = userDefaults.data(forKey: cacheKey),
              let record = try? JSONDecoder().decode(CacheRecord.self, from: data)
        else { return nil }

        let age = date.timeIntervalSince1970 - record.checkedAt
        guard age >= 0, age < successCacheLifetime,
              let url = URL(string: record.releaseURL),
              let release = try? GitHubLatestRelease(finalURL: url),
              DalSemanticVersion(record.version) == DalSemanticVersion(release.version)
        else {
            userDefaults.removeObject(forKey: cacheKey)
            return nil
        }
        return release
    }

    private func saveCache(
        release: GitHubLatestRelease,
        checkedAt: Date
    ) {
        let record = CacheRecord(
            checkedAt: checkedAt.timeIntervalSince1970,
            version: release.version,
            releaseURL: release.releaseURL.absoluteString
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        userDefaults.set(data, forKey: cacheKey)
    }
}
