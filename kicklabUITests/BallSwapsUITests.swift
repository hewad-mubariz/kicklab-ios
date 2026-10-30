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

    /// The ball and effect named in a dial touch's label, "Lava, Fire".
    @MainActor private func look(_ app: XCUIApplication, _ touch: Int) -> String {
        app.buttons["ball-touch-\(touch)"].label.components(separatedBy: ", ").dropFirst().joined(separator: ", ")
    }

    @MainActor
    func testLooksRecipesSplitAndRunPickers() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Requires the local video fixture")
        #endif
        let app = launchEditor()
        XCTAssertTrue(app.buttons["replay-tool-looks"].waitForExistence(timeout: 5), "Looks is a tool of its own")
        capture(app, "01 Customize grid")
        app.buttons["replay-tool-looks"].tap()

        // One look to start: the clip's own ball and effect on every touch.
        let summary = app.descendants(matching: .any)["looks-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.hasPrefix("Look 1 of 1"), summary.label)
        XCTAssertFalse(app.buttons["looks-clear"].exists)

        // Power-up levels up on the 10th, 25th, 50th and 100th touch.
        app.buttons["look-recipe-powerUp"].tap()
        XCTAssertTrue(app.buttons["look-recipe-powerUp"].isSelected)
        XCTAssertTrue(app.buttons["ball-touch-10"].waitForSelection())
        XCTAssertTrue(summary.label.hasPrefix("Look 2 of 5"), summary.label)
        XCTAssertEqual(look(app, 10), "Volt, Electric")
        XCTAssertEqual(look(app, 9), "original ball, Glow Trail")
        capture(app, "02 Power-up recipe")

        // New look here at touch 15 starts look 3 with the same look until it is changed.
        select(app, touch: 15)
        XCTAssertTrue(app.buttons["looks-new"].isEnabled)
        app.buttons["looks-new"].tap()
        XCTAssertTrue(summary.label.hasPrefix("Look 3 of 6"), summary.label)
        XCTAssertTrue(summary.label.contains("Touches 15 to 24"), summary.label)
        XCTAssertTrue(app.buttons["looks-remove"].waitForExistence(timeout: 3), "On a look's first touch the button removes it")
        XCTAssertFalse(app.buttons["look-recipe-powerUp"].isSelected, "A manual edit makes it your own")

        // The pickers change the whole run, not one touch.
        XCTAssertTrue(app.buttons["look-part-ball"].isSelected)
        app.buttons["look-ball-pearl"].tap()
        let pearl = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Pearl'"), object: app.buttons["ball-touch-16"])
        XCTAssertEqual(XCTWaiter.wait(for: [pearl], timeout: 3), .completed)
        app.buttons["look-part-effect"].tap()
        XCTAssertTrue(app.buttons["look-effect-ice"].waitForExistence(timeout: 5))
        app.buttons["look-effect-ice"].tap()
        XCTAssertTrue(app.buttons["look-effect-ice"].isSelected)
        XCTAssertEqual(look(app, 16), "Pearl, Ice")
        XCTAssertEqual(look(app, 15), "Pearl, Ice")
        XCTAssertEqual(look(app, 14), "Volt, Electric", "The run before keeps its look")
        capture(app, "03 Look with its own ball and effect")

        // The change moment applies at every change; its sound follows it.
        app.buttons["look-part-change"].tap()
        XCTAssertTrue(app.buttons["ball-swap-lightning"].waitForExistence(timeout: 5))
        app.buttons["ball-swap-lightning"].tap()
        XCTAssertTrue(app.buttons["ball-swap-lightning"].isSelected)
        XCTAssertTrue(app.descendants(matching: .any)["ball-swap-sound-summary"].label.contains("Thunder"))
        capture(app, "04 Change moment")

        // Remove look hands its touches back to Volt and Electric.
        app.buttons["looks-remove"].tap()
        XCTAssertEqual(look(app, 16), "Volt, Electric")
        XCTAssertTrue(summary.label.hasPrefix("Look 2 of 5"), summary.label)
        XCTAssertTrue(app.buttons["looks-new"].waitForExistence(timeout: 3))

        // Every opens a menu of intervals: every 3 changes on touches 4, 7, 10…
        let every = app.buttons["look-recipe-everyFive"]
        every.tap()
        XCTAssertTrue(app.buttons["Every 3 touches"].waitForExistence(timeout: 3), "Every opens its menu")
        capture(app, "04b Every menu")
        app.buttons["Every 3 touches"].tap()
        XCTAssertTrue(every.waitForSelection())
        XCTAssertTrue(every.label.contains("Every 3"), every.label)
        XCTAssertTrue(app.buttons["ball-touch-4"].waitForSelection())
        XCTAssertEqual(look(app, 3), "original ball, Glow Trail")
        XCTAssertEqual(look(app, 4), "Volt, Neon")
        XCTAssertEqual(look(app, 7), "Arctic Ice, Ice")

        // Custom… opens a slider up to the longest interval that repeats on this clip (132 touches: 65).
        every.tap()
        XCTAssertTrue(app.buttons["Custom…"].waitForExistence(timeout: 3))
        app.buttons["Custom…"].tap()
        let slider = app.sliders["look-every-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 3), "Custom opens a slider, not a keyboard")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertTrue(app.staticTexts["65"].exists, "The slider ends at the longest interval that fits")
        slider.adjust(toNormalizedSliderPosition: 1)
        let longest = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Every 65'"), object: every)
        XCTAssertEqual(XCTWaiter.wait(for: [longest], timeout: 4), .completed, every.label)
        slider.adjust(toNormalizedSliderPosition: 0.1)
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT (label CONTAINS 'Every 65')"), object: every)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 4), .completed, every.label)
        let step = try XCTUnwrap(Int(every.label.components(separatedBy: " ").last ?? ""), every.label)
        XCTAssertTrue((2...20).contains(step), every.label)
        XCTAssertTrue(app.buttons["ball-touch-\(step + 1)"].waitForSelection(timeout: 8))
        XCTAssertEqual(look(app, step), "original ball, Glow Trail")
        XCTAssertEqual(look(app, step + 1), "Volt, Neon")
        capture(app, "04c Every custom slider")
        app.buttons["look-every-done"].tap()
        XCTAssertTrue(slider.waitForNonExistence(timeout: 3))
        capture(app, "04d Every 7")

        // Remix lays a different mix; Clear brings back one look.
        app.buttons["look-recipe-remix"].tap()
        XCTAssertTrue(app.buttons["look-recipe-remix"].isSelected)
        XCTAssertTrue(app.buttons["looks-clear"].waitForExistence(timeout: 3))
        app.buttons["looks-clear"].tap()
        XCTAssertTrue(summary.label.hasPrefix("Look 1 of 1"), summary.label)

        // With looks on, the Ball page says it sets the first look and leads back to Looks.
        app.buttons["look-recipe-finale"].tap()
        app.buttons["replay-tools-back"].tap()
        app.buttons["replay-tool-ball"].tap()
        let note = app.buttons["ball-looks-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        app.buttons["replay-close-tools"].tap()
        app.buttons["replay-play"].tap()
        XCTAssertEqual(app.buttons["replay-play"].label, "Pause video")
        app.buttons["replay-play"].tap()
        XCTAssertTrue(app.startReplayDownload(), "Download starts in place with looks on")
    }

    @MainActor
    func testChangeSoundFollowsTheEffectAndOriginalSoundMutes() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Requires the local video fixture")
        #endif
        let app = launchEditor()
        // Without looks there is no change to hear.
        app.buttons["replay-tool-sound"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["sound-change-note"].waitForExistence(timeout: 5))
        app.buttons["replay-tools-back"].tap()
        app.buttons["replay-tool-looks"].tap()
        XCTAssertTrue(app.buttons["look-recipe-powerUp"].waitForExistence(timeout: 5))
        app.buttons["look-recipe-powerUp"].tap()
        app.buttons["replay-tools-back"].tap()
        app.buttons["replay-tool-sound"].tap()

        // Power-up's Burst plays Drop on Auto; a picked sound overrides it.
        XCTAssertTrue(app.buttons["swap-sound-auto"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["swap-sound-auto"].isSelected, "The change sound follows the effect")
        XCTAssertTrue(app.buttons["swap-sound-auto"].label.contains("Drop"))
        XCTAssertTrue(app.descendants(matching: .any)["sound-auto-note"].exists)
        app.buttons["swap-sound-chime"].tap()
        XCTAssertTrue(app.buttons["swap-sound-chime"].isSelected)
        XCTAssertFalse(app.buttons["swap-sound-auto"].isSelected, "A picked sound overrides the effect's")

        // The first touch sound mutes the original, None brings it back, and a manual choice wins.
        let original = app.switches["sound-original"]
        XCTAssertTrue(isOn(original), "The original sound plays by default")
        app.buttons["touch-sound-pop"].tap()
        XCTAssertTrue(app.buttons["touch-sound-pop"].isSelected)
        XCTAssertFalse(isOn(original), "A touch sound mutes the original automatically")
        capture(app, "05 Sound tool")
        app.buttons["touch-sound-none"].tap()
        XCTAssertTrue(isOn(original), "No touch sound restores the original it muted")
        app.buttons["touch-sound-kick"].tap()
        XCTAssertFalse(isOn(original))
        original.tap()
        XCTAssertTrue(isOn(original), "The person can keep both")
        app.buttons["replay-close-tools"].tap()
    }

    @MainActor
    func testMilestonesAndMyStyle() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Requires the local video fixture")
        #endif
        let app = launchEditor()

        // Milestones are on by default, with the fanfare as their own small switch.
        app.buttons["replay-tool-counter"].tap()
        let milestones = app.switches["counter-milestones"]
        XCTAssertTrue(milestones.waitForExistence(timeout: 5))
        XCTAssertTrue(isOn(milestones))
        let fanfare = app.buttons["milestone-sound"]
        XCTAssertEqual(fanfare.label, "Milestone fanfare on")
        fanfare.tap()
        XCTAssertEqual(fanfare.label, "Milestone fanfare off")
        fanfare.tap()
        XCTAssertEqual(fanfare.label, "Milestone fanfare on")
        milestones.tap()
        XCTAssertFalse(isOn(milestones))
        XCTAssertFalse(fanfare.isEnabled, "No fanfare without milestones")
        milestones.tap()
        XCTAssertTrue(isOn(milestones))
        Thread.sleep(forTimeInterval: 0.35)
        capture(app, "06 Milestones")

        // Each counter celebrates its own way: picking a counter picks its milestone, and the row
        // plays it on the clip.
        let preview = app.buttons["milestone-preview"]
        XCTAssertEqual(preview.label, "Milestones, Normal style")
        for (style, title, shot) in [("comic", "Comic", "06b Comic milestone"), ("goldCoin", "Gold Coin", "06c Gold Coin milestone")] {
            app.buttons["counter-style-\(style)"].tap()
            XCTAssertEqual(preview.label, "Milestones, \(title) style")
            preview.tap()
            Thread.sleep(forTimeInterval: 0.6)
            capture(app, shot)
        }
        app.buttons["counter-style-normal"].tap()
        app.buttons["replay-tools-back"].tap()

        // My style is offered once the replay is saved, and can be stopped from the same row.
        app.buttons["replay-close-tools"].tap()
        XCTAssertFalse(app.buttons["my-style-save"].exists, "My style is not part of the Customize grid")
        XCTAssertTrue(app.startReplayDownload(), "Download starts in place")
        XCTAssertTrue(app.waitForReplaySaved(timeout: 240), "The replay is saved to Photos")
        let save = app.buttons["my-style-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertEqual(save.label, "Save")
        save.tap()
        XCTAssertTrue(app.descendants(matching: .any)["my-style-saved"].waitForExistence(timeout: 3))
        capture(app, "07 My style after download")
        app.buttons["my-style-menu"].tap()
        let stop = app.buttons["Stop using My style"]
        XCTAssertTrue(stop.waitForExistence(timeout: 3))
        stop.tap()
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        XCTAssertEqual(save.label, "Save")
    }
}

private extension XCUIElement {
    /// The dial glides to a tapped touch; selection lands when it settles.
    func waitForSelection(timeout: TimeInterval = 3) -> Bool {
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: self)
        return XCTWaiter.wait(for: [selected], timeout: timeout) == .completed
    }
}
