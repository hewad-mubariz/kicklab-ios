import XCTest

final class ShotRollDistanceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testExperimentalReadoutAndControlsInPortraitAndLandscape() {
        let app = XCUIApplication()
        app.launchArguments = ["--shot-geometry-capture", "--roll-distance-ui-review", "--roll-speed-ui-fixture"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.staticTexts["roll-distance-value"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["roll-distance-value"].label, "1.23 m")
        XCTAssertEqual(app.staticTexts["roll-speed-value"].label, "2.6 km/h")
        XCTAssertEqual(app.staticTexts["roll-speed-peak"].label, "Peak rolling speed: 2.8 km/h")
        XCTAssertTrue(app.staticTexts["EXPERIMENTAL"].exists)
        XCTAssertFalse(app.buttons["roll-set-start"].isEnabled)
        XCTAssertFalse(app.buttons["power-shot-record"].isEnabled)
        attach(app, name: "Roll distance - portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscapeReady = NSPredicate { _, _ in
            app.frame.width > app.frame.height &&
                app.staticTexts["roll-distance-value"].frame.midX > app.frame.midX
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscapeReady, object: app)], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["roll-set-start"].isHittable)
        XCTAssertTrue(app.staticTexts["roll-speed-value"].isHittable)
        attach(app, name: "Roll distance - landscape")
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testPreviewExplainsTheMissingStartAndWaitsForTheBall() {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--shot-geometry-capture", "--roll-distance-ui-review", "--roll-distance-ui-waiting"]
        app.launch()
        XCTAssertTrue(app.staticTexts["roll-distance-value"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["roll-distance-value"].label, "Start not set")
        XCTAssertEqual(app.staticTexts["roll-speed-value"].label, "— km/h")
        XCTAssertFalse(app.staticTexts["roll-speed-peak"].exists)
        XCTAssertTrue(app.staticTexts["Finding the ball — keep it visible"].exists)
        XCTAssertFalse(app.buttons["power-shot-record"].isEnabled)
        XCTAssertFalse(app.buttons["roll-set-start"].isEnabled)
        attach(app, name: "Roll distance - waiting for the ball")

        app.terminate()
        app.launchArguments = ["--shot-geometry-capture", "--roll-distance-ui-review", "--roll-distance-ui-ready"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Ball found — record, then tap Set start"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["roll-distance-value"].label, "Start not set")
        XCTAssertTrue(app.buttons["power-shot-record"].isEnabled)
        XCTAssertFalse(app.buttons["roll-set-start"].isEnabled)
        attach(app, name: "Roll distance - ready to record")
    }

    @MainActor
    func testCanReturnToRecordingWithoutTheDistanceExperiment() {
        let app = XCUIApplication()
        app.launchArguments = ["--shot-geometry-capture", "--roll-distance-ui-review"]
        app.launch()
        XCTAssertTrue(app.switches["roll-distance-toggle"].waitForExistence(timeout: 10))
        let toggle = app.switches["roll-distance-toggle"]
        XCTAssertTrue(toggle.isEnabled)
        // SwiftUI exposes the whole labelled row as the switch. Its centre
        // is empty space; tap the actual thumb at the trailing edge.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["roll-distance-value"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["roll-speed-value"].exists)
        XCTAssertTrue(app.staticTexts["Recording test"].exists)
        XCTAssertFalse(app.buttons["roll-set-start"].exists)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testCalibrationRequiresBothCentresAndCanApplyAndClear() {
        let app = XCUIApplication()
        app.launchArguments = ["--shot-geometry-capture", "--roll-distance-ui-review", "--roll-calibration-ui-fixture"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["roll-calibrate"].waitForExistence(timeout: 10))
        app.buttons["roll-calibrate"].tap()
        let photo = app.images["calibration-canvas"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["calibration-apply"].isEnabled)
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        XCTAssertTrue(app.staticTexts["Now tap the centre of the far paper (B)."].exists)
        XCTAssertFalse(app.buttons["calibration-apply"].isEnabled)
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        XCTAssertTrue(app.buttons["calibration-apply"].isEnabled)
        attach(app, name: "Calibration - both paper centres selected")
        app.buttons["calibration-undo"].tap()
        XCTAssertFalse(app.buttons["calibration-apply"].isEnabled)
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        app.buttons["calibration-apply"].tap()
        XCTAssertTrue(app.staticTexts["3.00 m spacing applied • check separate 1 m and 2 m marks"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Measured-spacing calibration • rolling ball only • checks pending"].exists)
        app.buttons["roll-clear-calibration"].tap()
        XCTAssertTrue(app.staticTexts["Use two tape-measured paper centres to calibrate this setup."].exists)
        XCTAssertFalse(app.buttons["roll-clear-calibration"].exists)
        attach(app, name: "Calibration - deliberately cleared")
    }

    @MainActor
    func testCalibrationEditorSupportsLandscapeAndCancel() {
        let app = XCUIApplication()
        app.launchArguments = ["--shot-geometry-capture", "--roll-distance-ui-review", "--roll-calibration-ui-fixture"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["roll-calibrate"].waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscapeReady = NSPredicate { _, _ in app.frame.width > app.frame.height }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscapeReady, object: app)], timeout: 5), .completed)
        app.buttons["roll-calibrate"].tap()
        let photo = app.images["calibration-canvas"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        XCTAssertTrue(app.images["calibration-loupe"].exists)
        XCTAssertTrue(app.buttons["calibration-nudge-up"].isHittable)
        XCTAssertTrue(app.buttons["calibration-apply"].isHittable)
        XCTAssertTrue(app.buttons["calibration-apply"].isEnabled)
        attach(app, name: "Calibration - landscape")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["roll-calibrate"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["roll-clear-calibration"].exists)
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testPrecisionCalibrationCanAdjustRetapAndUndoWithoutLosingTheOtherPoint() {
        let app = XCUIApplication()
        app.launchArguments = ["--shot-geometry-capture", "--roll-distance-ui-review", "--roll-calibration-ui-fixture"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["roll-calibrate"].waitForExistence(timeout: 10))
        app.buttons["roll-calibrate"].tap()
        let photo = app.images["calibration-canvas"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["calibration-nudge-up"].isEnabled)
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        XCTAssertEqual(app.images["calibration-loupe"].label, "Magnified paper centre A")
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        XCTAssertEqual(app.images["calibration-loupe"].label, "Magnified paper centre B")
        let originalFit = app.staticTexts["calibration-fit-summary"].label
        for _ in 0..<6 { app.buttons["calibration-nudge-down"].tap() }
        XCTAssertNotEqual(app.staticTexts["calibration-fit-summary"].label, originalFit)
        for _ in 0..<6 { app.buttons["calibration-nudge-up"].tap() }
        XCTAssertEqual(app.staticTexts["calibration-fit-summary"].label, originalFit)
        app.buttons["calibration-adjust-A"].tap()
        XCTAssertEqual(app.images["calibration-loupe"].label, "Magnified paper centre A")
        attach(app, name: "Calibration precision - inspect and adjust A")

        app.buttons["calibration-retap"].tap()
        XCTAssertTrue(app.staticTexts["Tap the centre of paper A again."].exists)
        XCTAssertFalse(app.buttons["calibration-apply"].isEnabled)
        XCTAssertFalse(app.buttons["calibration-nudge-up"].isEnabled)
        app.buttons["calibration-retap"].tap()
        XCTAssertTrue(app.buttons["calibration-apply"].isEnabled)
        app.buttons["calibration-retap"].tap()
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.75)).tap()
        XCTAssertTrue(app.staticTexts["2 of 2 centres selected"].exists)
        XCTAssertEqual(app.images["calibration-loupe"].label, "Magnified paper centre A")
        XCTAssertTrue(app.buttons["calibration-apply"].isEnabled)
        app.buttons["calibration-undo"].tap()
        XCTAssertTrue(app.staticTexts["1 of 2 centres selected"].exists)
        XCTAssertFalse(app.buttons["calibration-adjust-B"].isEnabled)
        XCTAssertFalse(app.buttons["calibration-apply"].isEnabled)
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        app.buttons["calibration-apply"].tap()
        XCTAssertTrue(app.staticTexts["3.00 m spacing applied • check separate 1 m and 2 m marks"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCalibrationCanBeRepeatedWithoutLeavingPowerShot() {
        let app = XCUIApplication()
        app.launchArguments = ["--shot-geometry-capture", "--roll-distance-ui-review", "--roll-calibration-ui-fixture"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        for attempt in 1...3 {
            let calibrate = app.buttons["roll-calibrate"]
            XCTAssertTrue(calibrate.waitForExistence(timeout: 10))
            XCTAssertTrue(calibrate.isEnabled)
            XCTAssertEqual(calibrate.label, attempt == 1 ? "Calibrate distance" : "Recalibrate")
            calibrate.tap()
            let photo = app.images["calibration-canvas"]
            XCTAssertTrue(photo.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["0 of 2 centres selected"].exists)
            XCTAssertFalse(app.buttons["calibration-apply"].isEnabled)
            photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
            photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
            XCTAssertTrue(app.buttons["calibration-apply"].isEnabled)
            app.buttons["calibration-apply"].tap()
            XCTAssertTrue(app.staticTexts["3.00 m spacing applied • check separate 1 m and 2 m marks"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["roll-calibrate"].isEnabled)
            attach(app, name: "Calibration - repeated application \(attempt)")
        }

        app.buttons["roll-calibrate"].tap()
        XCTAssertTrue(app.images["calibration-canvas"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["3.00 m spacing applied • check separate 1 m and 2 m marks"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["roll-calibrate"].label, "Recalibrate")
        app.buttons["roll-clear-calibration"].tap()
        XCTAssertEqual(app.buttons["roll-calibrate"].label, "Calibrate distance")
        XCTAssertTrue(app.buttons["roll-calibrate"].isEnabled)
    }

    @MainActor
    func testCalibrationLossExplainsRecoveryInsteadOfShowingStaleZero() {
        let app = XCUIApplication()
        app.launchArguments = ["--shot-geometry-capture", "--roll-distance-ui-review", "--roll-speed-ui-fixture", "--roll-calibration-ui-invalidated"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.staticTexts["roll-distance-value"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["roll-distance-value"].label, "Recalibrate")
        XCTAssertEqual(app.staticTexts["roll-speed-value"].label, "— km/h")
        XCTAssertFalse(app.staticTexts["roll-speed-peak"].exists)
        XCTAssertEqual(app.staticTexts["roll-speed-status"].label, "Recalibrate to estimate speed")
        XCTAssertTrue(app.staticTexts["Distance paused • calibration required"].exists)
        XCTAssertTrue(app.staticTexts["Camera angle changed — calibrate again. Tap Recalibrate before recording again."].exists)
        XCTAssertFalse(app.staticTexts["0.00 m"].exists)
        XCTAssertEqual(app.buttons["roll-calibrate"].label, "Recalibrate")
        XCTAssertTrue(app.buttons["roll-calibrate"].isEnabled)
        XCTAssertFalse(app.buttons["power-shot-record"].isEnabled)
        XCTAssertFalse(app.buttons["roll-set-start"].isEnabled)
        attach(app, name: "Calibration lost - clear recovery state")
        app.buttons["roll-clear-calibration"].tap()
        XCTAssertEqual(app.staticTexts["roll-distance-value"].label, "Start not set")
        XCTAssertEqual(app.buttons["roll-calibrate"].label, "Calibrate distance")
        XCTAssertFalse(app.staticTexts["Distance paused • calibration required"].exists)
    }

    @MainActor
    func testStoppedRollingReadoutKeepsPeakWithoutShowingLiveMotion() {
        let app = XCUIApplication()
        app.launchArguments = ["--shot-geometry-capture", "--roll-distance-ui-review", "--roll-speed-ui-fixture", "--roll-speed-ui-stopped"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.staticTexts["roll-speed-value"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["roll-speed-value"].label, "— km/h")
        XCTAssertEqual(app.staticTexts["roll-speed-status"].label, "Recording stopped")
        XCTAssertEqual(app.staticTexts["roll-speed-peak"].label, "Peak rolling speed: 2.8 km/h")
        XCTAssertTrue(app.staticTexts["last estimate"].exists)
        attach(app, name: "Rolling speed - stopped with peak")
    }

    @MainActor
    func testPortraitPhotoTapsReturnToOriginalSensorCoordinates() {
        let app = XCUIApplication()
        app.launchArguments = ["--shot-geometry-capture", "--roll-distance-ui-review", "--roll-calibration-ui-fixture", "--roll-calibration-ui-portrait-photo"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["roll-calibrate"].waitForExistence(timeout: 10))
        app.buttons["roll-calibrate"].tap()
        let photo = app.images["calibration-canvas"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["calibration-apply"].isEnabled)
        let summary = app.staticTexts["calibration-fit-summary"].label.split(separator: " ")
        // Screen taps round to display pixels; the analytic pinhole baseline
        // is 3.50 m, but exact text equality would test pixel rounding.
        XCTAssertEqual(summary.count > 2 ? Float(summary[2]) ?? -1 : -1, 3.5, accuracy: 0.06)
        attach(app, name: "Calibration - portrait sensor rotation")
        app.buttons["calibration-apply"].tap()
        XCTAssertTrue(app.staticTexts["3.00 m spacing applied • check separate 1 m and 2 m marks"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testIndependentGapCheckShowsMismatchCanBeCorrectedAndAppliesAcrossOrientations() {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            let app = XCUIApplication()
            app.launchArguments = ["--shot-geometry-capture", "--roll-distance-ui-review", "--roll-calibration-ui-fixture", "--roll-calibration-ui-portrait-photo"]
            XCUIDevice.shared.orientation = orientation; app.launch()
            XCTAssertTrue(app.buttons["roll-calibrate"].waitForExistence(timeout: 10))
            app.buttons["roll-calibrate"].tap()
            let photo = app.images["calibration-canvas"]
            XCTAssertTrue(photo.waitForExistence(timeout: 5))
            photo.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
            photo.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
            app.buttons["calibration-check-gap"].tap()
            XCTAssertTrue(app.buttons["span-check-save"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["span-check-save"].isEnabled)
            let checkPhoto = app.images["span-check-canvas"]
            checkPhoto.coordinate(withNormalizedOffset: CGVector(dx: 1.0/3, dy: 0.5)).tap()
            checkPhoto.coordinate(withNormalizedOffset: CGVector(dx: 0.383333, dy: 0.5)).tap()
            XCTAssertTrue(app.staticTexts["span-check-result"].exists)
            XCTAssertTrue(app.buttons["span-check-save"].isEnabled)
            attach(app, name: "Gap check - mismatch \(orientation.rawValue)")
            app.buttons["span-check-save"].tap()
            XCTAssertTrue(app.staticTexts["calibration-check-mismatch"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["calibration-apply"].isEnabled)
            app.buttons["calibration-check-gap"].tap()
            XCTAssertTrue(app.buttons["span-check-undo"].waitForExistence(timeout: 5))
            app.buttons["span-check-undo"].tap(); app.buttons["span-check-undo"].tap()
            checkPhoto.coordinate(withNormalizedOffset: CGVector(dx: 1.0/3, dy: 0.5)).tap()
            checkPhoto.coordinate(withNormalizedOffset: CGVector(dx: 0.375, dy: 0.5)).tap()
            attach(app, name: "Gap check - matching \(orientation.rawValue)")
            app.buttons["span-check-save"].tap()
            XCTAssertTrue(app.staticTexts["calibration-check-result"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["calibration-check-mismatch"].exists)
            XCTAssertTrue(app.buttons["calibration-apply"].isHittable)
            XCTAssertTrue(app.buttons["calibration-apply"].isEnabled)
            app.buttons["calibration-apply"].tap()
            XCTAssertTrue(app.buttons["roll-clear-calibration"].waitForExistence(timeout: 5))
            app.terminate()
        }
        XCUIDevice.shared.orientation = .portrait
    }
}
