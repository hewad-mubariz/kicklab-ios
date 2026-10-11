import XCTest

/// Camera controls and warmup do not require a subscription or StoreKit.
final class CapturePreparationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testCaptureControlsHideDuringRecordingAndRestoreAfterStop() {
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "capture-controls"]
        app.launch()
        let record = app.buttons["record-capture-button"]
        let gallery = app.buttons["record-gallery-picker"]
        let flip = app.buttons["record-flip-camera"]
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        XCTAssertTrue(gallery.isHittable)
        XCTAssertTrue(flip.isHittable)
        XCTAssertGreaterThanOrEqual(gallery.frame.height, 44)
        XCTAssertGreaterThanOrEqual(flip.frame.height, 44)
        gallery.tap()
        XCTAssertTrue(app.staticTexts["Gallery selected"].exists)
        flip.tap()
        XCTAssertTrue(app.staticTexts["Camera flipped"].exists)
        attach(app, "Capture controls - ready")
        let center = record.frame.midX
        record.tap()
        XCTAssertEqual(record.value as? String, "Stop")
        XCTAssertFalse(gallery.exists)
        XCTAssertFalse(flip.exists)
        XCTAssertEqual(record.frame.midX, center, accuracy: 1)
        // Capture the final digits, after the intentional numeric transition.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        attach(app, "Capture controls - recording")
        record.tap()
        XCTAssertTrue(gallery.waitForExistence(timeout: 3))
        XCTAssertTrue(flip.isHittable)
        XCTAssertEqual(record.value as? String, "Record")
    }

    @MainActor
    func testPreparationDisablesOnlyRecordingAndAllowsClosing() {
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "capture-preparing"]
        app.launch()
        let record = app.buttons["record-capture-button"]
        let flip = app.buttons["record-flip-camera"]
        let gallery = app.buttons["record-gallery-picker"]
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        XCTAssertFalse(record.isEnabled)
        XCTAssertEqual(record.value as? String, "Getting ready")
        XCTAssertTrue(flip.isEnabled)
        XCTAssertTrue(gallery.isEnabled)
        flip.tap()
        XCTAssertTrue(app.staticTexts["Camera flipped"].exists)
        gallery.tap()
        XCTAssertTrue(app.staticTexts["Gallery selected"].exists)
        XCTAssertFalse(record.isEnabled)
        XCTAssertFalse(app.otherElements["capture-preparation-overlay"].exists)
        attach(app, "Camera preparation - small banner and disabled Record")
        let close = app.buttons["capture-close"]
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(app.staticTexts["capture-review-closed"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
