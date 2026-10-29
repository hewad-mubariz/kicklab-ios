import Foundation
import Testing
@testable import kicklab

struct ObservedContactRecoveryTests {
    private final class Resources {}
    private struct Fixture: Decodable {
        var config: CounterConfig
        let operations: [CounterTrace.Operation]
        var low: FootContactEvidence
        let alignedGround: GroundContactEvidence
        let suspectedFloor: FootContactEvidence
    }
    private func fixture() throws -> Fixture {
        let url = try #require(Bundle(for:Resources.self).url(forResource:"outdoor-three-minute-recovery-20261028",withExtension:"json"))
        return try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:url))
    }
    @Test func actualLegImpactCarriesItsOwnGroundProof() throws {
        var f = try fixture()
        #expect(f.low.observedLegContactMs == 8050)
        #expect(!FootContactRules.ankleTravels(f.low))
        #expect(!f.low.confirmsAlignedLegGroundClearance)
        f.low.alignedLegGroundEvidence = f.alignedGround
        #expect(f.low.confirmsAlignedLegGroundClearance)
        #expect(!f.suspectedFloor.confirmsAlignedLegGroundClearance)
        f.low.observedLegSamples = nil
        #expect(!f.low.confirmsAlignedLegGroundClearance)
    }
    private func run(enabled: Bool, body: Bool = true, hand: Bool = false,
                     missingRelease: Bool = false, clipped: Bool = false) throws -> CounterTrace {
        var f = try fixture(); f.config.recoversMeasuredTerminalRebound = enabled ? true : nil
        let c = StreamingCounter(config:f.config,rejectsHandContact:{_ in hand},recordTrace:true,
            allowsBodyContact:{_ in body})
        for o in f.operations { if let i=o.input {
            var ball=i.ball
            if i.timestampMs == 107976 {
                if missingRelease {ball=nil}
                if clipped {ball?.height=0.3}
            }
            c.push(frameIndex:i.frameIndex,timestampMs:i.timestampMs,ball:ball,person:i.person,
                cameraOffsetY:i.cameraOffsetY,reliable:i.reliable,sourceFrameIndex:i.sourceFrameIndex,player:i.player)
        }}
        c.flush(); let trace = try #require(c.traceSnapshot())
        #expect(try trace.replay() == trace.touches)
        return trace
    }
    @Test func measuredKneeReboundSurvivesTerminalSmoothing() throws {
        #expect(try run(enabled:false).touches.isEmpty)
        #expect(try run(enabled:true).touches.map(\.timestampMs) == [107910])
        #expect(try run(enabled:true,body:false).touches.isEmpty)
        #expect(try run(enabled:true,hand:true).touches.isEmpty)
        #expect(try run(enabled:true,missingRelease:true).touches.isEmpty)
        #expect(try run(enabled:true,clipped:true).touches.isEmpty)
    }
    @Test func experimentsAreOffByDefault() {
        #expect(!ObservedContactRecoveryPolicy.alignedLeg(arguments:[]))
        #expect(!ObservedContactRecoveryPolicy.terminalRebound(arguments:[]))
    }
}
