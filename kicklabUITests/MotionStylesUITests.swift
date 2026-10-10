import XCTest

final class MotionStylesUITests: XCTestCase {
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
            for _ in 0..<6 {
                if button.isHittable { break }
                options.swipeLeft()
            }
            XCTAssertTrue(button.isHittable, "\(style) is reachable")
            button.tap()
            XCTAssertTrue(button.isSelected)
            let preview = app.descendants(matching: .any)["motion-selected-preview"].firstMatch
            XCTAssertEqual(preview.value as? String, style)
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
        let toggle = app.switches["Show ball motion"]
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        app.buttons["replay-close-tools"].tap()
        XCTAssertTrue(graph.waitForNonExistence(timeout: 4))
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
        let include = app.switches["motion-include-export"]
        XCTAssertTrue(include.waitForExistence(timeout: 5))
        XCTAssertEqual(include.value as? String, "0")
        include.tap()
        XCTAssertEqual(include.value as? String, "1")
        app.buttons["motion-style-comet"].tap()
        attach(app, "Include Comet graph in saved video")
        app.buttons["replay-close-tools"].tap()
        let graph = app.descendants(matching: .any)["capture-motion-graph"].firstMatch
        XCTAssertEqual(graph.value as? String, "comet")
        XCTAssertTrue(graph.label.contains("included in saved video"))
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-graph"].tap()
        XCTAssertTrue(app.buttons["motion-style-comet"].waitForExistence(timeout: 5))
        XCTAssertEqual(include.value as? String, "1")
        app.switches["Show ball motion"].tap()
        XCTAssertEqual(app.switches["Show ball motion"].value as? String, "0")
        XCTAssertEqual(include.value as? String, "0")
        app.buttons["replay-close-tools"].tap()
        XCTAssertTrue(graph.waitForNonExistence(timeout: 4))
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
