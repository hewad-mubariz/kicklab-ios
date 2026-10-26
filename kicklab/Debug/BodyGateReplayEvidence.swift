#if DEBUG
import Foundation

/// Replay-only ablation. Evaluate body evidence in both arms so aligned physical
/// contacts and the hand/handling checks keep their existing behavior.
/// Never selected by live counting or saved-video analysis.
nonisolated final class BodyGateReplayEvidence: ContactEvidenceProviding {
    struct Assessment: Codable {
        let frameIndex, timestampMs: Int
        let originalBodyAllowed: Bool
        let resultingRejection: RejectionReason?
        let originalBodyFailure: RestrictedTouchPolicy.Failure?
        let handConfirmed: Bool
    }
    private let underlying: any ContactEvidenceProviding
    let bypassBodyRejection: Bool
    private var originalVerdicts: [Int: Bool] = [:]
    private(set) var assessments: [Assessment] = []

    init(_ underlying: any ContactEvidenceProviding, bypassBodyRejection: Bool) {
        self.underlying = underlying
        self.bypassBodyRejection = bypassBodyRejection
    }

    func allowsBodyContact(at frameIndex: Int, policy: CountingPolicy.BodyContact) -> Bool {
        let allowed = underlying.allowsBodyContact(at: frameIndex, policy: policy)
        originalVerdicts[frameIndex] = allowed
        return bypassBodyRejection || allowed
    }
    func configure(policy: CountingPolicy) { underlying.configure(policy: policy) }
    func rejectsHandContact(at frameIndex: Int) -> Bool { underlying.rejectsHandContact(at: frameIndex) }
    func footEvidence(at frameIndex: Int) -> FootContactEvidence? { underlying.footEvidence(at: frameIndex) }
    func groundEvidence(at frameIndex: Int, timed: Bool) -> GroundContactEvidence? {
        underlying.groundEvidence(at: frameIndex, timed: timed)
    }
    func handlingEvidence(at frameIndex: Int) -> BallHandlingEvidence? { underlying.handlingEvidence(at: frameIndex) }
    func streakHandlingEvidence(now: Int, after lastTouchMs: Int) -> BallHandlingEvidence? {
        underlying.streakHandlingEvidence(now: now, after: lastTouchMs)
    }
    func streakGroundEvidence(at frameIndex: Int, timed: Bool) -> GroundContactEvidence? {
        underlying.streakGroundEvidence(at: frameIndex, timed: timed)
    }
    func retainContactFrames(around index: Int?) { underlying.retainContactFrames(around: index) }

    func diagnostic(for decision: CounterDecision, ball: BallObservation?) -> TouchDebugEvent {
        let actual = underlying.diagnostic(for: decision, ball: ball)
        if let original = originalVerdicts.removeValue(forKey: decision.frameIndex) {
            // Save the original failure separately after counting has finished;
            // accepted events must not acquire a false rejection in their HUD.
            let originalDiagnostic = original || decision.rejection == .disallowedBodyContact ? actual
                : underlying.diagnostic(for: .init(frameIndex: decision.frameIndex,
                    timestampMs: decision.timestampMs, rejection: .disallowedBodyContact), ball: ball)
            assessments.append(.init(frameIndex: decision.frameIndex, timestampMs: decision.timestampMs,
                originalBodyAllowed: original, resultingRejection: decision.rejection,
                originalBodyFailure: originalDiagnostic.bodyFailure,
                handConfirmed: actual.handConfirmed || originalDiagnostic.handConfirmed))
        }
        return actual
    }
}
#endif
