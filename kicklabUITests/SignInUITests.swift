import XCTest

final class SignInUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testWelcomeAndProfileSheetInBothAppearances() {
        for appearance in ["dark", "light"] {
            let app = XCUIApplication()
            app.launchArguments = ["-kicklab.appearance", appearance, "--reset-welcome"]
            XCUIDevice.shared.orientation = .portrait
            app.launch()
            let guest = app.buttons["signin-guest"]
            XCTAssertTrue(guest.waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["signin-google"].exists)
            for identifier in ["signin-apple", "signin-email", "signin-guest"] {
                reveal(app.buttons[identifier], in: app)
            }
            attach(app, "Welcome - \(appearance)")
            reveal(app.buttons["signin-email"], in: app)
            app.buttons["signin-email"].tap()
            let email = app.textFields["email-address"]
            XCTAssertTrue(email.waitForExistence(timeout: 3))
            XCTAssertFalse(app.buttons["email-send"].isEnabled)
            email.tap()
            email.typeText("not-an-email")
            XCTAssertFalse(app.buttons["email-send"].isEnabled)
            email.typeText("@example.com")
            XCTAssertTrue(app.buttons["email-send"].isEnabled)
            attach(app, "Email sign in - \(appearance)")
            app.buttons["email-close"].tap()
            reveal(guest, in: app)
            guest.tap()
            XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["module-power-shot"].label.contains("BALL DISTANCE"))
            attach(app, "Home - \(appearance)")
            app.buttons["home-profile"].tap()
            XCTAssertTrue(app.buttons["profile-sign-in"].waitForExistence(timeout: 5))
            app.buttons["profile-sign-in"].tap()
            // Sign-in opens on top of Profile and returns to it.
            XCTAssertTrue(app.buttons["signin-not-now"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["signin-google"].exists)
            for identifier in ["signin-apple", "signin-email"] {
                reveal(app.buttons[identifier], in: app)
            }
            XCTAssertFalse(app.buttons["profile-sign-in"].isHittable)
            attach(app, "Profile sign in - \(appearance)")
            app.buttons["signin-email"].tap()
            XCTAssertTrue(app.textFields["email-address"].waitForExistence(timeout: 3))
            app.buttons["email-close"].tap()
            for identifier in ["signin-terms", "signin-privacy"] {
                reveal(app.buttons[identifier], in: app)
                app.buttons[identifier].tap()
                let browser = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
                XCTAssertTrue(browser.wait(for: .runningForeground, timeout: 5))
                app.activate()
                XCTAssertTrue(app.buttons["signin-not-now"].waitForExistence(timeout: 5))
            }
            reveal(app.buttons["signin-not-now"], in: app)
            app.buttons["signin-not-now"].tap()
            XCTAssertTrue(app.buttons["profile-sign-in"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["signin-not-now"].exists)
            app.buttons["profile-close"].tap()
            XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    func testGuestChoicePersistsAndProfileFollowsAppearanceSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-welcome"]
        app.launch()
        XCTAssertTrue(app.buttons["signin-guest"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["signin-google"].exists)
        reveal(app.buttons["signin-email"], in: app)
        app.buttons["signin-email"].tap()
        XCTAssertTrue(app.textFields["email-address"].waitForExistence(timeout: 3))
        app.buttons["email-close"].tap()
        reveal(app.buttons["signin-guest"], in: app)
        app.buttons["signin-guest"].tap()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["signin-guest"].exists)
        for appearance in ["Light", "Dark", "System"] {
            app.buttons["home-profile"].tap()
            app.buttons["profile-settings"].tap()
            app.segmentedControls["appearance-picker"].buttons[appearance].tap()
            XCTAssertTrue(app.segmentedControls["appearance-picker"].buttons[appearance].isSelected)
            app.navigationBars["Settings"].buttons.element(boundBy: 0).tap()
            app.buttons["profile-sign-in"].tap()
            XCTAssertTrue(app.buttons["signin-apple"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.buttons["signin-google"].exists)
            for identifier in ["signin-apple", "signin-email", "signin-not-now"] {
                reveal(app.buttons[identifier], in: app)
            }
            attach(app, "Sign in appearance switched - \(appearance)")
            app.buttons["signin-not-now"].tap()
            XCTAssertTrue(app.buttons["profile-sign-in"].waitForExistence(timeout: 5))
            app.buttons["profile-close"].tap()
            XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 5))
        }
        app.buttons["home-profile"].tap()
        app.buttons["profile-close"].tap()
        app.buttons["module-juggling"].tap()
        XCTAssertTrue(app.buttons["record-gallery-picker"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testLargeTextCanScrollToAllAccountActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-welcome", "-kicklab.appearance", "light",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["signin-guest"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["signin-google"].exists)
        for identifier in ["signin-apple", "signin-email", "signin-guest", "signin-privacy"] {
            reveal(app.buttons[identifier], in: app)
        }
        attach(app, "Welcome - accessibility text")
        reveal(app.buttons["signin-guest"], in: app)
        app.buttons["signin-guest"].tap()
        XCTAssertTrue(app.buttons["home-profile"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        for _ in 0..<6 where !element.isHittable { app.swipeDown() }
        XCTAssertTrue(element.isHittable, "\(element.identifier) must remain reachable", file: file, line: line)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
