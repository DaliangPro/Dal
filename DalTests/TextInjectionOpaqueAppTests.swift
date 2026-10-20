@testable import Dal
import XCTest

final class TextInjectionOpaqueAppTests: XCTestCase {
    func testOpaqueAppsBypassFocusDetection() {
        XCTAssertTrue(TextInjectionEngine.isAXOpaqueApp("com.tencent.xinWeChat"))
        XCTAssertTrue(TextInjectionEngine.isAXOpaqueApp("com.tencent.WeWorkMac"))
        XCTAssertTrue(TextInjectionEngine.isAXOpaqueApp("com.meta.endo"))
    }

    func testRegularAppsKeepFocusDetection() {
        XCTAssertFalse(TextInjectionEngine.isAXOpaqueApp(nil))
        XCTAssertFalse(TextInjectionEngine.isAXOpaqueApp("com.apple.Safari"))
        XCTAssertFalse(TextInjectionEngine.isAXOpaqueApp("com.anthropic.claudefordesktop"))
    }
}
