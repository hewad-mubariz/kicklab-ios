import XCTest

/// The Power Shot camera editor: the move carousel, the camera track and the block inspector.
@MainActor final class ShotCameraUITests: ProReplayUITestCase {
    private func openCamera() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "shot-camera-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["shot-effects-customize"].waitForExistence(timeout: 30))
        app.buttons["shot-effects-customize"].tap()
        XCTAssertTrue(app.buttons["shot-tool-camera"].waitForExistence(timeout: 5))
        app.buttons["shot-tool-camera"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["shot-camera-timeline"].waitForExistence(timeout: 5))
        return app
    }
    private func settled(_ app: XCUIApplication) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                    object: app.staticTexts["Preparing replay…"])
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }
    private func picture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func add(_ move: String, family: String, in app: XCUIApplication) {
        app.buttons["shot-camera-family-\(family)"].tap()
        let card = app.buttons["shot-camera-move-\(move)"]
        XCTAssertTrue(card.waitForExistence(timeout: 3), move)
        card.tap(); settled(app)
        XCTAssertTrue(app.buttons["shot-camera-block-\(move)"].waitForExistence(timeout: 5), move)
    }

    func testMovesLandOnTheTrackBackToBackWithTheirControls() {
        let app = openCamera()
        add("impact", family: "hit", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["shot-camera-inspector"].exists, "A new block opens its controls")
        picture("Impact block and its controls", app: app)
        app.buttons["shot-camera-done"].tap()
        add("chase", family: "follow", in: app)
        XCTAssertTrue(app.buttons["shot-camera-block-impact"].exists, "Adding a move keeps what is already there")
        picture("Impact then Chase Cam", app: app)
        app.buttons["shot-camera-undo"].tap()
        XCTAssertFalse(app.buttons["shot-camera-block-chase"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.buttons["shot-camera-block-impact"].exists)
    }

    func testEveryFamilyAddsAMoveThatCanBeChangedAndDeleted() {
        let app = openCamera()
        for (move, family) in [("ramp", "time"), ("spotlight", "look"), ("recoil", "hit"), ("follow", "follow")] {
            add(move, family: family, in: app)
            app.buttons["shot-camera-change"].tap()
            XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 3), "Changing a move reopens the carousel")
            app.buttons["Cancel"].tap()
            app.buttons["shot-camera-delete"].tap(); settled(app)
            XCTAssertFalse(app.buttons["shot-camera-block-\(move)"].waitForExistence(timeout: 1), move)
        }
    }

    func testFrameStepsMoveThePlayheadAndCompareShowsTheOriginal() {
        let app = openCamera()
        let time = app.staticTexts["shot-camera-time"]
        XCTAssertTrue(time.waitForExistence(timeout: 3))
        let before = time.label
        app.buttons["shot-camera-next-frame"].tap()
        let next = time.label
        XCTAssertNotEqual(next, before)
        app.buttons["shot-camera-previous-frame"].tap()
        XCTAssertEqual(time.label, before, "Frame steps land on real frames and come back")
        let timeline = app.descendants(matching: .any)["shot-camera-timeline"].firstMatch
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4))
            .press(forDuration: 0.05, thenDragTo: timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)))
        XCTAssertNotEqual(time.label, before, "Dragging the timeline scrubs")
        app.descendants(matching: .any)["shot-camera-compare"].firstMatch.press(forDuration: 0.6)
        picture("Scrubbed timeline", app: app)
    }

    func testCameraTrackVideoIsSaved() {
        // The review fixture places the moves and saves locally as soon as the editor opens.
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "shot-camera-fixture", "--shot-camera-moves", "impact,chase",
                               "--shot-export-to", "documents:camera-ui-exports"]
        app.launch()
        XCTAssertTrue(app.otherElements["replay-share-panel"].waitForExistence(timeout: 60), "The camera track renders and saves")
        picture("Saved camera track", app: app)
    }
}
