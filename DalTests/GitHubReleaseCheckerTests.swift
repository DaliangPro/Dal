import Foundation
import XCTest
@testable import Dal

@MainActor
final class GitHubReleaseCheckerTests: XCTestCase {

    private actor FetchCounter {
        private var count = 0
        private let release: GitHubLatestRelease

        init(release: GitHubLatestRelease) {
            self.release = release
        }

        func fetch() -> GitHubLatestRelease {
            count += 1
            return release
        }

        func fetch(after delay: Duration) async -> GitHubLatestRelease {
            count += 1
            try? await Task.sleep(for: delay)
            return release
        }

        func value() -> Int {
            count
        }
    }

    private actor LimitedFetchCounter {
        private var count = 0

        func fetch() throws -> GitHubLatestRelease {
            count += 1
            throw GitHubReleaseCheckError.temporarilyLimited(retryAfter: nil)
        }

        func value() -> Int {
            count
        }
    }

    private final class TestClock {
        var date: Date

        init(date: Date) {
            self.date = date
        }
    }

    func testLatestReleaseRedirectParsesOfficialTag() throws {
        let release = try GitHubLatestRelease(
            finalURL: XCTUnwrap(
                URL(string: "https://github.com/DaliangPro/Dal/releases/tag/v2.3.0")
            )
        )

        XCTAssertEqual(release.version, "2.3.0")
        XCTAssertEqual(
            release.releaseURL.absoluteString,
            "https://github.com/DaliangPro/Dal/releases/tag/v2.3.0"
        )
    }

    func testLatestReleaseRedirectRejectsOtherHostsRepositoriesAndMalformedTags() throws {
        let invalidURLs = [
            "https://example.com/DaliangPro/Dal/releases/tag/v2.3.0",
            "https://github.com/Other/Dal/releases/tag/v2.3.0",
            "https://github.com/DaliangPro/Dal/releases/tag/latest",
            "http://github.com/DaliangPro/Dal/releases/tag/v2.3.0",
        ]

        for rawURL in invalidURLs {
            XCTAssertThrowsError(
                try GitHubLatestRelease(finalURL: XCTUnwrap(URL(string: rawURL))),
                rawURL
            )
        }
    }

    func testSemanticVersionsIgnoreVPrefixAndTrailingZeroComponents() throws {
        XCTAssertEqual(
            try XCTUnwrap(DalSemanticVersion("v2.0")),
            try XCTUnwrap(DalSemanticVersion("2.0.0"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(DalSemanticVersion("2.0.9")),
            try XCTUnwrap(DalSemanticVersion("2.1.0"))
        )
        XCTAssertNil(DalSemanticVersion("2.0-beta"))
    }

    func testCheckerReportsMatchingAndDifferentVersions() async throws {
        let release = try GitHubLatestRelease(
            finalURL: XCTUnwrap(
                URL(string: "https://github.com/DaliangPro/Dal/releases/tag/v2.1.0")
            )
        )

        let currentDefaults = makeIsolatedDefaults()
        defer { currentDefaults.cleanup() }
        let currentChecker = GitHubReleaseChecker(
            userDefaults: currentDefaults.defaults,
            currentVersion: { "2.1.0" },
            fetchLatest: { release }
        )
        await currentChecker.checkForUpdates()
        XCTAssertEqual(
            currentChecker.state,
            .upToDate(installedVersion: "2.1.0", latestVersion: "2.1.0")
        )

        let oldDefaults = makeIsolatedDefaults()
        defer { oldDefaults.cleanup() }
        let oldChecker = GitHubReleaseChecker(
            userDefaults: oldDefaults.defaults,
            currentVersion: { "2.0.0" },
            fetchLatest: { release }
        )
        await oldChecker.checkForUpdates()
        XCTAssertEqual(
            oldChecker.state,
            .versionMismatch(
                installedVersion: "2.0.0",
                latestVersion: "2.1.0",
                releaseURL: release.releaseURL
            )
        )
    }

    func testDalRenameBuildDoesNotOfferDowngradeToOldRelease() async throws {
        let release = try GitHubLatestRelease(finalURL: XCTUnwrap(
            URL(string: "https://github.com/DaliangPro/Dal/releases/tag/v2.1.2")))
        let storage = makeIsolatedDefaults()
        defer { storage.cleanup() }
        let checker = GitHubReleaseChecker(
            userDefaults: storage.defaults,
            currentVersion: { "2.2.0" },
            fetchLatest: { release }
        )
        await checker.checkForUpdates()
        XCTAssertEqual(checker.state, .aheadOfRelease(
            installedVersion: "2.2.0", latestVersion: "2.1.2"))
    }

    func testSuccessfulResultIsCachedAcrossRepeatedChecksAndCheckerInstances() async throws {
        let release = try GitHubLatestRelease(
            finalURL: XCTUnwrap(
                URL(string: "https://github.com/DaliangPro/Dal/releases/tag/v2.1.0")
            )
        )
        let counter = FetchCounter(release: release)
        let storage = makeIsolatedDefaults()
        defer { storage.cleanup() }
        let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

        let first = GitHubReleaseChecker(
            userDefaults: storage.defaults,
            currentVersion: { "2.0.0" },
            now: { fixedDate },
            fetchLatest: { await counter.fetch() }
        )
        await first.checkForUpdates()
        await first.checkForUpdates()

        let second = GitHubReleaseChecker(
            userDefaults: storage.defaults,
            currentVersion: { "2.0.0" },
            now: { fixedDate.addingTimeInterval(60) },
            fetchLatest: { await counter.fetch() }
        )
        await second.checkForUpdates()

        let fetchCount = await counter.value()
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(first.state, second.state)
    }

    func testConcurrentClicksShareSingleInFlightCheck() async throws {
        let release = try GitHubLatestRelease(
            finalURL: XCTUnwrap(
                URL(string: "https://github.com/DaliangPro/Dal/releases/tag/v2.1.0")
            )
        )
        let counter = FetchCounter(release: release)
        let storage = makeIsolatedDefaults()
        defer { storage.cleanup() }
        let checker = GitHubReleaseChecker(
            userDefaults: storage.defaults,
            currentVersion: { "2.0.0" },
            fetchLatest: {
                await counter.fetch(after: .milliseconds(80))
            }
        )

        let firstCheck = Task { @MainActor in
            await checker.checkForUpdates()
        }
        await Task.yield()
        XCTAssertEqual(checker.state, .checking)

        await checker.checkForUpdates()
        await firstCheck.value

        let fetchCount = await counter.value()
        XCTAssertEqual(fetchCount, 1)
    }

    func testRateLimitResponseBlocksRetriesForAtLeastOneMinute() async {
        let counter = LimitedFetchCounter()
        let storage = makeIsolatedDefaults()
        defer { storage.cleanup() }
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_800_000_000))
        let checker = GitHubReleaseChecker(
            userDefaults: storage.defaults,
            currentVersion: { "2.0.0" },
            now: { clock.date },
            failureCooldown: 10,
            fetchLatest: { try await counter.fetch() }
        )

        await checker.checkForUpdates()
        clock.date = clock.date.addingTimeInterval(30)
        await checker.checkForUpdates()
        let countBeforeRetryWindow = await counter.value()
        XCTAssertEqual(countBeforeRetryWindow, 1)

        clock.date = clock.date.addingTimeInterval(31)
        await checker.checkForUpdates()
        let countAfterRetryWindow = await counter.value()
        XCTAssertEqual(countAfterRetryWindow, 2)
    }

    func testDefaultEndpointAvoidsGitHubRESTAPI() {
        XCTAssertEqual(
            GitHubLatestReleaseEndpoint.latestReleaseURL.absoluteString,
            "https://github.com/DaliangPro/Dal/releases/latest"
        )
        XCTAssertNotEqual(
            GitHubLatestReleaseEndpoint.latestReleaseURL.host,
            "api.github.com"
        )
    }

    private func makeIsolatedDefaults() -> (
        defaults: UserDefaults,
        cleanup: () -> Void
    ) {
        let suiteName = "DalTests.GitHubReleaseChecker.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (
            defaults,
            {
                defaults.removePersistentDomain(forName: suiteName)
            }
        )
    }
}
