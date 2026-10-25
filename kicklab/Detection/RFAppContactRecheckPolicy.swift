import Foundation

// Diagnostic admission limits. Rechecks measure a real retained exposure and
// never supply another recheck's identity hint or rewrite trajectory inputs.
nonisolated struct ContactRecheckPolicy {
    // Four 30 Hz exposures, including sub-millisecond capture jitter. A short
    // impact occlusion must not discard the image that the contact verifier
    // can still bracket. Both identity checks and the retained-age cap remain.
    let maximumHintAge = 0.134
    let maximumRetainedAge = 0.500
    let maximumRetainedFrames = 8
    let maximumStartLatency = 0.750
    let maximumResultLatency = 0.950
    let minimumInterval = 0.300

    /// A single admitted window can measure its center plus two neighbors.
    /// Every image must retain independent original detections on both sides.
    /// Prefer the closest missing exposures; a smoothed reversal can precede
    /// or follow the actual impact. Never use a repaired view as an identity hint.
    func impactWindow(contactMs: Int, missing: [ContactFrameWindow.Stamp],
                      observed: [ContactFrameWindow.Stamp]) -> [Int] {
        let eligible = missing.filter { frame in
            guard abs(frame.timestampMs-contactMs) <= 67,
                  let before = observed.filter({ $0.timestampMs < frame.timestampMs }).max(by: { $0.timestampMs < $1.timestampMs }),
                  let after = observed.filter({ $0.timestampMs > frame.timestampMs }).min(by: { $0.timestampMs < $1.timestampMs }) else { return false }
            return frame.timestampMs-before.timestampMs <= 134 && after.timestampMs-frame.timestampMs <= 134
        }
        return Array(eligible.sorted {
            let a = abs($0.timestampMs-contactMs), b = abs($1.timestampMs-contactMs)
            return a == b ? $0.timestampMs > $1.timestampMs : a < b
        }.prefix(3).map(\.index))
    }

    func permitsImpactWindow(source: Double, now: Double, lastSource: Double, lastWall: Double) -> Bool {
        source.isFinite && now.isFinite && source-lastSource >= minimumInterval-0.000001
            && now-lastWall >= minimumInterval-0.000001
    }

    /// Repair a real missing impact neighbor only when that side has no close
    /// observation. Identity must be independently observed before AND after.
    func neighbor(contactMs: Int, missing: [ContactFrameWindow.Stamp], observed: [ContactFrameWindow.Stamp]) -> Int? {
        let candidates = missing.filter { frame in
            let delta = frame.timestampMs-contactMs
            guard delta != 0, abs(delta) <= 100,
                  !observed.contains(where: {
                      let dt = $0.timestampMs-contactMs
                      return delta < 0 ? (-67 ... -1).contains(dt) : (1...67).contains(dt)
                  }),
                  let before = observed.filter({ $0.timestampMs < frame.timestampMs }).max(by: { $0.timestampMs < $1.timestampMs }),
                  let after = observed.filter({ $0.timestampMs > frame.timestampMs }).min(by: { $0.timestampMs < $1.timestampMs }) else { return false }
            return frame.timestampMs-before.timestampMs <= 134 && after.timestampMs-frame.timestampMs <= 134
        }
        return candidates.min {
            let a = abs(abs($0.timestampMs-contactMs)-50), b = abs(abs($1.timestampMs-contactMs)-50)
            return a == b ? $0.timestampMs < $1.timestampMs : a < b
        }?.index
    }

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

/// One bounded detector retry before the trajectory consumes a lost frame.
/// This measures the current image; it cannot manufacture a kick or bypass gates.
nonisolated struct ImpactGapRecoveryPolicy {
    func permits(source: Double, hintTime: Double, now: Double, due: Double,
                 lastSource: Double, lastWall: Double, outstanding: Int, budget: Double) -> Bool {
        [source,hintTime,now,due].allSatisfy(\.isFinite)
            && source > hintTime && source-hintTime <= 0.101
            && source-lastSource >= 0.3 && now-lastWall >= 0.3
            && ContactBacklogPolicy().permits(outstanding: outstanding, currentFrameLag: now-due, rfBudget: budget)
    }
    func accepts(score: Double, completed: Double, due: Double) -> Bool {
        score.isFinite && score >= 0.7 && completed.isFinite && due.isFinite
            && completed >= due && completed-due <= 0.4
    }
}
