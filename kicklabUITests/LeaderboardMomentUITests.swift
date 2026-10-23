import XCTest

final class LeaderboardMomentUITests: XCTestCase {
    @MainActor
    func testMomentReasonsAndFullOriginalRemainAccessible() {
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "leaderboard-moments",
            "--session-video", "documents:leaderboard-review.mov"]
        app.launch()
        XCTAssertTrue(app.buttons["leaderboard-review-moments"].waitForExistence(timeout: 10))
        app.buttons["leaderboard-review-moments"].tap()
        let play = app.buttons["leaderboard-play-moment"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "not proof of a hand touch")).firstMatch.exists)
        play.tap()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Flagged moment with context"; attachment.lifetime = .keepAlways; add(attachment)
        let foot = app.buttons["leaderboard-moment-lowContactUncertain-8000"]
        for _ in 0..<4 where !foot.isHittable { app.swipeUp() }
        XCTAssertTrue(foot.exists); foot.tap()
        for _ in 0..<4 where !play.isHittable { app.swipeDown() }
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "distinguish a foot touch")).firstMatch.exists)
        let full = app.buttons["Watch full recording"]
        XCTAssertTrue(full.isHittable); full.tap()
        XCTAssertTrue(app.navigationBars["Original recording"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(play.waitForExistence(timeout: 5))
    }

    @MainActor
    func testChosenLeftOutTouchesShowTheStreakTheyWouldMake() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "leaderboard-correction",
            "--session-video", "documents:leaderboard-review.mov"]
        app.launch()
        let header = app.descendants(matching: .any)["correction-header"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertTrue(header.label.contains("27"), header.label)
        let send = app.buttons["correction-send"]
        for moment in ["handsUncertain-5200", "lowContactUncertain-9400", "bodyUncertain-12400"] {
            let count = app.buttons["correction-count-\(moment)"]
            for _ in 0..<4 where !count.isHittable { app.swipeUp() }
            count.tap()
        }
        for _ in 0..<4 where !header.isHittable { app.swipeDown() }
        XCTAssertTrue(header.label.contains("30"), "27 plus three confirmed touches: \(header.label)")
        for _ in 0..<5 where !send.isHittable { app.swipeUp() }
        XCTAssertFalse(send.isEnabled, "Agreeing to the rules comes first")
        let agree = app.switches["correction-agree"]
        agree.switches.firstMatch.exists ? agree.switches.firstMatch.tap() : agree.tap()
        XCTAssertTrue(send.isEnabled)
        XCTAssertTrue(send.label.contains("3 touches"), send.label)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Three touches chosen"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
