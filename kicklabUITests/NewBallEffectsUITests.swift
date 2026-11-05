import XCTest

final class NewBallEffectsUITests: ProReplayUITestCase {
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
        XCTAssertTrue(app.buttons["ball-picker-chrome"].waitForStableFrame())
        app.buttons["ball-picker-chrome"].tap()
        XCTAssertTrue(app.buttons["ball-picker-chrome"].isSelected,
                      "The Chrome pick must take effect before leaving the ball panel")
        app.buttons["replay-tools-back"].tap()
        XCTAssertTrue(app.buttons["replay-tool-effects"].waitForStableFrame(),
                      "Wait for the tool tray to settle before tapping Effects")
        app.buttons["replay-tool-effects"].tap()
        XCTAssertFalse(app.buttons["effect-picker-shadow"].exists)
        XCTAssertFalse(app.buttons["effect-picker-pixel"].exists)
        XCTAssertFalse(app.buttons["effect-picker-labFlame"].exists)
        for style in ["glowTrail", "blueFlame", "emberWake", "flameRibbon", "heatPulse"] {
            let button = app.buttons["effect-picker-\(style)"]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            XCTAssertTrue(button.isHittable, "\(style) must fit in the effects panel")
            button.tap()
            XCTAssertTrue(button.isSelected)
        }
        let picker = XCTAttachment(screenshot: app.screenshot())
        picker.name = "Five new effects - native picker"; picker.lifetime = .keepAlways; add(picker)
        app.buttons["replay-tools-back"].tap()
        XCTAssertTrue(app.buttons["replay-tool-ball"].waitForStableFrame())
        app.buttons["replay-tool-ball"].tap()
        XCTAssertTrue(app.buttons["ball-picker-chrome"].waitForStableFrame())
        let selected = app.buttons.matching(NSPredicate(format: "selected == true"))
            .allElementsBoundByIndex.map(\.identifier)
        XCTAssertTrue(app.buttons["ball-picker-chrome"].isSelected,
                      "Changing effects must preserve Chrome. Selected buttons: \(selected)")
        app.buttons["replay-close-tools"].tap()
        app.buttons["replay-play"].tap()
        XCTAssertEqual(app.buttons["replay-play"].label, "Pause video")
        app.buttons["replay-play"].tap()
        XCTAssertTrue(app.startReplayDownload(), "Download starts in place")
    }
}
