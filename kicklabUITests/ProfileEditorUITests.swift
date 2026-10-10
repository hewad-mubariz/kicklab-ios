import XCTest

@MainActor
final class ProfileEditorUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testCountryScrollAndDraftSurviveRefreshThenSave() throws {
        let app = openEditor(appearance: "dark", refresh: true)
        capture(app, "profile-editor-dark")
        replace(app.textFields["profile-name-field"], with: "Alex Morgan")
        app.buttons["profile-country"].tap()
        let list = app.scrollViews["profile-country-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        for _ in 0..<5 { list.swipeUp(velocity: .slow) }
        let visible = list.buttons.allElementsBoundByIndex.filter { $0.isHittable }
        let anchor = try XCTUnwrap(visible.dropFirst().first)
        let identifier = anchor.identifier
        let y = anchor.frame.midY
        XCTAssertFalse(list.buttons["country-option-none"].isHittable)
        // The fixture publishes a fresh cloud profile every second while this
        // screen is open; an idle interval catches delayed jumps to the top.
        let settled = expectation(description: "Background profile refreshes complete")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertTrue(list.buttons[identifier].isHittable)
        XCTAssertEqual(list.buttons[identifier].frame.midY, y, accuracy: 2)
        capture(app, "country-scroll-retained")

        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("Japan")
        let japan = app.buttons["country-option-JP"]
        XCTAssertTrue(japan.waitForExistence(timeout: 3))
        capture(app, "country-search")
        japan.tap()
        XCTAssertEqual(app.textFields["profile-name-field"].value as? String, "Alex Morgan")
        XCTAssertEqual(app.buttons["profile-country"].value as? String, "Japan")
        app.buttons["profile-name-save"].tap()
        XCTAssertTrue(app.buttons["profile-edit-name"].waitForExistence(timeout: 5))
        app.buttons["profile-edit-name"].tap()
        XCTAssertEqual(app.textFields["profile-name-field"].value as? String, "Alex Morgan")
        XCTAssertEqual(app.buttons["profile-country"].value as? String, "Japan")
    }

    func testCountryCancelAndNameValidationInLightMode() {
        let app = openEditor(appearance: "light")
        capture(app, "profile-editor-light")
        app.buttons["profile-country"].tap()
        app.buttons["country-option-none"].tap()
        XCTAssertEqual(app.buttons["profile-country"].value as? String, "Not selected")
        replace(app.textFields["profile-name-field"], with: " ")
        XCTAssertFalse(app.buttons["profile-name-save"].isEnabled)
        let field = app.textFields["profile-name-field"]
        field.tap()
        field.typeText(String(repeating: "a", count: 41) + "\n")
        XCTAssertEqual((field.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).count, 41)
        XCTAssertFalse(app.buttons["profile-name-save"].isEnabled)
        app.buttons["profile-name-cancel"].tap()
        app.buttons["profile-edit-name"].tap()
        XCTAssertEqual(app.textFields["profile-name-field"].value as? String, "Alex Rivera")
        XCTAssertEqual(app.buttons["profile-country"].value as? String, "Germany")
    }

    func testFailedSaveKeepsDraftAndAllowsRetry() {
        let app = openEditor(appearance: "dark", failure: true)
        replace(app.textFields["profile-name-field"], with: "New name")
        app.buttons["profile-name-save"].tap()
        XCTAssertTrue(app.staticTexts["profile-save-error"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["profile-name-field"].value as? String, "New name")
        XCTAssertTrue(app.buttons["profile-name-save"].isEnabled)
    }

    private func openEditor(appearance: String, refresh: Bool = false, failure: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--profile-editor-review", "-kicklab.welcome.completed", "YES", "-kicklab.appearance", appearance, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if refresh { app.launchArguments.append("--profile-refresh-review") }
        if failure { app.launchArguments.append("--profile-save-failure") }
        app.launch()
        XCTAssertTrue(app.buttons["home-profile"].waitForExistence(timeout: 15))
        app.buttons["home-profile"].tap()
        XCTAssertTrue(app.buttons["profile-edit-name"].waitForExistence(timeout: 5))
        app.buttons["profile-edit-name"].tap()
        XCTAssertTrue(app.textFields["profile-name-field"].waitForExistence(timeout: 5))
        return app
    }

    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        // Select the whole draft rather than assuming where a tap placed the caret.
        field.press(forDuration: 1.1)
        let selectAll = XCUIApplication().descendants(matching: .any).matching(identifier: "Select All").firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 3), XCUIApplication().debugDescription)
        selectAll.tap()
        field.typeText(text + "\n")
        XCTAssertEqual(field.value as? String, text)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
