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
        XCTAssertFalse(app.buttons["ball-distance-saved-tests"].isEnabled)
        XCTAssertFalse(app.staticTexts["ball-distance-value"].exists)
        attach("Ball Distance - recording landscape")
        app.buttons["ball-distance-record"].tap()
        assertReady(app)
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

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
