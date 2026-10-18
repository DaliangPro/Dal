import Foundation
import XCTest
@testable import Muse

final class UpdateManifestTests: XCTestCase {
    func testCloudInstallationSelectsCloudArtifact() throws {
        let release = try decodeRelease(artifactsJSON: completeArtifactsJSON)

        let selected = try release.resolvedArtifact(isLocalInstallation: false)

        XCTAssertEqual(selected.kind, .cloud)
        XCTAssertEqual(selected.url.absoluteString, "https://updates.example/Muse-v2.0.0-cloud.dmg")
        XCTAssertEqual(selected.sha256, String(repeating: "a", count: 64))
    }

    func testLocalInstallationSelectsLocalArtifact() throws {
        let release = try decodeRelease(artifactsJSON: completeArtifactsJSON)

        let selected = try release.resolvedArtifact(isLocalInstallation: true)

        XCTAssertEqual(selected.kind, .local)
        XCTAssertEqual(selected.url.absoluteString, "https://updates.example/Muse-v2.0.0-local.dmg")
        XCTAssertEqual(selected.sha256, String(repeating: "b", count: 64))
    }

    func testMissingSelectedArtifactIsRejectedWithVariantName() throws {
        let release = try decodeRelease(
            artifactsJSON: #"{"cloud":{"url":"https://updates.example/cloud.dmg","sha256":"\#(String(repeating: "a", count: 64))"}}"#
        )

        XCTAssertThrowsError(try release.resolvedArtifact(isLocalInstallation: true)) { error in
            XCTAssertTrue(error.localizedDescription.lowercased().contains("local"), error.localizedDescription)
        }
    }

    func testMissingOrBlankSHA256IsRejected() throws {
        for shaJSON in ["null", "\"\"", "\"   \""] {
            let release = try decodeRelease(
                artifactsJSON: #"{"cloud":{"url":"https://updates.example/cloud.dmg","sha256":\#(shaJSON)}}"#
            )

            XCTAssertThrowsError(try release.resolvedArtifact(isLocalInstallation: false), shaJSON)
        }
    }

    func testMalformedSHA256IsRejected() throws {
        let release = try decodeRelease(
            artifactsJSON: #"{"cloud":{"url":"https://updates.example/cloud.dmg","sha256":"abc123"}}"#
        )

        XCTAssertThrowsError(try release.resolvedArtifact(isLocalInstallation: false))
    }

    func testInvalidOrInsecureURLIsRejectedWithoutFallback() throws {
        for url in ["not a url", "http://updates.example/cloud.dmg", ""] {
            let release = try decodeRelease(
                artifactsJSON: #"{"cloud":{"url":"\#(url)","sha256":"\#(String(repeating: "a", count: 64))"}}"#
            )

            XCTAssertThrowsError(try release.resolvedArtifact(isLocalInstallation: false), url)
        }
    }

    func testMalformedReleaseVersionIsRejectedBeforeCreatingDownloadPath() throws {
        let release = try decodeRelease(
            version: "../2.0.0",
            artifactsJSON: completeArtifactsJSON
        )

        XCTAssertThrowsError(try release.resolvedArtifact(isLocalInstallation: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("版本"), error.localizedDescription)
        }
    }

    func testLegacyFlatArtifactSchemaIsNotSilentlyAccepted() {
        let legacy = """
        {
          "version": "2.0.0",
          "date": "2026-07-21",
          "notes": "fixture",
          "cloud_dmg_url": "https://updates.example/cloud.dmg",
          "cloud_dmg_sha256": "\(String(repeating: "a", count: 64))"
        }
        """

        XCTAssertThrowsError(try JSONDecoder().decode(UpdateInfo.self, from: Data(legacy.utf8)))
    }

    func testRepositoryManifestAndDualArtifactFixtureDecode() throws {
        let repositoryManifest = try Data(contentsOf: repositoryRoot.appendingPathComponent("updates.json"))
        let decodedRepository = try JSONDecoder().decode(UpdateManifest.self, from: repositoryManifest)
        XCTAssertEqual(decodedRepository.latest, "2.1.0")

        let fixture = """
        {
          "latest": "2.0.0",
          "releases": [
            {
              "version": "2.0.0",
              "date": "2026-07-21",
              "notes": "fixture",
              "artifacts": \(completeArtifactsJSON)
            }
          ]
        }
        """
        let decodedFixture = try JSONDecoder().decode(UpdateManifest.self, from: Data(fixture.utf8))
        XCTAssertEqual(decodedFixture.releases.count, 1)
        XCTAssertNoThrow(try decodedFixture.releases[0].resolvedArtifact(isLocalInstallation: false))
        XCTAssertNoThrow(try decodedFixture.releases[0].resolvedArtifact(isLocalInstallation: true))
    }

    @MainActor
    func testAutomaticUpdateChannelRemainsDisabled() {
        XCTAssertFalse(UpdateChecker.updateChannelEnabled)
    }

    private var completeArtifactsJSON: String {
        """
        {
          "cloud": {
            "url": "https://updates.example/Muse-v2.0.0-cloud.dmg",
            "sha256": "\(String(repeating: "a", count: 64))"
          },
          "local": {
            "url": "https://updates.example/Muse-v2.0.0-local.dmg",
            "sha256": "\(String(repeating: "b", count: 64))"
          }
        }
        """
    }

    private func decodeRelease(
        version: String = "2.0.0",
        artifactsJSON: String
    ) throws -> UpdateInfo {
        let json = """
        {
          "version": "\(version)",
          "date": "2026-07-21",
          "notes": "fixture",
          "artifacts": \(artifactsJSON)
        }
        """
        return try JSONDecoder().decode(UpdateInfo.self, from: Data(json.utf8))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
