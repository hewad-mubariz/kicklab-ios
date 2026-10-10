import Foundation

/// Owned by the capture queue. At most one frame runs and one newer frame waits.
/// Completed work must call finish() on that same queue. Capture never waits.
nonisolated struct LiveAnalysisBuffer<Frame> {
    private(set) var isRunning = false
    private(set) var pending: Frame?
    private var lastOfferedTime: Double?
    private(set) var throttled = 0
    private(set) var replaced = 0
    private(set) var offered = 0
    let framesPerSecond: Double

    init(framesPerSecond: Double = 30) {
        precondition(framesPerSecond > 0)
        self.framesPerSecond = framesPerSecond
    }

    mutating func offer(_ frame: Frame, at time: Double) -> Frame? {
        guard time.isFinite else { return nil }
        // Allow timestamp rounding, without accidentally selecting every third
        // frame of a 59.94 fps stream instead of every second frame.
        if let last = lastOfferedTime, time - last < 1 / framesPerSecond - 0.0005 {
            throttled += 1
            return nil
        }
        lastOfferedTime = time
        offered += 1
        if isRunning {
            if pending != nil { replaced += 1 }
            pending = frame
            return nil
        }
        isRunning = true
        return frame
    }

    mutating func finish() -> Frame? {
        let next = pending
        pending = nil
        isRunning = next != nil
        return next
    }

    mutating func cancelPending() { pending = nil }
}
