import XCTest

final class LearningCoachUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func launch(_ appearance: String = "light", largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES", "--history-review", "empty",
            "-kicklab.appearance", appearance, "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-juggledude.notifications.session-completed", "NO", "-debug.overlaysVisible", "NO"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 20))
        app.mainTab("learn").tap()
        XCTAssertTrue(app.buttons["learn-start"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testLessonPracticeAndEasierRoute() {
        let app = launch()
        attach(app, "Learn - light")
        app.buttons["learn-start"].tap()
        XCTAssertTrue(app.buttons["learn-practice"].waitForExistence(timeout: 8))
        if app.buttons["learn-voice"].label == "Mute coach" { app.buttons["learn-voice"].tap() }
        attach(app, "Coach - one touch")
        app.buttons["learn-speed"].tap()
        XCTAssertTrue(app.buttons["learn-speed"].label.contains("0.5"))
        app.buttons["learn-angle"].tap()
        XCTAssertTrue(app.buttons["learn-angle"].label.contains("Side"))
        attach(app, "Coach - side view")
        app.buttons["learn-angle"].tap()
        app.buttons["learn-practice"].tap()
        XCTAssertTrue(app.buttons["learn-practice"].label.contains("Done"))
        XCTAssertTrue(app.staticTexts["learn-caption"].label.contains("Let's try together"))
        let firstRound = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Try 1 of 3"), object: app.staticTexts["learn-round"])
        XCTAssertEqual(XCTWaiter.wait(for: [firstRound], timeout: 12), .completed)
        XCTAssertTrue(app.staticTexts["learn-caption"].label.contains("gentle touch"))
        app.buttons["learn-practice"].tap()
        XCTAssertTrue(app.buttons["learn-easier"].waitForExistence(timeout: 5))
        attach(app, "Coach - check in")
        app.buttons["learn-easier"].tap()
        let easierTitle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Bounce. Catch. Repeat."), object: app.staticTexts["learn-lesson-title"])
        XCTAssertEqual(XCTWaiter.wait(for: [easierTitle], timeout: 5), .completed)
        app.buttons["learn-close"].tap()
        XCTAssertTrue(app.buttons["learn-start"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDarkAndAdvancedLessons() {
        let app = launch("dark")
        attach(app, "Learn - dark")
        app.swipeUp()
        let advanced = app.buttons["learn-level-advanced"]
        if !advanced.isHittable { app.buttons["learn-level-control"].swipeLeft() }
        advanced.tap()
        XCTAssertTrue(app.buttons["learn-lesson-change-height"].waitForExistence(timeout: 5))
        attach(app, "Learn - advanced")
        app.buttons["learn-lesson-change-height"].tap()
        XCTAssertTrue(app.buttons["learn-practice"].waitForExistence(timeout: 5))
        attach(app, "Coach - height control dark")
        app.buttons["learn-hear-coach"].tap()
        XCTAssertEqual(app.buttons["learn-voice"].label, "Mute coach")
        app.buttons["learn-voice"].tap()
        XCTAssertEqual(app.buttons["learn-voice"].label, "Enable coach voice")
        app.buttons["learn-close"].tap()
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// A stable capture window for the local animated design preview.
    @MainActor
    func testCoachMotionPreviewForReview() {
        let app = launch()
        app.buttons["learn-start"].tap()
        XCTAssertTrue(app.buttons["learn-hear-coach"].waitForExistence(timeout: 8))
        app.buttons["learn-hear-coach"].tap()
        print("LEARN_PREVIEW_READY")
        sleep(16)
        attach(app, "Coach - animated preview")
    }
}
