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
            XCTAssertTrue(guest.isHittable)
            XCTAssertTrue(app.buttons["signin-apple"].isHittable)
            XCTAssertTrue(app.buttons["signin-google"].isHittable)
            XCTAssertTrue(app.buttons["signin-email"].isHittable)
            attach(app, "Welcome - \(appearance)")
            app.buttons["signin-email"].tap()
            XCTAssertTrue(app.textFields["email-address"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.buttons["email-send"].isEnabled)
            attach(app, "Email sign in - \(appearance)")
            app.buttons["email-close"].tap()
            guest.tap()
            XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 5))
            app.buttons["home-profile"].tap()
            XCTAssertTrue(app.buttons["profile-sign-in"].waitForExistence(timeout: 5))
            app.buttons["profile-sign-in"].tap()
            // Profile hands over to the same main sign-in view instead of stacking a sheet.
            XCTAssertTrue(app.buttons["signin-not-now"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["signin-apple"].isHittable)
            XCTAssertFalse(app.buttons["profile-sign-in"].exists)
            attach(app, "Profile sign in - \(appearance)")
            app.buttons["signin-email"].tap()
            XCTAssertTrue(app.textFields["email-address"].waitForExistence(timeout: 3))
            app.buttons["email-close"].tap()
            for identifier in ["signin-terms", "signin-privacy"] {
                app.buttons[identifier].tap()
                let browser = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
                XCTAssertTrue(browser.wait(for: .runningForeground, timeout: 5))
                app.activate()
                XCTAssertTrue(app.buttons["signin-not-now"].waitForExistence(timeout: 5))
            }
            app.buttons["signin-not-now"].tap()
            XCTAssertTrue(app.buttons["module-juggling"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["signin-not-now"].exists)
            app.terminate()
        }
    }

    @MainActor
    func testGuestChoicePersistsAndProfileFollowsAppearanceSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-welcome"]
        app.launch()
        XCTAssertTrue(app.buttons["signin-guest"].waitForExistence(timeout: 15))
        app.buttons["signin-email"].tap()
        XCTAssertTrue(app.textFields["email-address"].waitForExistence(timeout: 3))
        app.buttons["email-close"].tap()
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
            attach(app, "Sign in appearance switched - \(appearance)")
            app.buttons["signin-not-now"].tap()
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
        for identifier in ["signin-apple", "signin-google", "signin-email", "signin-guest", "signin-privacy"] {
            let button = app.buttons[identifier]
            for _ in 0..<6 where !button.isHittable { app.swipeUp() }
            XCTAssertTrue(button.isHittable, "\(identifier) must remain accessible at large text sizes")
        }
        attach(app, "Welcome - accessibility text")
        app.buttons["signin-guest"].tap()
        XCTAssertTrue(app.buttons["home-profile"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
