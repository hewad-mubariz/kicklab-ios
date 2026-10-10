import Foundation
import Testing
@testable import kicklab

struct FootContactEvidenceTests {
    private struct Fixture: Decodable {
        let name: String
        let expected: Bool
        let evidence: FootContactEvidence
    }
    private final class BundleToken {}
    private func samples(time: Int = 99, confidence: Double = 0.9,
                         beforeY: Double = 0.50, afterY: Double = 0.54) -> FootContactEvidence {
        func sample(_ ms: Int, _ y: Double) -> FootContactRules.Sample {
            .init(timestampMs: ms, ballX: 0.5, ballY: y, width: 0.18, height: 0.10,
                  confidence: confidence, ankles: ["right": .init(x: ms < time ? 0.45 : 0.5, y: 0.6)],
                  hips: ["right": .init(x: 0.5, y: 0.3)])
        }
        return .init(before: sample(time-99,beforeY), contact: sample(time,0.6), after: sample(time+66,afterY))
    }

    @Test func actualMissesCloseGroundEventsAndStationaryFootAreSeparated() throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "foot-ground-evidence", withExtension: "json"))
        let cases = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        #expect(cases.count == 9)
        for item in cases { #expect(item.evidence.confirms == item.expected, "\(item.name)") }
    }

    @Test func rollingBallOrOneSidedApproachDoesNotEstablishFootImpact() {
        #expect(!samples(beforeY: 0.60, afterY: 0.60).confirms)
        #expect(!samples(beforeY: 0.50, afterY: 0.60).confirms)
        #expect(!samples(beforeY: 0.60, afterY: 0.50).confirms)
        #expect(!samples(confidence: 0.49).confirms)
    }

    @Test func MissingUncertainOrUnrelatedAnkleCannotRescueTheFloor() {
        let e = samples()
        for point in [FootContactRules.Point(x: 0.5,y: 0.6,confidence: 0.1),
                      .init(x: 0.5,y: 0.6,confidence: .nan), .init(x: 0.9,y: 0.6)] {
            let c = FootContactRules.Sample(timestampMs: e.contact.timestampMs, ballX: e.contact.ballX,
                ballY: e.contact.ballY,width: e.contact.width,height: e.contact.height,confidence: 0.9,
                ankles: ["right":point], hips: e.contact.hips)
            #expect(!FootContactEvidence(before: e.before,contact: c,after: e.after).confirms)
        }
        let empty = FootContactRules.Sample(timestampMs: e.contact.timestampMs,ballX: 0.5,ballY: 0.6,
            width: 0.18,height: 0.1,confidence: 0.9,ankles: [:])
        #expect(!FootContactEvidence(before: e.before,contact: empty,after: e.after).confirms)
    }

    @Test func StaleFramesOrBallSizeDiscontinuityRemainUnknown() {
        let e = samples()
        let late = FootContactRules.Sample(timestampMs: 500,ballX: 0.5,ballY: 0.54,
            width: 0.18,height: 0.1,confidence: 0.9,ankles: e.after.ankles, hips: e.after.hips)
        #expect(!FootContactEvidence(before: e.before,contact: e.contact,after: late).confirms)
        let resized = FootContactRules.Sample(timestampMs: 165,ballX: 0.5,ballY: 0.54,
            width: 0.36,height: 0.2,confidence: 0.9,ankles: e.after.ankles, hips: e.after.hips)
        #expect(!FootContactEvidence(before: e.before,contact: e.contact,after: resized).confirms)
    }

    private func gradualMotion(ankleX: [Double] = [0.482, 0.5, 0.524],
                               hipX: [Double] = [0.5, 0.5, 0.5],
                               afterConfidence: Double = 1, afterHipConfidence: Double? = 1) -> FootContactEvidence {
        let template = samples()
        let old = [template.before, template.contact, template.after]
        let values = old.enumerated().map { i,s in
            FootContactRules.Sample(timestampMs: s.timestampMs,ballX: s.ballX,ballY: s.ballY,
                width: s.width,height: s.height,confidence: s.confidence,
                ankles: ["right": .init(x: ankleX[i],y: 0.6,confidence: i == 2 ? afterConfidence : 1)],
                hips: i == 2 && afterHipConfidence == nil ? [:] :
                    ["right": .init(x: hipX[i],y: 0.3,confidence: i == 2 ? afterHipConfidence! : 1)])
        }
        return .init(before: values[0],contact: values[1],after: values[2])
    }

    @Test func resolvedFootTravelCanContinueAcrossTheImpact() throws {
        let e = gradualMotion()
        // Each half is smaller than the original 0.15-diameter motion floor;
        // the aligned full-window movement resolves the actual small kick.
        #expect(e.confirms)
        let restored = try JSONDecoder().decode(FootContactEvidence.self,from:JSONEncoder().encode(e))
        #expect(restored == e && restored.confirms)
    }

    @Test func fullWindowDoesNotTreatStationaryFeetTranslationOrReversingJitterAsAKick() {
        #expect(!gradualMotion(ankleX: [0.5,0.5,0.5]).confirms)
        #expect(!gradualMotion(hipX: [0.482,0.5,0.524]).confirms)
        #expect(!gradualMotion(ankleX: [0.482,0.5,0.482]).confirms)
        #expect(!gradualMotion(ankleX: [0.5,0.5,0.545]).confirms)
        #expect(!gradualMotion(ankleX: [0.482,0.5,0.504]).confirms)
    }

    @Test func gradualRecoveryRequiresConfidentAfterJoints() {
        #expect(!gradualMotion(afterConfidence: 0.49).confirms)
        #expect(!gradualMotion(afterHipConfidence: 0.49).confirms)
        #expect(!gradualMotion(afterHipConfidence: nil).confirms)
        #expect(!gradualMotion(afterHipConfidence: .nan).confirms)
    }

    private func machine(hand: Bool = false, evidence: FootContactEvidence?) -> TouchStateMachine {
        let c = TouchStateMachine(config: CounterConfig())
        c.footContactEvidence = { _ in evidence }
        c.rejectsHandContact = { _ in hand }
        for i in 0...8 {
            c.personBoxes[i] = .init(x: 0.5,y: 0.31,width: 0.8,height: 0.62)
            c.detectedFrames.insert(i); c.ballHeights[i] = 0.04
        }
        for (i,y) in [0.4,0.45,0.55,0.6,0.58,0.55].enumerated() {
            _ = c.push(.init(frameIndex: i,timestampMs: i*33,x: 0.5,y: y,
                vy: i < 4 ? 0.5 : -0.5,confidence: 0.9,valid: true,motion: i < 4 ? .falling : .rising))
        }
        return c
    }

    @Test func footRecoveryStillRequiresMatchingTimeAndPreservesHandVeto() {
        #expect(machine(evidence: samples()).count == 1)
        #expect(machine(evidence: nil).rejected.last?.reason == .groundBounce)
        #expect(machine(evidence: samples(time: 199)).count == 0)
        #expect(machine(hand: true,evidence: samples()).rejected.last?.reason == .handContact)
    }

    @Test func fullFootEvidenceReplaysWithoutPoseAndMissingEvidenceFails() throws {
        var requests = 0
        let c = StreamingCounter(recordTrace: true,footContactEvidence: { f in
            requests += 1; return samples(time: f*33)
        })
        for (f,y) in [0.35,0.4,0.46,0.53,0.6,0.67,0.73,0.76,0.74,0.70,0.63,0.55,0.46,0.38,0.32].enumerated() {
            let time = f*33
            c.push(frameIndex: f,timestampMs: time,
                ball: .init(frameIndex:f,timestampMs:time,x:0.5,y:y,width:0.18,height:0.1,confidence:0.9),
                person: .init(x:0.5,y:0.36,width:0.8,height:0.72))
        }
        c.flush(); #expect(c.count == 1); #expect(requests == 1)
        let trace = try #require(c.traceSnapshot())
        #expect(trace.decisions.contains { $0.value.footConfirmed == true && $0.value.footEvidence != nil })
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let restored = try PropertyListDecoder().decode(CounterTrace.self,from:encoder.encode(trace))
        #expect(try restored.replay() == c.touches); #expect(requests == 1)
        let missing = CounterTrace(revision: trace.revision, config: trace.config, usesHandVerifier: false,
            usesFootVerifier: true, complete: trace.complete, operations: trace.operations, decisions: [], touches: trace.touches)
        #expect(throws: CounterTrace.ReplayError.self) { try missing.replay() }
    }
}
