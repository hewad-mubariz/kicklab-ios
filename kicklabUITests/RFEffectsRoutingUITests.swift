import XCTest

@MainActor
final class RFEffectsRoutingUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    /// Host prelaunches rf-post-session with a real source/live track, no visual track,
    /// --analysis-ignore-cache and --rf-effects-audit. Never selects a replacement ball.
    func testColdPostSessionFirePreparesAndExportsOriginalBall() {
        let app = XCUIApplication(); app.activate()
        XCTAssertTrue(app.buttons["replay-customize"].waitForExistence(timeout: 30))
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-effects"].tap()
        let fire = app.buttons["effect-picker-fire"]
        if !fire.isHittable { app.swipeUp() }
        XCTAssertTrue(fire.waitForExistence(timeout: 5)); fire.tap()
        app.buttons["replay-close-tools"].tap()
        let status = app.staticTexts["replay-effects-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        capture(app, "Real post-session fire preparation")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Effects ready'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 240), .completed)
        capture(app, "Prepared fire with original ball")
        let save = app.buttons["replay-export"]
        XCTAssertTrue(save.isEnabled); save.tap()
        let spring = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            if spring.alerts.firstMatch.exists {
                let allow = spring.alerts.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Allow' AND NOT label CONTAINS[c] 'Don' AND NOT label CONTAINS[c] 'Not'")).firstMatch
                if allow.exists { allow.tap() }
            }
            if save.exists && save.label == "Saved to Photos. Share" { break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertEqual(save.label, "Saved to Photos. Share")
        capture(app, "Fire-only export saved to Photos")
    }
}
