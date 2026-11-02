import XCTest

/// A clip above 60 fps: Download splits into the faster and original choices, a tap away folds them
/// back, and picking one starts the download in the same button.
final class DownloadChoiceUITests: ProReplayUITestCase {
    /// Keeps a screenshot in the result and, when DOWNLOAD_CHOICE_SHOTS names a folder, as a PNG there.
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let folder = ProcessInfo.processInfo.environment["DOWNLOAD_CHOICE_SHOTS"], !folder.isEmpty {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }

    @MainActor
    func testFastClipDownloadSplitsIntoTwoChoices() {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kicklabTests/Fixtures/capture-sixty-as-120.mov").path
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "capture-flow", "--session-video", fixture]
        app.launch()
        XCTAssertTrue(app.buttons["replay-customize"].waitForExistence(timeout: 20))
        app.buttons["replay-customize"].tap()

        let download = app.buttons["replay-export"]
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        download.tap()
        let faster = app.buttons["replay-save-faster"], original = app.buttons["replay-save-original"]
        XCTAssertTrue(faster.waitForExistence(timeout: 5))
        XCTAssertTrue(original.exists)
        XCTAssertTrue(faster.label.contains("720p · 60 fps"), faster.label)
        XCTAssertTrue(original.label.contains("720p · 120 fps"), original.label)
        Thread.sleep(forTimeInterval: 0.8)
        capture(app, "download-choices")

        XCTAssertFalse(app.buttons["replay-save-cancel"].exists, "No close button: a tap away dismisses")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(faster.waitForNonExistence(timeout: 3))
        XCTAssertFalse(original.exists)
        XCTAssertTrue(download.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.6)

        download.tap()
        XCTAssertTrue(faster.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.6)
        faster.tap()
        // The saved toast shows for a few seconds and names what was saved, not a fixed 1080p. Watch
        // for it while allowing Photos access if iOS asks; a short clip saves within a second or two.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let saved = app.buttons["replay-saved-toast"]
        var savedLabel: String?
        let deadline = Date().addingTimeInterval(30)
        while savedLabel == nil, Date() < deadline {
            if saved.exists { savedLabel = saved.label; break }
            for title in ["Allow", "Allow Full Access", "OK"] where springboard.alerts.buttons[title].exists {
                springboard.alerts.buttons[title].tap()
            }
        }
        XCTAssertTrue(savedLabel?.contains("720p · 60 fps") == true, savedLabel ?? "no saved toast")
        XCTAssertEqual(app.buttons["replay-export"].label, "Saved to Photos. Share")
        capture(app, "download-saved")
    }
}
