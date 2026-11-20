import XCTest

/// Phone-only visual check of the replay tray (Ball sets and the Analytics grid) on a review clip
/// copied to the app's Documents folder, so no saved session is opened or changed.
/// Runs only with PHONE_TRAY_REVIEW set (TEST_RUNNER_PHONE_TRAY_REVIEW=1) and the clip at
/// Documents/review-eighteen.mov.
@MainActor
final class PhoneReplayToolsReview: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func pause(_ seconds: Double) {
        let done = expectation(description: "pause")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 5)
    }

    func testBallSetsAndAnalyticsOnPhone() throws {
        guard ProcessInfo.processInfo.environment["PHONE_TRAY_REVIEW"] != nil else { throw XCTSkip("Phone review only") }
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "capture-flow", "--session-video", "documents:review-eighteen.mov"]
        app.launch()
        XCTAssertTrue(app.buttons["replay-customize"].waitForExistence(timeout: 30))
        app.buttons["replay-customize"].tap()
        XCTAssertTrue(app.buttons["replay-tool-ball"].waitForExistence(timeout: 5))
        shot(app, "00 tools")
        app.buttons["replay-tool-ball"].tap()
        let balls = app.scrollViews["ball-picker-options"]
        XCTAssertTrue(balls.waitForExistence(timeout: 5))
        if app.buttons["paywall-close"].exists { XCTFail("The Ball page is behind the paywall on this phone"); return }
        pause(0.5)
        shot(app, "01 balls after 0.5 s")
        pause(2.5)
        shot(app, "02 balls after 3 s")
        for index in 3...6 {
            balls.swipeUp(); pause(1)
            shot(app, String(format: "%02d balls scrolled", index))
        }
        let kintsugi = app.buttons["ball-picker-kintsugi"]
        for _ in 0..<8 where !kintsugi.isHittable { balls.swipeDown() }
        kintsugi.tap()
        pause(0.25)
        shot(app, "11 kintsugi hop")
        pause(2)
        shot(app, "12 kintsugi on the clip")
        app.buttons["replay-tools-back"].tap()
        app.buttons["replay-tool-graph"].tap()
        XCTAssertTrue(app.buttons["motion-style-ballMotion"].waitForExistence(timeout: 5))
        pause(1)
        shot(app, "13 analytics top")
        let options = app.scrollViews["motion-style-options"]
        options.swipeUp(); pause(0.8)
        shot(app, "14 analytics scrolled")
        options.swipeUp(); options.swipeUp(); pause(0.8)
        shot(app, "15 analytics lab views")
        // One analytic at a time: Ball Flight replaces the graph on the replay.
        let flight = app.buttons["lab-view-ball-flight"]
        for _ in 0..<6 where !flight.isHittable { options.swipeUp() }
        flight.tap(); pause(1)
        shot(app, "16 ball flight picked")
        let foot = app.buttons["lab-view-foot-rally"]
        for _ in 0..<6 where !foot.isHittable { options.swipeDown() }
        foot.tap(); pause(2)
        shot(app, "17 foot rally picked")
        app.buttons["replay-close-tools"].tap(); pause(2)
        shot(app, "18 foot rally on the replay")
    }
}
