import XCTest

/// Manual physical-device checks using known videos already in Photos.
final class ImportFlowUITests: XCTestCase {
    @MainActor func testIPhone11FullHDRImport() throws { try runImport(label: "Video, fifty-two seconds, 31. October, 16:43", name: "free-hdr52", pro: false) }
    @MainActor func testIPhone11ProImport() throws { try runImport(label: "Video, nineteen seconds, 07. November, 18:14", name: "pro-indoor19", pro: true) }
    @MainActor func testFreeRecentOriginalImport() throws { try runImport(label: "Video, thirty-nine seconds, 07. November, 18:28", name: "free-original", pro: false) }
    @MainActor func testProRecentOriginalImport() throws { try runImport(label: "Video, thirty-nine seconds, 07. November, 18:28", name: "pro-original", pro: true) }
    @MainActor func testFreeSDRImport() throws { try runImport(label: "Video, thirteen seconds, 06. November, 11:56", name: "free-sdr", pro: false) }
    @MainActor func testProSDRImport() throws { try runImport(label: "Video, thirteen seconds, 06. November, 11:56", name: "pro-sdr", pro: true) }

    @MainActor private func runImport(label: String, name: String, pro: Bool) throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the dedicated preview on a physical phone with the documented Photos fixtures")
        #endif
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--history-review", "empty", "--import-flow-audit", name,
            "--analysis-ignore-cache", "-kicklab.welcome.completed", "YES",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-debug.overlaysVisible", "NO"]
        if pro { app.launchArguments.append("--import-flow-pro") }
        app.launch()
        XCTAssertTrue(app.buttons["home-import-video"].waitForExistence(timeout: 20))
        app.buttons["home-import-video"].tap()
        let video = app.images.matching(NSPredicate(format: "label == %@", label)).firstMatch
        guard video.waitForExistence(timeout: 10) else { throw XCTSkip("Required juggling fixture is not visible in this Photos library") }
        if !video.isHittable {
            app.scrollViews["photosView_content_scroll_view"].swipeUp()
            // Photos virtualizes its image cells while decelerating. A tap
            // during that scroll can be swallowed instead of selecting media.
            Thread.sleep(forTimeInterval: 2)
        }
        let start = ProcessInfo.processInfo.systemUptime
        video.tap()
        Thread.sleep(forTimeInterval: 3)
        let handoff = XCTAttachment(string: app.debugDescription)
        handoff.name = name + " after selection"; handoff.lifetime = .keepAlways; add(handoff)
        let selectionShot = XCTAttachment(screenshot: app.screenshot())
        selectionShot.name = name + " after selection"; selectionShot.lifetime = .keepAlways; add(selectionShot)
        let original = app.descendants(matching: .any)["original-replay-surface"].firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 420), app.debugDescription)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Ready'"), object: original)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        XCTAssertFalse(app.descendants(matching: .any)["effects-replay-surface"].firstMatch.exists)
        let timing = XCTAttachment(string: "Photos tile: \(label)\nTap to observed ready: \(ProcessInfo.processInfo.systemUptime - start)s\nPro fixture: \(pro)")
        timing.name = name + " timing"; timing.lifetime = .keepAlways; add(timing)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name + " replay"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-effects"].tap()
        if pro {
            XCTAssertTrue(app.buttons["effect-picker-none"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["effect-picker-none"].isSelected)
        } else {
            XCTAssertTrue(app.buttons["pro-close"].waitForExistence(timeout: 10))
            app.buttons["pro-close"].tap()
        }
        XCTAssertTrue(original.exists)
    }

}
