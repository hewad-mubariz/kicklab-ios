import Foundation

/// The counter depends on contact evidence, without knowing how Vision obtains it.
nonisolated protocol ContactEvidenceProviding: AnyObject {
    func configure(policy: CountingPolicy)
    func rejectsHandContact(at frameIndex: Int) -> Bool
    func allowsBodyContact(at frameIndex: Int, policy: CountingPolicy.BodyContact) -> Bool
    func footEvidence(at frameIndex: Int) -> FootContactEvidence?
    func groundEvidence(at frameIndex: Int, timed: Bool) -> GroundContactEvidence?
    func handlingEvidence(at frameIndex: Int) -> BallHandlingEvidence?
    func retainContactFrames(around index: Int?)
    func diagnostic(for decision: CounterDecision, ball: BallObservation?) -> TouchDebugEvent
}

nonisolated extension ContactEvidenceProviding {
    func configure(policy: CountingPolicy) {}
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
        var config = config
        if policy.body.usesVisibleFoot { config.recoversVisibleFootOutsideRegion = true }
        if policy.body.usesMeasuredFoot {
            config.usesRecheckedRegionContact = true
            config.recoversSmallVisibleContacts = true
        }
        if policy.body == .smallArcV23 {
            if MeasuredReboundPolicy.settledProbe() { config.probesSettledMeasuredRebound = true }
            if MeasuredReboundPolicy.confirmation() {
                config.recoversUnsmoothedFootRebound = true
                config.usesJointGapRelease = true
                config.requiresDistantLowFootProof = true
            }
            config.recoversMeasuredSmallArcs = true
            if MeasuredReboundPolicy.slowRise() { config.recoversMeasuredSlowRise = true }
            if ObservedContactRecoveryPolicy.terminalRebound() { config.recoversMeasuredTerminalRebound = true }
            if ObservedContactRecoveryPolicy.gapRebound() { config.recoversMeasuredGapRebound = true }
            if AlignedFootRegionPolicy.enabled() { config.recoversAlignedFootRegion = true }
            if MeasuredFootImpactPolicy.toeLift() { config.recoversBriefToeLift = true }
            if MeasuredFootImpactPolicy.floorRebound() { config.rejectsDescendingFloorRebound = true }
        }
        return StreamingCounter(config: config,
            rejectsHandContact: { [weak verifier] in
                verifies ? (verifier?.rejectsHandContact(at: $0) ?? false) : false
            },
            recordTrace: counts && recordTrace,
            traceLimit: TouchCountingDebugProfile.traceLimit,
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
                ? { [weak verifier] in verifier?.handlingEvidence(at: $0) } : nil)
    }
}
