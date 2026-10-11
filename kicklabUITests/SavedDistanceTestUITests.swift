import XCTest

@MainActor
final class SavedDistanceTestUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSavedTestsCanOpenBeforeFloorSetupAndAreDisabledWhileRecording() {
        let app = XCUIApplication()
        app.launchArguments = ["--ball-distance-design", "setup"]
        app.launch()
        let saved = app.buttons["ball-distance-saved-tests"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        XCTAssertTrue(saved.isEnabled)
        saved.tap()
        XCTAssertTrue(app.navigationBars["Saved tests"].waitForExistence(timeout: 5))
        app.buttons["saved-shots-done"].tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--ball-distance-design", "recording"]
        app.launch()
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        XCTAssertFalse(saved.isEnabled)
    }

    /// Seed the review simulator with the seven original recording folders first.
    /// These private videos deliberately aren't bundled in the application or tests.
    func testSavedRollAndShotReplayTheirAuditedDistances() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ball-distance-design", "setup"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["ball-distance-saved-tests"].waitForExistence(timeout: 10))
        app.buttons["ball-distance-saved-tests"].tap()
        let slow = app.buttons["saved-shot-88803AED-7493-4240-872D-811B96277464"]
        guard slow.waitForExistence(timeout: 5) else {
            throw XCTSkip("Requires the private saved-recording review fixture on this simulator")
        }
        slow.tap()
        let replay = app.buttons["saved-distance-replay"]
        XCTAssertTrue(replay.waitForExistence(timeout: 15))
        wait(replay, "enabled == true", seconds: 15)
        replay.tap()
        wait(app.staticTexts["saved-distance-test-value"], "label == '9.99 m'", seconds: 25)
        XCTAssertEqual(app.staticTexts["saved-distance-original"].label, "9.99 m")
        attach("Slow roll - 9.99 m")
        replay.tap()
        wait(app.staticTexts["saved-distance-test-value"], "label BEGINSWITH '0.'", seconds: 5)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["saved-shot-A4133079-EE39-49F5-9D69-B863BFC523EB"].tap()
        wait(replay, "enabled == true", seconds: 15)
        replay.tap()
        wait(app.staticTexts["saved-distance-test-value"], "label == '9.44 m'", seconds: 20)
        XCTAssertEqual(app.staticTexts["saved-distance-original"].label, "0.14 m")
        attach("Shot - 9.44 m versus 0.14 m")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: app)], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["saved-distance-test-value"].isHittable)
        XCTAssertTrue(app.staticTexts["saved-distance-original"].isHittable)
        attach("Saved test - landscape")
        XCUIDevice.shared.orientation = .portrait
    }

    private func wait(_ element: XCUIElement, _ predicate: String, seconds: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: seconds), .completed)
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
