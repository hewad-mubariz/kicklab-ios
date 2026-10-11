import XCTest

final class BallDistanceUITests: ProReplayUITestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

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
