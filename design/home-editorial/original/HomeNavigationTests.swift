import XCTest

final class HomeNavigationTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testHomeRoutesAndAppearance() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 10))
        app.buttons["tab-profile"].tap()
        app.segmentedControls["appearance-picker"].buttons["Light"].tap()
        app.buttons["tab-home"].tap()

        let milestone = app.buttons["next-milestone"]
        XCTAssertTrue(milestone.isHittable)
        XCTAssertLessThanOrEqual(milestone.frame.maxY, app.buttons["tab-home"].frame.minY)
        XCTAssertFalse(app.buttons["module-dribbling"].isEnabled)
        attach(app, name: "Home - Light")

        app.buttons["module-target-shoot"].tap()
        XCTAssertTrue(app.staticTexts["This training mode is coming soon. In the meantime, build your ball control with Juggling."].waitForExistence(timeout: 3))
        app.buttons["Got it"].tap()
        milestone.tap()
        XCTAssertTrue(app.buttons["Train toward this goal"].waitForExistence(timeout: 3))
        app.buttons["tab-home"].tap()
        app.buttons["Notifications"].tap()
        XCTAssertTrue(app.staticTexts["You're all caught up"].waitForExistence(timeout: 3))
        app.buttons["Back to the pitch"].tap()
        app.buttons["Open profile"].tap()
        app.segmentedControls["appearance-picker"].buttons["Dark"].tap()
        app.buttons["tab-home"].tap()
        XCTAssertTrue(milestone.isHittable)
        attach(app, name: "Home - Dark")
        app.buttons["tab-train"].tap()
        XCTAssertTrue(app.buttons["Start juggling"].waitForExistence(timeout: 3))
        attach(app, name: "Train - Dark")
        app.buttons["tab-challenges"].tap()
        XCTAssertTrue(app.buttons["Give it a try"].waitForExistence(timeout: 3))
        app.buttons["tab-profile"].tap()
        app.terminate()
        app.launch()
        app.buttons["tab-profile"].tap()
        XCTAssertTrue(app.segmentedControls["appearance-picker"].buttons["Dark"].isSelected)
        app.segmentedControls["appearance-picker"].buttons["System"].tap()
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
