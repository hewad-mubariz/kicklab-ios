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
    private(set) var framesPerSecond: Double

    init(framesPerSecond: Double = 30) {
        precondition(framesPerSecond.isFinite && framesPerSecond > 0)
        self.framesPerSecond = framesPerSecond
    }

    mutating func setFramesPerSecond(_ value: Double) {
        precondition(value.isFinite && value > 0)
        framesPerSecond = value
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

/// Only schedules inference. Recording and all counter timestamps keep their
/// original capture clock. Missing a ball while a player is present is active.
nonisolated struct LiveAnalysisCadence {
    private var emptySince: Double?
    private var coolerSince: Double?
    private var coolingTarget: Double?
    private(set) var thermalFPS = 30.0
    private(set) var isIdle = false
    var framesPerSecond: Double { isIdle ? min(5, thermalFPS) : thermalFPS }

    mutating func observe(time: Double, hasBall: Bool, hasPerson: Bool,
                          thermal: ProcessInfo.ThermalState) {
        guard time.isFinite else { return }
        let target: Double
        switch thermal {
        case .nominal: target = 30
        case .fair: target = 20
        case .serious: target = 15
        case .critical: target = 10
        @unknown default: target = 15
        }
        if target <= thermalFPS {
            thermalFPS = target
            coolerSince = nil; coolingTarget = nil
        } else {
            if coolingTarget != target { coolerSince = time; coolingTarget = target }
            if let since = coolerSince, time - since >= 10 {
                thermalFPS = target
                coolerSince = nil; coolingTarget = nil
            }
        }
        if hasBall || hasPerson {
            emptySince = nil
            isIdle = false
        } else {
            if emptySince == nil { emptySince = time }
            isIdle = time - (emptySince ?? time) >= 2
        }
    }
}
