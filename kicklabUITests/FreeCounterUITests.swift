import XCTest

/// Uses the main app's real free-access path without requiring a StoreKit purchase session.
@MainActor
final class FreeCounterUITests: XCTestCase {
    func testFreeReplayKeepsCounterAndTimerWhilePremiumChoicesOpenPaywall() {
        continueAfterFailure = false
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kicklabTests/Fixtures/juggling-eighteen.mov").path
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "motion-replay", "--session-video", fixture]
        app.launch()
        XCTAssertTrue(app.buttons["replay-customize"].waitForExistence(timeout: 20))
        let timer = app.descendants(matching: .any)["replay-elapsed-time"].firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["replay-select-counter"].exists)
        attach(app, "Free replay with Normal counter and timer")
        app.buttons["replay-customize"].tap()
        XCTAssertFalse(app.buttons["replay-tool-timer"].label.contains("Pro"))
        XCTAssertFalse(app.buttons["replay-tool-counter"].label.contains("Pro"))
        app.buttons["replay-tool-timer"].tap()
        let timerSwitch = app.switches["Show elapsed time"]
        XCTAssertTrue(timerSwitch.waitForExistence(timeout: 5))
        timerSwitch.switches.firstMatch.tap()
        XCTAssertTrue(timer.waitForNonExistence(timeout: 5))
        timerSwitch.switches.firstMatch.tap()
        XCTAssertTrue(timer.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["pro-close"].exists)
        app.buttons["replay-tools-back"].tap()
        app.buttons["replay-tool-counter"].tap()
        XCTAssertTrue(app.buttons["counter-style-normal"].waitForExistence(timeout: 5))
        app.buttons["counter-style-normal"].tap()
        XCTAssertFalse(app.buttons["pro-close"].exists)
        app.buttons["counter-style-jelly"].tap()
        XCTAssertTrue(app.buttons["pro-close"].waitForExistence(timeout: 5))
        app.buttons["pro-close"].tap()
        XCTAssertTrue(app.buttons["counter-style-normal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["counter-style-normal"].isSelected)
        app.switches["counter-show"].tap()
        XCTAssertTrue(app.buttons["replay-select-counter"].waitForNonExistence(timeout: 5))
        app.switches["counter-show"].tap()
        XCTAssertTrue(app.buttons["replay-select-counter"].waitForExistence(timeout: 5))
        app.buttons["replay-tools-back"].tap()
        for tool in ["ball", "effects", "graph"] {
            XCTAssertTrue(app.buttons["replay-tool-\(tool)"].label.contains("Pro"))
            app.buttons["replay-tool-\(tool)"].tap()
            XCTAssertTrue(app.buttons["pro-close"].waitForExistence(timeout: 5))
            app.buttons["pro-close"].tap()
            XCTAssertTrue(app.buttons["replay-tool-\(tool)"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["replay-tools-back"].exists)
        }
        attach(app, "Free tools and locked Pro effects")
        app.buttons["replay-close-tools"].tap()
        XCTAssertTrue(app.buttons["replay-export"].isEnabled)
        XCTAssertTrue(timer.exists)
        XCTAssertTrue(app.buttons["replay-select-counter"].exists)
    }

    func testFinalValidationPanelExposesDurationLadderAndArming() {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kicklabTests/Fixtures/juggling-eighteen.mov").path
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "motion-replay", "--session-video", fixture]
        app.launch()
        XCTAssertTrue(app.buttons["debug-final-tests"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["debug-thermal-state"].exists)
        app.buttons["debug-final-tests"].tap()
        for seconds in [30, 60, 120, 180, 300, 600, 900] {
            XCTAssertTrue(app.buttons["final-test-arm-\(seconds)"].waitForExistence(timeout: 5))
        }
        attach(app, "Final validation duration ladder")
        app.buttons["final-test-arm-900"].tap()
        XCTAssertTrue(app.staticTexts["Test armed: 15 min"].waitForExistence(timeout: 5))
        app.buttons["debug-final-tests"].tap()
        app.buttons["Disarm"].tap()
        app.buttons["Done"].tap()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
