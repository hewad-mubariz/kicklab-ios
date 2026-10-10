import XCTest

final class CaptureProcessingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSavedCaptureProcessesThenOpensResponsiveEditorWithStoredSettings() throws {
        #if targetEnvironment(simulator)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kicklabTests/Fixtures/capture-sixty.mov").path
        #else
        let fixture = "documents:processing-regression.mov"
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES", "--capture-processing-video", fixture]
        app.launch()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 15))
        app.buttons["module-juggling"].tap()
        // Home -> RecordView -> immediate PostSessionFlowView; precise effects are deferred.
        // This deliberately avoids --session-design, which disables preference writes.
        assertResponsiveEditor(app, timeout: 10)
        app.buttons["replay-close"].tap()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 10))
        app.buttons["module-juggling"].tap()
        assertResponsiveEditor(app, timeout: 10)
        XCTAssertTrue(app.startReplayDownload(), "Download starts in place")
        attach(app, "Processed recording - downloading")
    }

    @MainActor
    func testDeferredBallEffectsContinueAcrossShareAndReopening() throws {
        #if targetEnvironment(simulator)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kicklabTests/Fixtures/capture-sixty.mov").path
        #else
        let fixture = "documents:processing-regression.mov"
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES", "--capture-processing-video", fixture]
        app.launch()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout:15))
        app.buttons["module-juggling"].tap()
        XCTAssertTrue(app.buttons["replay-customize"].waitForExistence(timeout:10))
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-ball"].tap()
        app.buttons["ball-picker-gold"].tap()
        XCTAssertTrue(app.staticTexts["replay-spin-status"].waitForExistence(timeout:10))
        app.buttons["replay-close-tools"].tap()
        // The download waits on the same shared ball preparation the editor shows.
        XCTAssertTrue(app.startReplayDownload(), "Download starts in place")
        let status = app.staticTexts["replay-spin-status"]
        XCTAssertTrue(status.waitForExistence(timeout:10))
        let ready = XCTNSPredicateExpectation(predicate:NSPredicate { _, _ in
            ["Source spin", "Little visible spin", "Spin uncertain", "Ball not tracked"].contains(status.label)
        }, object:status)
        XCTAssertEqual(XCTWaiter.wait(for:[ready],timeout:120),.completed)
        app.buttons["replay-play"].tap()
        XCTAssertEqual(app.buttons["replay-play"].label,"Pause video")
        app.buttons["replay-play"].tap()
        XCTAssertTrue(app.waitForReplaySaved(timeout: 300), "The download finishes once preparation is done")
        attach(app,"Shared ball preparation completed and saved")
    }

    @MainActor
    func testPhoneRecordStopEditorAndRecordAgain() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("A physical camera is required")
        #else
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 15))
        app.buttons["module-juggling"].tap()
        for _ in 0..<2 {
            let record = app.buttons["record-capture-button"]
            XCTAssertTrue(record.waitForExistence(timeout: 15))
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: record)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
            record.tap()
            let started = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Stop'"), object: record)
            XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 30), .completed)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
            record.tap()
            assertResponsiveEditor(app, timeout: 120)
            XCTAssertTrue(app.startReplayDownload(), "Download starts in place")
            XCTAssertTrue(app.waitForReplaySaved(timeout: 180))
            app.buttons["replay-record-another"].tap()
        }
        app.buttons["capture-close"].tap()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 10))
        #endif
    }

    @MainActor
    private func assertResponsiveEditor(_ app: XCUIApplication, timeout: TimeInterval) {
        XCTAssertTrue(app.buttons["replay-export"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.staticTexts["Processing Your Session"].exists)
        XCTAssertTrue(app.buttons["replay-play"].waitForExistence(timeout: 10))
        app.buttons["replay-play"].tap()
        XCTAssertEqual(app.buttons["replay-play"].label, "Pause video")
        app.buttons["replay-play"].tap()
        app.buttons["replay-customize"].tap()
        XCTAssertTrue(app.buttons["replay-tool-counter"].waitForExistence(timeout: 5))
        app.buttons["replay-close-tools"].tap()
        attach(app, "Processing completed - responsive editor")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
