import Foundation
import Testing
@testable import kicklab

struct CountingPipelineTests {
    private final class Evidence: ContactEvidenceProviding {
        var hand = false
        var body = true
        var calls: [String] = []
        var policies: [CountingPolicy.BodyContact] = []

        func rejectsHandContact(at frameIndex: Int) -> Bool { calls.append("hand"); return hand }
        func allowsBodyContact(at frameIndex: Int, policy: CountingPolicy.BodyContact) -> Bool {
            calls.append("body"); policies.append(policy); return body
        }
        func footEvidence(at frameIndex: Int) -> FootContactEvidence? { calls.append("foot"); return nil }
        func groundEvidence(at frameIndex: Int, timed: Bool) -> GroundContactEvidence? { calls.append("ground"); return nil }
        var holdsBall = false
        var missingHandling = false
        func handlingEvidence(at frameIndex: Int) -> BallHandlingEvidence? {
            calls.append("handling")
            guard !missingHandling else { return nil }
            let contactMs = frameIndex*33
            return .init(contactMs: contactMs, samples: [-100,-50,0,50,100].map { offset in
                .init(timestampMs: contactMs+offset, ball: .init(x: 0.5,y: 0.6),
                      width: 0.18,height: 0.1,confidence: 0.9,imageAspect: 0.5625,
                      wrists: [.left: .init(x: 0.4,y: holdsBall ? 0.56 : 0.3),
                               .right: .init(x: 0.6,y: holdsBall ? 0.56 : 0.3)])
            })
        }
        func retainContactFrames(around index: Int?) {}
        func diagnostic(for decision: CounterDecision, ball: BallObservation?) -> TouchDebugEvent {
            .init(frameIndex: decision.frameIndex, time: Double(decision.timestampMs)/1000,
                  rejection: decision.rejection, handConfirmed: decision.handRejected == true,
                  bodyFailure: nil, ball: ball)
        }
    }

    private let policy = CountingPolicy(verifiesContacts: true, body: .poseContinuityV4, ground: .corroboratedFeet)

    private func feed(_ counter: StreamingCounter) {
        let arc = [0.35,0.4,0.46,0.53,0.6,0.67,0.73,0.76,0.74,0.70,0.63,0.55,0.46,0.38,0.32]
        for (frame, y) in arc.enumerated() {
            counter.push(frameIndex: frame, timestampMs: frame*33,
                ball: .init(frameIndex: frame, timestampMs: frame*33, x: 0.5, y: y,
                            width: 0.05, height: 0.03, confidence: 0.9),
                person: .init(x: 0.5, y: 0.45, width: 0.8, height: 0.9))
        }
        counter.flush()
    }

    @Test func sharedConstructionPreservesGateOrderAndHandVeto() throws {
        let evidence = Evidence()
        evidence.hand = true
        let counter = ContactCounterFactory.make(verifier: evidence, policy: policy)
        feed(counter)
        #expect(counter.count == 0)
        #expect(evidence.calls == ["ground", "body", "hand"])
        #expect(evidence.policies == [.poseContinuityV4])
        let trace = try #require(counter.traceSnapshot())
        #expect(trace.decisions.last?.value.rejection == .handContact)
        #expect(try trace.replay() == counter.touches)
    }

    @Test func bodyRejectionStopsBeforeHandVerification() throws {
        let evidence = Evidence()
        evidence.body = false
        let counter = ContactCounterFactory.make(verifier: evidence, policy: policy)
        feed(counter)
        #expect(counter.count == 0)
        #expect(evidence.calls == ["ground", "body"])
        #expect(counter.traceSnapshot()?.decisions.last?.value.rejection == .disallowedBodyContact)
    }

    @Test func visualPreparationDoesNotRunContactChecksOrCount() {
        let evidence = Evidence()
        let counter = ContactCounterFactory.make(verifier: evidence, policy: policy, mode: .visualOnly)
        feed(counter)
        #expect(counter.count == 0)
        #expect(counter.lastPoint != nil, "Visual preparation still needs the smoothed trajectory")
        #expect(evidence.calls.isEmpty)
        #expect(counter.traceSnapshot() == nil)
    }

    @Test func counterDoesNotRetainVisionAndMissingBodyEvidenceCannotPass() {
        var evidence: Evidence? = Evidence()
        let isReleased = { [weak evidence] in evidence == nil }
        let counter = ContactCounterFactory.make(verifier: evidence, policy: policy)
        evidence = nil
        #expect(isReleased())
        feed(counter)
        #expect(counter.count == 0)
        #expect(counter.traceSnapshot()?.decisions.last?.value.rejection == .disallowedBodyContact)
    }

    @Test func disabledVerificationIgnoresAnAvailableProvider() {
        let evidence = Evidence()
        evidence.hand = true
        let disabled = CountingPolicy(verifiesContacts: false, body: .unrestricted, ground: .corroboratedFeet)
        let counter = ContactCounterFactory.make(verifier: evidence, policy: disabled)
        feed(counter)
        #expect(counter.count == 1)
        #expect(evidence.calls.isEmpty)
    }

    @Test func currentBuildUsesValidatedContactPolicyAndCannotDisableHandChecks() {
        let normal = CountingPolicy.configured(arguments: [])
        let disabled = CountingPolicy.configured(arguments: ["--juggling-no-hand-check"])
        #expect(normal.verifiesContacts)
        #expect(normal.ground == .corroboratedFeet)
        #expect(normal.body == .raisedFootV14)
        #expect(normal.bodySignature == "|raised-foot-v14")
        #expect(!normal.body.allowsObservedLegRecovery(after: .lowContactNeedsFootEvidence))
        #expect(normal.handling == .sustainedGripV1)
        #expect(normal.handlingSignature == "|handling-v1")
        #expect(disabled.verifiesContacts)
    }

    @Test func currentLegEligibilityStillCannotBypassHandOrHoldingVeto() throws {
        let current = CountingPolicy.configured(arguments: [])
        for handContact in [true, false] {
            let evidence = Evidence()
            evidence.hand = handContact
            evidence.holdsBall = !handContact
            let counter = ContactCounterFactory.make(verifier:evidence,policy:current)
            feed(counter)
            #expect(counter.count == 0)
            #expect(evidence.policies == [.raisedFootV14])
            #expect(evidence.calls == (handContact ? ["ground","body","hand"] : ["ground","body","hand","handling"]))
            let trace = try #require(counter.traceSnapshot())
            #expect(trace.decisions.last?.value.rejection == (handContact ? .handContact : .heldBall))
            #expect(try trace.replay().isEmpty)
        }
    }

    @Test func sustainedHandlingVetoIsRecordedAndReplaysExactly() throws {
        let evidence = Evidence()
        evidence.holdsBall = true
        var handlingPolicy = policy
        handlingPolicy.handling = .sustainedGripV1
        let counter = ContactCounterFactory.make(verifier: evidence,policy: handlingPolicy)
        feed(counter)
        #expect(evidence.calls == ["ground","body","hand","handling"])
        #expect(counter.count == 0)
        let trace = try #require(counter.traceSnapshot())
        #expect(trace.usesHandlingVerifier == true)
        #expect(trace.decisions.last?.value.rejection == .heldBall)
        #expect(trace.decisions.last?.value.handlingEvidence?.state == .held)
        #expect(try trace.replay().isEmpty)
        let restored = try PropertyListDecoder().decode(CounterTrace.self,from: PropertyListEncoder().encode(trace))
        #expect(try restored.replay().isEmpty)
    }

    @Test func missingHandlingEvidenceDoesNotVetoOtherwiseValidTouch() throws {
        let evidence = Evidence()
        evidence.missingHandling = true
        var handlingPolicy = policy
        handlingPolicy.handling = .sustainedGripV1
        let counter = ContactCounterFactory.make(verifier: evidence,policy: handlingPolicy)
        feed(counter)
        #expect(counter.count == 1)
        let trace = try #require(counter.traceSnapshot())
        #expect(trace.decisions.last?.value.handlingChecked == true)
        #expect(trace.decisions.last?.value.handlingEvidence == nil)
        #expect(try trace.replay() == counter.touches)
    }

    @Test func typedLandmarksRetainLegacyJSONAndPropertyListKeys() throws {
        let legacy = Data(#"{"left":{"x":0.4,"y":0.8,"confidence":0.3},"right":{"x":0.6,"y":0.9,"confidence":0.9}}"#.utf8)
        let landmarks = try JSONDecoder().decode([BodySide: PoseLandmark].self, from: legacy)
        #expect(landmarks[.left]?.confidence == 0.3)
        let data = try PropertyListEncoder().encode(landmarks)
        let oldReader = try PropertyListDecoder().decode([String: PoseLandmark].self, from: data)
        #expect(oldReader["right"] == landmarks[.right])
        let joints: [BodyJoint: PosePoint] = [.leftAnkle: .init(x: 0.4, y: 0.8)]
        let oldJoints = try JSONDecoder().decode([String: PosePoint].self, from: JSONEncoder().encode(joints))
        #expect(oldJoints["left_ankle"] == joints[.leftAnkle])
    }
}
