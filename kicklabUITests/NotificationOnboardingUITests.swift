import XCTest

/// Run on a fresh simulator installation so Apple's permission is undecided.
final class NotificationOnboardingUITests: XCTestCase {
    @MainActor func testFirstCompletedSessionAsksOnHomeAndDefersOtherNotices() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let base = ["-kicklab.welcome.completed", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments = base + ["-juggledude.notifications.session-completed", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 15))
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(system.alerts.firstMatch.waitForExistence(timeout: 2), "No prompt before a finished session")
        app.terminate()

        // Supply the persisted completion signal used by successful recording/import.
        app.launchArguments = base + ["-juggledude.notifications.session-completed", "YES",
            "--app-update-preview", "--app-update-preview-reset"]
        app.launch()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 15))
        let permission = system.alerts.firstMatch
        XCTAssertTrue(permission.waitForExistence(timeout: 10))
        XCTAssertTrue(permission.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'notifications'")).firstMatch.exists)
        XCTAssertTrue(permission.buttons["Allow"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Standard notification permission after first session, on Home"
        shot.lifetime = .keepAlways; add(shot)
        permission.buttons["Allow"].tap()
        XCTAssertFalse(app.alerts["Update available"].waitForExistence(timeout: 2), "Do not stack an update after notification permission")
        openNotificationSettings(app)
        let practice = app.switches["notifications-practice"]
        XCTAssertEqual(practice.value as? String, "1", "Allow automatically enables practice reminders")
        XCTAssertTrue(app.datePickers["notifications-time"].exists)
        practice.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(practice.value as? String, "0")
        app.terminate()

        app.launchArguments = base + ["-juggledude.notifications.session-completed", "YES", "--app-update-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 15))
        let update = app.alerts["Update available"]
        XCTAssertTrue(update.waitForExistence(timeout: 10), "Deferred notices become eligible on the next launch")
        update.buttons["Not now"].tap()
        XCTAssertFalse(system.alerts.firstMatch.waitForExistence(timeout: 2))
        openNotificationSettings(app)
        XCTAssertEqual(app.switches["notifications-practice"].value as? String, "0", "Do not undo a saved opt-out")
    }

    @MainActor private func openNotificationSettings(_ app: XCUIApplication) {
        app.buttons["home-profile"].tap()
        XCTAssertTrue(app.buttons["profile-settings"].waitForExistence(timeout: 5))
        app.buttons["profile-settings"].tap()
        XCTAssertTrue(app.buttons["settings-notifications"].waitForExistence(timeout: 5))
        app.buttons["settings-notifications"].tap()
        let practice = app.switches["notifications-practice"]
        XCTAssertTrue(practice.waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: practice)], timeout: 10), .completed)
    }
}
