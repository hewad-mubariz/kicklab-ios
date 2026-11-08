import XCTest

/// Dedicated preview only. Leaves the requested training opt-in enabled for
/// the one-device APNs check. The server schedules the opted-in practice reminder.
final class RemotePushUITests: XCTestCase {
    @MainActor func testLeaderboardPreferenceAndColdNotificationTap() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let base = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments = base
        app.launch()
        enterAppIfNeeded(app)
        app.terminate()
        app.launchArguments = base + ["--notification-review"]
        app.launch()
        let toggle = app.switches["notifications-leaderboard"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: toggle)], timeout: 15), .completed)
        // Restore only this test preference after an interrupted prior run.
        if toggle.value as? String == "1" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        XCTAssertEqual(toggle.value as? String, "0")
        let practiceBefore = app.switches["notifications-practice"].value as? String
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = springboard.alerts.firstMatch
        if permission.waitForExistence(timeout: 3), permission.buttons["Allow"].exists { permission.buttons["Allow"].tap() }
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertEqual(app.switches["notifications-practice"].value as? String, practiceBefore)
        app.terminate()
        app.launchArguments = base + ["--leaderboard-notification-tap-review"]
        app.launch()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 2)
        app.terminate()
        XCUIDevice.shared.press(.home)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
            .press(forDuration: 0.2, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
        let notice = springboard.staticTexts["Juggle Dude leaderboard tap check"].firstMatch
        if !notice.waitForExistence(timeout: 10) { springboard.swipeUp() }
        XCTAssertTrue(notice.waitForExistence(timeout: 20))
        notice.tap()
        openNotificationIfNeeded(app, notice: notice, springboard: springboard)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.buttons["leaderboard-close"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["capture-close"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Leaderboard notification opened leaderboard"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["leaderboard-close"].tap()
        app.terminate()
        app.launchArguments = base + ["--notification-review"]
        app.launch()
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
    }

    @MainActor func testNotificationTapOpensSetupFromTerminatedApp() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--notification-tap-review", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        enterAppIfNeeded(app)
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
        openNotificationIfNeeded(app, notice: notice, springboard: springboard)
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

    @MainActor private func openNotificationIfNeeded(_ app: XCUIApplication, notice: XCUIElement, springboard: XCUIApplication) {
        // iOS can expand a group or hint a side swipe on the first tap instead of
        // executing the default action. Use the system's Open action in that case.
        guard !app.wait(for: .runningForeground, timeout: 4), notice.exists else { return }
        notice.swipeRight()
        if !app.wait(for: .runningForeground, timeout: 3) {
            let open = springboard.buttons["Open"].firstMatch
            if open.waitForExistence(timeout: 3) { open.tap() }
        }
    }

    @MainActor private func enterAppIfNeeded(_ app: XCUIApplication) {
        // An OS cold launch does not inherit XCTest's UserDefaults arguments.
        // Finish welcome through the real UI so its completion is persisted.
        let guest = app.buttons["signin-guest"]
        if guest.waitForExistence(timeout: 3) { guest.tap() }
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 20))
    }
}
