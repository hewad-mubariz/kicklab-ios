import XCTest

final class BallDistanceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testDistanceScreenUsesTheSameControlsInPortraitAndLandscapeWithoutSpeedOrTouches() {
        let app = XCUIApplication()
        app.launchArguments = ["--ball-distance-design", "recording"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.staticTexts["ball-distance-title"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["ball-distance-value"].label, "2.29 m")
        XCTAssertFalse(app.staticTexts["roll-speed-value"].exists)
        XCTAssertFalse(app.switches["roll-distance-toggle"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["capture-touch-counter"].exists)
        XCTAssertTrue(app.buttons["ball-distance-record"].isHittable)
        attach(app, "Ball Distance - portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: app)], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["ball-distance-value"].isHittable)
        XCTAssertTrue(app.buttons["ball-distance-record"].isHittable)
        attach(app, "Ball Distance - landscape")
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testImportStaysAvailableWhileFindingTheGround() {
        let app = XCUIApplication()
        app.launchArguments = ["--ball-distance-design", "setup"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["ball-distance-import"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["ball-distance-import"].isEnabled)
        XCTAssertFalse(app.buttons["ball-distance-record"].isEnabled)
        // No measured-marks setup: ARKit finds the floor, and the distance is marked experimental.
        XCTAssertFalse(app.buttons["ball-distance-setup"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["ball-distance-finding"].exists)
        XCTAssertTrue(app.staticTexts["ball-distance-experimental"].exists)
        XCTAssertEqual(app.staticTexts["ball-distance-value"].label, "— m")
        attach(app, "Ball Distance - setup")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: app)], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["ball-distance-record"].exists)
        XCTAssertTrue(app.buttons["ball-distance-import"].isHittable)
        attach(app, "Ball Distance - setup landscape")
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testPowerShotEditorHasOnlyEffectsAndGraph() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Local visual-review video is available in the simulator")
        #endif
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kicklabTests/Fixtures/juggling-eighteen.mov").path
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "ball-video", "--session-video", fixture]
        app.launch()
        // The processing screen runs first, then the editor takes over.
        let customize = app.buttons["shot-effects-customize"]
        XCTAssertTrue(customize.waitForExistence(timeout: 300))
        XCTAssertFalse(app.buttons["replay-select-counter"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["capture-rhythm"].exists)
        XCTAssertFalse(app.staticTexts["ball-distance-value"].exists, "Ordinary imports must not acquire a guessed distance")
        attach(app, "Power Shot editor")
        customize.tap()
        XCTAssertTrue(app.buttons["shot-tool-effects"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["shot-tool-graph"].exists)
        for tool in ["ball", "timer", "counter", "effects", "graph"] {
            XCTAssertFalse(app.buttons["replay-tool-\(tool)"].exists, "The juggling \(tool) tool is not part of Power Shot")
        }
        attach(app, "Power Shot editor - effects and graph")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
