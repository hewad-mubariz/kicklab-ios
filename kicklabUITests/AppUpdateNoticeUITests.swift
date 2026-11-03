import XCTest

/// A newer App Store version shows a native alert; Not now keeps the update available in Settings.
final class AppUpdateNoticeUITests: XCTestCase {
    @MainActor
    func testNativeUpdateAlertDismissesAndKeepsSettingsLink() {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES", "--app-update-preview", "--app-update-preview-reset"]
        app.launch()
        let alert = app.alerts["Update available"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Juggle Dude 1.3.0 is here")).firstMatch.exists)
        XCTAssertTrue(alert.buttons["Update"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Native update alert"; shot.lifetime = .keepAlways; add(shot)
        if let folder = ProcessInfo.processInfo.environment["BALL_PAGE_SHOTS"], !folder.isEmpty {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("update-alert.png"))
        }
        alert.buttons["Not now"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        app.buttons["home-profile"].tap()
        XCTAssertTrue(app.buttons["profile-settings"].waitForExistence(timeout: 5))
        app.buttons["profile-settings"].tap()
        let update = app.buttons["settings-app-update"]
        XCTAssertTrue(update.waitForExistence(timeout: 5))
        if !update.isHittable { app.swipeUp() }
        XCTAssertTrue(update.isHittable)
        app.terminate()
        app.launchArguments = ["-kicklab.welcome.completed", "YES", "--app-update-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["home-profile"].waitForExistence(timeout: 10))
        let repeats = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: app.alerts["Update available"])
        repeats.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [repeats], timeout: 3), .completed,
            "The dismissed version must stay dismissed after relaunch")
    }
}
