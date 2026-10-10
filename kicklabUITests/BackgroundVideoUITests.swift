import XCTest

/// Stage background-input.mov in Documents before running on a physical iPhone.
final class BackgroundVideoUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testImportMakesProgressAfterHome() throws { try exercise("import", backgroundSeconds: 25) }

    @MainActor
    func testGraphExportMakesProgressAfterHome() throws { try exercise("export", backgroundSeconds: 25) }

    @MainActor
    func testShotExportMakesProgressAfterHome() throws { try exercise("shot", backgroundSeconds: 25) }

    @MainActor
    func testSavedConfirmationOpensPhotosAndDoesNotRedirectOnReturn() {
        let app = XCUIApplication()
        app.launchArguments = ["--background-video-review", "photos"]
        app.launch()
        let saved = app.buttons["review-saved-video"]
        XCTAssertTrue(saved.waitForExistence(timeout: 20))
        saved.tap()
        let alert = app.alerts["Video saved to Photos"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["OK"].tap()
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        XCTAssertTrue(photos.wait(for: .runningForeground, timeout: 10))
        app.activate()
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        XCTAssertFalse(alert.exists)
    }

    @MainActor
    private func exercise(_ mode: String, backgroundSeconds: TimeInterval) throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Continued processing requires a physical device")
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["--background-video-review", mode, "--background-video-source", "documents:background-input.mov", "--analysis-ignore-cache"]
        app.launch()
        let status = app.staticTexts["background-video-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        Thread.sleep(forTimeInterval: backgroundSeconds)
        app.activate()
        let updates = app.staticTexts["background-video-updates"]
        XCTAssertTrue(updates.waitForExistence(timeout: 10))
        let count = Int(updates.label.components(separatedBy: " ").first ?? "0") ?? 0
        XCTAssertGreaterThan(count, 0, "The video must advance while backgrounded, not merely resume on return")
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Done' OR label BEGINSWITH 'Failed'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 300), .completed)
        XCTAssertEqual(status.label, "Done")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(mode) advanced in background"; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
