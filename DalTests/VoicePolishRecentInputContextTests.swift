import XCTest
@testable import Dal

final class VoicePolishRecentInputContextTests: XCTestCase {
    func testRecentInputsAreMemoryOnlyBoundedAndApplicationIsolated() async {
        let store = VoicePolishRecentInputContextStore(
            maximumEntriesPerApplication: 3,
            timeToLive: 900
        )
        let now = Date(timeIntervalSince1970: 10_000)
        for index in 1...4 {
            await store.remember(
                "输入 \(index)",
                applicationBundleID: "com.example.chat",
                at: now.addingTimeInterval(Double(index))
            )
        }
        await store.remember(
            "另一应用",
            applicationBundleID: "com.example.mail",
            at: now.addingTimeInterval(5)
        )

        let chat = await store.recentInputs(
            applicationBundleID: "COM.EXAMPLE.CHAT",
            at: now.addingTimeInterval(6)
        )
        let mail = await store.recentInputs(
            applicationBundleID: "com.example.mail",
            at: now.addingTimeInterval(6)
        )

        XCTAssertEqual(chat, ["输入 2", "输入 3", "输入 4"])
        XCTAssertEqual(mail, ["另一应用"])
        XCTAssertFalse(chat.contains("另一应用"))
    }

    func testRecentInputsExpireAndRequireKnownApplication() async {
        let store = VoicePolishRecentInputContextStore(
            maximumEntriesPerApplication: 3,
            timeToLive: 60
        )
        let now = Date(timeIntervalSince1970: 20_000)
        await store.remember("旧输入", applicationBundleID: "com.example.chat", at: now)
        await store.remember("不能归属", applicationBundleID: nil, at: now)

        let expired = await store.recentInputs(
            applicationBundleID: "com.example.chat",
            at: now.addingTimeInterval(61)
        )
        let unknown = await store.recentInputs(applicationBundleID: nil, at: now)

        XCTAssertTrue(expired.isEmpty)
        XCTAssertTrue(unknown.isEmpty)
    }

    func testWritingContextCarriesOnlyExplicitlyInjectedRecentInputs() throws {
        let base = WritingContext(
            applicationBundleID: "com.example.chat",
            scene: .chat,
            level: .metadataOnly,
            safety: .unknown
        )
        XCTAssertTrue(base.recentDalInputs.isEmpty)

        let enriched = base.includingRecentDalInputs(["上一条消息"])
        XCTAssertEqual(enriched.recentDalInputs, ["上一条消息"])
    }
}
