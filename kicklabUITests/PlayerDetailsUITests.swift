import XCTest

final class PlayerDetailsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testDifferentPlayersAtSameRankAndRepeatedDetailsUseSelectedPlayer() {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES", "--leaderboard-review-count", "10",
                               "-kicklab.appearance", "light", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.buttons["home-leaderboard"].waitForExistence(timeout: 10))
        app.buttons["home-leaderboard"].tap()
        let first = app.buttons["leaderboard-pennant-1"]
        let second = app.buttons["leaderboard-pennant-2"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        func detail(_ element: XCUIElement, name: String, score: String) {
            let correct = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", name), object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [correct], timeout: 5), .completed)
            element.tap()
            XCTAssertTrue(app.buttons["leaderboard-player-close"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.navigationBars[name].exists, "Details must belong to the selected player")
            XCTAssertTrue(app.staticTexts.allElementsBoundByIndex.contains { $0.label.filter(\.isNumber) == score.filter(\.isNumber) },
                          "Details must show that player's streak regardless of the region's grouping separator")
            app.buttons["leaderboard-player-close"].tap()
            XCTAssertTrue(first.waitForExistence(timeout: 5))
        }
        detail(first, name: "Leo", score: "458")
        detail(second, name: "Noah", score: "421")
        detail(first, name: "Leo", score: "458")
        app.buttons["leaderboard-period-all-time"].tap()
        detail(first, name: "Amir", score: "1,284")
        detail(second, name: "Leo", score: "1,102")
        app.buttons["leaderboard-period-week"].tap()
        detail(first, name: "Leo", score: "458")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Player identity after switching periods and reopening details"
        shot.lifetime = .keepAlways; add(shot)
    }
}
