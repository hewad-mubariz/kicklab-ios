import XCTest

final class ReleaseCandidateUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testCombinedHomeSettingsAndLeaderboard() {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES", "--leaderboard-review-count", "3"]
        app.launch()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 15))
        attach(app, "Combined 1.2 home")
        app.buttons["home-profile"].tap()
        XCTAssertTrue(app.buttons["profile-settings"].waitForExistence(timeout: 5))
        app.buttons["profile-settings"].tap()
        XCTAssertTrue(app.buttons["settings-storage"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["shoe-recovery-toggle"].exists)
        XCTAssertTrue(app.buttons["settings-notifications"].exists)
        attach(app, "Combined 1.2 settings with default counter")
        app.navigationBars["Settings"].buttons.element(boundBy: 0).tap()
        app.buttons["profile-close"].tap()
        let leaderboard = app.buttons["home-leaderboard"]
        XCTAssertTrue(leaderboard.waitForExistence(timeout: 5))
        leaderboard.tap()
        XCTAssertTrue(app.buttons["leaderboard-close"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["leaderboard-pennant-1"].waitForExistence(timeout: 10))
        attach(app, "Combined 1.2 leaderboard")
        app.buttons["leaderboard-close"].tap()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 5))
    }

    @MainActor private func attach(_ app: XCUIApplication, _ title: String) {
        let item = XCTAttachment(screenshot: app.screenshot())
        item.name = title; item.lifetime = .keepAlways; add(item)
    }
}
