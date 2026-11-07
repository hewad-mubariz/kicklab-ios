import XCTest

/// Stage background-input.mov in Documents before running on a physical iPhone.
final class BackgroundVideoUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testImportMakesProgressAfterHome() throws { try exercise("import", backgroundSeconds: 25) }

    @MainActor
    func testImportFinishesWithoutReopeningApp() throws {
        try exercise("import", backgroundSeconds: 120, requiresBackgroundCompletion: true)
    }

    @MainActor
    func testCountingContinuesAcrossHomeAndReturn() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Continued processing requires a physical device")
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["--background-video-review", "import", "--analysis-ignore-cache",
            "--background-video-report", "lifecycle-latest"]
        app.launch()
        let status = app.staticTexts["background-video-status"]
        let backend = app.staticTexts["background-video-model-backend"]
        XCTAssertTrue(backend.waitForExistence(timeout: 20))
        let started = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Accelerated' OR label == 'CPU'"), object: backend)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 60), .completed)
        let foregroundBackend = backend.label
        XCTAssertEqual(app.staticTexts["background-video-allowed"].label, "Allowed")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        Thread.sleep(forTimeInterval: 8)
        app.activate()
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Importing", "Return before completion to exercise the switch back")
        let cpuUpdates = Int(app.staticTexts["background-video-cpu-updates"].label) ?? 0
        XCTAssertGreaterThan(cpuUpdates, 0, "Frames must actually advance on CPU while backgrounded")
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", foregroundBackend), object: backend)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 30), .completed)
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Done' OR label BEGINSWITH 'Failed'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 240), .completed)
        XCTAssertEqual(status.label, "Done")
        XCTAssertEqual(backend.label, foregroundBackend)
        if foregroundBackend == "Accelerated" {
            XCTAssertGreaterThanOrEqual(Int(app.staticTexts["background-video-model-switches"].label) ?? 0, 2)
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Counting continued through CPU switch and foreground return"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testGraphExportMakesProgressAfterHome() throws { try exercise("export", backgroundSeconds: 25) }

    @MainActor
    func testShotExportMakesProgressAfterHome() throws { try exercise("shot", backgroundSeconds: 25) }

    @MainActor
    func testArtworkExportMakesProgressAfterHome() throws { try exercise("artwork", backgroundSeconds: 25) }

    @MainActor
    func testSavedBannerOpensPhotosAndDoesNotRedirectOnReturn() {
        let app = XCUIApplication()
        app.launchArguments = ["--background-video-review", "photos"]
        app.launch()
        let saved = app.buttons["review-saved-video"]
        XCTAssertTrue(saved.waitForExistence(timeout: 20))
        saved.tap()
        let banner = app.buttons["replay-saved-toast"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Video saved to Photos"].exists)
        banner.tap()
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        XCTAssertTrue(photos.wait(for: .runningForeground, timeout: 10))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Video saved to Photos"].exists)
    }

    @MainActor
    private func exercise(_ mode: String, backgroundSeconds: TimeInterval, requiresBackgroundCompletion: Bool = false) throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Continued processing requires a physical device")
        #endif
        let app = XCUIApplication()
        let source = mode == "artwork" ? "documents:ball-gpu-background-input.mov" : "documents:background-input.mov"
        app.launchArguments = ["--background-video-review", mode, "--background-video-source", source, "--analysis-ignore-cache"]
        app.launch()
        let status = app.staticTexts["background-video-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        if mode == "import" {
            // Minimize only after the analyzer acquired its background lease
            // and processed frames, matching the user-facing import flow.
            let progress = app.staticTexts["background-video-progress"]
            let started = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
                if status.label.hasPrefix("Failed") { return true }
                guard let element = object as? XCUIElement, let value = Double(element.label) else { return false }
                return value > 0 && value < 1
            }, object: progress)
            XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 60), .completed)
            XCTAssertFalse(status.label.hasPrefix("Failed"), status.label)
            XCTAssertEqual(app.staticTexts["background-video-allowed"].label, "Allowed")
        } else {
            let preparing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Preparing export'"), object: status)
            XCTAssertEqual(XCTWaiter.wait(for:[preparing],timeout:60),.completed)
        }
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        var remaining = backgroundSeconds
        while remaining > 0 {
            let interval = min(30, remaining)
            Thread.sleep(forTimeInterval: interval)
            remaining -= interval
        }
        app.activate()
        let updates = app.staticTexts["background-video-updates"]
        XCTAssertTrue(updates.waitForExistence(timeout: 10))
        let count = Int(updates.label.components(separatedBy: " ").first ?? "0") ?? 0
        XCTAssertGreaterThan(count, 3, "The video must keep advancing while backgrounded, beyond a pending frame at Home")
        if requiresBackgroundCompletion {
            XCTAssertEqual(app.staticTexts["background-video-completion"].label, "Finished in background")
            XCTAssertEqual(status.label, "Done", "Counting must finish before reopening the app")
        }
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Done' OR label BEGINSWITH 'Failed'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 300), .completed)
        XCTAssertEqual(status.label, "Done")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(mode) advanced in background"; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
