import XCTest

@MainActor
final class RFFullAppUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func waitEnabled(_ element: XCUIElement, _ seconds: Double = 60) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: element)], timeout: seconds), .completed)
    }
    private func allowCamera() {
        let spring = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if spring.alerts.firstMatch.waitForExistence(timeout: 3) {
            let allow = spring.alerts.buttons["Allow"]
            let ok = spring.alerts.buttons["OK"]
            if allow.exists { allow.tap() } else if ok.exists { ok.tap() }
        }
    }
    private func openJuggling(_ app: XCUIApplication) {
        let module = app.buttons["module-juggling"]
        XCTAssertTrue(module.waitForExistence(timeout: 30))
        // Use the visible Start session footer; the Debug HUD can overlap the card artwork.
        module.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        allowCamera()
    }
    func testCameraRecordStopAndReopen() {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES"]
        app.launch()
        openJuggling(app)
        let record = app.buttons["record-capture-button"]
        waitEnabled(record)
        XCTAssertEqual(record.label, "Start Recording")
        attach(app, "Full app camera ready")
        app.buttons["record-flip-camera"].tap(); waitEnabled(record)
        app.buttons["record-flip-camera"].tap(); waitEnabled(record)
        record.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Stop Recording'"), object: record)], timeout: 15), .completed)
        let pause = expectation(description: "Record eight seconds")
        DispatchQueue.main.asyncAfter(deadline: .now()+8) { pause.fulfill() }
        wait(for: [pause], timeout: 10)
        attach(app, "Full app recording")
        record.tap()
        XCTAssertTrue(app.buttons["replay-customize"].waitForExistence(timeout: 90))
        attach(app, "Recorded video in normal replay editor")
        app.buttons["replay-close"].tap()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 15))
        openJuggling(app)
        // Reopen from home and ensure a second preparation works.
        waitEnabled(record)
        XCTAssertEqual(record.label, "Start Recording")
        app.buttons["capture-close"].tap()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 15))
        attach(app, "Returned to full app home")
    }
    func testRecordedSessionEffectsControls() {
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "effects", "--rf-full-app-review", "RFValidation-effects"]
        app.launch()
        XCTAssertTrue(app.buttons["replay-customize"].waitForExistence(timeout: 40))
        XCTAssertTrue(app.buttons["replay-select-counter"].exists)
        app.buttons["replay-play"].tap()
        attach(app, "Real recorded session replay")
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-effects"].tap()
        for effect in ["fire", "neon"] {
            let item = app.buttons["effect-picker-"+effect]
            if !item.isHittable { app.swipeUp() }
            XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
            attach(app, "Real session "+effect)
        }
        app.buttons["replay-tools-back"].tap()
        app.buttons["replay-tool-ball"].tap()
        let gold = app.buttons["ball-picker-gold"]
        if !gold.isHittable { app.swipeUp() }
        XCTAssertTrue(gold.waitForExistence(timeout: 5)); gold.tap()
        attach(app, "Real session gold skin")
        app.buttons["replay-tools-back"].tap()
        app.buttons["replay-tool-counter"].tap()
        app.buttons["counter-style-normal"].tap()
        app.buttons["replay-close-tools"].tap()
        XCTAssertTrue(app.buttons["replay-export"].isEnabled)
        attach(app, "Editor ready to export")
    }
    func testDownloadCounterToPhotos() {
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "effects", "--rf-full-app-review", "RFValidation-effects"]
        app.launch()
        XCTAssertTrue(app.buttons["replay-customize"].waitForExistence(timeout: 40))
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-effects"].tap()
        app.buttons["effect-picker-none"].tap()
        app.buttons["replay-close-tools"].tap()
        let button = app.buttons["replay-export"]
        waitEnabled(button); button.tap()
        let spring = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if spring.alerts.firstMatch.exists {
                let allow = spring.alerts.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Allow' AND NOT label CONTAINS[c] 'Don' AND NOT label CONTAINS[c] 'Not'")).firstMatch
                if allow.exists { allow.tap() }
            }
            if button.exists && button.label == "Saved to Photos. Share" { break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertEqual(button.label, "Saved to Photos. Share")
        attach(app, "Real export saved to Photos")
    }

}
