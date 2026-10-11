import XCTest

final class BallCollectionUITests: ProReplayUITestCase {
    @MainActor
    func testAllFourNewBallsFitAndSelectionSurvivesReopening() {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kicklabTests/Fixtures/juggling-eighteen.mov").path
        #else
        let fixture = "documents:pro-access-juggling.mov"
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "motion-replay", "--session-video", fixture]
        app.launch()
        XCTAssertTrue(app.buttons["replay-customize"].waitForExistence(timeout: 20))
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-ball"].tap()
        XCTAssertTrue(app.buttons["ball-picker-classic"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ball-picker-classic"].isHittable, "Existing styles still fit")
        for skin in ["metal", "lava", "pearl", "volt"] {
            let button = app.buttons["ball-picker-\(skin)"]
            XCTAssertTrue(button.isHittable)
            button.tap()
            app.buttons["replay-tools-back"].tap()
            app.buttons["replay-tool-ball"].tap()
            XCTAssertTrue(button.isSelected, "\(skin) must commit to the clip")
            XCTAssertFalse(app.descendants(matching: .any)["pro-style-badge"].firstMatch.exists)
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Four new ball materials in the Pro picker"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["ball-picker-original"].tap()
        app.buttons["replay-tools-back"].tap()
        app.buttons["replay-tool-ball"].tap()
        XCTAssertTrue(app.buttons["ball-picker-original"].isSelected)
        app.buttons["replay-close-tools"].tap()
        XCTAssertFalse(app.staticTexts["replay-spin-status"].exists)
    }
}
