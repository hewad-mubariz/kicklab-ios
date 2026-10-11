import XCTest

@MainActor
final class BallDistanceDeviceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testRealRecordingOpensEffectsAndReturnsToReadyWithoutGroundSetup() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical camera")
        #else
        let app = XCUIApplication()
        app.launchArguments = ["--ball-distance-design", "live"]
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let record = app.buttons["ball-distance-record"]
            XCTAssertTrue(record.waitForExistence(timeout: 20))
            wait(record, "enabled == true", timeout: 20)
            XCTAssertFalse(app.staticTexts["ball-distance-value"].exists)
            record.tap()
            wait(app.staticTexts["ball-distance-recording-status"], "label CONTAINS '0:02'", timeout: 15)
            record.tap()
            XCTAssertTrue(app.buttons["shot-effects-customize"].waitForExistence(timeout: 120))
            XCTAssertFalse(app.staticTexts["ball-distance-value"].exists)
            XCTAssertFalse(app.descendants(matching: .any)["capture-touch-counter"].exists)
            attach(orientation == .portrait ? "Recorded portrait - effects" : "Recorded landscape - effects")
            app.buttons["shot-effects-close"].tap()
            XCTAssertTrue(record.waitForExistence(timeout: 10))
            wait(record, "enabled == true", timeout: 20)
        }
        #endif
    }

    private func wait(_ element: XCUIElement, _ predicate: String, timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
