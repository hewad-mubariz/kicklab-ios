import XCTest

/// The timer's looks and its sticker editing: tap, drag, pinch, reset, restyle and remove.
final class TimerStickerUITests: ProReplayUITestCase {
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
    func testTimerLooksAndStickerEditing() throws {
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

        // Every look is on the Timer page; the free Pill is the default.
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-timer"].tap()
        XCTAssertTrue(app.buttons["timer-style-pill"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["timer-style-pill"].isSelected)
        for style in ["clean", "broadcast", "stopwatch", "digital", "flip", "neon"] {
            let tile = app.buttons["timer-style-\(style)"]
            XCTAssertTrue(tile.isHittable, "\(style) fits on the Timer page")
            tile.tap()
            XCTAssertTrue(tile.isSelected)
        }
        app.buttons["timer-style-broadcast"].tap()
        XCTAssertTrue(app.switches["Show elapsed time"].exists)
        capture(app, "07 Timer styles")
        app.buttons["replay-close-tools"].tap()

        // Tap the timer on the video to edit it like the counter.
        let timer = app.descendants(matching: .any)["replay-elapsed-time"]
        XCTAssertTrue(timer.waitForExistence(timeout: 5))
        let original = timer.frame
        app.buttons["replay-select-timer"].tap()
        XCTAssertTrue(app.buttons["replay-remove-timer"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["replay-customize"].label, "Timer style")
        capture(app, "08 Timer selected")

        // Drag it down and left.
        let start = timer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.38, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        let moved = timer.frame
        XCTAssertLessThan(moved.midX, original.midX - 40, "Dragging moves the timer left")
        XCTAssertGreaterThan(moved.midY, original.midY + 150, "and down")

        // Pinch it bigger.
        timer.pinch(withScale: 1.6, velocity: 1.5)
        XCTAssertGreaterThan(timer.frame.width, moved.width * 1.15, "Pinching enlarges the timer")
        capture(app, "09 Timer moved and enlarged")

        // Reset puts it back where it started.
        XCTAssertEqual(app.buttons["replay-play"].label, "Reset timer position")
        app.buttons["replay-play"].tap()
        let reset = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(timer.frame.midX - original.midX) < 4 && abs(timer.frame.width - original.width) < 4
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reset], timeout: 3), .completed)

        // The style pill opens straight on the Timer page with the look still chosen.
        app.buttons["replay-customize"].tap()
        XCTAssertTrue(app.buttons["timer-style-broadcast"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["timer-style-broadcast"].isSelected)
        app.buttons["replay-close-tools"].tap()

        // Done ends editing; removing hides the timer and turns its switch off.
        app.buttons["replay-select-timer"].tap()
        XCTAssertTrue(app.buttons["replay-reset"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["replay-reset"].label, "Done adjusting timer")
        app.buttons["replay-reset"].tap()
        XCTAssertFalse(app.buttons["replay-remove-timer"].waitForExistence(timeout: 1))
        app.buttons["replay-select-timer"].tap()
        app.buttons["replay-remove-timer"].tap()
        XCTAssertFalse(timer.waitForExistence(timeout: 2), "Removing hides the timer")
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-timer"].tap()
        XCTAssertTrue(app.switches["Show elapsed time"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["Show elapsed time"].value as? String, "0")
    }
}
