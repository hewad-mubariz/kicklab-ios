import Foundation
import Testing
@testable import kicklab

struct MeasuredReboundConfirmationTests {
    private final class Resources {}
    private struct Fixture: Decodable {
        let timestampMs, frame: Int
        var config: CounterConfig
        let foot: FootContactEvidence
        let operations: [CounterTrace.Operation]
    }
    private func fixtures() throws -> [Fixture] {
        let url=try #require(Bundle(for:Resources.self).url(forResource:"outdoor-round2-rebounds-20261028",withExtension:"json"))
        return try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:url))
    }
    private func run(_ f:Fixture, enabled:Bool, foot:Bool=true, hand:Bool=false,
                     body:Bool=true, missingRelease:Bool=false) throws -> CounterTrace {
        var config=f.config
        config.recoversUnsmoothedFootRebound=enabled ? true:nil
        config.usesJointGapRelease=enabled ? true:nil
        let counter=StreamingCounter(config:config,rejectsHandContact:{_ in hand},recordTrace:true,
            footContactEvidence:{ i in foot && i==f.frame ? f.foot:nil },allowsBodyContact:{_ in body})
        for op in f.operations {if let i=op.input {
            counter.push(frameIndex:i.frameIndex,timestampMs:i.timestampMs,
                ball:missingRelease && [214003,280733].contains(i.timestampMs) ? nil:i.ball,
                person:i.person,cameraOffsetY:i.cameraOffsetY,reliable:i.reliable,
                sourceFrameIndex:i.sourceFrameIndex,player:i.player)
        }}
        counter.flush()
        let trace=try #require(counter.traceSnapshot())
        #expect(try trace.replay()==trace.touches)
        return trace
    }
    @Test func measuredRecoveriesNeedFootProofAndKeepBodyAndHandVetoes() throws {
        for f in try fixtures() {
            #expect(try !run(f,enabled:false).touches.contains { $0.timestampMs==f.timestampMs })
            #expect(try run(f,enabled:true).touches.contains { $0.timestampMs==f.timestampMs })
            #expect(try !run(f,enabled:true,foot:false).touches.contains { $0.timestampMs==f.timestampMs })
            #expect(try !run(f,enabled:true,hand:true).touches.contains { $0.timestampMs==f.timestampMs })
            #expect(try !run(f,enabled:true,body:false).touches.contains { $0.timestampMs==f.timestampMs })
            #expect(try !run(f,enabled:true,missingRelease:true).touches.contains { $0.timestampMs==f.timestampMs })
        }
    }
    @Test func shallowToeRequiresContinuedLiftAndTwoReleaseViews() throws {
        let f=try #require(fixtures().first { $0.timestampMs==213903 })
        let g=try #require(f.foot.compactGroundEvidence)
        #expect(MeasuredFootImpactRules.shallowToeRebound(g))
        var missing=g
        missing.compactFootSamples=(g.compactFootSamples ?? g.samples).filter { $0.timestampMs != 213936 }
        #expect(!MeasuredFootImpactRules.shallowToeRebound(missing))
        missing=g
        missing.compactFootSamples=(g.compactFootSamples ?? g.samples).filter { $0.timestampMs <= 213970 }
        #expect(!MeasuredFootImpactRules.shallowToeRebound(missing))
        #expect(!MeasuredReboundPolicy.confirmation(arguments:[]))
    }
    @Test func adjacentToeUsesOnlyNextMeasuredImpactAndPreservesHistoricalEvidence() throws {
        let url=try #require(Bundle(for:Resources.self).url(forResource:"outdoor-round2-adjacent-toe-20261028",withExtension:"json"))
        var foot=try JSONDecoder().decode(FootContactEvidence.self,from:Data(contentsOf:url))
        let ground=try #require(foot.compactGroundEvidence)
        #expect(!foot.confirmsShallowToeRebound)
        #expect(MeasuredFootImpactRules.adjacentShallowToeRebound(ground)==213903)
        foot.allowsAdjacentShallowToeRebound=true
        #expect(foot.confirmsShallowToeRebound)
        for removed in [213903,213936,213770] {
            var missing=ground
            missing.compactFootSamples=(ground.compactFootSamples ?? ground.samples).filter { $0.timestampMs != removed }
            #expect(MeasuredFootImpactRules.adjacentShallowToeRebound(missing)==nil)
        }
        var noRelease=ground
        noRelease.compactFootSamples=(ground.compactFootSamples ?? ground.samples).filter { $0.timestampMs <= 213970 }
        #expect(MeasuredFootImpactRules.adjacentShallowToeRebound(noRelease)==nil)
    }
    @Test func distantAnkleHeightReboundsNeedFootEvidenceWithoutBroadeningToeContacts() throws {
        let url=try #require(Bundle(for:Resources.self).url(forResource:"outdoor-round2-distant-floor-20261028",withExtension:"json"))
        let floors=try JSONDecoder().decode([GroundContactEvidence].self,from:Data(contentsOf:url))
        for ground in floors {
            #expect(!ground.needsPositiveFootContact)
            #expect(ground.hasDistantLowBall)
            var continuous=ground; continuous.requiresPositiveLowContact=nil
            #expect(!continuous.hasDistantLowBall)
            #expect(MeasuredFootImpactRules.adjacentShallowToeRebound(ground)==nil)
        }
        for f in try fixtures() {
            if let ground=f.foot.compactGroundEvidence { #expect(!ground.hasDistantLowBall) }
        }
    }
    @Test func savedFalseFloorBounceDoesNotSatisfyToeProof() throws {
        let url=try #require(Bundle(for:Resources.self).url(forResource:"outdoor-foot-impact-20261028",withExtension:"json"))
        let rows=try JSONDecoder().decode([CounterDecision].self,from:Data(contentsOf:url))
        let ground=try #require(rows.first { $0.timestampMs==248418 }?.groundEvidence)
        #expect(!MeasuredFootImpactRules.shallowToeRebound(ground))
        #expect(MeasuredFootImpactRules.adjacentShallowToeRebound(ground)==nil)
    }
}
