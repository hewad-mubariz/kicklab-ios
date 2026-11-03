import XCTest

extension XCUIElement {
    /// A tray's controls exist before its spring has finished moving them.
    /// Wait for stable hit-test geometry so XCTest taps the intended card.
    @MainActor
    func waitForStableFrame(timeout: TimeInterval = 5) -> Bool {
        var previous: CGRect?
        var unchangedSince = Date()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard self.exists, self.isHittable else {
                previous = nil
                return false
            }
            let current = self.frame
            guard !current.isEmpty else { return false }
            guard current == previous else {
                previous = current
                unchangedSince = Date()
                return false
            }
            return Date().timeIntervalSince(unchangedSince) >= 0.35
        }, object: self)
        return XCTWaiter.wait(for: [ready], timeout: timeout) == .completed
    }
}
