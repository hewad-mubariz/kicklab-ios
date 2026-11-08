import XCTest

/// Real OS delivery on the preview install. Start with both opt-ins off.
final class NotificationDeliveryUITests: XCTestCase {
    @MainActor func testWeeklyScheduleMigrationAndReminderDeliveryFixture() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--notification-review", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let practice = app.switches["notifications-practice"]
        XCTAssertTrue(practice.waitForExistence(timeout: 20))
        waitEnabled(practice)
        XCTAssertEqual(practice.value as? String, "0", "Preserve existing user opt-ins; this check expects them off")
        app.buttons["notification-review-clear-practice"].tap()
        waitLabel(app.staticTexts["notification-review-practice-delivered"], "0 practice alerts")
        toggle(practice)
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.waitForExistence(timeout: 3) {
            XCTAssertTrue(alert.buttons["Allow"].exists)
            alert.buttons["Allow"].tap()
        }
        waitEnabled(practice)
        waitLabel(app.staticTexts["notification-review-pending"], "3 practice reminders")
        app.buttons["notification-review-legacy"].tap()
        waitLabel(app.staticTexts["notification-review-pending"], "4 practice reminders")
        app.buttons["notification-review-refresh"].tap()
        waitLabel(app.staticTexts["notification-review-pending"], "3 practice reminders")
        app.buttons["notification-review-soon"].tap()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        // A separate one-shot fixture checks the real reminder content/category
        // on any day. The three production calendar requests are checked above.
        Thread.sleep(forTimeInterval: 20)
        let delivered = XCTAttachment(screenshot: XCUIApplication(bundleIdentifier: "com.apple.springboard").screenshot())
        delivered.name = "Practice reminder delivery fixture outside app"; delivered.lifetime = .keepAlways; add(delivered)
        app.activate()
        app.buttons["notification-review-refresh"].tap()
        waitLabel(app.staticTexts["notification-review-practice-delivered"], "1 practice alerts")
        app.terminate(); app.launch()
        waitLabel(app.staticTexts["notification-review-pending"], "3 practice reminders")
        app.buttons["notification-review-default-time"].tap()
        waitEnabled(app.switches["notifications-practice"])
        app.buttons["notification-review-refresh"].tap()
        waitLabel(app.staticTexts["notification-review-pending"], "3 practice reminders")
        toggle(app.switches["notifications-practice"])
        waitEnabled(app.switches["notifications-practice"])
        app.buttons["notification-review-refresh"].tap()
        waitLabel(app.staticTexts["notification-review-pending"], "0 practice reminders")
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
