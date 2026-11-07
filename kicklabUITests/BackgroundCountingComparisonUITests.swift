import XCTest

/// Stage background-input.mov in the separate 1.2 preview's Documents folder.
/// ABBA order exposes run-to-run variation without comparing different devices.
final class BackgroundCountingComparisonUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testForegroundVersusBackgroundCounting() throws {
        try compare([("foreground-1", false), ("background-1", true),
                     ("background-2", true), ("foreground-2", false)])
    }

    @MainActor
    func testWarmForegroundVersusBackgroundCounting() throws {
        try compare([("foreground-3", false), ("background-3", true)])
    }

    @MainActor
    private func compare(_ runs: [(String, Bool)]) throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Continued processing requires a physical device")
        #endif
        for (name, background) in runs {
            let app = XCUIApplication()
            app.launchArguments = ["--background-video-review", "import",
                "--background-video-source", "documents:background-input.mov",
                "--background-video-start-delay", "10",
                "--background-video-report", "iphone17-" + name,
                "--analysis-ignore-cache"]
            app.launch()
            let status = app.staticTexts["background-video-status"]
            XCTAssertTrue(status.waitForExistence(timeout: 20))
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Ready to count' OR label BEGINSWITH 'Failed'"), object: status)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
            XCTAssertEqual(status.label, "Ready to count")
            XCTAssertEqual(app.staticTexts["background-video-allowed"].label, "Allowed")
            if background {
                XCUIDevice.shared.press(.home)
                XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
                // Delay is excluded from the analyzer's elapsed_s measurement.
                // Leave time for completion without any foreground processing.
                for _ in 0..<3 { Thread.sleep(forTimeInterval: 30) }
                app.activate()
                XCTAssertTrue(status.waitForExistence(timeout: 10))
                XCTAssertEqual(status.label, "Done", "The job must finish before reopening")
                XCTAssertEqual(app.staticTexts["background-video-start-state"].label, "Started in background")
                XCTAssertEqual(app.staticTexts["background-video-completion"].label, "Finished in background")
                let updates = Int(app.staticTexts["background-video-updates"].label.components(separatedBy: " ").first ?? "0") ?? 0
                XCTAssertGreaterThan(updates, 3)
            } else {
                let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Done' OR label BEGINSWITH 'Failed'"), object: status)
                XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 120), .completed)
                XCTAssertEqual(status.label, "Done")
                XCTAssertEqual(app.staticTexts["background-video-start-state"].label, "Started in foreground")
                XCTAssertEqual(app.staticTexts["background-video-updates"].label, "0 background updates")
            }
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            app.terminate()
        }
    }
}
