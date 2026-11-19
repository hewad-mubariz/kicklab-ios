import XCTest

final class NativeTabsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func launch(appearance: String = "light", language: String = "en", largeText: Bool = false,
                        history: String = "empty", best: Int = 42, name: String = "") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES", "--history-review", history,
            "--leaderboard-samples", "-kicklab.juggling.bestStreak", "\(best)", "-kicklab.profile.displayName", name,
            "-kicklab.appearance", appearance, "-AppleLanguages", "(\(language))", "-AppleLocale", "en_US",
            "-juggledude.notifications.session-completed", "NO", "-debug.overlaysVisible", "NO"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 20))
        return app
    }

    @MainActor
    func testNativeTabsPreserveProfileAndChallengeNavigation() {
        let app = launch()
        XCTAssertEqual(app.mainTabButtons.count, 5)
        XCTAssertTrue(app.mainTab("home").isSelected)
        attach(app, "Home - native tabs")

        app.mainTab("challenges").tap()
        app.buttons["challenge-cup-01"].tap()
        XCTAssertTrue(app.buttons["challenge-try"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.mainTab("challenges").isSelected)
        attach(app, "Challenge - first three card")
        app.mainTab("learn").tap()
        XCTAssertTrue(app.mainTab("learn").isSelected)
        XCTAssertTrue(app.descendants(matching: .any)["learn-coming-soon"].waitForExistence(timeout: 5))
        attach(app, "Learn - coming soon")
        app.mainTab("challenges").tap()
        XCTAssertTrue(app.buttons["challenge-try"].waitForExistence(timeout: 5))

        // Profile opens from the photo on Home and closes back to Home.
        app.mainTab("home").tap()
        app.buttons["home-profile"].tap()
        XCTAssertTrue(app.buttons["profile-close"].waitForExistence(timeout: 5))
        app.swipeUp()
        app.buttons["profile-settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        attach(app, "Profile - settings from Home")
        app.navigationBars["Settings"].buttons.element(boundBy: 0).tap()
        app.swipeDown()
        app.buttons["profile-close"].tap()
        XCTAssertTrue(app.buttons["home-profile"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.mainTab("home").isSelected)

        app.mainTab("leaderboard").tap()
        XCTAssertTrue(app.otherElements["leaderboard-screen"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["leaderboard-close"].exists)
        attach(app, "Leaderboard - native tabs")
        app.mainTab("home").tap()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testHomeShowsBestNextGoalAndWeek() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, history: "filled", name: "Alex Sample")
            XCTAssertEqual(app.descendants(matching: .any)["home-personal-best"].label,
                           "Personal best streak, 42 consecutive touches")
            XCTAssertTrue(app.descendants(matching: .any)["home-next-goal"].label.hasPrefix("Next goal, 50 touches"))
            XCTAssertEqual(app.descendants(matching: .any)["home-week"].label, "This week, 3 sessions")
            XCTAssertTrue(app.descendants(matching: .any)["home-last-session"].exists)
            XCTAssertEqual(app.descendants(matching: .any)["home-days-in-a-row"].label, "3 days in a row")
            XCTAssertEqual(app.staticTexts["home-greeting"].label, "Hey, Alex")
            XCTAssertTrue(app.staticTexts["home-subtitle"].exists)
            XCTAssertTrue(app.buttons["home-profile"].exists)
            sleep(2)
            attach(app, "Home - \(appearance)")
            if appearance == "dark" {
                for frame in 1...4 { attach(app, "Home - motion \(frame)") }
            }
            app.swipeUp()
            sleep(1)
            attach(app, "Home - \(appearance) lower")
            if appearance == "light" {
                app.swipeDown()
                app.descendants(matching: .any)["home-next-goal"].tap()
                XCTAssertTrue(app.buttons["capture-close"].waitForExistence(timeout: 20))
                XCTAssertTrue(app.descendants(matching: .any)["capture-challenge-goal"].label.contains("50"))
                // The camera slides in; tapping Close mid-slide can close it before XCTest checks it.
                let close = app.buttons["capture-close"]
                for _ in 0..<15 where !close.isHittable { usleep(200_000) }
                close.tap()
                XCTAssertTrue(app.mainTab("home").waitForExistence(timeout: 8))
            }
            app.terminate()
        }
        let first = launch(appearance: "dark", best: 0)
        XCTAssertEqual(first.descendants(matching: .any)["home-personal-best"].label,
                       "Personal best streak. Record your first juggling streak.")
        XCTAssertTrue(first.descendants(matching: .any)["home-next-goal"].label.hasPrefix("Next goal, 10 touches"))
        sleep(2)
        attach(first, "Home - first session dark")
        first.terminate()

        let german = launch(appearance: "light", language: "de", history: "filled", name: "Alex Sample")
        XCTAssertTrue(german.descendants(matching: .any)["home-next-goal"].exists)
        XCTAssertTrue(german.descendants(matching: .any)["home-days-in-a-row"].exists)
        sleep(2)
        attach(german, "Home - German light")
        german.swipeUp()
        sleep(1)
        attach(german, "Home - German light lower")
    }

    /// Design review only: each tab icon's tap animation, in light and dark.
    @MainActor
    func testAnimatedTabIconsForReview() {
        for appearance in ["dark", "light"] {
            let app = launch(appearance: appearance, history: "filled")
            for tab in ["learn", "challenges", "wallGame", "leaderboard", "home"] {
                let button = app.mainTab(tab)
                button.tap()
                // A burst of the button alone, to follow the animation frame by frame.
                for frame in 1...6 {
                    let shot = XCTAttachment(screenshot: button.screenshot())
                    shot.name = "Tab play - \(appearance) \(tab) \(frame)"
                    shot.lifetime = .keepAlways
                    add(shot)
                }
                XCTAssertTrue(button.isSelected)
                sleep(1)
                attach(app, "Tab icons - \(appearance) \(tab)")
            }
            app.terminate()
        }
    }

    /// Design review only: the icons replaying in a loop, captured as a strip of frames.
    @MainActor
    func testTabIconDemoFramesForReview() {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES", "--history-review", "filled",
            "-kicklab.appearance", "dark", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "--tab-icon-demo", "-debug.overlaysVisible", "NO", "-juggledude.notifications.session-completed", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 20))
        for frame in 1...48 {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = String(format: "Tab demo %02d", frame)
            shot.lifetime = .keepAlways
            add(shot)
        }
    }

    /// The widget, the Control Center button and the quick action all end in this link
    /// (or the same request); it opens the juggling camera and closes back to Home.
    @MainActor
    func testStartJugglingLinkOpensCamera() {
        let app = launch()
        XCTAssertTrue(app.buttons["module-juggling"].label.contains("Start juggling"))
        app.open(URL(string: "juggledude://start-juggling")!)
        let close = app.buttons["capture-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 20))
        attach(app, "Start juggling link - camera")
        for _ in 0..<15 where !close.isHittable { usleep(200_000) }
        close.tap()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 8))
    }

    /// Design review only: every widget card, drawn in the app with sample numbers.
    @MainActor
    func testWidgetCardsForReview() {
        let app = XCUIApplication()
        app.launchArguments = ["--widget-review", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["widget-review"].waitForExistence(timeout: 15))
        sleep(1)
        attach(app, "Widget cards - top")
        app.swipeUp()
        sleep(1)
        attach(app, "Widget cards - bottom")
    }

    /// Design review only: the Home ball in other skins.
    @MainActor
    func testHomeBallSkinsForReview() {
        for skin in ["volt", "chrome", "galaxy", "gold"] {
            let app = XCUIApplication()
            app.launchArguments = ["-kicklab.welcome.completed", "YES", "--history-review", "filled",
                "-kicklab.juggling.bestStreak", "42", "-kicklab.appearance", "dark", "-AppleLanguages", "(en)",
                "-AppleLocale", "en_US", "-debug.home.ballSkin", skin, "-debug.overlaysVisible", "NO",
                "-juggledude.notifications.session-completed", "NO"]
            app.launch()
            XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 20))
            sleep(2)
            attach(app, "Home ball - \(skin)")
            app.terminate()
        }
    }

    @MainActor
    func testChallengeCameraReturnsToGoalAndHidesTabs() {
        let app = launch(appearance: "dark")
        app.mainTab("challenges").tap()
        attach(app, "Challenges - dark")
        let beatYourBest = app.buttons["challenge-cup-08"]
        XCTAssertTrue(beatYourBest.waitForExistence(timeout: 8))
        reveal(beatYourBest, in: app)
        beatYourBest.tap()
        XCTAssertTrue(app.descendants(matching: .any)["challenge-line"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["challenge-line"].label.contains("42"))
        app.buttons["challenge-try"].tap()
        XCTAssertTrue(app.buttons["capture-close"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["capture-challenge-goal"].label.contains("43"))
        attach(app, "Challenge - full-screen camera goal")
        // UIKit may retain the covered tab bar in the accessibility tree.
        XCTAssertFalse(app.mainTab("home").isHittable)
        app.buttons["capture-close"].tap()
        XCTAssertTrue(app.buttons["challenge-cup-08"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.mainTab("challenges").isSelected)
        app.mainTab("home").tap()
        app.buttons["module-juggling"].tap()
        XCTAssertTrue(app.buttons["capture-close"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.descendants(matching: .any)["capture-challenge-goal"].exists)
        app.buttons["capture-close"].tap()
        XCTAssertTrue(app.mainTab("home").waitForExistence(timeout: 8))
    }

    @MainActor
    func testHomeImportCanCancelBackToNativeTabs() {
        let app = launch()
        app.swipeUp()
        app.buttons["home-import-video"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.mainTab("home").waitForExistence(timeout: 8))
        XCTAssertTrue(app.mainTab("home").isSelected)
        app.mainTab("challenges").tap()
        attach(app, "Challenges - light")
    }

    @MainActor
    func testChallengesSupportGermanAndLargeText() {
        for largeText in [false, true] {
            let app = launch(language: "de", largeText: largeText)
            XCTAssertEqual(app.mainTab("leaderboard").label, "Rangliste")
            app.mainTab("challenges").tap()
            attach(app, largeText ? "Challenges - German large text" : "Challenges - German")
            app.buttons["challenge-cup-01"].tap()
            XCTAssertTrue(app.buttons["challenge-try"].waitForExistence(timeout: 5))
            attach(app, largeText ? "Challenge card - German large text" : "Challenge card - German")
            app.terminate()
        }
    }

    @MainActor
    func testWallGameTabAndSetupReturnWithoutOpeningCamera() {
        for language in ["en", "de"] {
            let app = launch(appearance: language == "en" ? "light" : "dark", language: language)
            XCTAssertEqual(app.mainTabButtons.count, 5)
            app.mainTab("wallGame").tap()
            XCTAssertTrue(app.buttons["wall-game-setup"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.mainTab("wallGame").isSelected)
            XCTAssertFalse(app.buttons["capture-close"].exists)
            attach(app, "Wall Game - \(language) five tabs")
            app.buttons["wall-game-setup"].tap()
            XCTAssertTrue(app.buttons["wall-game-setup-done"].waitForExistence(timeout: 5))
            attach(app, "Wall Game - \(language) setup")
            app.buttons["wall-game-setup-done"].tap()
            XCTAssertTrue(app.mainTab("wallGame").isSelected)
            app.mainTab("learn").tap()
            XCTAssertTrue(app.mainTab("learn").isSelected)
            app.mainTab("wallGame").tap()
            XCTAssertTrue(app.buttons["wall-game-setup"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    func testChallengePathForReview() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            app.mainTab("challenges").tap()
            for frame in 0..<6 {
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = "Arrival \(appearance) \(frame)"
                shot.lifetime = .keepAlways
                add(shot)
            }
            app.buttons["challenge-group-streaks"].tap()
            XCTAssertTrue(app.buttons["challenge-invite"].waitForExistence(timeout: 5))
            sleep(3)
            attach(app, "Challenges - \(appearance) top")
            app.swipeUp()
            sleep(1)
            attach(app, "Challenges - \(appearance) path")
            let next = app.buttons["challenge-cup-06"]
            reveal(next, in: app)
            next.tap()
            XCTAssertTrue(app.buttons["challenge-try"].waitForExistence(timeout: 5))
            sleep(1)
            attach(app, "Challenge card - \(appearance) Half Century")
            guard appearance == "light" else { app.terminate(); continue }

            app.buttons["challenge-rules"].tap()
            XCTAssertTrue(app.buttons["challenge-sheet-close"].waitForExistence(timeout: 5))
            sleep(1)
            attach(app, "Challenge rules - Half Century")
            app.buttons["challenge-sheet-close"].tap()
            XCTAssertTrue(app.buttons["challenge-friend"].waitForExistence(timeout: 5))
            app.buttons["challenge-friend"].tap()
            XCTAssertTrue(app.buttons["challenge-share-invite"].waitForExistence(timeout: 5))
            sleep(1)
            attach(app, "Challenge invite - Half Century")
            app.buttons["challenge-sheet-close"].tap()

            let invite = app.buttons["challenge-invite"]
            for _ in 0..<4 where !invite.isHittable { app.swipeDown() }
            invite.tap()
            XCTAssertTrue(app.buttons["challenge-friend-format-sprintDuel"].waitForExistence(timeout: 5))
            sleep(1)
            attach(app, "Friend formats")
            app.buttons["challenge-friend-format-sprintDuel"].tap()
            XCTAssertTrue(app.buttons["challenge-share-invite"].waitForExistence(timeout: 5))
            sleep(1)
            attach(app, "Friend invite - Sprint duel")
            app.buttons["challenge-sheet-close"].tap()

            // A practice goal marked done fills its cup and the ball hops to the next one.
            app.buttons["challenge-group-oneFoot"].tap()
            let rightThree = app.buttons["challenge-cup-09"]
            XCTAssertTrue(rightThree.waitForExistence(timeout: 5))
            sleep(1)
            attach(app, "Challenges - one foot")
            rightThree.tap()
            XCTAssertTrue(app.buttons["challenge-mark"].waitForExistence(timeout: 5))
            attach(app, "Challenge card - Right Foot 3")
            app.buttons["challenge-mark"].tap()
            for frame in 0..<8 {
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = "Ball hop \(frame)"
                shot.lifetime = .keepAlways
                add(shot)
            }
            sleep(3)
            attach(app, "Challenges - one foot after hop")
            app.buttons["challenge-ball"].tap()
            attach(app, "Ball kick")
            app.buttons["challenge-group-streaks"].tap()
            app.terminate()
        }
    }

    @MainActor
    func testChallengeKitGroupsForReview() {
        let app = launch(appearance: "light")
        app.mainTab("challenges").tap()
        for group in ["tricks", "oneFoot", "footwork", "timed", "speed", "rounds"] {
            app.buttons["challenge-group-\(group)"].tap()
            sleep(3)
            attach(app, "Kit - \(group)")
            app.swipeUp()
            sleep(1)
            attach(app, "Kit - \(group) lower")
            app.swipeDown(); app.swipeDown()
        }
        app.buttons["challenge-group-streaks"].tap()
    }

    /// Scrolls until the element sits clear of the floating tab bar.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if element.isHittable, element.frame.maxY < app.frame.maxY - 150, element.frame.minY > 120 { return }
            if element.frame.minY <= 120 { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
        }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
