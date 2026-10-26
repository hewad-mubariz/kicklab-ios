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
