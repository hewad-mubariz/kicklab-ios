import XCTest

@MainActor final class ShotCameraUITests: XCTestCase {
    private func openCamera(export: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "shot-camera-fixture"]
        if export { app.launchArguments += ["--shot-export-to", "documents:camera-ui-exports"] }
        app.launch()
        XCTAssertTrue(app.buttons["shot-effects-customize"].waitForExistence(timeout: 30))
        app.buttons["shot-effects-customize"].tap()
        XCTAssertTrue(app.buttons["shot-tool-camera"].waitForExistence(timeout: 5))
        app.buttons["shot-tool-camera"].tap()
        XCTAssertTrue(app.buttons["shot-camera-chooser"].waitForExistence(timeout: 5))
        return app
    }
    private func settled(_ app: XCUIApplication) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                    object: app.staticTexts["Preparing replay…"])
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }
    private func choose(_ style: String, in app: XCUIApplication) {
        app.buttons["shot-camera-chooser"].tap()
        let item = app.buttons["shot-camera-" + style]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.tap(); settled(app)
    }
    private func picture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testEveryEffectHasFocusedControlsAndOriginalComparison() {
        let app = openCamera()
        let controls = ["follow":"Zoom", "impact":"Duration", "ramp":"Slow motion", "tilt":"Angle", "lens":"Magnification", "freeze":"Hold", "split":"Detail zoom", "frames":"Add frame"]
        for style in ["follow", "impact", "ramp", "tilt", "lens", "freeze", "split", "frames", "none"] {
            choose(style, in: app)
            if let label = controls[style] { XCTAssertTrue(app.staticTexts[label].exists || app.buttons[label].exists, style) }
            XCTAssertTrue(app.buttons["shot-camera-chooser"].isHittable)
            app.buttons["shot-camera-original"].tap(); settled(app)
            XCTAssertEqual(app.buttons["shot-camera-original"].label, "Show effect")
            app.buttons["shot-camera-original"].tap(); settled(app)
            XCTAssertEqual(app.buttons["shot-camera-original"].label, "Show original")
            picture("Camera controls - " + style, app: app)
        }
        XCTAssertFalse(app.buttons["shot-effects-save"].isEnabled)
    }
    func testFrameSelectionCancelCommitAndSharedContact() {
        let app = openCamera()
        choose("impact", in: app)
        let before = app.staticTexts["shot-moment-time-impact"].label
        app.buttons["shot-edit-moment"].tap()
        XCTAssertTrue(app.buttons["shot-frame-next"].waitForExistence(timeout: 3))
        let first = app.staticTexts["shot-frame-time"].label
        app.buttons["shot-frame-next"].tap()
        XCTAssertNotEqual(app.staticTexts["shot-frame-time"].label, first)
        app.buttons["shot-frame-cancel"].tap(); settled(app)
        XCTAssertEqual(app.staticTexts["shot-moment-time-impact"].label, before)
        app.buttons["shot-edit-moment"].tap()
        app.buttons["shot-frame-next"].tap()
        let selected = app.staticTexts["shot-frame-time"].label
        picture("Exact source frame picker", app: app)
        app.buttons["shot-frame-done"].tap(); settled(app)
        XCTAssertEqual(app.staticTexts["shot-moment-time-impact"].label, selected)
        choose("tilt", in: app)
        XCTAssertEqual(app.staticTexts["shot-moment-time-impact"].label, selected)
        app.buttons["shot-camera-auto-strike"].tap()
        XCTAssertEqual(app.staticTexts["shot-moment-time-impact"].label, before)
    }
    func testRangeAndSpatialEditorsAndReviewFrames() {
        let app = openCamera()
        choose("ramp", in: app)
        app.buttons["shot-edit-range"].tap()
        XCTAssertTrue(app.buttons["shot-range-end"].waitForExistence(timeout: 3))
        app.buttons["shot-range-end"].tap()
        app.buttons["shot-timeline-zoom-in"].tap()
        app.buttons["shot-frame-next"].tap()
        picture("Source range picker", app: app)
        app.buttons["shot-frame-done"].tap(); settled(app)
        app.buttons["shot-ramp-rate-0.5"].tap(); settled(app)
        XCTAssertEqual(app.buttons["shot-ramp-rate-0.5"].value as? String, "Selected")
        choose("lens", in: app)
        app.buttons["shot-target-lensArea"].tap(); settled(app)
        let target = app.descendants(matching: .any)["shot-target-preview"].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6)).tap()
        picture("Inspect source area", app: app)
        app.buttons["shot-target-done"].tap(); settled(app)
        app.buttons["shot-target-lensPosition"].tap(); settled(app)
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.3)).tap()
        app.buttons["shot-target-done"].tap(); settled(app)
        choose("split", in: app)
        app.buttons["shot-choice-Stacked"].tap()
        XCTAssertEqual(app.buttons["shot-choice-Stacked"].value as? String, "Selected")
        picture("Stacked wide and detail", app: app)
        choose("frames", in: app)
        app.buttons["shot-frame-add"].tap()
        app.buttons["shot-frame-next"].tap()
        app.buttons["shot-frame-done"].tap(); settled(app)
        XCTAssertTrue(app.buttons["shot-camera-frame-3"].exists)
        XCTAssertTrue(app.buttons["shot-frame-update"].isEnabled)
        app.buttons["shot-frame-update"].tap()
        app.buttons["shot-frame-next"].tap()
        app.buttons["shot-frame-done"].tap(); settled(app)
        app.buttons["shot-frame-remove"].tap()
        XCTAssertFalse(app.buttons["shot-camera-frame-3"].exists)
    }
    func testCameraOnlyVideoCanBeSaved() {
        let app = openCamera(export: true)
        choose("follow", in: app)
        app.sliders["shot-control-zoom"].adjust(toNormalizedSliderPosition: 0.65)
        app.buttons["shot-close-tools"].tap()
        XCTAssertTrue(app.buttons["shot-effects-save"].isEnabled)
        app.buttons["shot-effects-save"].tap()
        XCTAssertTrue(app.otherElements["replay-share-panel"].waitForExistence(timeout: 45))
    }
    func testRangeHandlesDragWithoutCrossing() {
        let app = openCamera()
        choose("ramp", in: app)
        app.buttons["shot-edit-range"].tap()
        app.buttons["shot-timeline-zoom-in"].tap()
        let end = app.descendants(matching: .any)["shot-range-end-handle"].firstMatch
        let start = app.descendants(matching: .any)["shot-range-start-handle"].firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 3)); XCTAssertTrue(start.exists)
        let before = end.value as? String
        end.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.15,
            thenDragTo: start.coordinate(withNormalizedOffset: CGVector(dx: -1, dy: 0.5)))
        XCTAssertNotEqual(end.value as? String, before)
        XCTAssertGreaterThan(end.value as? String ?? "", start.value as? String ?? "")
        picture("Dragged noncrossing range handles", app: app)
        app.buttons["shot-frame-done"].tap(); settled(app)
    }
}
