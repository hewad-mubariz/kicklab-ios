import XCTest

/// A newer App Store version shows a banner on the home screen; Not now hides it for that version.
final class AppUpdateNoticeUITests: XCTestCase {
    @MainActor
    func testUpdateBannerShowsOnHomeAndDismisses() {
        let app = XCUIApplication()
        app.launchArguments = ["-kicklab.welcome.completed", "YES", "--app-update-preview"]
        app.launch()
        let banner = app.descendants(matching: .any)["app-update-banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Juggle Dude 1.3.0 is here"].exists)
        XCTAssertTrue(app.buttons["app-update-open"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Update banner"; shot.lifetime = .keepAlways; add(shot)
        if let folder = ProcessInfo.processInfo.environment["BALL_PAGE_SHOTS"], !folder.isEmpty {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("update-banner.png"))
        }
        app.buttons["app-update-dismiss"].tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 3))
    }
}
