import XCTest

final class SessionHistoryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func open(_ mode: String, appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES", "-kicklab.appearance", appearance,
                               "--history-review", mode]
        #if targetEnvironment(simulator)
        let video = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kicklabTests/Fixtures/capture-sixty.mov").path
        app.launchArguments += ["--history-review-video", video]
        #endif
        app.launch()
        let button = app.buttons["home-session-history"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        if !button.isHittable { app.swipeUp() }
        button.tap()
        return app
    }

    @MainActor
    func testEmptyHistoryOpensFromHomeAndProfile() {
        let app = open("empty", appearance: "light")
        XCTAssertTrue(app.descendants(matching: .any)["history-empty"].waitForExistence(timeout: 5))
        attach(app, "History empty — light")
        app.buttons["history-close"].tap()
        app.buttons["home-profile"].tap()
        let history = app.buttons["profile-session-history"]
        if !history.isHittable { app.swipeUp() }
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.tap()
        XCTAssertTrue(app.descendants(matching: .any)["history-empty"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSourceFiltersDetailReplayAndPersistence() {
        let app = open("filled", appearance: "dark")
        let recording = app.buttons["history-session-00000000-0000-0000-0000-000000000001"]
        let imported = app.buttons["history-session-00000000-0000-0000-0000-000000000002"]
        XCTAssertTrue(recording.waitForExistence(timeout: 5))
        attach(app, "History list — dark")
        app.segmentedControls["history-filter"].buttons["Imported"].tap()
        XCTAssertTrue(imported.waitForExistence(timeout: 3))
        XCTAssertFalse(recording.exists)
        imported.tap()
        XCTAssertTrue(app.staticTexts["history-no-replay"].waitForExistence(timeout: 3))
        attach(app, "Imported session — no local replay")
        app.navigationBars["Session details"].buttons.element(boundBy: 0).tap()
        app.segmentedControls["history-filter"].buttons["Recorded"].tap()
        recording.tap()
        let replay = app.buttons["history-watch-replay"]
        #if targetEnvironment(simulator)
        XCTAssertTrue(replay.waitForExistence(timeout: 5))
        attach(app, "Recorded session — dark")
        replay.tap()
        XCTAssertTrue(app.buttons["history-replay-close"].waitForExistence(timeout: 5))
        app.buttons["history-replay-close"].tap()
        let remove = app.buttons["history-remove-replay"]
        if !remove.isHittable { app.swipeUp() }
        remove.tap()
        app.buttons["Remove replay"].tap()
        XCTAssertTrue(app.staticTexts["history-no-replay"].waitForExistence(timeout: 5))
        XCTAssertFalse(replay.exists)
        #endif
        app.terminate()
        let restored = open("keep", appearance: "light")
        XCTAssertTrue(restored.buttons[recording.identifier].waitForExistence(timeout: 5))
        attach(restored, "History list — light after relaunch")
        restored.buttons[recording.identifier].tap()
        XCTAssertTrue(restored.staticTexts["history-no-replay"].waitForExistence(timeout: 5))
        XCTAssertTrue(restored.staticTexts["128"].exists)
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor
    func testSlowArchiveNeverGatesEditorOrHistoryPlayback() throws {
        #if targetEnvironment(simulator)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kicklabTests/Fixtures/capture-sixty.mov").path
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES", "--history-review", "empty",
            "--history-save-delay", "60", "--capture-processing-video", fixture]
        app.launch()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 10))
        app.buttons["module-juggling"].tap()
        let play = app.buttons["replay-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 8), "The 60-second archive job cannot delay the preview")
        play.tap()
        XCTAssertEqual(play.label, "Pause video")
        play.tap()
        attach(app, "Preview usable while history copy is deliberately stalled")
        app.buttons["replay-close"].tap()
        app.buttons["home-session-history"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history-session-' ")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["history-watch-replay"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["history-remove-replay"].exists, "The permanent copy is still stalled")
        app.buttons["history-watch-replay"].tap()
        XCTAssertTrue(app.buttons["history-replay-close"].waitForExistence(timeout: 5))
        app.terminate()
        // The interrupted copy is recovered on the next launch with no delay.
        let restored = open("keep", appearance: "dark")
        let restoredRow = restored.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history-session-' ")).firstMatch
        XCTAssertTrue(restoredRow.waitForExistence(timeout: 5))
        restoredRow.tap()
        XCTAssertTrue(restored.buttons["history-remove-replay"].waitForExistence(timeout: 5))
        #else
        throw XCTSkip("This test uses a simulator-only local fixture")
        #endif
    }
}
