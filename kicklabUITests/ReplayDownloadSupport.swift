import XCTest

extension XCUIApplication {
    /// Taps the editor's download button, allows adding to Photos if iOS asks, and waits
    /// until the download has started (the button stops saying "Download").
    @MainActor @discardableResult
    func startReplayDownload(timeout: TimeInterval = 10) -> Bool {
        let download = buttons["replay-export"]
        guard download.waitForExistence(timeout: timeout) else { return false }
        download.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["Allow", "Allow Full Access", "OK"] {
            let button = springboard.alerts.buttons[title]
            if button.waitForExistence(timeout: title == "Allow" ? 3 : 0.5) { button.tap(); break }
        }
        let started = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != 'Download'"), object: download)
        return XCTWaiter.wait(for: [started], timeout: timeout) == .completed
    }

    /// Waits for the replay to be in Photos: the share panel with its next steps appears.
    @MainActor
    func waitForReplaySaved(timeout: TimeInterval) -> Bool {
        otherElements["replay-share-panel"].waitForExistence(timeout: timeout)
            || buttons["replay-record-another"].waitForExistence(timeout: 1)
    }
}
