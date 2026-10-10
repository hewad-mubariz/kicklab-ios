import XCTest

final class CaptureFlowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testReadyCaptureHasSessionAndMetricsWithoutEditingTools() {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES"]
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
        // "Counter style" morphs into the tray, opened straight on the styles.
        app.buttons["replay-customize"].tap()
        XCTAssertTrue(app.buttons["counter-style-normal"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["replay-export"].exists, "Counter styles open in the tray, not a sheet")
        attach(app, "Editor - counter styles from the selected counter")
        app.buttons["replay-close-tools"].tap()
        XCTAssertTrue(app.buttons["replay-select-counter"].waitForExistence(timeout: 3))
        app.buttons["replay-select-counter"].tap()
        XCTAssertTrue(app.buttons["replay-remove-counter"].waitForExistence(timeout: 3))
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
        // Tools open in place inside the panel; the editor stays on screen.
        XCTAssertTrue(app.switches["Show elapsed time"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["replay-export"].exists)
        app.buttons["replay-tools-back"].tap()
        XCTAssertTrue(app.buttons["replay-tool-counter"].waitForExistence(timeout: 3))
        app.buttons["replay-tool-counter"].tap()
        // Counter styles open in place like the other tools, and apply live.
        let normal = app.buttons["counter-style-normal"], odometer = app.buttons["counter-style-odometer"]
        XCTAssertTrue(normal.waitForExistence(timeout: 5))
        XCTAssertTrue(normal.isSelected)
        XCTAssertTrue(app.switches["counter-show"].exists)
        XCTAssertFalse(app.sliders["Counter size"].exists, "Placement is by gesture, not sliders")
        attach(app, "Counter styles - normal default and alternatives")
        odometer.tap()
        XCTAssertTrue(odometer.isSelected)
        normal.tap()
        XCTAssertTrue(normal.isSelected)
        app.buttons["replay-close-tools"].tap()

        // Download saves in place: no Save & Share page, then share and next steps.
        XCTAssertTrue(app.startReplayDownload(), "Download starts at once")
        attach(app, "Download - saving in place")
        XCTAssertTrue(app.waitForReplaySaved(timeout: 240), "The replay is saved to Photos")
        XCTAssertTrue(app.buttons["replay-record-another"].exists)
        XCTAssertTrue(app.buttons["replay-done"].exists)
        attach(app, "Download - saved, share and next steps")
    }

    @MainActor
    func testClassicCounterCanBeSelectedAndKeptAlongsideNormal() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This fixture path is only available in the simulator")
        #endif
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kicklabTests/Fixtures/juggling-eighteen.mov").path
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "capture-flow", "--session-video", fixture]
        app.launch()
        XCTAssertTrue(app.buttons["replay-customize"].waitForExistence(timeout: 15))
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-counter"].tap()
        let normal = app.buttons["counter-style-normal"], classic = app.buttons["counter-style-classic"]
        XCTAssertTrue(classic.waitForExistence(timeout: 5))
        XCTAssertTrue(normal.isSelected)
        XCTAssertTrue(app.buttons["counter-style-odometer"].exists)
        attach(app, "Counter styles - Normal and Classic")
        classic.tap()
        XCTAssertTrue(classic.isSelected)
        attach(app, "Counter styles - Classic original design")
        app.buttons["replay-close-tools"].tap()
        attach(app, "Replay - Classic counter")
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-counter"].tap()
        XCTAssertTrue(classic.waitForExistence(timeout: 5))
        XCTAssertTrue(classic.isSelected, "The chosen style is kept")
        normal.tap()
        XCTAssertTrue(normal.isSelected)
        app.buttons["replay-close-tools"].tap()
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
        let chrome = app.buttons["ball-picker-chrome"]
        XCTAssertTrue(chrome.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["replay-export"].exists, "Ball choices open in place, not in a sheet")
        chrome.tap()
        XCTAssertTrue(chrome.isSelected)
        attach(app, "Ball page - picks apply live")
        app.buttons["replay-tools-back"].tap()

        app.buttons["replay-tool-effects"].tap()
        let fire = app.buttons["effect-picker-fire"], ice = app.buttons["effect-picker-ice"]
        XCTAssertTrue(fire.waitForExistence(timeout: 5))
        XCTAssertTrue(fire.isSelected)
        ice.tap()
        XCTAssertTrue(ice.isSelected)
        XCTAssertTrue(app.sliders["Effect intensity"].exists)
        attach(app, "Effects page - ball effect icons")
        app.buttons["replay-tools-back"].tap()

        app.buttons["replay-tool-ball"].tap()
        XCTAssertTrue(chrome.waitForExistence(timeout: 5))
        XCTAssertTrue(chrome.isSelected, "Changing the effect must keep the ball")
        app.buttons["ball-picker-original"].tap()
        app.buttons["replay-tools-back"].tap()

        app.buttons["replay-tool-effects"].tap()
        XCTAssertTrue(ice.waitForExistence(timeout: 5))
        XCTAssertTrue(ice.isSelected, "Changing the ball must preserve the effect")
        app.buttons["replay-close-tools"].tap()
        XCTAssertTrue(app.buttons["replay-customize"].waitForExistence(timeout: 3))
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
