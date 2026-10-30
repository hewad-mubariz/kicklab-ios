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

    @MainActor private func launchEditor() -> XCUIApplication {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kicklabTests/Fixtures/juggling-eighteen.mov").path
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "capture-flow", "--session-video", fixture]
        app.launch()
        XCTAssertTrue(app.buttons["replay-customize"].waitForExistence(timeout: 20))
        app.buttons["replay-customize"].tap()
        return app
    }

    private func isOn(_ toggle: XCUIElement) -> Bool { (toggle.value as? String) == "1" }

    /// Swipes the dial toward a touch until it is on screen, as a person would, then taps it.
    @MainActor private func select(_ app: XCUIApplication, touch: Int) {
        let target = app.buttons["ball-touch-\(touch)"]
        for _ in 0..<15 where !target.exists {
            let shown = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ball-touch-'"))
                .allElementsBoundByIndex.compactMap { Int($0.identifier.replacingOccurrences(of: "ball-touch-", with: "")) }
            guard let low = shown.min(), let high = shown.max() else { break }
            let handle = app.buttons["ball-touch-\((low + high) / 2)"]
            if touch < low { handle.swipeRight(velocity: .fast) } else { handle.swipeLeft(velocity: .fast) }
        }
        XCTAssertTrue(target.waitForExistence(timeout: 3), "Touch \(touch) is on the dial")
        target.tap()
        XCTAssertTrue(target.waitForSelection(), "Touch \(touch) settles under the lens")
    }

    @MainActor
    func testPerTouchBallsChangeEffectAndSoundsAreSelectable() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Requires the local video fixture")
        #endif
        let app = launchEditor()
        XCTAssertTrue(app.buttons["replay-tool-sound"].waitForExistence(timeout: 5), "Sound is a tool of its own")
        capture(app, "01 Customize grid")
        app.buttons["replay-tool-ball"].tap()

        // One ball is the default; the switch brings in the touch dial.
        let perTouch = app.switches["ball-per-touch"]
        XCTAssertTrue(perTouch.waitForExistence(timeout: 5))
        XCTAssertFalse(isOn(perTouch))
        XCTAssertFalse(app.buttons["ball-touch-1"].exists)
        XCTAssertTrue(app.buttons["ball-picker-chrome"].exists, "The full grid shows while it is off")
        perTouch.tap()
        XCTAssertTrue(isOn(perTouch))
        XCTAssertTrue(app.buttons["ball-touches-cycle"].waitForExistence(timeout: 5))
        capture(app, "02 Per touch dial")

        // Touch 3 takes Lava; touch 6 inherits it until it takes Pearl.
        select(app, touch: 3)
        XCTAssertTrue(app.buttons["ball-picker-lava"].waitForExistence(timeout: 5))
        app.buttons["ball-picker-lava"].tap()
        XCTAssertTrue(app.buttons["ball-picker-lava"].isSelected)
        select(app, touch: 6)
        XCTAssertTrue(app.buttons["ball-picker-lava"].isSelected, "Later touches keep the last ball")
        app.buttons["ball-picker-pearl"].tap()
        XCTAssertTrue(app.buttons["ball-picker-pearl"].isSelected)

        // The change moment has its own animated tiles.
        XCTAssertTrue(app.buttons["ball-swap-burst"].waitForExistence(timeout: 5))
        app.buttons["ball-swap-burst"].tap()
        XCTAssertTrue(app.buttons["ball-swap-burst"].isSelected)
        XCTAssertFalse(app.buttons["ball-swap-pop"].isSelected)
        let summary = app.descendants(matching: .any)["ball-swap-sound-summary"]
        XCTAssertTrue(summary.label.contains("Drop"), "Burst plays its own sound: \(summary.label)")
        capture(app, "03 Ball per touch with burst")

        // Going back to touch 3 lands Pearl on touch 6 and still shows Lava on 3.
        select(app, touch: 3)
        XCTAssertTrue(app.buttons["ball-picker-lava"].isSelected)
        XCTAssertEqual(app.buttons["ball-touch-6"].label, "Touch 6, Pearl")
        XCTAssertEqual(app.buttons["ball-touch-4"].label, "Touch 4, Lava")
        XCTAssertEqual(app.buttons["ball-touch-1"].label, "Touch 1, original ball")

        // Sounds: the first touch sound mutes the original, None brings it back.
        app.buttons["replay-tools-back"].tap()
        app.buttons["replay-tool-sound"].tap()
        let original = app.switches["sound-original"]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        XCTAssertTrue(isOn(original), "The original sound plays by default")
        XCTAssertTrue(app.buttons["touch-sound-none"].isSelected)
        app.buttons["touch-sound-pop"].tap()
        XCTAssertTrue(app.buttons["touch-sound-pop"].isSelected)
        XCTAssertFalse(isOn(original), "A touch sound mutes the original automatically")
        XCTAssertTrue(app.buttons["swap-sound-auto"].isSelected, "The change sound follows the effect")
        XCTAssertTrue(app.buttons["swap-sound-auto"].label.contains("Drop"))
        XCTAssertTrue(app.descendants(matching: .any)["sound-auto-note"].exists)
        app.buttons["swap-sound-chime"].tap()
        XCTAssertTrue(app.buttons["swap-sound-chime"].isSelected)
        XCTAssertFalse(app.buttons["swap-sound-auto"].isSelected, "A picked sound overrides the effect's")
        XCTAssertFalse(app.descendants(matching: .any)["sound-change-note"].exists, "Changes exist, so no hint is needed")
        capture(app, "04 Sound tool")
        app.buttons["touch-sound-none"].tap()
        XCTAssertTrue(isOn(original), "No touch sound restores the original it muted")
        app.buttons["touch-sound-kick"].tap()
        XCTAssertFalse(isOn(original))
        original.tap()
        XCTAssertTrue(isOn(original), "The person can keep both")
        app.buttons["touch-sound-none"].tap()
        XCTAssertTrue(isOn(original))

        // Off sets the per-touch balls aside; on again brings them back.
        app.buttons["replay-tools-back"].tap()
        app.buttons["replay-tool-ball"].tap()
        XCTAssertTrue(app.buttons["ball-touch-3"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["ball-swap-sound-summary"].label.contains("Chime"),
                      "The Ball page shows the overriding sound")
        XCTAssertTrue(isOn(app.switches["ball-per-touch"]))
        app.switches["ball-per-touch"].tap()
        XCTAssertFalse(app.buttons["ball-touch-3"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["ball-picker-chrome"].waitForExistence(timeout: 5), "The full grid is back")
        app.switches["ball-per-touch"].tap()
        XCTAssertTrue(app.buttons["ball-touch-6"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["ball-touch-6"].label, "Touch 6, Pearl", "Picks come back with the switch")

        app.buttons["replay-close-tools"].tap()
        app.buttons["replay-play"].tap()
        XCTAssertEqual(app.buttons["replay-play"].label, "Pause video")
        app.buttons["replay-play"].tap()
        XCTAssertTrue(app.startReplayDownload(), "Download starts in place with sounds on")
    }

    @MainActor
    func testCyclePresetFillsTheDialAndClearEmptiesIt() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Requires the local video fixture")
        #endif
        let app = launchEditor()
        app.buttons["replay-tool-ball"].tap()
        XCTAssertTrue(app.switches["ball-per-touch"].waitForExistence(timeout: 5))
        app.switches["ball-per-touch"].tap()
        XCTAssertTrue(app.buttons["ball-touches-cycle"].waitForExistence(timeout: 5))
        select(app, touch: 3)
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
        capture(app, "06 Sound tool without changes")
        app.buttons["replay-close-tools"].tap()
    }
}

private extension XCUIElement {
    /// The dial glides to a tapped touch; selection lands when it settles.
    func waitForSelection(timeout: TimeInterval = 3) -> Bool {
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: self)
        return XCTWaiter.wait(for: [selected], timeout: timeout) == .completed
    }
}
