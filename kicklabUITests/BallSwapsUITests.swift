import XCTest

/// Per-touch balls, the change moment and the sound tool in the replay editor.
final class BallSwapsUITests: ProReplayUITestCase {
    /// Keeps a screenshot in the result and, when BALL_SWAPS_SHOTS names a folder, as a PNG there.
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let folder = ProcessInfo.processInfo.environment["BALL_SWAPS_SHOTS"], !folder.isEmpty {
            let file = name.lowercased().replacingOccurrences(of: " ", with: "-") + ".png"
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(file))
        }
    }

    @MainActor
    func testPerTouchBallsChangeEffectAndSoundsAreSelectable() throws {
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
        XCTAssertTrue(app.buttons["replay-tool-sound"].waitForExistence(timeout: 5), "Sound is a tool of its own")
        capture(app, "01 Customize grid")
        app.buttons["replay-tool-ball"].tap()

        // One ball is the default; per touch brings in the touch strip.
        XCTAssertTrue(app.buttons["ball-mode-touches"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ball-mode-single"].isSelected)
        XCTAssertFalse(app.buttons["ball-touch-1"].exists)
        app.buttons["ball-mode-touches"].tap()
        XCTAssertTrue(app.buttons["ball-touch-1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ball-touches-cycle"].exists)
        capture(app, "02 Per touch mode")

        // Touch 3 takes Lava; touch 6 inherits it until it takes Pearl.
        app.buttons["ball-touch-3"].tap()
        XCTAssertTrue(app.buttons["ball-touch-3"].isSelected)
        XCTAssertTrue(app.buttons["ball-picker-lava"].waitForExistence(timeout: 5))
        app.buttons["ball-picker-lava"].tap()
        XCTAssertTrue(app.buttons["ball-picker-lava"].isSelected)
        app.buttons["ball-touch-6"].tap()
        XCTAssertTrue(app.buttons["ball-picker-lava"].isSelected, "Later touches keep the last ball")
        app.buttons["ball-picker-pearl"].tap()
        XCTAssertTrue(app.buttons["ball-picker-pearl"].isSelected)

        // The change moment has its own row.
        XCTAssertTrue(app.buttons["ball-swap-burst"].waitForExistence(timeout: 5))
        app.buttons["ball-swap-burst"].tap()
        XCTAssertTrue(app.buttons["ball-swap-burst"].isSelected)
        XCTAssertFalse(app.buttons["ball-swap-pop"].isSelected)
        capture(app, "03 Ball per touch with burst")

        // Going back to touch 3 commits Pearl on touch 6 and still shows Lava on 3.
        app.buttons["ball-touch-3"].tap()
        XCTAssertTrue(app.buttons["ball-picker-lava"].isSelected)
        XCTAssertEqual(app.buttons["ball-touch-6"].label, "Touch 6, Pearl")
        XCTAssertEqual(app.buttons["ball-touch-4"].label, "Touch 4, Lava")
        XCTAssertEqual(app.buttons["ball-touch-1"].label, "Touch 1, original ball")

        // Sounds: one cue per touch, one on each change.
        app.buttons["replay-tools-back"].tap()
        app.buttons["replay-tool-sound"].tap()
        XCTAssertTrue(app.buttons["touch-sound-pop"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["touch-sound-none"].isSelected)
        app.buttons["touch-sound-pop"].tap()
        XCTAssertTrue(app.buttons["touch-sound-pop"].isSelected)
        app.buttons["swap-sound-chime"].tap()
        XCTAssertTrue(app.buttons["swap-sound-chime"].isSelected)
        XCTAssertFalse(app.descendants(matching: .any)["sound-change-note"].exists, "Changes exist, so no hint is needed")
        capture(app, "04 Sound tool")

        // The ball page reopens in per-touch mode; one ball clears the changes.
        app.buttons["replay-tools-back"].tap()
        app.buttons["replay-tool-ball"].tap()
        XCTAssertTrue(app.buttons["ball-touch-3"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ball-mode-touches"].isSelected)
        app.buttons["ball-mode-single"].tap()
        XCTAssertFalse(app.buttons["ball-touch-3"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["ball-picker-chrome"].waitForExistence(timeout: 5), "The full grid is back")

        app.buttons["replay-close-tools"].tap()
        app.buttons["replay-play"].tap()
        XCTAssertEqual(app.buttons["replay-play"].label, "Pause video")
        app.buttons["replay-play"].tap()
        XCTAssertTrue(app.startReplayDownload(), "Download starts in place with sounds on")
    }

    @MainActor
    func testCyclePresetFillsTheStripAndClearEmptiesIt() throws {
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
        XCTAssertTrue(app.buttons["ball-mode-touches"].waitForExistence(timeout: 5))
        app.buttons["ball-mode-touches"].tap()
        XCTAssertTrue(app.buttons["ball-touches-cycle"].waitForExistence(timeout: 5))
        app.buttons["ball-touches-cycle"].tap()
        let everyTwo = app.buttons["Every 2 touches"]
        XCTAssertTrue(everyTwo.waitForExistence(timeout: 5))
        everyTwo.tap()
        // The real ball leads, then the default set rotates in two touches at a time.
        func ball(_ touch: Int) -> String {
            app.buttons["ball-touch-\(touch)"].label.components(separatedBy: ", ").last ?? ""
        }
        XCTAssertEqual(ball(1), "original ball")
        XCTAssertEqual(ball(2), "original ball")
        XCTAssertEqual(ball(3), "Volt")
        XCTAssertEqual(ball(4), "Volt")
        XCTAssertEqual(ball(5), "Lava")
        capture(app, "05 Cycle every 2 touches")
        app.buttons["ball-touches-clear"].tap()
        XCTAssertEqual(ball(3), "original ball")
        XCTAssertEqual(ball(5), "original ball")
        // With no changes left, the sound tool explains why the change sound is quiet.
        app.buttons["replay-tools-back"].tap()
        app.buttons["replay-tool-sound"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["sound-change-note"].waitForExistence(timeout: 5))
        app.buttons["replay-close-tools"].tap()
    }
}
