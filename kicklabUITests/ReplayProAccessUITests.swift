import XCTest
import StoreKitTest

@MainActor
final class ReplayProAccessUITests: XCTestCase {
    private var store: SKTestSession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        store = try SKTestSession(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "JuggleDude", withExtension: "storekit")))
        store.resetToDefaultState()
        store.clearTransactions()
        store.disableDialogs = true
        store.timeRate = .realTime
    }

    override func tearDownWithError() throws {
        store.clearTransactions()
        store.resetToDefaultState()
    }

    func testFreeJugglingBlocksEveryPaidToolBeforeItChangesTheVideo() {
        let app = juggling()
        XCTAssertTrue(app.descendants(matching: .any)["capture-elapsed-time"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["replay-select-counter"].exists)
        XCTAssertFalse(app.otherElements["capture-motion-graph"].exists)
        app.buttons["replay-customize"].tap()
        XCTAssertFalse(app.buttons["replay-tool-timer"].label.contains("Pro"))
        app.buttons["replay-tool-timer"].tap()
        XCTAssertTrue(app.buttons["replay-tools-back"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["pro-close"].exists)
        app.buttons["replay-tools-back"].tap()

        for tool in ["counter", "ball", "effects", "graph"] {
            XCTAssertTrue(app.buttons["replay-tool-\(tool)"].label.contains("Pro"))
            app.buttons["replay-tool-\(tool)"].tap()
            XCTAssertTrue(app.buttons["pro-close"].waitForExistence(timeout: 5))
            app.buttons["pro-close"].tap()
            XCTAssertTrue(app.buttons["replay-tool-\(tool)"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["replay-tools-back"].exists, "Locked tool must never open")
            XCTAssertFalse(app.buttons["counter-style-jelly"].exists)
            XCTAssertFalse(app.buttons["replay-select-counter"].exists)
            XCTAssertFalse(app.otherElements["capture-motion-graph"].exists)
        }
        app.buttons["replay-close-tools"].tap()
        XCTAssertTrue(app.buttons["replay-export"].isEnabled)
        XCTAssertTrue(app.descendants(matching: .any)["capture-elapsed-time"].firstMatch.exists)
        attach(app, "Free replay unchanged after cancelling each paid tool")
    }

    func testJugglingPurchaseOpensRequestedToolWithoutBadgesAndExpiryReturnsToFree() throws {
        let app = juggling()
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-graph"].tap()
        buy(app)
        XCTAssertTrue(app.buttons["motion-style-comet"].waitForExistence(timeout: 8))
        assertNoProBadges(app)
        app.buttons["motion-style-comet"].tap()
        app.buttons["replay-close-tools"].tap()
        let graph = app.descendants(matching: .any)["capture-motion-graph"].firstMatch
        XCTAssertTrue(graph.waitForExistence(timeout: 5))
        XCTAssertEqual(graph.value as? String, "comet")

        app.buttons["replay-customize"].tap()
        for tool in ["counter", "ball", "effects", "graph"] {
            XCTAssertFalse(app.buttons["replay-tool-\(tool)"].label.contains("Pro"))
            app.buttons["replay-tool-\(tool)"].tap()
            XCTAssertTrue(app.buttons["replay-tools-back"].waitForExistence(timeout: 5))
            assertNoProBadges(app)
            XCTAssertFalse(app.buttons["pro-close"].exists)
            if tool == "counter" { app.buttons["counter-style-jelly"].tap() }
            app.buttons["replay-tools-back"].tap()
        }
        attach(app, "Pro tools without premium badges")
        try store.expireSubscription(productIdentifier: "com.hewad.juggledude.pro.monthly")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["replay-customize"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["replay-select-counter"].exists)
        XCTAssertFalse(graph.exists)
        app.buttons["replay-customize"].tap()
        app.buttons["replay-tool-counter"].tap()
        XCTAssertTrue(app.buttons["pro-close"].waitForExistence(timeout: 5))
    }

    func testFreeShotBlocksPremiumPicksAndCancellationKeepsThePreviousFreeLook() {
        let app = shot()
        app.buttons["shot-effects-customize"].tap()
        app.buttons["shot-tool-effects"].tap()
        XCTAssertTrue(app.buttons["shot-effect-glowTrail"].isSelected)
        // Test both free choices, including keeping None rather than forcing the default back.
        for freeStyle in ["none", "glowTrail"] {
            app.buttons["shot-effect-\(freeStyle)"].tap()
            XCTAssertFalse(app.buttons["pro-close"].exists)
            app.buttons["shot-effect-blueJet"].tap()
            XCTAssertTrue(app.buttons["pro-close"].waitForExistence(timeout: 5))
            app.buttons["pro-close"].tap()
            XCTAssertTrue(app.buttons["shot-effect-\(freeStyle)"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["shot-effect-\(freeStyle)"].isSelected)
            XCTAssertFalse(app.buttons["shot-effect-blueJet"].isSelected)
        }
        attach(app, "Paid trail cancelled without changing the free selection")
        app.buttons["shot-tools-back"].tap()
        for tool in ["graph", "camera"] {
            XCTAssertTrue(app.buttons["shot-tool-\(tool)"].label.contains("Pro"))
            app.buttons["shot-tool-\(tool)"].tap()
            XCTAssertTrue(app.buttons["pro-close"].waitForExistence(timeout: 5))
            app.buttons["pro-close"].tap()
            XCTAssertTrue(app.buttons["shot-tool-\(tool)"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["shot-tools-back"].exists)
            XCTAssertFalse(app.buttons["shot-camera-chooser"].exists)
        }
    }

    func testShotPurchaseAppliesRequestedTrailAndRemovesAllControlBadges() {
        let app = shot()
        app.buttons["shot-effects-customize"].tap()
        app.buttons["shot-tool-effects"].tap()
        app.buttons["shot-effect-blueJet"].tap()
        buy(app)
        XCTAssertTrue(app.buttons["shot-effect-blueJet"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["shot-effect-blueJet"].isSelected)
        assertNoProBadges(app)
        app.buttons["shot-tools-back"].tap()
        XCTAssertFalse(app.buttons["shot-tool-graph"].label.contains("Pro"))
        XCTAssertFalse(app.buttons["shot-tool-camera"].label.contains("Pro"))
        app.buttons["shot-tool-graph"].tap()
        XCTAssertTrue(app.buttons["shot-tools-back"].waitForExistence(timeout: 5))
        assertNoProBadges(app)
        app.buttons["shot-tools-back"].tap()
        app.buttons["shot-tool-camera"].tap()
        app.buttons["shot-camera-chooser"].tap()
        XCTAssertFalse(app.buttons["shot-camera-impact"].label.contains("PRO"))
        app.buttons["shot-camera-impact"].tap()
        assertNoProBadges(app)
        XCTAssertFalse(app.buttons["pro-close"].exists)
        app.buttons["shot-close-tools"].tap()
        XCTAssertTrue(app.buttons["shot-effects-save"].waitForExistence(timeout: 5))
        attach(app, "Pro shot with requested effect and camera")
    }

    private func assertNoProBadges(_ app: XCUIApplication) {
        XCTAssertFalse(app.descendants(matching: .any)["pro-style-badge"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Pro"].exists)
        XCTAssertFalse(app.staticTexts["PRO"].exists)
    }

    private func juggling() -> XCUIApplication {
        #if targetEnvironment(simulator)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kicklabTests/Fixtures/juggling-eighteen.mov").path
        #else
        let fixture = "documents:pro-access-juggling.mov"
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "motion-replay", "--session-video", fixture]
        app.launch()
        XCTAssertTrue(app.buttons["replay-customize"].waitForExistence(timeout: 20))
        return app
    }

    private func shot() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--session-design", "shot-pro-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["shot-effects-customize"].waitForExistence(timeout: 30))
        return app
    }

    private func buy(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["pro-plan-monthly"].waitForExistence(timeout: 5))
        app.buttons["pro-plan-monthly"].tap()
        let purchase = app.buttons["pro-purchase"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: purchase)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        purchase.tap()
        XCTAssertTrue(purchase.waitForNonExistence(timeout: 15))
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
