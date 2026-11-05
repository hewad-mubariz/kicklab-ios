import XCTest

/// Capture is available to guests, independently of paid editor tools or floor tracking.
@MainActor
final class BallDistanceCaptureUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testRecordingIsReadyWithoutGroundInPortraitAndLandscape() {
        let app = XCUIApplication()
        app.launchArguments = ["--ball-distance-design", "setup"]
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        XCTAssertTrue(app.staticTexts["ball-distance-title"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["ball-distance-title"].label, "BALL DISTANCE")
        assertReady(app)
        attach("Ball Distance - ready portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: app)], timeout: 5), .completed)
        assertReady(app)
        attach("Ball Distance - ready landscape")
        app.buttons["ball-distance-record"].tap()
        XCTAssertEqual(app.buttons["ball-distance-record"].label, "Stop recording")
        XCTAssertFalse(app.buttons["ball-distance-import"].isEnabled)
        XCTAssertFalse(app.buttons["ball-distance-flip"].isEnabled)
        XCTAssertFalse(app.buttons["ball-distance-saved-shots"].isEnabled)
        XCTAssertFalse(app.staticTexts["ball-distance-value"].exists)
        attach("Ball Distance - recording landscape")
        app.buttons["ball-distance-record"].tap()
        assertReady(app)
    }

    func testCameraHasNoReadyOrQualityLabel() {
        let app = XCUIApplication()
        app.launchArguments = ["--ball-distance-design", "setup"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["ball-distance-record"].waitForExistence(timeout: 10))
        assertReady(app)
        XCTAssertFalse(app.staticTexts["Ready to record"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["ball-distance-quality"].exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'fps'")).firstMatch.exists)
    }

    func testSavedShotsOpenTheEditorKeepTheChosenEffectAndCanBeRemoved() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Reads a video from this Mac")
        #endif
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kicklabTests/Fixtures/power-shot-2.5s.mp4").path
        let app = XCUIApplication()
        app.launchArguments = ["--history-review", "empty", "--ball-distance-design", "setup", "--saved-shots-video", fixture]
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        let saved = app.buttons["ball-distance-saved-shots"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        attach("Ball Distance - camera with saved shots")
        saved.tap()
        XCTAssertTrue(app.descendants(matching: .any)["saved-shots"].waitForExistence(timeout: 5))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'saved-shot-'"))
        // The fixture adds both shots just after launch; pull to read them again if they came after.
        if !rows.element(boundBy: 1).waitForExistence(timeout: 5) {
            app.swipeDown()
            XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 5))
        }
        attach("Saved shots - list")
        rows.element(boundBy: 0).tap()

        let open = app.buttons["saved-shot-edit-replay"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        attach("Saved shots - details")
        open.tap()
        XCTAssertTrue(app.buttons["shot-effects-close"].waitForExistence(timeout: 120), "The editor should open")
        settle()
        attach("Saved shots - editor")
        XCTAssertFalse(app.descendants(matching: .any)["shot-effects-problem"].exists, "The first open should play")
        // Starts on the default effect; a free player can change it to no effect.
        app.buttons["shot-effects-customize"].tap()
        XCTAssertTrue(app.buttons["shot-tool-effects"].waitForExistence(timeout: 5))
        app.buttons["shot-tool-effects"].tap()
        let noEffect = app.buttons["shot-effect-none"]
        XCTAssertTrue(noEffect.waitForExistence(timeout: 5))
        XCTAssertFalse(noEffect.isSelected)
        noEffect.tap()
        wait(noEffect, "selected == true")
        app.buttons["shot-effects-close"].tap()

        // Back on the same page, and the editor reopens as the player left it.
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(app.buttons["shot-effects-customize"].waitForExistence(timeout: 30))
        settle()
        attach("Saved shots - editor reopened")
        XCTAssertFalse(app.descendants(matching: .any)["shot-effects-problem"].exists, "Reopening should play")
        app.buttons["shot-effects-customize"].tap()
        XCTAssertTrue(app.buttons["shot-tool-effects"].waitForExistence(timeout: 5))
        app.buttons["shot-tool-effects"].tap()
        XCTAssertTrue(noEffect.waitForExistence(timeout: 5))
        XCTAssertTrue(noEffect.isSelected, "The chosen effect should come back")
        settle()
        attach("Saved shots - effect kept")
        app.buttons["shot-effects-close"].tap()

        // Back to the list, then remove one shot and return to the camera.
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(rows.element(boundBy: 0).waitForExistence(timeout: 5))
        rows.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["saved-shot-remove"].waitForExistence(timeout: 5))
        app.buttons["saved-shot-remove"].tap()
        let confirm = app.sheets.buttons["Remove shot"].exists ? app.sheets.buttons["Remove shot"] : app.buttons["Remove shot"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(rows.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertFalse(rows.element(boundBy: 1).exists, "Only the other shot should be left")

        app.buttons["saved-shots-close"].tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
    }

    func testImportRemainsAvailableWithoutCameraPermission() {
        let app = XCUIApplication()
        app.launchArguments = ["--ball-distance-design", "denied"]
        app.launch()
        XCTAssertTrue(app.buttons["ball-distance-import"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["ball-distance-import"].isEnabled)
        XCTAssertFalse(app.buttons["ball-distance-record"].isEnabled)
        XCTAssertTrue(app.buttons["Open Settings"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["ball-distance-finding"].exists)
    }

    private func assertReady(_ app: XCUIApplication) {
        let record = app.buttons["ball-distance-record"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: record)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        XCTAssertTrue(record.isEnabled)
        XCTAssertTrue(record.isHittable)
        XCTAssertTrue(app.buttons["ball-distance-import"].isHittable)
        XCTAssertTrue(app.buttons["ball-distance-flip"].isHittable)
        XCTAssertFalse(app.staticTexts["ball-distance-value"].exists)
        XCTAssertFalse(app.staticTexts["roll-speed-value"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["capture-touch-counter"].exists)
        XCTAssertFalse(app.buttons["ball-distance-setup"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["ball-distance-finding"].exists)
        XCTAssertFalse(app.staticTexts["ball-distance-experimental"].exists)
    }

    private func wait(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 5) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, format)
    }

    /// The editor's entrance takes a moment; a screenshot before it ends shows an empty screen.
    private func settle() { _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settled")], timeout: 4) }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
