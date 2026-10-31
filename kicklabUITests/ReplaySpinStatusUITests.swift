import XCTest

final class ReplaySpinStatusUITests: ProReplayUITestCase {
    @MainActor
    func testReplacementSpinStatusSurvivesSeekingAndReopening() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Local simulator video fixture")
        #endif
        continueAfterFailure=false
        let fixture=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kicklabTests/Fixtures/juggling-eighteen.mov").path
        let app=XCUIApplication()
        app.launchArguments=["--session-design","capture-flow","--session-video",fixture,"--spin-readout"]
        app.launch()
        XCTAssertTrue(app.buttons["replay-customize"].waitForExistence(timeout:20))
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-ball"].tap()
        app.buttons["ball-picker-gold"].tap()
        let status=app.staticTexts["replay-spin-status"]
        XCTAssertTrue(status.waitForExistence(timeout:10))
        XCTAssertTrue(["Preparing source spin…","Spin uncertain","Little visible spin","Ball not tracked","Source spin"].contains(status.label))
        app.buttons["replay-close-tools"].tap()
        let slider=app.sliders["Video position"]
        slider.adjust(toNormalizedSliderPosition:0.25)
        app.buttons["replay-play"].tap()
        app.buttons["replay-play"].tap()
        XCTAssertTrue(status.exists)
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-ball"].tap()
        app.buttons["ball-picker-original"].tap()
        // The existing ball picker deliberately commits its selection after
        // its 1.15 s animation. Check the resulting state rather than the tap.
        let hidden=XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:status)
        XCTAssertEqual(XCTWaiter.wait(for:[hidden],timeout:5),.completed)
        app.buttons["ball-picker-gold"].tap()
        XCTAssertTrue(status.waitForExistence(timeout:10))
        let screenshot=XCTAttachment(screenshot:app.screenshot())
        screenshot.name="Replacement spin status after seeking and reopening"
        screenshot.lifetime = .keepAlways;add(screenshot)
    }

    /// Players only see a wait for the ball or a retry, never the spin readout frame by frame.
    @MainActor
    func testPlayersNeverSeeTheSpinReadout() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Local simulator video fixture")
        #endif
        continueAfterFailure=false
        let fixture=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kicklabTests/Fixtures/juggling-eighteen.mov").path
        let app=XCUIApplication()
        app.launchArguments=["--session-design","capture-flow","--session-video",fixture]
        app.launch()
        XCTAssertTrue(app.buttons["replay-customize"].waitForExistence(timeout:20))
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-ball"].tap()
        app.buttons["ball-picker-gold"].tap()
        app.buttons["replay-close-tools"].tap()
        app.buttons["replay-play"].tap()
        let status=app.staticTexts["replay-spin-status"]
        let readout=["Preparing source spin…","Spin uncertain","Little visible spin","Ball not tracked","Source spin","Effects ready"]
        for _ in 0..<12 {
            if status.exists { XCTAssertFalse(readout.contains(status.label), status.label) }
            XCTAssertFalse(app.staticTexts["replay-effects-status"].exists && app.staticTexts["replay-effects-status"].label == "Effects ready")
            Thread.sleep(forTimeInterval:0.5)
        }
    }
}
