import Foundation

// Diagnostic admission limits. Rechecks measure a real retained exposure and
// never supply another recheck's identity hint or rewrite trajectory inputs.
nonisolated struct ContactRecheckPolicy {
    let maximumHintAge = 0.100
    let maximumRetainedAge = 0.500
    let maximumRetainedFrames = 8
    let maximumStartLatency = 0.750
    let maximumResultLatency = 0.950
    let minimumInterval = 0.300

    func permits(source: Double, before: Double, after: Double, arrived: Double,
                 now: Double, due: Double, lastSource: Double, lastWall: Double) -> Bool {
        guard [source,before,after,arrived,now,due].allSatisfy(\.isFinite),
              before < source, source < after, after <= arrived,
              source-before <= maximumHintAge+0.000001,
              after-source <= maximumHintAge+0.000001,
              arrived-source <= maximumRetainedAge+0.000001,
              now >= due, now-due <= maximumStartLatency,
              source-lastSource >= minimumInterval-0.000001,
              now-lastWall >= minimumInterval-0.000001 else { return false }
        return true
    }
    func acceptsResult(now: Double, due: Double) -> Bool {
        now.isFinite && due.isFinite && now >= due && now-due <= maximumResultLatency
    }
}
