import Foundation
import Testing
@testable import kicklab

struct MeasuredReboundStabilityTests {
    private final class Resources {}
    private struct Fixture: Decodable {
        var config: CounterConfig
        let operations: [CounterTrace.Operation]
        let feet: [Int: FootContactEvidence]
        let ground: [GroundContactEvidence]
    }
    private func fixture() throws -> Fixture {
        let url = try #require(Bundle(for: Resources.self).url(forResource: "outdoor-rebound-stability-20261028", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    private func run(enabled: Bool, foot: Bool, hand: Bool = false, missingRelease: Bool = false) throws -> CounterTrace {
        var f = try fixture()
        f.config.recoversMeasuredSlowRise = enabled ? true : nil
        let c = StreamingCounter(config: f.config, rejectsHandContact: { _ in hand }, recordTrace: true,
            footContactEvidence: { foot ? f.feet[$0] : nil }, allowsBodyContact: { _ in true })
        for o in f.operations {
            if let i=o.input {
                c.push(frameIndex:i.frameIndex, timestampMs:i.timestampMs,
                    ball: missingRelease && i.timestampMs == 14950 ? nil : i.ball,
                    person:i.person,cameraOffsetY:i.cameraOffsetY,reliable:i.reliable,
                    sourceFrameIndex:i.sourceFrameIndex,player:i.player)
            }
        }
        c.flush()
        let trace = try #require(c.traceSnapshot())
        #expect(try trace.replay() == trace.touches)
        return trace
    }
    @Test func neutralSmoothedReboundRequiresActualReleaseAndPositiveFootProof() throws {
        #expect(try !run(enabled:false,foot:true).touches.contains { $0.timestampMs == 14850 })
        #expect(try run(enabled:true,foot:true).touches.contains { $0.timestampMs == 14850 })
        #expect(try !run(enabled:true,foot:false).touches.contains { $0.timestampMs == 14850 })
        #expect(try !run(enabled:true,foot:true,missingRelease:true).touches.contains { $0.timestampMs == 14850 })
        #expect(try !run(enabled:true,foot:true,hand:true).touches.contains { $0.timestampMs == 14850 })
    }
    @Test func raisedCompactKickUsesStableOppositeFoot() throws {
        for var e in try fixture().ground {
        #expect(!e.confirmsCompactFootContact)
        #expect(e.confirmsGroundContact(corroboratingWeakAnkles:true))
        e.checksRaisedCompactFoot = true
        e.usesCorroboratedRaisedToe = true
        #expect(e.confirmsCompactFootContact)
        #expect(!e.confirmsGroundContact(corroboratingWeakAnkles:true))
        let original = e.compactFootSamples ?? e.samples
        e.compactFootSamples = original.map { s in
            var ankles = s.ankles
            if let foot=ankles[.right], let other=ankles[.left] {
                ankles[.left] = .init(x:other.x,y:foot.y,confidence:other.confidence)
            }
            return .init(timestampMs:s.timestampMs,ballX:s.ballX,ballY:s.ballY,width:s.width,height:s.height,
                confidence:s.confidence,imageAspect:s.imageAspect,ankles:ankles,hips:s.hips)
        }
        #expect(!e.confirmsCompactFootContact)
        }
    }
    @Test func movingFeetDoNotRescueKnownGroundBounces() throws {
        struct Negative: Decodable { let name: String; let proposedMs: Int; let samples: [FootContactRules.Sample] }
        let url = try #require(Bundle(for: Resources.self).url(forResource: "outdoor-adjacent-ground-negatives-20261028", withExtension: "json"))
        for row in try JSONDecoder().decode([Negative].self,from:Data(contentsOf:url)) {
            let samples = row.samples.map { s in GroundContactEvidence.Sample(timestampMs:s.timestampMs,
                ballX:s.ballX,ballY:s.ballY,width:s.width,height:s.height,confidence:s.confidence,
                imageAspect:0.5625,ankles:s.ankles,hips:s.hips) }
            var e = GroundContactEvidence(contactMs:row.proposedMs,samples:samples)
            e.checksCompactFootContact=true; e.checksAdjacentCompactImpact=true
            e.corroboratesCompactAnkles=true; e.usesMeasuredCompactRelease=true
            e.allowsSettlingCompactRelease=true; e.checksRaisedCompactFoot=true; e.usesCorroboratedRaisedToe=true
            #expect(!e.confirmsCompactFootContact,"Must reject \(row.name)")
        }
    }
    @Test func earlyProposalWithoutMeasuredReleaseRemainsUnconfirmed() throws {
        let url = try #require(Bundle(for:Resources.self).url(forResource:"outdoor-two-exposure-impact-20261028",withExtension:"json"))
        var g = try JSONDecoder().decode(GroundContactEvidence.self,from:Data(contentsOf:url))
        #expect(!g.confirmsCompactFootContact)
        #expect(g.needsPositiveFootContact)
        // Even at the visible impact, only a late release remains. Changing
        // alignment cannot manufacture the two measured release views required.
        g = GroundContactEvidence(contactMs: 21565, samples: g.samples,
            checksCompactFootContact: true, compactFootSamples: g.compactFootSamples,
            corroboratesCompactAnkles: true, usesMeasuredCompactRelease: true,
            checksRaisedCompactFoot: true, usesCorroboratedRaisedToe: true)
        #expect(!g.confirmsCompactFootContact)
    }

    @Test func experimentsAreOffByDefault() {
        #expect(!MeasuredReboundPolicy.slowRise(arguments:[]))
        #expect(!MeasuredReboundPolicy.raisedFoot(arguments:[]))
    }
}
