import XCTest
import StoreKitTest

@MainActor
final class ProPaywallUITests: XCTestCase {
    private var session: SKTestSession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        session = try SKTestSession(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "JuggleDude", withExtension: "storekit")))
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.storefront = "DEU"
        session.locale = Locale(identifier: "en_US")
    }

    override func tearDownWithError() throws {
        session.clearTransactions()
        session.resetToDefaultState()
    }

    func testLocalizedPlansPurchaseAndProPersistsAfterRelaunch() {
        let app = openPaywall()
        let purchase = app.buttons["pro-purchase"]
        expectLabel(purchase, contains: "29.99/year")
        XCTAssertTrue(app.buttons["pro-close"].isHittable)
        for link in ["pro-restore", "pro-terms", "pro-privacy"] {
            XCTAssertTrue(app.buttons[link].exists)
        }
        XCTAssertTrue(app.buttons["pro-plan-yearly"].label.contains("Save 50%"))
        XCTAssertFalse(app.staticTexts["pro-saving"].exists)
        attach(app, "Yearly App Store price and saving")
        app.buttons["pro-plan-monthly"].tap()
        expectLabel(purchase, contains: "4.99/month")
        purchase.tap()
        XCTAssertTrue(app.buttons["pro-close"].waitForNonExistence(timeout: 10),
                      "A completed purchase must return to Profile automatically")
        let pro = app.buttons["profile-pro"]
        expectLabel(pro, contains: "Active")
        XCTAssertTrue(pro.isHittable)
        XCTAssertFalse(app.alerts["You’re Pro"].exists)
        attach(app, "Verified Pro status")
        pro.tap()
        XCTAssertTrue(app.buttons["pro-close"].waitForExistence(timeout: 5))
        let monthly = app.buttons["pro-plan-monthly"]
        let yearly = app.buttons["pro-plan-yearly"]
        XCTAssertTrue(monthly.isSelected, "An active monthly subscription must override the yearly default")
        XCTAssertTrue(monthly.label.contains("Current plan"))
        XCTAssertFalse(yearly.isSelected)
        XCTAssertTrue(monthly.isEnabled)
        XCTAssertTrue(yearly.isEnabled, "Active subscribers can open Apple's plan management from either card")
        XCTAssertTrue(app.staticTexts["pro-change-plan-help"].exists)
        app.buttons["pro-close"].tap()
        app.terminate()
        app.launch()
        app.buttons["home-profile"].tap()
        expectLabel(app.buttons["profile-pro"], contains: "Active")
    }

    func testRestoreWithNoSubscriptionAndCloseRemainAvailable() {
        let app = openPaywall()
        expectLabel(app.buttons["pro-purchase"], contains: "29.99/year")
        app.buttons["pro-restore"].tap()
        XCTAssertTrue(app.alerts["No active subscription"].waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["pro-close"].isHittable)
        app.buttons["pro-close"].tap()
        XCTAssertTrue(app.buttons["profile-pro"].waitForExistence(timeout: 5))
    }

    func testActiveSubscriberCanReopenProAndRestore() {
        let app = openPaywall()
        let purchase = app.buttons["pro-purchase"]
        expectLabel(purchase, contains: "29.99/year")
        purchase.tap()
        XCTAssertTrue(app.buttons["pro-close"].waitForNonExistence(timeout: 10),
                      "A completed purchase must return to Profile automatically")
        let pro = app.buttons["profile-pro"]
        expectLabel(pro, contains: "Active")
        pro.tap()
        XCTAssertTrue(app.buttons["pro-close"].waitForExistence(timeout: 5))
        expectLabel(purchase, contains: "Manage Pro subscription")
        XCTAssertTrue(app.buttons["pro-plan-yearly"].isSelected)
        XCTAssertTrue(app.buttons["pro-plan-yearly"].label.contains("Current plan"))
        XCTAssertTrue(app.buttons["pro-plan-monthly"].isEnabled)
        let restore = app.buttons["pro-restore"]
        for _ in 0..<3 where !restore.isHittable { app.swipeUp() }
        XCTAssertTrue(restore.isHittable, "Active subscribers must be able to reach Restore")
        restore.tap()
        XCTAssertTrue(app.alerts["Pro restored"].waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()
        expectLabel(purchase, contains: "Manage Pro subscription")
        attach(app, "Active subscriber can restore from Pro screen")
    }

    private func openPaywall() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["home-profile"].waitForExistence(timeout: 10))
        app.buttons["home-profile"].tap()
        let pro = app.buttons["profile-pro"]
        XCTAssertTrue(pro.waitForExistence(timeout: 5))
        pro.tap()
        XCTAssertTrue(app.buttons["pro-purchase"].waitForExistence(timeout: 5))
        return app
    }

    private func expectLabel(_ element: XCUIElement, contains text: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 12), .completed)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
