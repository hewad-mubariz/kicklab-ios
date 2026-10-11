import XCTest

@MainActor
final class SavedShotPhaseUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testMarkFramesSeparateFlightFromRollAndRestoreAfterReopening() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ball-distance-design", "setup"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["ball-distance-saved-tests"].waitForExistence(timeout: 10))
        app.buttons["ball-distance-saved-tests"].tap()
        let shot = app.buttons["saved-shot-37273B4C-10F3-4B37-A7EA-32126BECD806"]
        guard shot.waitForExistence(timeout: 5) else {
            throw XCTSkip("Requires the private saved-recording fixture on this simulator")
        }
        shot.tap()
        let phases = app.buttons["saved-distance-phases"]
        wait(phases, "enabled == true", 15); phases.tap()
        let next = app.buttons["phase-next-frame"]
        wait(next, "enabled == true", 15)
        app.buttons["phase-options"].tap(); app.buttons["Clear marks"].tap()
        XCTAssertFalse(app.buttons["phase-set-landing"].isEnabled)
        app.sliders["phase-scrubber"].adjust(toNormalizedSliderPosition: 0.56)
        wait(next, "enabled == true", 10)
        let before = app.staticTexts["phase-frame"].label
        next.tap(); wait(next, "enabled == true", 10)
        XCTAssertNotEqual(before, app.staticTexts["phase-frame"].label)
        let kickTime = time(app)
        attach("Choose kick frame")
        XCTAssertTrue(app.buttons["phase-set-kick"].isEnabled, app.debugDescription)
        app.buttons["phase-set-kick"].tap()
        XCTAssertFalse(app.buttons["phase-set-landing"].isEnabled)
        app.sliders["phase-scrubber"].adjust(toNormalizedSliderPosition: 0.64)
        wait(next, "enabled == true", 10)
        let landingTime = time(app)
        attach("Choose landing frame")
        XCTAssertTrue(app.buttons["phase-set-landing"].isEnabled, app.debugDescription)
        app.buttons["phase-set-landing"].tap()
        XCTAssertEqual(app.staticTexts["phase-save-status"].label, "Marks saved on this iPhone")
        let result = app.staticTexts["phase-flight-time"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        let interval = try XCTUnwrap(Double(result.label.components(separatedBy: " ")[0]))
        XCTAssertEqual(interval, landingTime - kickTime, accuracy: 0.002)
        let span = app.staticTexts["phase-ground-span"].label
        attach("Marked flight - portrait")
        app.scrollViews["phase-controls"].swipeUp()
        let flight = app.buttons["phase-play-flight"]
        XCTAssertTrue(flight.isHittable)
        flight.tap()
        wait(app.staticTexts["phase-time"], "label == '\(String(format: "%.3f s", landingTime))'", 10)
        wait(app.buttons["phase-play"], "label == 'Play'", 10)
        wait(next, "enabled == true", 10)
        XCTAssertEqual(time(app), landingTime, accuracy: 0.001)
        XCTAssertEqual(app.staticTexts["phase-current"].label, "After landing · roll / bounce")
        let totalFrames = try XCTUnwrap(app.staticTexts["phase-frame"].label.components(separatedBy: " / ").last)
        app.buttons["phase-play-after"].tap()
        wait(app.staticTexts["phase-frame"], "label == 'Frame \(totalFrames) / \(totalFrames)'", 25)
        wait(app.buttons["phase-play"], "label == 'Play'", 25)
        XCTAssertEqual(app.staticTexts["phase-ground-span"].label, span, "Later movement cannot change the marked span")
        XCTAssertEqual(result.label, String(format: "%.3f s", interval))
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: app)], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["phase-play"].isHittable)
        attach("Marked flight - landscape")
        XCUIDevice.shared.orientation = .portrait
        app.navigationBars.buttons.element(boundBy: 0).tap()
        wait(phases, "enabled == true", 15); phases.tap()
        wait(next, "enabled == true", 15)
        XCTAssertEqual(result.label, String(format: "%.3f s", interval))
        XCTAssertTrue(app.staticTexts["phase-save-status"].label.hasPrefix("Saved marks restored"))
    }

    private func time(_ app: XCUIApplication) -> Double {
        Double(app.staticTexts["phase-time"].label.components(separatedBy: " ")[0]) ?? -1
    }
    private func wait(_ element: XCUIElement, _ predicate: String, _ timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
