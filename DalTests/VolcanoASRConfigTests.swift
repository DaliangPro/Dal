import XCTest
@testable import Dal

final class VolcanoASRConfigTests: XCTestCase {
    func testConfigRejectsMaskedCredentials() {
        XCTAssertNil(VolcanoASRConfig(credentials: [
            "appKey": "7210869106",
            "accessKey": "5P_t••••M4tC",
            "resourceId": VolcanoASRConfig.resourceIdAuto,
        ]))

        XCTAssertNil(VolcanoASRConfig(credentials: [
            "appKey": "5P_t••••M4tC",
            "accessKey": "real_access_token",
            "resourceId": VolcanoASRConfig.resourceIdAuto,
        ]))
    }

    func testConfigTrimsCredentials() throws {
        let config = try XCTUnwrap(VolcanoASRConfig(credentials: [
            "appKey": "  app_id  ",
            "accessKey": "  access_token  ",
            "resourceId": VolcanoASRConfig.resourceIdBigASR,
        ]))

        XCTAssertEqual(config.appKey, "app_id")
        XCTAssertEqual(config.accessKey, "access_token")
        XCTAssertEqual(config.resourceId, VolcanoASRConfig.resourceIdBigASR)
    }
}
