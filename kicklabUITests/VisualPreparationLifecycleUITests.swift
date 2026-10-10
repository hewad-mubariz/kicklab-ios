import XCTest

/// Runs the saved-recording editor on a staged, real phone capture. The raw
/// archive written by VideoAnalyzer is compared externally with the foreground
/// reference, so a responsive editor alone cannot hide lost background frames.
final class VisualPreparationLifecycleUITests: XCTestCase {
    @MainActor
    func testPreparationSurvivesBackgroundAndReturnsToResponsiveEditor() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the staged real phone recording")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES",
            "--capture-processing-video", "documents:batch-fresh-source.mov",
            "--yolo26-motion-model-only", "--visual-async2", "--analysis-ignore-cache",
            "--effects-folder", "batch-visual-lifecycle-background", "--effects-follow-review"]
        app.launch()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 20))
        app.buttons["module-juggling"].tap()
        XCTAssertTrue(app.buttons["replay-customize"].waitForExistence(timeout: 20))
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-ball"].tap()
        app.buttons["ball-picker-galaxy"].tap()
        app.buttons["replay-close-tools"].tap()
        let status = app.staticTexts["replay-spin-status"]
        let active = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            status.exists && status.label.hasPrefix("Preparing ball effects")
                && !status.label.contains("· 0%")
        }, object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [active], timeout: 30), .completed)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 5))
        app.activate()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            status.exists && ["Source spin", "Little visible spin", "Spin uncertain", "Ball not tracked"].contains(status.label)
        }, object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 180), .completed)
        app.buttons["replay-play"].tap()
        XCTAssertEqual(app.buttons["replay-play"].label, "Pause video")
        app.buttons["replay-play"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Prepared ball after background and resume"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        #endif
    }
}
