import Foundation

/// Positive evidence that separates leaderboard runs. It never changes which
/// juggling contacts the counter accepts, or the session's total.
nonisolated struct StreakInterruption: Codable, Equatable, Sendable {
    static let signature = "|streak-interruptions-v1"
    enum Kind: String, Codable, Sendable { case heldBall, groundContact }
    let timestampMs: Int
    let kind: Kind
    var handling: BallHandlingEvidence? = nil
    var ground: GroundContactEvidence? = nil

    var reviewReason: ContactReviewReason { kind == .heldBall ? .heldBall : .groundContact }

    static func held(_ evidence: BallHandlingEvidence, after lastTouchMs: Int) -> Self? {
        guard evidence.contactMs > lastTouchMs, evidence.observedImpactMs == nil,
              evidence.samples.allSatisfy({ $0.timestampMs > lastTouchMs }),
              evidence.state == .held else { return nil }
        return .init(timestampMs: evidence.contactMs, kind: .heldBall, handling: evidence)
    }

    static func floor(_ decision: CounterDecision, evidence: GroundContactEvidence,
                      policy: GroundContactPolicy, cadenceAware: Bool) -> Self? {
        // A rejected low candidate alone is not proof: ask for the same
        // sustained floor evidence used by the counting rules. No new veto.
        guard decision.rejection == .groundBounce, decision.footConfirmed != true,
              evidence.contactMs == decision.timestampMs else { return nil }
        let floorReached = decision.ground.map { floor in
            decision.observedBallBottom.map { $0 >= floor } ?? false
        } ?? false
        guard evidence.confirmsGroundContact(corroboratingWeakAnkles: policy == .corroboratedFeet,
                                             cadenceAware: cadenceAware)
            || (floorReached && evidence.confirmsBallBesideFeet) else { return nil }
        return .init(timestampMs: decision.timestampMs, kind: .groundContact, ground: evidence)
    }
}

/// The pose check can't tell a low toe tap from a floor bounce, because the ankle
/// barely moves in either. The next touch shows which it was: a real bounce breaks
/// the juggling, a toe tap doesn't. Applies to streaks only, so the count never changes.
nonisolated struct StreakGroundCalls {
    /// In one session 41 wrong calls all fell at most 1.75 ball heights, with touches
    /// within 1.17 s either side. Real floor bounces broke the rhythm or fell further.
    static let maximumFallBallHeights = 2.0
    static let rhythmMS = 1_200
    /// Kick, bounce, kick, bounce is not low juggling, however low the ball stays.
    static let bouncingRun = 3

    struct Call {
        let frameIndex: Int
        let timestampMs: Int
        let time: Double
        let fallBallHeights: Double?
        let previousTouchMs: Int?
    }
    private var calls: [Call] = []
    private var touchesAfterCalls = 0

    mutating func add(_ call: Call) { calls.append(call) }

    /// The calls this touch overrules. `sameContact`: counted one frame after being
    /// called the floor, which is one contact and gets one answer.
    mutating func touch(frameIndex: Int, timestampMs: Int) -> [(time: Double, sameContact: Bool)] {
        defer { calls = [] }
        let earlier = calls.filter { frameIndex-$0.frameIndex > 1 }
        touchesAfterCalls = earlier.isEmpty ? 0 : touchesAfterCalls+1
        return calls.compactMap { call in
            if frameIndex-call.frameIndex <= 1 { return (call.time, true) }
            guard touchesAfterCalls < Self.bouncingRun,
                  let fall = call.fallBallHeights, fall <= Self.maximumFallBallHeights,
                  let previous = call.previousTouchMs, call.timestampMs-previous <= Self.rhythmMS,
                  timestampMs-call.timestampMs <= Self.rhythmMS else { return nil }
            return (call.time, false)
        }
    }
}

/// Check between contacts at most four times per second, only while there is
/// an unfinished run. One proven interruption suffices until a new touch.
/// Missing observations and elapsed time never constitute an interruption.
nonisolated struct StreakInterruptionSchedule {
    private var endedAt: Int?
    private var probedAt: Int?

    func hasOpenRun(lastTouchMs: Int?) -> Bool {
        guard let lastTouchMs else { return false }
        return endedAt.map { lastTouchMs > $0 } ?? true
    }
    mutating func end(at timestampMs: Int) { endedAt = max(endedAt ?? timestampMs, timestampMs) }
    mutating func shouldProbe(now: Int, lastTouchMs: Int?, hasBall: Bool) -> Bool {
        guard hasBall, hasOpenRun(lastTouchMs: lastTouchMs), let lastTouchMs,
              now-lastTouchMs >= 200 else { return false }
        if let probedAt, now >= probedAt, now-probedAt < 250 { return false }
        self.probedAt = now
        return true
    }
}
