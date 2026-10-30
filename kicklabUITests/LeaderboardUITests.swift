import XCTest
import Vision

final class LeaderboardUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// A persisted session ID used to expose a second, unguarded review entry point.
    @MainActor
    func testAutomaticBetaSavedReplayDoesNotOfferSubmission() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This fixture path is only available in the simulator")
        #endif
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kicklabTests/Fixtures/juggling-eighteen.mov").path
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "saved-replay", "--session-video", fixture]
        app.launch()
        XCTAssertTrue(app.buttons["replay-export"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["replay-leaderboard-submit"].exists)
        XCTAssertFalse(app.buttons["correction-send"].exists)
        app.buttons["replay-customize"].tap()
        XCTAssertTrue(app.buttons["replay-close-tools"].waitForExistence(timeout: 5))
        app.buttons["replay-close-tools"].tap()
        XCTAssertTrue(app.buttons["replay-play"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["replay-leaderboard-submit"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Saved replay without manual leaderboard submission"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testAutomaticBetaReplayStreakIsInformational() {
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "leaderboard-replay-card"]
        app.launch()
        let card = app.descendants(matching: .any)["replay-leaderboard-review-card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(card.label.contains("Best streak 27"), card.label)
        XCTAssertTrue(card.label.contains("Counts on the leaderboard by itself"), card.label)
        XCTAssertFalse(app.buttons["replay-leaderboard-review-card"].exists)
        card.tap()
        XCTAssertFalse(app.buttons["correction-send"].exists)
        XCTAssertTrue(card.exists)
    }

    @MainActor
    func testEmptyResponseShowsAnHonestEmptyState() {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES", "--leaderboard-review-count", "0"]
        app.launch()
        let open = app.buttons["home-leaderboard"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(app.descendants(matching: .any)["leaderboard-empty"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.descendants(matching: .any)["leaderboard-pennant-1"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Juggle Dude leaderboard — empty response"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Retained pending-check data must not revive the postponed review flow.
    @MainActor
    func testAutomaticBetaHidesPendingTouchChecks() {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES", "--leaderboard-preview", "inReview", "-kicklab.appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["home-leaderboard"].waitForExistence(timeout: 10))
        app.buttons["home-leaderboard"].tap()
        let pill = app.buttons["leaderboard-you-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 8))
        XCTAssertFalse(pill.label.contains("in review"), pill.label)
        pill.tap()
        let row = app.buttons["leaderboard-row-11"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let settled = expectation(description: "Row settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        XCTAssertTrue(row.label.contains("27 touches"), row.label)
        XCTAssertFalse(row.label.contains("in review"), row.label)
        XCTAssertFalse(row.label.contains("if confirmed"), row.label)
        XCTAssertFalse(app.buttons["leaderboard-my-submissions"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Automatic beta without pending-check prompts"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// An old response can carry an approved attempt ID even when checks are off.
    @MainActor
    func testAutomaticBetaHidesLegacyReviewDetailsAndReporting() {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES", "--leaderboard-review-count", "1",
                               "--leaderboard-legacy-review", "-kicklab.appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["home-leaderboard"].waitForExistence(timeout: 10))
        app.buttons["home-leaderboard"].tap()
        let first = app.descendants(matching: .any)["leaderboard-pennant-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        first.tap()
        XCTAssertTrue(app.buttons["leaderboard-player-close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Best streak"].exists)
        XCTAssertTrue(app.staticTexts["Counted automatically from a recorded session."].exists)
        XCTAssertFalse(app.staticTexts["Checked streak"].exists)
        XCTAssertFalse(app.buttons["Report this score"].exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "reviewer confirmed")).firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Legacy review response renders as automatic beta"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testDelayedSinglePlayerPennantIsVisible() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES", "--leaderboard-review-count", "1", "-kicklab.appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["home-leaderboard"].waitForExistence(timeout: 10))
        app.buttons["home-leaderboard"].tap()
        let first = app.descendants(matching: .any)["leaderboard-pennant-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let settled = expectation(description: "Pennant reveal settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "leaderboard-single-player"
        attachment.lifetime = .keepAlways
        add(attachment)
        // The outer accessibility frame remains full-sized even if the cloth is
        // visually flattened. Inspect its lower half to catch that exact bug.
        let source = try XCTUnwrap(shot.image.cgImage)
        let scale = CGFloat(source.width) / app.frame.width
        let rect = first.frame
        let pennant = try XCTUnwrap(source.cropping(to: CGRect(x: rect.minX * scale, y: rect.minY * scale,
            width: rect.width * scale, height: rect.height * scale).integral))
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: pennant).perform([textRequest])
        let visibleText = (textRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(visibleText.contains("1"), "The rank must be drawn inside the pennant")
        XCTAssertTrue(visibleText.localizedCaseInsensitiveContains("You"), "The player's name must be drawn, not just the photo")
        XCTAssertTrue(visibleText.contains("74"), "The score must be drawn inside the pennant")
        try assertExpanded(shot, pennant: rect, app: app)
        XCTAssertLessThan(first.frame.minY, app.frame.height * 0.5)
        XCTAssertFalse(app.descendants(matching: .any)["leaderboard-you"].exists,
                       "Your podium place must not be duplicated at the bottom")
        XCTAssertFalse(app.descendants(matching: .any)["leaderboard-row-1"].exists,
                       "Top three players appear in the podium only")
    }

    @MainActor
    private func assertExpanded(_ shot: XCUIScreenshot, pennant rect: CGRect, app: XCUIApplication,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try XCTUnwrap(shot.image.cgImage)
        let scale = CGFloat(source.width) / app.frame.width
        let crop = CGRect(x: rect.minX * scale, y: (rect.minY + rect.height * 0.35) * scale,
                          width: rect.width * scale, height: rect.height * 0.5 * scale).integral
        let image = try XCTUnwrap(source.cropping(to: crop))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let green = stride(from: 0, to: pixels.count, by: 4).filter { offset in
            let r = Double(pixels[offset]), g = Double(pixels[offset + 1]), b = Double(pixels[offset + 2])
            return g > 100 && g > r * 0.95 && g > b * 1.3 && r > b * 1.3
        }.count
        XCTAssertGreaterThan(Double(green) / Double(image.width * image.height), 0.2,
                             "The first-place pennant must stay expanded", file: file, line: line)
    }

    @MainActor
    func testCachedTabsAndPullToRefreshKeepPodiumVisible() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES", "--leaderboard-review-count", "1", "-kicklab.appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["home-leaderboard"].waitForExistence(timeout: 10))
        app.buttons["home-leaderboard"].tap()
        let first = app.descendants(matching: .any)["leaderboard-pennant-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        func expectScore(_ score: Int) {
            let result = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "\(score) touches"), object: first)
            XCTAssertEqual(XCTWaiter.wait(for: [result], timeout: 5), .completed)
        }
        expectScore(74)
        app.buttons["leaderboard-period-all-time"].tap()
        expectScore(96)
        try assertExpanded(app.screenshot(), pennant: first.frame, app: app)
        app.buttons["leaderboard-period-week"].tap()
        expectScore(74) // A second request would return 75 instead.
        XCTAssertFalse(app.descendants(matching: .any)["leaderboard-loading"].exists)
        try assertExpanded(app.screenshot(), pennant: first.frame, app: app)
        app.buttons["leaderboard-period-all-time"].tap()
        expectScore(96)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.1, thenDragTo: end)
        expectScore(97)
        try assertExpanded(app.screenshot(), pennant: first.frame, app: app)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "leaderboard-refreshed-without-refolding"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["leaderboard-period-week"].tap()
        expectScore(74) // Refreshing All Time must leave This Week cached.
    }

    @MainActor
    func testOpensOneLeaderboardSwitchesPeriodsAndCloses() {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES", "--leaderboard-samples",
                               "-kicklab.juggling.personalBest", "350", "-kicklab.appearance", "dark"]
        app.launch()
        let open = app.buttons["home-leaderboard"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()

        let first = app.descendants(matching: .any)["leaderboard-pennant-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["leaderboard-preview-label"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["leaderboard-row-4"].label.contains("you"))
        let weekLeader = first.label

        let settled = expectation(description: "Preview reveal settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        let top = XCTAttachment(screenshot: app.screenshot())
        top.name = "leaderboard-ten-players-top"
        top.lifetime = .keepAlways
        add(top)
        let last = app.descendants(matching: .any)["leaderboard-row-10"]
        for _ in 0..<5 where !last.isHittable { app.swipeUp() }
        XCTAssertTrue(last.isHittable)
        XCTAssertFalse(app.descendants(matching: .any)["leaderboard-row-11"].exists)
        let bottom = XCTAttachment(screenshot: app.screenshot())
        bottom.name = "leaderboard-ten-players-list"
        bottom.lifetime = .keepAlways
        add(bottom)
        app.buttons["leaderboard-close"].tap()
        open.tap()
        XCTAssertTrue(app.buttons["leaderboard-period-week"].isHittable, "Reopening starts at the top")
        XCTAssertTrue(first.isHittable)

        app.buttons["leaderboard-period-all-time"].tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", weekLeader), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed, "All time shows a different board")
        XCTAssertTrue(app.buttons["leaderboard-period-all-time"].isSelected)

        XCTAssertFalse(app.buttons["leaderboard-scope"].exists, "One shared leaderboard has no location selector")

        first.tap()
        XCTAssertTrue(app.buttons["leaderboard-player-close"].waitForExistence(timeout: 3))
        app.buttons["leaderboard-player-close"].tap()
        app.buttons["leaderboard-close"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
    }
}
