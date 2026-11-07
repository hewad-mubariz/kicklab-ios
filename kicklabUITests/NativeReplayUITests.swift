import XCTest

final class NativeReplayUITests: XCTestCase {
    @MainActor
    func testOriginalHDRReplayAndEffectAccess() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("artifacts/release120/native-replay-hdr.mov").path
        guard FileManager.default.fileExists(atPath: fixture) else {
            throw XCTSkip("Requires the two-second HDR review extract")
        }
        #else
        let fixture = "documents:native-replay-hdr.mov"
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "capture-flow", "--session-video", fixture]
        app.launch()
        let original = app.descendants(matching: .any)["original-replay-surface"].firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Ready'"), object: original)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        attach(app, "Original HDR replay without effect preparation")
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-effects"].tap()
        // Free access must keep the native replay and never prepare a proxy.
        // The unrestricted debug build exercises the paid transition below.
        if app.buttons["pro-close"].waitForExistence(timeout: 3) {
            app.buttons["pro-close"].tap()
            XCTAssertTrue(original.waitForExistence(timeout: 5))
            XCTAssertFalse(app.descendants(matching: .any)["effects-replay-surface"].firstMatch.exists)
            app.buttons["replay-close-tools"].tap()
            attach(app, "Free HDR replay remains native after dismissing Pro")
            return
        }
        XCTAssertTrue(app.buttons["effect-picker-none"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["effect-picker-none"].isSelected)
        app.buttons["effect-picker-fire"].tap()
        let effects = app.descendants(matching: .any)["effects-replay-surface"].firstMatch
        XCTAssertTrue(effects.waitForExistence(timeout: 90), "Only selecting an effect should prepare the HDR editing copy")
        XCTAssertFalse(original.exists)
        attach(app, "Selected effect on the HDR editing preview")
        app.buttons["effect-picker-none"].tap()
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Ready'"), object: original)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
        XCTAssertFalse(effects.exists)
        app.buttons["replay-close-tools"].tap()
        attach(app, "Original HDR replay restored after removing the effect")
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
