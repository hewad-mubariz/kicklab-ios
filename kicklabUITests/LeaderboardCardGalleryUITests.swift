import XCTest

/// Screenshots of every leaderboard card, in both appearances, for design review.
/// Uses sample boards and a fake account only; nothing reaches a real account.
final class LeaderboardCardGalleryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = true }

    @MainActor
    func testCaptureEveryLeaderboardCard() {
        for appearance in ["dark", "light"] {
            let app = XCUIApplication()
            app.launchArguments = ["-kicklab.welcome.completed", "YES", "--leaderboard-preview", "mixed",
                                   "-kicklab.appearance", appearance]
            app.launch()
            if appearance == "dark" {
                let card = app.buttons["home-leaderboard-card"]
                for _ in 0..<5 where !(card.exists && card.isHittable) { app.swipeUp() }
                pause(1)
                capture(app, "Home card")
                for _ in 0..<5 { app.swipeDown() }
            }
            XCTAssertTrue(app.buttons["home-leaderboard"].waitForExistence(timeout: 10))
            app.buttons["home-leaderboard"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["leaderboard-pennant-1"].waitForExistence(timeout: 8))
            pause(2.5)
            capture(app, "Pennants · \(appearance)")
            app.swipeUp()
            pause(1.5)
            capture(app, "Player rows · \(appearance)")
            let row = app.buttons["leaderboard-row-5"]
            if row.waitForExistence(timeout: 3) {
                row.tap()
                pause(1.5)
                capture(app, "Player detail · \(appearance)")
            }
            app.terminate()

            let joining = XCUIApplication()
            joining.launchArguments = ["-kicklab.welcome.completed", "YES", "--profile-editor-review",
                                       "-kicklab.leaderboard.askedToJoin", "", "-kicklab.appearance", appearance]
            joining.launch()
            XCTAssertTrue(joining.buttons["home-leaderboard"].waitForExistence(timeout: 10))
            joining.buttons["home-leaderboard"].tap()
            XCTAssertTrue(joining.descendants(matching: .any)["leaderboard-join-card"].waitForExistence(timeout: 8))
            pause(1.5)
            capture(joining, "Join card · \(appearance)")
            joining.terminate()
        }
        let replay = XCUIApplication()
        replay.launchArguments = ["--session-design", "leaderboard-replay-card", "--session-video", "documents:leaderboard-review.mov"]
        replay.launch()
        XCTAssertTrue(replay.descendants(matching: .any)["replay-leaderboard-review-card"].waitForExistence(timeout: 10))
        pause(1.5)
        capture(replay, "Post-session card")
    }

    private func pause(_ seconds: TimeInterval) {
        let done = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 1)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
