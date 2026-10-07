import XCTest

final class HomeNavigationTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTrainingHomeAndAppearancePersistence() {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.juggling.personalBest", "42"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["module-juggling"].isEnabled)
        XCTAssertTrue(app.buttons["module-power-shot"].isEnabled)
        XCTAssertFalse(app.buttons["module-target-shooting"].isEnabled)
        XCTAssertFalse(app.buttons["tab-home"].exists)
        XCTAssertEqual(app.descendants(matching: .any)["home-personal-best"].label,
                       "Juggling personal best, 42 touches")

        app.buttons["home-profile"].tap()
        app.buttons["profile-settings"].tap()
        app.segmentedControls["appearance-picker"].buttons["Light"].tap()
        attach(app, name: "Profile settings - Light")
        app.navigationBars["Settings"].buttons.element(boundBy: 0).tap()
        app.buttons["profile-close"].tap()
        XCTAssertTrue(app.buttons["home-import-video"].isHittable)
        attach(app, name: "Training home - Light")
        app.buttons["home-profile"].tap()
        app.buttons["profile-settings"].tap()
        app.segmentedControls["appearance-picker"].buttons["Dark"].tap()
        app.navigationBars["Settings"].buttons.element(boundBy: 0).tap()
        app.buttons["profile-close"].tap()
        attach(app, name: "Training home - Dark")
        app.terminate()
        app.launch()
        app.buttons["home-profile"].tap()
        app.buttons["profile-settings"].tap()
        XCTAssertTrue(app.segmentedControls["appearance-picker"].buttons["Dark"].isSelected)
        app.navigationBars["Settings"].buttons.element(boundBy: 0).tap()
        app.buttons["profile-close"].tap()
        app.buttons["home-setup-guide"].tap()
        XCTAssertTrue(app.staticTexts["Prop up your phone"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testProfileNameSaveCancelAndPersistence() {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.juggling.personalBest", "42"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        app.buttons["home-profile"].tap()
        XCTAssertEqual(app.descendants(matching: .any)["profile-personal-best"].label,
                       "Juggling personal best, 42 touches")
        app.buttons["profile-edit-name"].tap()
        let field = app.textFields["profile-name-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        let originalName = (field.value as? String).flatMap { $0 == "Your name" ? "" : $0 } ?? ""
        replaceName(in: field, with: "  Jordan  ")
        app.buttons["profile-name-save"].tap()
        XCTAssertEqual(app.staticTexts["profile-name"].label, "Jordan")
        attach(app, name: "Profile - personal best and name")

        app.buttons["profile-edit-name"].tap()
        replaceName(in: field, with: "Unsaved change")
        app.buttons["profile-name-cancel"].tap()
        XCTAssertEqual(app.staticTexts["profile-name"].label, "Jordan")
        app.terminate()
        app.launch()
        app.buttons["home-profile"].tap()
        XCTAssertEqual(app.staticTexts["profile-name"].label, "Jordan")

        // Leave the simulator's existing profile as it was before this test.
        app.buttons["profile-edit-name"].tap()
        replaceName(in: field, with: originalName)
        app.buttons["profile-name-save"].tap()
        XCTAssertEqual(app.staticTexts["profile-name"].label,
                       originalName.isEmpty ? "Your profile" : originalName)
        app.buttons["profile-close"].tap()
        XCTAssertTrue(app.buttons["module-juggling"].isHittable)
    }

    @MainActor
    private func replaceName(in field: XCUIElement, with value: String) {
        field.tap()
        let current = (field.value as? String).flatMap { $0 == "Your name" ? "" : $0 } ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + value)
    }

    @MainActor
    func testPowerShotKeepsResearchControlsAndCanClose() {
        let app = XCUIApplication()
        app.launchArguments = ["--roll-distance-ui-review"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["module-power-shot"].waitForExistence(timeout: 10))
        app.buttons["module-power-shot"].tap()
        XCTAssertTrue(app.staticTexts["power-shot-title"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["roll-distance-toggle"].exists)
        XCTAssertTrue(app.buttons["roll-calibrate"].exists)
        XCTAssertTrue(app.buttons["power-shot-saved-shots"].exists)
        XCTAssertTrue(app.buttons["power-shot-record"].exists)
        attach(app, name: "Power Shot - existing research controls")
        app.buttons["power-shot-close"].tap()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testJugglingAndImportCanReturnHome() {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 10))
        app.buttons["module-juggling"].tap()
        XCTAssertTrue(app.buttons["record-gallery-picker"].waitForExistence(timeout: 10))
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["record-gallery-picker"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home-import-video"].waitForExistence(timeout: 5))
        app.buttons["home-import-video"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["record-gallery-picker"].exists)
    }

    @MainActor
    func testEmptyRecordAndAccessibilityLayout() {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.juggling.personalBest", "0",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let juggling = app.buttons["module-juggling"]
        XCTAssertTrue(juggling.waitForExistence(timeout: 10))
        let powerShot = app.buttons["module-power-shot"]
        // Large text switches the grid to a single column instead of squeezing labels.
        XCTAssertGreaterThanOrEqual(powerShot.frame.minY, juggling.frame.maxY)
        attach(app, name: "Training home - accessibility text")
        app.buttons["home-profile"].tap()
        XCTAssertTrue(app.staticTexts["profile-name"].waitForExistence(timeout: 3))
        let profileRecord = app.descendants(matching: .any)["profile-personal-best"]
        XCTAssertEqual(profileRecord.label,
                       "Juggling personal best. Your first juggling session starts your record.")
        for _ in 0..<4 where !app.buttons["profile-settings"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["profile-settings"].isHittable)
        attach(app, name: "Profile - accessibility text")
        app.buttons["profile-close"].tap()
        let record = app.descendants(matching: .any)["home-personal-best"]
        for _ in 0..<6 where !record.isHittable { app.swipeUp() }
        XCTAssertEqual(record.label, "Juggling personal best. Your first record starts here.")
        let importButton = app.buttons["home-import-video"]
        for _ in 0..<6 where !importButton.isHittable { app.swipeUp() }
        XCTAssertTrue(importButton.isHittable)
        attach(app, name: "Training home - accessibility lower content")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
