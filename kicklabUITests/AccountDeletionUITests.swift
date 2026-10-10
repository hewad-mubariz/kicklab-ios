import XCTest

@MainActor
final class AccountDeletionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testConfirmationCanCancelThenDeletionReturnsToGuest() {
        let app = openProfile()
        app.buttons["profile-delete-account"].tap()
        XCTAssertTrue(app.alerts["Delete your account?"].waitForExistence(timeout: 3))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["profile-account-email"].exists)
        app.buttons["profile-delete-account"].tap()
        app.alerts["Delete your account?"].buttons["Delete account"].tap()
        XCTAssertTrue(app.buttons["home-profile"].waitForExistence(timeout: 8))
        app.buttons["home-profile"].tap()
        XCTAssertTrue(app.buttons["profile-sign-in"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["profile-delete-account"].exists)
    }

    func testFailureKeepsSignedInProfileAndAllowsRetry() {
        let app = openProfile(failure: true)
        app.buttons["profile-delete-account"].tap()
        app.alerts["Delete your account?"].buttons["Delete account"].tap()
        let error = app.staticTexts["Account deletion couldn’t be confirmed. Please try again."]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["profile-account-email"].exists)
        XCTAssertTrue(app.buttons["profile-delete-account"].isEnabled)
    }

    private func openProfile(failure: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--account-deletion-review", "-kicklab.welcome.completed", "YES"]
        if failure { app.launchArguments.append("--account-deletion-failure") }
        app.launch()
        XCTAssertTrue(app.buttons["home-profile"].waitForExistence(timeout: 12))
        app.buttons["home-profile"].tap()
        let button = app.buttons["profile-delete-account"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        for _ in 0..<4 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.isHittable)
        return app
    }
}
