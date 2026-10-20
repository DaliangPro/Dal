import AppKit
import XCTest
@testable import Dal

final class SettingsWindowPresenterTests: XCTestCase {
    @MainActor
    func testOpenBeforeSceneActionIsReadyQueuesOnlyOneOpen() async {
        _ = NSApplication.shared
        let presenter = AppWindowPresenter(windowID: "settings")
        var calls = 0
        presenter.open()
        presenter.open()
        XCTAssertEqual(calls, 0)
        presenter.register { calls += 1 }
        XCTAssertEqual(calls, 1)
        presenter.register { calls += 1 }
        XCTAssertEqual(calls, 1)
        presenter.open()
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func test首次引导在动作注册前请求也只打开一次() {
        _ = NSApplication.shared
        let presenter = AppWindowPresenter(windowID: "setup")
        var calls = 0
        AppStartupCoordinator.showSetupWizardIfNeeded(
            hasCompletedSetup: false,
            openSetupWindow: presenter.open
        )
        presenter.open()
        XCTAssertEqual(calls, 0)

        presenter.register { calls += 1 }
        XCTAssertEqual(calls, 1)
        presenter.register { calls += 1 }
        XCTAssertEqual(calls, 1)
        presenter.open()
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func test完成引导后不自动打开但仍可手动打开() {
        _ = NSApplication.shared
        let presenter = AppWindowPresenter(windowID: "setup")
        var calls = 0
        presenter.register { calls += 1 }
        AppStartupCoordinator.showSetupWizardIfNeeded(
            hasCompletedSetup: true,
            openSetupWindow: presenter.open
        )
        XCTAssertEqual(calls, 0)
        presenter.open()
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func test设置和引导分别使用各自的场景动作() {
        _ = NSApplication.shared
        let settings = AppWindowPresenter(windowID: "settings")
        let setup = AppWindowPresenter(windowID: "setup")
        var opened: [String] = []
        settings.register { opened.append("settings") }
        setup.register { opened.append("setup") }
        setup.open()
        settings.open()
        setup.open()
        XCTAssertEqual(opened, ["setup", "settings", "setup"])
    }
}
