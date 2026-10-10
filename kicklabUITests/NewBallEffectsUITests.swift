import XCTest

final class NewBallEffectsUITests: XCTestCase {
    @MainActor
    func testAllSixEffectsAreSelectableAndBallSelectionSurvives() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Requires the local video fixture")
        #endif
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kicklabTests/Fixtures/juggling-eighteen.mov").path
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "capture-flow", "--session-video", fixture]
        app.launch()
        XCTAssertTrue(app.buttons["replay-customize"].waitForExistence(timeout: 20))
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-ball"].tap()
        app.buttons["ball-picker-chrome"].tap()
        app.buttons["replay-tools-back"].tap()
        app.buttons["replay-tool-effects"].tap()
        XCTAssertFalse(app.buttons["effect-picker-shadow"].exists)
        XCTAssertFalse(app.buttons["effect-picker-pixel"].exists)
        for style in ["labFlame", "glowTrail", "blueFlame", "emberWake", "flameRibbon", "heatPulse"] {
            let button = app.buttons["effect-picker-\(style)"]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            XCTAssertTrue(button.isHittable, "\(style) must fit in the effects panel")
            button.tap()
            XCTAssertTrue(button.isSelected)
        }
        let picker = XCTAttachment(screenshot: app.screenshot())
        picker.name = "Six new effects - native picker"; picker.lifetime = .keepAlways; add(picker)
        app.buttons["replay-tools-back"].tap()
        app.buttons["replay-tool-ball"].tap()
        XCTAssertTrue(app.buttons["ball-picker-chrome"].isSelected)
        app.buttons["replay-close-tools"].tap()
        app.buttons["replay-play"].tap()
        XCTAssertEqual(app.buttons["replay-play"].label, "Pause video")
        app.buttons["replay-play"].tap()
        XCTAssertTrue(app.startReplayDownload(), "Download starts in place")
    }
}
