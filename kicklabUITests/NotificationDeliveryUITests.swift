import XCTest

/// Real OS delivery on the preview install. Start with both opt-ins off.
final class NotificationDeliveryUITests: XCTestCase {
    @MainActor func testDailyReminderDeliveryAndDisable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--notification-review", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let daily = app.switches["notifications-daily"]
        XCTAssertTrue(daily.waitForExistence(timeout: 20))
        waitEnabled(daily)
        XCTAssertEqual(daily.value as? String, "0", "Preserve existing user opt-ins; this check expects them off")
        app.buttons["notification-review-clear-daily"].tap()
        waitLabel(app.staticTexts["notification-review-daily-delivered"], "0 daily alerts")
        toggle(daily)
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.waitForExistence(timeout: 3) {
            XCTAssertTrue(alert.buttons["Allow"].exists)
            alert.buttons["Allow"].tap()
        }
        waitEnabled(daily)
        app.buttons["notification-review-soon"].tap()
        waitLabel(app.staticTexts["notification-review-pending"], "1 daily reminders")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        // The repeating calendar trigger is 30–90 seconds away; iOS delivery
        // is not an exact timer (this phone also has Sleep Focus enabled).
        for _ in 0..<5 { Thread.sleep(forTimeInterval: 32) }
        let delivered = XCTAttachment(screenshot: XCUIApplication(bundleIdentifier: "com.apple.springboard").screenshot())
        delivered.name = "Daily reminder outside app"; delivered.lifetime = .keepAlways; add(delivered)
        app.activate()
        app.buttons["notification-review-refresh"].tap()
        waitLabel(app.staticTexts["notification-review-daily-delivered"], "1 daily alerts")
        app.terminate(); app.launch()
        waitLabel(app.staticTexts["notification-review-pending"], "1 daily reminders")
        app.buttons["notification-review-default-time"].tap()
        waitEnabled(app.switches["notifications-daily"])
        app.buttons["notification-review-refresh"].tap()
        waitLabel(app.staticTexts["notification-review-pending"], "1 daily reminders")
        toggle(app.switches["notifications-daily"])
        waitEnabled(app.switches["notifications-daily"])
        app.buttons["notification-review-refresh"].tap()
        waitLabel(app.staticTexts["notification-review-pending"], "0 daily reminders")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Delivered reminder and disabled schedule"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor private func waitEnabled(_ element: XCUIElement) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)], timeout: 15), .completed)
    }
    @MainActor private func toggle(_ element: XCUIElement) {
        // SwiftUI's accessibility switch covers the label and thumb. On iOS 27
        // a center tap can land on the inert label; target the actual control.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }
    @MainActor private func waitLabel(_ element: XCUIElement, _ value: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", value), object: element)], timeout: 10), .completed)
    }
}
