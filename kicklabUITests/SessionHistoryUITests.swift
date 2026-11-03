import XCTest

final class SessionHistoryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func open(_ mode: String, appearance: String, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES", "-kicklab.appearance", appearance,
                               "--history-review", mode] + arguments
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
        XCTAssertFalse(app.buttons["history-edit-replay"].exists)
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
        XCTAssertFalse(app.buttons["history-edit-replay"].exists)
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
    func testSavedSessionReopensEditsAfterRelaunchAndExportsAgain() throws {
        #if targetEnvironment(simulator)
        let app = open("editable", appearance: "dark")
        let row = "history-session-00000000-0000-0000-0000-000000000001"
        app.buttons[row].tap()
        XCTAssertTrue(app.buttons["history-edit-replay"].waitForExistence(timeout: 10))
        attach(app, "Saved replay card with Open editor")
        app.buttons["history-edit-replay"].tap()
        XCTAssertTrue(app.buttons["replay-customize"].waitForExistence(timeout: 20))
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-counter"].tap()
        let label = app.textFields["counter-text"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        label.tap()
        label.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7) + "Ballkontakte\n")
        XCTAssertEqual(label.value as? String, "Ballkontakte")
        attach(app, "Custom German counter label")
        let showCounter = app.switches["counter-show"]
        XCTAssertTrue(showCounter.waitForExistence(timeout: 5))
        XCTAssertEqual(showCounter.value as? String, "1")
        showCounter.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["replay-select-counter"].waitForNonExistence(timeout: 5))
        app.buttons["replay-close"].tap()
        XCTAssertTrue(app.buttons["history-watch-replay"].waitForExistence(timeout: 5))
        app.terminate()

        let restored = open("keep", appearance: "dark")
        restored.buttons[row].tap()
        restored.buttons["history-watch-replay"].tap()
        XCTAssertTrue(restored.buttons["history-replay-edit"].waitForExistence(timeout: 5))
        restored.buttons["history-replay-edit"].tap()
        XCTAssertTrue(restored.buttons["replay-customize"].waitForExistence(timeout: 20))
        XCTAssertFalse(restored.buttons["replay-select-counter"].exists, "This session's counter choice must survive relaunch")
        restored.buttons["replay-customize"].tap()
        restored.buttons["replay-tool-counter"].tap()
        let restoredLabel = restored.textFields["counter-text"]
        XCTAssertTrue(restoredLabel.waitForExistence(timeout: 5))
        XCTAssertEqual(restoredLabel.value as? String, "Ballkontakte", "Label survives closing and relaunching")
        restored.buttons["counter-text-reset"].tap()
        XCTAssertEqual(restoredLabel.value as? String, "Touches")
        restored.buttons["replay-close-tools"].tap()
        attach(restored, "Reopened saved edit")
        XCTAssertTrue(restored.startReplayDownload())
        XCTAssertTrue(restored.waitForReplaySaved(timeout: 60))
        XCTAssertFalse(restored.buttons["replay-record-another"].exists)
        attach(restored, "Saved session exported again")
        restored.buttons["replay-close"].tap()
        XCTAssertTrue(restored.staticTexts["2"].waitForExistence(timeout: 5), "Editing cannot change the saved result")
        #else
        throw XCTSkip("Uses a simulator-only local video fixture")
        #endif
    }

    @MainActor
    func testLegacyReplayCanRebuildForEditingWithoutChangingHistoryScore() throws {
        #if targetEnvironment(simulator)
        let app = open("legacy-timed", appearance: "light", arguments: ["--analysis-ignore-cache"])
        app.buttons["history-session-00000000-0000-0000-0000-000000000001"].tap()
        XCTAssertTrue(app.buttons["history-edit-replay"].waitForExistence(timeout: 10))
        app.buttons["history-edit-replay"].tap()
        XCTAssertTrue(app.otherElements["session-processing-overlay"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["cancel-video-import"].exists)
        attach(app, "History uses the gallery processing screen")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["replay-customize"].exists || app.staticTexts["history-editor-error"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 180), .completed)
        XCTAssertTrue(app.buttons["replay-customize"].exists)
        app.buttons["replay-close"].tap()
        XCTAssertTrue(app.staticTexts["2"].waitForExistence(timeout: 5))
        #else
        throw XCTSkip("Uses a simulator-only local video fixture")
        #endif
    }

    @MainActor
    func testCameraCanReturnHomeBeforeRecording() {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES", "--history-review", "empty"]
        app.launch()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 10))
        app.buttons["module-juggling"].tap()
        XCTAssertTrue(app.buttons["capture-close"].waitForExistence(timeout: 5))
        app.buttons["capture-close"].tap()
        XCTAssertTrue(app.buttons["capture-close"].waitForNonExistence(timeout: 5))
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
        XCTAssertTrue(app.buttons["replay-close"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["capture-close"].waitForExistence(timeout: 5))
        let cameraReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["capture-close"])
        XCTAssertEqual(XCTWaiter.wait(for: [cameraReady], timeout: 5), .completed)
        app.buttons["capture-close"].tap()
        XCTAssertTrue(app.buttons["capture-close"].waitForNonExistence(timeout: 10), app.debugDescription)
        if !app.buttons["home-session-history"].isHittable { app.swipeUp() }
        let homeReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["home-session-history"])
        XCTAssertEqual(XCTWaiter.wait(for: [homeReady], timeout: 5), .completed, app.debugDescription)
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
