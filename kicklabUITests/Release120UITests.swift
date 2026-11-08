import XCTest

/// Run only against com.juggledude.release120.preview on the staged iPhone 11.
final class Release120UITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testEditorExportCanCancelAndRestart() {
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "effects", "--session-video", "documents:background-input.mov",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let export = app.buttons["replay-export"].firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 20))
        export.tap()
        let systemAlert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if systemAlert.waitForExistence(timeout: 1) { allowSystemPrompt() }
        let cancel = app.buttons["replay-export-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        let stopped = app.staticTexts["Saving stopped. Tap Download to try again."]
        XCTAssertTrue(stopped.waitForExistence(timeout: 15))
        XCTAssertFalse(cancel.exists)
        export.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        XCTAssertTrue(stopped.waitForExistence(timeout: 15))
    }

    @MainActor
    func testRemindersAndRealVideoBackgroundSave() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Background export needs a physical device")
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["--notification-review", "--reset-practice-notifications", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let exports = app.switches["notifications-exports"]
        XCTAssertTrue(exports.waitForExistence(timeout: 20))
        waitEnabled(exports)
        toggle(exports)
        allowSystemPrompt()
        let practice = app.switches["notifications-practice"]
        waitEnabled(practice)
        toggle(practice)
        waitEnabled(practice)
        app.buttons["notification-review-refresh"].tap()
        waitLabel(app.staticTexts["notification-review-pending"], "0 practice reminders")
        XCTAssertTrue(app.datePickers["notifications-time"].exists)
        let settings = XCTAttachment(screenshot: app.screenshot())
        settings.name = "1.2 notification settings"; settings.lifetime = .keepAlways; add(settings)
        // Persist across a real relaunch, then remove the weekly test reminders.
        app.terminate()
        app.launchArguments = ["--notification-review"]
        app.launch()
        waitLabel(app.staticTexts["notification-review-pending"], "0 practice reminders")
        XCTAssertEqual(app.switches["notifications-exports"].value as? String, "1")
        let persistedPractice = app.switches["notifications-practice"]
        waitEnabled(persistedPractice); toggle(persistedPractice); waitEnabled(persistedPractice)
        app.buttons["notification-review-refresh"].tap()
        waitLabel(app.staticTexts["notification-review-pending"], "0 practice reminders")

        app.terminate()
        app.launchArguments = ["--background-video-review", "artwork-save",
            "--background-video-source", "documents:background-input.mov",
            "--background-video-track", "documents:background-track.plist"]
        app.launch()
        allowSystemPrompt()
        let status = app.staticTexts["background-video-status"]
        waitLabel(status, "Preparing export", timeout: 90)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        // This clip is 13 seconds of real juggling; precomputed masks isolate export.
        Thread.sleep(forTimeInterval: 50)
        app.activate()
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Done", "Saving must finish before returning to the app")
        let count = Int(app.staticTexts["background-video-updates"].label.components(separatedBy: " ").first ?? "0") ?? 0
        XCTAssertGreaterThan(count, 0)
        let result = XCTAttachment(screenshot: app.screenshot())
        result.name = "Real juggling export finished in background"; result.lifetime = .keepAlways; add(result)

        app.terminate()
        app.launchArguments = ["--notification-review"]
        app.launch()
        let delivered = app.staticTexts["notification-review-delivered"]
        XCTAssertTrue(delivered.waitForExistence(timeout: 20))
        let received = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES '[1-9][0-9]* export alerts'"), object: delivered)
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 10), .completed)
        let exportsOff = app.switches["notifications-exports"]
        waitEnabled(exportsOff)
        if exportsOff.value as? String == "1" { toggle(exportsOff); waitEnabled(exportsOff) }
    }

    @MainActor private func allowSystemPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 8) else { return }
        let allow = alert.buttons.matching(NSPredicate(format: "label == 'Allow' OR label == 'Allow Access to Add Photos' OR label == 'Allow Adding Photos' OR label == 'OK'")).firstMatch
        XCTAssertTrue(allow.exists, "Unexpected permission prompt: \(alert.debugDescription)")
        allow.tap()
    }

    @MainActor private func toggle(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    @MainActor private func waitEnabled(_ element: XCUIElement) {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
    }

    @MainActor private func waitLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 15) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout))
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: timeout), .completed)
    }
}
