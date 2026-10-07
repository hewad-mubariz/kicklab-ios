import XCTest

final class CaptureFlowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testReadyCaptureHasSessionAndMetricsWithoutEditingTools() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 10))
        app.buttons["module-juggling"].tap()
        XCTAssertTrue(app.buttons["record-gallery-picker"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["capture-session-name"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["capture-touch-counter"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["capture-elapsed-time"].exists)
        XCTAssertFalse(app.buttons["replay-customize"].exists)
        XCTAssertFalse(app.buttons["Test ball model"].exists)
        attach(app, "Capture - actual ready screen")
        app.buttons["capture-close"].tap()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testStoppedFlowOpensEditorAndToolboxThenExport() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This fixture path is only available in the simulator")
        #endif
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kicklabTests/Fixtures/juggling-eighteen.mov").path
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "capture-flow", "--session-video", fixture]
        app.launch()
        XCTAssertTrue(app.buttons["replay-export"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Session Complete!"].exists)
        XCTAssertFalse(app.buttons["record-gallery-picker"].exists)
        XCTAssertTrue(app.buttons["replay-select-counter"].waitForExistence(timeout: 15))
        app.buttons["replay-play"].tap()
        XCTAssertEqual(app.buttons["replay-play"].label, "Pause video")
        app.buttons["replay-play"].tap()
        attach(app, "Stopped session - editor")
        app.buttons["replay-select-counter"].tap()
        XCTAssertTrue(app.buttons["replay-remove-counter"].waitForExistence(timeout: 3))
        attach(app, "Editor - counter selected")
        app.buttons["replay-remove-counter"].tap()
        XCTAssertTrue(app.buttons["replay-select-counter"].waitForNonExistence(timeout: 3))
        app.buttons["replay-reset"].tap()
        XCTAssertTrue(app.buttons["replay-select-counter"].waitForExistence(timeout: 3))
        app.buttons["replay-customize"].tap()
        attach(app, "Editor - after opening tools")
        XCTAssertTrue(app.buttons["replay-tool-counter"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["replay-tool-timer"].exists)
        XCTAssertTrue(app.buttons["replay-tool-ball"].exists)
        XCTAssertTrue(app.buttons["replay-tool-effects"].exists)
        XCTAssertTrue(app.buttons["replay-tool-graph"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Backgrounds, coming soon"].exists)
        XCTAssertFalse(app.staticTexts["Close tools"].exists)
        let closeTools = app.buttons["replay-close-tools"]
        XCTAssertTrue(closeTools.isHittable)
        XCTAssertGreaterThanOrEqual(closeTools.frame.height, 44)
        attach(app, "Editor - floating toolbox")
        closeTools.tap()
        XCTAssertTrue(app.buttons["replay-tool-counter"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.sliders["Video position"].exists)
        app.buttons["replay-customize"].tap()
        XCTAssertTrue(app.buttons["replay-tool-timer"].waitForExistence(timeout: 3))
        app.buttons["replay-tool-timer"].tap()
        XCTAssertTrue(app.switches["Show elapsed time"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()

        openTool("counter", in: app)
        let chooseStyle = app.buttons["counter-choose-style"]
        XCTAssertTrue(chooseStyle.waitForExistence(timeout: 5))
        XCTAssertTrue(chooseStyle.label.contains("Normal"))
        chooseStyle.tap()
        XCTAssertTrue(app.buttons["counter-style-normal"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["counter-style-normal"].isSelected)
        attach(app, "Counter styles - normal default and alternatives")
        app.buttons["counter-style-particleBurst"].tap()
        XCTAssertTrue(chooseStyle.waitForExistence(timeout: 3))
        XCTAssertTrue(chooseStyle.label.contains("Particle Burst"))
        chooseStyle.tap()
        app.buttons["counter-style-normal"].tap()
        XCTAssertTrue(chooseStyle.waitForExistence(timeout: 3))
        app.buttons["counter-editor-done"].tap()

        app.buttons["replay-export"].tap()
        XCTAssertTrue(app.staticTexts["Save & Share"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testBallReplacementAndEffectsApplyIndependently() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This fixture path is only available in the simulator")
        #endif
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kicklabTests/Fixtures/juggling-eighteen.mov").path
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "capture-flow", "--session-video", fixture]
        app.launch()
        XCTAssertTrue(app.buttons["replay-export"].waitForExistence(timeout: 15))

        openTool("ball", in: app)
        XCTAssertTrue(app.buttons["ball-picker-chrome"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Choose an Effect"].exists)
        app.buttons["ball-picker-chrome"].tap()
        attach(app, "Ball picker - modern replacements")
        app.buttons["ball-picker-apply"].tap()

        openTool("effects", in: app)
        XCTAssertTrue(app.buttons["effect-picker-fire"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["effect-picker-fire"].isSelected)
        app.buttons["effect-picker-ice"].tap()
        app.buttons["effect-picker-apply"].tap()

        openTool("ball", in: app)
        XCTAssertTrue(app.buttons["ball-picker-chrome"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ball-picker-chrome"].isSelected)
        app.buttons["ball-picker-arctic"].tap()
        app.buttons["ball-picker-close"].tap()

        openTool("ball", in: app)
        XCTAssertTrue(app.buttons["ball-picker-chrome"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ball-picker-chrome"].isSelected, "Closing must discard the draft ball")
        app.buttons["ball-picker-original"].tap()
        app.buttons["ball-picker-apply"].tap()

        openTool("effects", in: app)
        XCTAssertTrue(app.buttons["effect-picker-ice"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["effect-picker-ice"].isSelected, "Changing the ball must preserve the effect")
        app.buttons["effect-picker-close"].tap()
    }

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
    private func openTool(_ name: String, in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["replay-customize"].waitForExistence(timeout: 5))
        app.buttons["replay-customize"].tap()
        let tool = app.buttons["replay-tool-\(name)"]
        XCTAssertTrue(tool.waitForExistence(timeout: 3))
        tool.tap()
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
