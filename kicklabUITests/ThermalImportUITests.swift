import XCTest

/// Requires the locally staged thermal-background.json and its source video.
/// Exercises a real app background/foreground transition during model work.
final class ThermalImportUITests: XCTestCase {
    @MainActor
    func testImportResumesAfterBackgrounding() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--thermal-review", "documents:thermal-background.json", "--analysis-ignore-cache"]
        app.launch()
        XCTAssertTrue(app.staticTexts["RUNNING 0-touch18"].waitForExistence(timeout: 15))
        let progress = app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' frames · '")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        let started = NSPredicate { _, _ in
            let count = Int(progress.label.components(separatedBy: " ").first ?? "0") ?? 0
            return count >= 15
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: started, object: nil)], timeout: 15), .completed)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        XCTAssertTrue(app.staticTexts["COMPLETE"].waitForExistence(timeout: 120),
                      "The original import must resume rather than stall or restart")
    }
}
