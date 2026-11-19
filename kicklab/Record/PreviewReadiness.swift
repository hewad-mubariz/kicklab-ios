import Foundation

/// Only foreground time before the first completed video frame can time out.
nonisolated struct PreviewReadiness {
    private var lastTime: TimeInterval?
    private var wasActive = false
    private var waiting: TimeInterval = 0
    private(set) var ready = false
    var timeout: TimeInterval = 10

    mutating func presented() { ready = true }

    /// iOS can suspend the polling task before it observes an inactive sample.
    mutating func suspend() { lastTime = nil; wasActive = false }

    mutating func timedOut(now: TimeInterval, active: Bool) -> Bool {
        defer { lastTime = now; wasActive = active }
        guard !ready else { return false }
        if active, wasActive, let lastTime { waiting += max(0, now - lastTime) }
        return waiting >= timeout
    }
}
