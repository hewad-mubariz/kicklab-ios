import XCTest

final class MotionStylesUITests: ProReplayUITestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testNativeMotionStyleSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "motion-styles"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Bounce Run"].waitForExistence(timeout: 10))
        attach(app, "Ten motion styles - native renderers")
    }

    @MainActor
    func testEveryStyleAppliesToReplayAndResetKeepsOriginalDefault() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Local video fixture requires simulator")
        #endif
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kicklabTests/Fixtures/juggling-eighteen.mov").path
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "motion-replay", "--session-video", fixture]
        app.launch()
        XCTAssertTrue(app.buttons["replay-select-counter"].waitForExistence(timeout: 20))
        app.sliders["Video position"].adjust(toNormalizedSliderPosition: 0.24)
        let graph = app.descendants(matching: .any)["capture-motion-graph"].firstMatch
        XCTAssertEqual(graph.value as? String, "ballMotion")
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-graph"].tap()
        XCTAssertTrue(app.buttons["motion-style-ballMotion"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["motion-style-ballMotion"].isSelected)
        attach(app, "Graph picker - default")
        let options = app.scrollViews["motion-style-options"]
        for style in ["comet", "bounceRun", "heartbeat", "melody", "fireworks", "skyMeter", "combo", "metronome", "rainbowArcs"] {
            let button = app.buttons["motion-style-\(style)"]
            // Two to a row, scrolling down.
            for _ in 0..<6 {
                if button.isHittable { break }
                options.swipeUp()
            }
            XCTAssertTrue(button.isHittable, "\(style) is reachable")
            button.tap()
            XCTAssertTrue(button.isSelected)
            attach(app, "Graph picker - \(style)")
            app.buttons["replay-close-tools"].tap()
            XCTAssertTrue(graph.waitForExistence(timeout: 4))
            XCTAssertEqual(graph.value as? String, style)
            attach(app, "Replay HUD - \(style)")
            app.buttons["replay-customize"].tap()
            app.buttons["replay-tool-graph"].tap()
            XCTAssertTrue(button.waitForExistence(timeout: 4))
            XCTAssertTrue(button.isSelected, "Selection survives closing tools")
        }
        app.buttons["replay-close-tools"].tap()
        app.buttons["replay-reset"].tap()
        XCTAssertTrue(graph.waitForExistence(timeout: 4))
        XCTAssertEqual(graph.value as? String, "ballMotion")
    }

    @MainActor
    func testMotionPreviewPlaysAndPausesTheClip() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Local video fixture requires simulator")
        #endif
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kicklabTests/Fixtures/juggling-eighteen.mov").path
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "motion-replay", "--session-video", fixture]
        app.launch()
        XCTAssertTrue(app.buttons["replay-select-counter"].waitForExistence(timeout: 20))
        app.sliders["Video position"].adjust(toNormalizedSliderPosition: 0.15)
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-graph"].tap()
        let comet = app.buttons["motion-style-comet"]
        XCTAssertTrue(comet.waitForExistence(timeout: 5))
        comet.tap()
        XCTAssertTrue(comet.isSelected)
        let time = app.staticTexts["motion-preview-time"]
        let initial = time.label
        let play = app.buttons["motion-preview-play"]
        play.tap()
        XCTAssertEqual(play.label, "Pause motion preview")
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", initial), object: time)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 8), .completed)
        play.tap()
        XCTAssertEqual(play.label, "Play motion preview")
        attach(app, "Comet - motion preview paused after playback")
    }

    @MainActor
    func testGraphCanBeIncludedInSavedVideo() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Local video fixture requires simulator")
        #endif
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kicklabTests/Fixtures/juggling-eighteen.mov").path
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "motion-replay", "--session-video", fixture]
        app.launch()
        XCTAssertTrue(app.buttons["replay-customize"].waitForExistence(timeout: 20))
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-graph"].tap()
        let off = app.buttons["analytics-placement-off"]
        let card = app.buttons["analytics-placement-card"]
        let full = app.buttons["analytics-placement-full"]
        XCTAssertTrue(off.waitForExistence(timeout: 5))
        XCTAssertTrue(off.isSelected, "Nothing is added to the saved video until chosen")
        attach(app, "Analytics placement - off")
        card.tap()
        XCTAssertTrue(card.isSelected)
        attach(app, "Analytics placement - card")
        full.tap()
        XCTAssertTrue(full.isSelected)
        XCTAssertFalse(card.isSelected)
        app.buttons["motion-style-comet"].tap()
        attach(app, "Include Comet graph in saved video")
        app.buttons["replay-close-tools"].tap()
        let graph = app.descendants(matching: .any)["capture-motion-graph"].firstMatch
        XCTAssertEqual(graph.value as? String, "comet")
        XCTAssertTrue(graph.label.contains("included in saved video"))
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-graph"].tap()
        XCTAssertTrue(full.waitForExistence(timeout: 5))
        XCTAssertTrue(full.isSelected, "The choice survives closing tools")
        off.tap()
        XCTAssertTrue(off.isSelected)
        app.buttons["replay-close-tools"].tap()
        // The replay keeps its own graph; only the saved video loses it.
        XCTAssertTrue(graph.waitForExistence(timeout: 4))
        XCTAssertFalse(graph.label.contains("included in saved video"))
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
