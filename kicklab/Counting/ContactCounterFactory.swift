import Foundation

/// The counter depends on contact evidence, without knowing how Vision obtains it.
nonisolated protocol ContactEvidenceProviding: AnyObject {
    func configure(policy: CountingPolicy)
    func rejectsHandContact(at frameIndex: Int) -> Bool
    func allowsBodyContact(at frameIndex: Int, policy: CountingPolicy.BodyContact) -> Bool
    func footEvidence(at frameIndex: Int) -> FootContactEvidence?
    func groundEvidence(at frameIndex: Int, timed: Bool) -> GroundContactEvidence?
    func handlingEvidence(at frameIndex: Int) -> BallHandlingEvidence?
    func streakHandlingEvidence(now: Int, after lastTouchMs: Int) -> BallHandlingEvidence?
    func streakGroundEvidence(at frameIndex: Int, timed: Bool) -> GroundContactEvidence?
    func retainContactFrames(around index: Int?)
    func diagnostic(for decision: CounterDecision, ball: BallObservation?) -> TouchDebugEvent
}

nonisolated extension ContactEvidenceProviding {
    func configure(policy: CountingPolicy) {}
    func streakHandlingEvidence(now: Int, after lastTouchMs: Int) -> BallHandlingEvidence? { nil }
    func streakGroundEvidence(at frameIndex: Int, timed: Bool) -> GroundContactEvidence? { nil }
}

nonisolated enum ContactCounterFactory {
    enum Mode { case counting, visualOnly }

    /// The caller owns the verifier. Weak callbacks allow camera cleanup to release
    /// Vision buffers even while the finished counter's numeric trace is retained.
    static func make(verifier: (any ContactEvidenceProviding)?, policy: CountingPolicy = .current,
                     config: CounterConfig = CounterConfig(), mode: Mode = .counting,
                     recordTrace: Bool = true) -> StreamingCounter {
        let counts = mode == .counting
        let verifies = counts && policy.verifiesContacts
        let checksBody = counts && policy.body != .unrestricted
        verifier?.configure(policy: policy)
        return StreamingCounter(config: config,
            rejectsHandContact: { [weak verifier] in
                verifies ? (verifier?.rejectsHandContact(at: $0) ?? false) : false
            },
            recordTrace: counts && recordTrace,
            footContactEvidence: verifies ? { [weak verifier] in verifier?.footEvidence(at: $0) } : nil,
            countsTouches: counts,
            retainContactFrames: { [weak verifier] in verifier?.retainContactFrames(around: $0) },
            allowsBodyContact: checksBody ? { [weak verifier] in
                verifier?.allowsBodyContact(at: $0, policy: policy.body) ?? false
            } : nil,
            diagnoseContact: checksBody ? { [weak verifier] in verifier?.diagnostic(for: $0, ball: $1) } : nil,
            groundPolicy: policy.ground,
            groundContactEvidence: verifies ? { [weak verifier] in verifier?.groundEvidence(at: $0, timed: policy.body.usesObservedImpact) } : nil,
            handlingEvidence: verifies && policy.handling != .disabled
                ? { [weak verifier] in verifier?.handlingEvidence(at: $0) } : nil,
            streakHandlingEvidence: verifies && policy.handling != .disabled
                ? { [weak verifier] in verifier?.streakHandlingEvidence(now: $0, after: $1) } : nil,
            streakGroundEvidence: verifies
                ? { [weak verifier] in verifier?.streakGroundEvidence(at: $0, timed: policy.body.usesObservedImpact) } : nil)
    }
}
