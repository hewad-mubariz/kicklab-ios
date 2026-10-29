import Foundation
import Testing
@testable import kicklab

struct MeasuredFootImpactTests {
    private final class Resources {}
    private func load<T:Decodable>(_ name:String, as:T.Type) throws -> T {
        let url=try #require(Bundle(for:Resources.self).url(forResource:name,withExtension:"json"))
        return try JSONDecoder().decode(T.self,from:Data(contentsOf:url))
    }
    private func ground(_ ms:Int) throws -> GroundContactEvidence {
        let rows=try load("outdoor-foot-impact-20261028",as:[CounterDecision].self)
        return try #require(rows.first { $0.timestampMs==ms }?.groundEvidence)
    }
    @Test func briefToeFlickSeparatesFromMovingFootGroundBounce() throws {
        let toe=try ground(159140), floor=try ground(248418)
        #expect(MeasuredFootImpactRules.briefToeLift(toe))
        #expect(MeasuredFootImpactRules.descendingFloorRebound(toe)==nil)
        #expect(!MeasuredFootImpactRules.briefToeLift(floor))
        #expect(MeasuredFootImpactRules.descendingFloorRebound(floor)==248385)
    }
    @Test func toeRecoveryNeedsObservedLiftAndTwoReleaseViews() throws {
        var g=try ground(159140)
        g.compactFootSamples=g.compactFootSamples?.filter { $0.timestampMs != 159173 }
        #expect(!MeasuredFootImpactRules.briefToeLift(g))
        g=try ground(159140)
        g.compactFootSamples=g.compactFootSamples?.filter { $0.timestampMs <= 159206 }
        #expect(!MeasuredFootImpactRules.briefToeLift(g))
    }
    @Test func ambiguousOrDuplicateFloorEvidenceDoesNotVeto() throws {
        let source=try ground(248418)
        var g=GroundContactEvidence(contactMs:source.contactMs,samples:source.samples.filter { $0.timestampMs < 248385 || $0.timestampMs > 248451 })
        #expect(MeasuredFootImpactRules.descendingFloorRebound(g)==nil)
        g=GroundContactEvidence(contactMs:source.contactMs,samples:source.samples+source.samples)
        #expect(MeasuredFootImpactRules.descendingFloorRebound(g)==nil)
    }
    private func leg(_ s:[FootPoseSample], enabled:Bool) -> Int? {
        ObservedLegContactRules.contactTime(s,at:291566,usesTemporalEvidence:true,usesCadenceWindow:true,
            allowsNearSupportFoot:true,usesImageSupport:true,allowsTurningHip:true,allowsLowToeDeparture:true,
            corroboratesWeakSupport:enabled)
    }
    @Test func observedStableSupportCanCorroborateOneMarginalView() throws {
        let s=try load("outdoor-weak-support-20261028",as:[FootPoseSample].self)
        #expect(leg(s,enabled:false)==nil)
        #expect(leg(s,enabled:true)==291566)
        #expect(s.first?.landmarks[.rightAnkle]?.confidence == 0.443603515625)
        var missing=s;missing[0].landmarks[.rightAnkle]=nil
        #expect(leg(missing,enabled:true)==nil)
        var weak=s;weak[0].landmarks[.rightAnkle]?.confidence=0.2
        #expect(leg(weak,enabled:true)==nil)
        var drifting=s
        if let p=drifting[0].landmarks[.rightAnkle] {
            drifting[0].landmarks[.rightAnkle] = .init(x:p.x+0.1,y:p.y,confidence:p.confidence)
        }
        #expect(leg(drifting,enabled:true)==nil)
        #expect(leg(s.filter { $0.pose.timestampMs <= 291566 },enabled:true)==nil)
    }
    private struct RegionFixture:Decodable {
        var config:CounterConfig
        let operations:[CounterTrace.Operation]
        var evidence:FootContactEvidence
    }
    private func region(enabled:Bool,body:Bool=true,hand:Bool=false,missingImpact:Bool=false) throws -> CounterTrace {
        var f=try load("outdoor-aligned-region-20261028",as:RegionFixture.self)
        f.config.recoversAlignedFootRegion=enabled ? true:nil
        let c=StreamingCounter(config:f.config,rejectsHandContact:{_ in hand},recordTrace:true,
            footContactEvidence:{_ in missingImpact ? nil:f.evidence},allowsBodyContact:{_ in body})
        for o in f.operations {if let i=o.input {
            c.push(frameIndex:i.frameIndex,timestampMs:i.timestampMs,ball:i.ball,person:i.person,
                cameraOffsetY:i.cameraOffsetY,reliable:i.reliable,sourceFrameIndex:i.sourceFrameIndex,player:i.player)
        }}
        c.flush();let t=try #require(c.traceSnapshot())
        #expect(try t.replay()==t.touches)
        return t
    }
    @Test func alignedRegionKeepsRealExposureAndDownstreamVetoes() throws {
        #expect(try region(enabled:false).touches.allSatisfy { abs($0.timestampMs-149273)>100 })
        #expect(try region(enabled:true).touches.contains { $0.timestampMs==149273 })
        #expect(try region(enabled:true,body:false).touches.isEmpty)
        #expect(try region(enabled:true,hand:true).touches.isEmpty)
        #expect(try region(enabled:true,missingImpact:true).touches.allSatisfy { abs($0.timestampMs-149273)>100 })
    }
    @Test func newOptionsAreOffByDefault() {
        #expect(!AlignedFootRegionPolicy.enabled(arguments:[]))
        #expect(!MeasuredFootImpactPolicy.toeLift(arguments:[]))
        #expect(!MeasuredFootImpactPolicy.floorRebound(arguments:[]))
        #expect(!MeasuredFootImpactPolicy.weakSupport(arguments:[]))
    }
}
