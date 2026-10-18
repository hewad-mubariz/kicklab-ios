#if POWER_SHOT_DEBUG
import XCTest

@MainActor
final class PowerShotLabUITests: XCTestCase {
    override func tearDown() { XCUIDevice.shared.orientation = .portrait }

    func testGuidedChecklistSelectsTrialPersistsAndDoesNotCompleteWithoutEvidence() {
        let app = XCUIApplication()
        app.launchArguments = ["--roll-distance-ui-review", "--roll-distance-ui-ready"]
        app.launch()
        XCTAssertTrue(app.buttons["lab-checklist"].waitForExistence(timeout: 10))
        app.buttons["lab-checklist"].tap()
        let listImage = XCTAttachment(screenshot: app.screenshot())
        listImage.name = "Training checklist"; listImage.lifetime = .keepAlways; add(listImage)
        app.buttons["lab-step-stationary"].tap()
        XCTAssertTrue(app.staticTexts["0 / 2 complete · 0 saved"].exists)
        let stepImage = XCTAttachment(screenshot: app.screenshot())
        stepImage.name = "Guided stationary step"; stepImage.lifetime = .keepAlways; add(stepImage)
        app.buttons["lab-use-step"].tap()
        XCTAssertTrue(app.staticTexts["Keep the ball still · 0/2 reviewed"].waitForExistence(timeout: 3))
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["Keep the ball still · 0/2 reviewed"].waitForExistence(timeout: 10))
        app.buttons["lab-checklist"].tap()
        app.buttons["lab-step-calibration"].tap()
        let gap = app.textFields["lab-step-gap"]
        gap.tap()
        gap.typeText("No tape today")
        let enteredText = gap.value as? String ?? ""
        XCTAssertTrue(enteredText.contains("No tape today"))
        app.buttons["lab-save-gap"].tap()
        app.buttons["lab-checklist-camera"].tap()
        app.buttons["lab-checklist"].tap()
        XCTAssertTrue(app.staticTexts["Gap: \(enteredText)"].waitForExistence(timeout: 3))
    }

    func testPenaltySetupAndEvidenceOnlyModeDoNotInventMeasurement() {
        let app = XCUIApplication()
        app.launchArguments = ["--roll-distance-ui-review", "--roll-distance-ui-ready"]
        app.launch()
        XCTAssertTrue(app.buttons["Evidence only"].waitForExistence(timeout: 10))
        app.buttons["Evidence only"].tap()
        XCTAssertTrue(app.staticTexts["Video + diagnostics · no live measurement"].exists)
        XCTAssertFalse(app.buttons["lab-record"].isEnabled, "Preview has no actual camera frame")
        app.buttons["Trial setup"].tap()
        let penaltyToggle = app.switches["Penalty / goal-line check"]
        if penaltyToggle.value as? String != "1" { penaltyToggle.switches.firstMatch.tap() }
        XCTAssertEqual(penaltyToggle.value as? String, "1")
        XCTAssertTrue(app.textFields["Spot to goal line (m)"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["Spot to goal line (m)"].value as? String, "11")
        app.buttons["Done"].tap()
        app.buttons["AR estimates"].tap()
        XCTAssertTrue(app.staticTexts["Start not set"].exists)
    }

    func testIsolatedRecorderSetupAndDiagnosticsAreReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--roll-distance-ui-review", "--roll-distance-ui-ready"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Power Shot Lab"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["lab-record"].isHittable)
        app.buttons["Trial setup"].tap()
        XCTAssertTrue(app.textFields["Surface / lighting / phone support"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(app.buttons["lab-diagnostics"].waitForExistence(timeout: 3))
        app.buttons["lab-diagnostics"].tap()
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(app.staticTexts["AR tracking"].exists)
        XCTAssertTrue(app.buttons["lab-record"].isHittable)
        app.buttons["lab-saved-tests"].tap()
        XCTAssertTrue(app.staticTexts["No saved shots yet"].waitForExistence(timeout: 3))
        app.buttons["saved-shots-done"].tap()
        XCTAssertTrue(app.buttons["lab-record"].waitForExistence(timeout: 3))
    }

    func testLandscapeKeepsRecordingAndCalibrationAccessible() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--roll-distance-ui-review", "--roll-distance-ui-ready", "--roll-calibration-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["lab-record"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["lab-record"].isHittable)
        app.buttons["lab-calibrate"].tap() // XCTest scrolls the actual control into view.
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["lab-record"].isHittable)
    }
}
#endif
