import XCTest

final class ProMembershipUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testProBadgeExplainsMembershipWithoutOpeningScoreDetails() {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES", "--verified-pro-badges", "--leaderboard-preview", "mixed",
                               "-kicklab.appearance", "dark", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.buttons["home-leaderboard"].waitForExistence(timeout: 15))
        app.buttons["home-leaderboard"].tap()
        let badge = app.buttons["leaderboard-pro-1"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["leaderboard-pro-2"].exists)
        // Wait for the pennant's entrance before exercising the actual hit target.
        XCTAssertTrue(app.buttons["leaderboard-pennant-1"].waitForExistence(timeout: 5))
        badge.tap()
        XCTAssertTrue(app.alerts["Pro member"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["leaderboard-player-close"].exists)
        app.alerts.buttons["OK"].tap()
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Pro membership badges — dark leaderboard"; shot.lifetime = .keepAlways; add(shot)
        let rowBadge = app.buttons["leaderboard-pro-4"]
        if !rowBadge.isHittable { app.swipeUp() }
        XCTAssertTrue(rowBadge.waitForExistence(timeout: 5))
        rowBadge.tap()
        XCTAssertTrue(app.alerts["Pro member"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        app.buttons["leaderboard-row-4"].tap()
        XCTAssertTrue(app.buttons["leaderboard-player-close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["leaderboard-detail-pro"].exists)
    }
}
