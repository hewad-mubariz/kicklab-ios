import XCTest

/// Temporary: the Camera tool as it is today, on a real shot.
final class ShotCameraLookTemp: XCTestCase {
    @MainActor
    func testLook() {
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "shot-effects",
                               "--shot-video", "/Volumes/My Passport/input/new_postive_inputs_3_oct/power_shot_2.MOV",
                               "--shot-track-cache", "/private/tmp/claude-501/-Users-hewadmubariz-Desktop-projects-kicklab/62b7eb1e-700e-4586-b5a7-08c9bfcef011/scratchpad/shot/tracks/shot2.plist", "--shot-style", "fireTrail"]
        app.launch()
        let customize = app.buttons["shot-effects-customize"]
        XCTAssertTrue(customize.waitForExistence(timeout: 60))
        Thread.sleep(forTimeInterval: 2)
        for _ in 0..<3 where !app.buttons["shot-tool-camera"].exists {
            if app.buttons["shot-tools-back"].exists { app.buttons["shot-tools-back"].tap() } else { customize.tap() }
            _ = app.buttons["shot-tool-camera"].waitForExistence(timeout: 5)
        }
        Thread.sleep(forTimeInterval: 1)
        attach(app, "1 tools")
        app.buttons["shot-tool-camera"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        attach(app, "2 camera page")
        app.buttons["shot-camera-frames"].tap()
        Thread.sleep(forTimeInterval: 3)
        attach(app, "3 frame steps")
        app.buttons["shot-camera-follow"].tap()
        Thread.sleep(forTimeInterval: 3)
        attach(app, "4 follow")
        app.buttons["shot-camera-frames"].tap()
        Thread.sleep(forTimeInterval: 2)
        app.buttons["shot-close-tools"].tap()
        Thread.sleep(forTimeInterval: 2)
        attach(app, "5 frames in replay")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
