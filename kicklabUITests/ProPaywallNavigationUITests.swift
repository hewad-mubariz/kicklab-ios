import XCTest

/// Navigation checks never purchase or restore a subscription.
@MainActor
final class ProPaywallNavigationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testProfilePaywallClosesImmediatelyAndAfterScrolling() {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES"]
        app.launch()
        let profile = app.buttons["home-profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 15))
        profile.tap()
        let pro = app.buttons["profile-pro"]
        XCTAssertTrue(pro.waitForExistence(timeout: 5))
        let invite = app.buttons["profile-pro-redeem-invite"]
        XCTAssertTrue(invite.exists, "Guests and signed-in users can redeem an invite from Profile")
        for scroll in [false, true] {
            pro.tap()
            let close = app.buttons["pro-close"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["pro-redeem-invite"].exists, "Invite redemption remains available on the paywall")
            if scroll { app.swipeUp() }
            XCTAssertTrue(close.isHittable)
            if scroll {
                // The whole visible control is tappable, not just the X glyph.
                close.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
            } else { close.tap() }
            XCTAssertTrue(close.waitForNonExistence(timeout: 5), "Close must dismiss the paywall")
            XCTAssertTrue(pro.isHittable, "Return to the profile that opened the paywall")
        }
        app.buttons["profile-close"].tap()
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
    }

    func testDirectPaywallReviewCanReturnHome() {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES", "--session-design", "paywall"]
        app.launch()
        let close = app.buttons["pro-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let monthly = app.buttons["pro-plan-monthly"]
        let yearly = app.buttons["pro-plan-yearly"]
        monthly.tap()
        XCTAssertTrue(monthly.isSelected)
        XCTAssertFalse(yearly.isSelected)
        yearly.tap()
        XCTAssertTrue(yearly.isSelected)
        XCTAssertFalse(monthly.isSelected)
        close.tap()
        XCTAssertTrue(app.buttons["home-profile"].waitForExistence(timeout: 5))
        XCTAssertFalse(close.exists)
    }

    func testDebugPanelShowsBuildAndNoRestoreAttemptWithoutTriggeringApple() {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES", "--session-design", "paywall"]
        app.launch()
        let debug = app.buttons["pro-debug-open"]
        XCTAssertTrue(debug.waitForExistence(timeout: 10))
        debug.tap()
        let result = app.staticTexts["pro-debug-restore-result"]
        if !result.isHittable { app.swipeUp() }
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertEqual(result.label, "Not attempted in this launch")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Subscription diagnostics D1"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["pro-close"].isHittable)
    }
}
