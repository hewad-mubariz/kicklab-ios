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
        for scroll in [false, true] {
            pro.tap()
            let close = app.buttons["pro-close"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
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
        close.tap()
        XCTAssertTrue(app.buttons["home-profile"].waitForExistence(timeout: 5))
        XCTAssertFalse(close.exists)
    }
}
