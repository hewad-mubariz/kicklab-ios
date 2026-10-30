import XCTest

/// Exercises a real export through the foreground-only service on the minimum OS.
final class LegacyVideoProcessingUITests: XCTestCase {
    @MainActor
    func testExportPausesInBackgroundAndFinishesAfterReturning() throws {
        try XCTSkipIf(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26,
                      "This checks the older-system foreground fallback")
        continueAfterFailure = false
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kicklabTests/Fixtures/capture-sixty.mov").path
        let app = XCUIApplication()
        app.launchArguments = ["--background-video-review", "export", "--background-video-source", fixture]
        app.launch()
        let status = app.staticTexts["background-video-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        let started = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Preparing export'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 10), .completed)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        // Stay away long enough for the export to have advanced without a checkpoint.
        Thread.sleep(forTimeInterval: 4)
        app.activate()
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["background-video-updates"].label, "0 background updates")
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Done' OR label BEGINSWITH 'Failed'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 90), .completed)
        XCTAssertEqual(status.label, "Done")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "iOS 18 export resumed and completed"; shot.lifetime = .keepAlways
        add(shot)
    }
}
