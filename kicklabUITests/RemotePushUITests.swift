import XCTest

/// Dedicated preview only. Leaves the requested training opt-in enabled for
/// the one-device APNs check. The server schedules the opted-in practice reminder.
final class RemotePushUITests: XCTestCase {
    @MainActor func testNotificationTapOpensSetupFromTerminatedApp() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--notification-tap-review", "-kicklab.welcome.completed", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 20))
        // Let the launch task schedule the alert, then exercise a cold start.
        Thread.sleep(forTimeInterval: 2)
        app.terminate()
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
            .press(forDuration: 0.2, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
        let notice = springboard.staticTexts["Juggle Dude notification tap check"].firstMatch
        // Reveal older notification history if the card is not visible.
        // Run this UI check unlocked with Focus off; never change Focus here.
        if !notice.waitForExistence(timeout: 10) { springboard.swipeUp() }
        XCTAssertTrue(notice.waitForExistence(timeout: 20), springboard.debugDescription)
        let before = XCTAttachment(screenshot: springboard.screenshot()); before.name = "Notification tap fixture"; before.lifetime = .keepAlways; add(before)
        notice.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.buttons["capture-close"].waitForExistence(timeout: 20))
        XCTAssertNotEqual(app.buttons["record-capture-button"].label, "Stop Recording")
        let after = XCTAttachment(screenshot: app.screenshot()); after.name = "Notification opened juggling setup"; after.lifetime = .keepAlways; add(after)
        app.buttons["capture-close"].tap()
    }

    @MainActor func testRegisterPreviewWithApple() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--notification-review", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let toggle = app.switches["notifications-practice"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 25))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: toggle)], timeout: 30), .completed)
        if toggle.value as? String == "0" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.waitForExistence(timeout: 3), alert.buttons["Allow"].exists { alert.buttons["Allow"].tap() }
        let status = app.staticTexts["notification-review-push"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Apple: true"), object: status)], timeout: 45), .completed)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Apple push registration"; shot.lifetime = .keepAlways; add(shot)
    }
}
