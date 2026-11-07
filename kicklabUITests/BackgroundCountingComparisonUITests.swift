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

    /// Full 56m47s source, with a five-minute Home interval during analysis.
    /// The staged file bypasses Photos transfer; the production analyzer,
    /// background lease, frame policy and mask retention remain unchanged.
    @MainActor
    func testLongVideoCountingAcrossBackground() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Continued processing requires a physical device")
        #endif
        executionTimeAllowance = 10_800
        let app = XCUIApplication()
        app.launchArguments = ["--background-video-review", "import",
            "--background-video-source", "documents:long-video-20261108.mov",
            "--background-video-report", "iphone17-long-20261108",
            "--background-video-journal", "--analysis-ignore-cache", "--pose-profile"]
        app.launch()
        let status = app.staticTexts["background-video-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        let backend = app.staticTexts["background-video-model-backend"]
        let started = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Accelerated' OR label == 'CPU'"), object: backend)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 90), .completed)
        XCTAssertEqual(app.staticTexts["background-video-allowed"].label, "Allowed")
        for _ in 0..<4 { Thread.sleep(forTimeInterval: 30) }
        XCTAssertEqual(status.label, "Importing")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        for _ in 0..<10 { Thread.sleep(forTimeInterval: 30) }
        app.activate()
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        let returned = XCTAttachment(screenshot: app.screenshot())
        returned.name = "Long video after five minutes in background"
        returned.lifetime = .keepAlways; add(returned)
        XCTAssertFalse(status.label.hasPrefix("Failed"), status.label)
        XCTAssertGreaterThan(Int(app.staticTexts["background-video-cpu-updates"].label) ?? 0, 0)
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Done' OR label BEGINSWITH 'Failed'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 10_000), .completed)
        XCTAssertEqual(status.label, "Done")
        XCTAssertEqual(app.staticTexts["background-video-progress"].label, "1.0")
        let completed = XCTAttachment(screenshot: app.screenshot())
        completed.name = "Long video complete"
        completed.lifetime = .keepAlways; add(completed)
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
