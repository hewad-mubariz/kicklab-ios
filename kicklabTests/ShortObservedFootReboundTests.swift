import Foundation
import Testing
@testable import kicklab

struct ShortObservedFootReboundTests {
    private final class Resources {}
    private struct Fixture: Decodable {
        let targetMs, targetFrame: Int
        let config: CounterConfig
        let foot: FootContactEvidence
        let operations: [CounterTrace.Operation]
    }
    private func fixture() throws -> Fixture {
        let url = try #require(Bundle(for:Resources.self).url(forResource:"short-observed-rebound-20261110",withExtension:"json"))
        return try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:url))
    }
    private func run(_ fixture:Fixture, enabled:Bool = true, foot:Bool = true,
                     hand:Bool = false, body:Bool = true, held:Bool = false,
                     missingRelease:Bool = false, unreliable:Bool = false) throws -> CounterTrace {
        var config = fixture.config
        config.recoversShortObservedFootRebound = enabled ? true:nil
        let holding = BallHandlingEvidence(contactMs:fixture.targetMs,samples:[-100,-50,0,50,100].map { dt in
            .init(timestampMs:fixture.targetMs+dt,ball:.init(x:0.5,y:0.6),width:0.18,height:0.1,
                confidence:0.9,imageAspect:0.5625,wrists:[.left:.init(x:0.4,y:0.56,confidence:0.9),
                    .right:.init(x:0.6,y:0.56,confidence:0.9)])
        })
        #expect(holding.state == .held)
        let counter = StreamingCounter(config:config,rejectsHandContact:{ _ in hand },recordTrace:true,
            footContactEvidence:{ frame in foot && frame == fixture.targetFrame ? fixture.foot:nil },
            allowsBodyContact:{ _ in body },handlingEvidence:{ _ in held ? holding:nil })
        for operation in fixture.operations { if let input = operation.input {
            let release = (1...134).contains(input.timestampMs-fixture.targetMs)
            counter.push(frameIndex:input.frameIndex,timestampMs:input.timestampMs,
                ball:missingRelease && release ? nil:input.ball,person:input.person,
                cameraOffsetY:input.cameraOffsetY,reliable:input.reliable && !(unreliable && release),
                sourceFrameIndex:input.sourceFrameIndex,player:input.player)
        } }
        counter.flush()
        let trace = try #require(counter.traceSnapshot())
        #expect(try trace.replay() == trace.touches)
        #expect(counter.flush().isEmpty)
        return trace
    }
    @Test func measuredShallowContactCountsOnceWithVerifiedFoot() throws {
        let f = try fixture()
        #expect(f.foot.confirms)
        #expect(try run(f).touches.filter { $0.timestampMs == f.targetMs }.count == 1)
        #expect(try !run(f,enabled:false).touches.contains { $0.timestampMs == f.targetMs })
    }
    @Test func proposalCannotBypassEvidenceAndContactVetoes() throws {
        let f = try fixture()
        for trace in try [run(f,foot:false),run(f,hand:true),run(f,body:false),run(f,held:true),
                          run(f,missingRelease:true),run(f,unreliable:true)] {
            #expect(!trace.touches.contains { $0.timestampMs == f.targetMs })
        }
    }
    @Test func oldConfigurationDoesNotEnableNewRules() throws {
        let old = try JSONDecoder().decode(CounterConfig.self,from:JSONEncoder().encode(CounterConfig()))
        #expect(old.recoversShortObservedFootRebound == nil)
        #expect(old.requiresResolvedEdgeFootContact == nil)
    }
    @Test func rejectedObservedWindowsAtRecordedCadenceFinishWithoutInventingTouches() throws {
        struct Inputs: Decodable { let operations: [CounterTrace.Operation] }
        let url = try #require(Bundle(for:Resources.self).url(forResource:"short-observed-cadence-20261110",withExtension:"json"))
        let input = try JSONDecoder().decode(Inputs.self,from:Data(contentsOf:url))
        var traces: [CounterTrace] = []
        for enabled in [false,true] {
            var config = CounterConfig()
            config.recoversShortObservedFootRebound = enabled ? true:nil
            let counter = StreamingCounter(config:config,rejectsHandContact:{ _ in false },recordTrace:true,
                footContactEvidence:{ _ in nil },allowsBodyContact:{ _ in true })
            for operation in input.operations { if let i = operation.input {
                counter.push(frameIndex:i.frameIndex,timestampMs:i.timestampMs,ball:i.ball,person:i.person,
                    cameraOffsetY:i.cameraOffsetY,reliable:i.reliable,sourceFrameIndex:i.sourceFrameIndex,player:i.player)
            } }
            counter.flush()
            let trace = try #require(counter.traceSnapshot())
            #expect(try trace.replay() == trace.touches)
            traces.append(trace)
        }
        // Missing foot evidence must not turn this previously crashing window
        // into an extra contact. Exercise this fixture in optimized builds too.
        #expect(traces[0].touches == traces[1].touches)
    }
}

struct UnresolvedEdgeFootTests {
    private final class Resources {}
    private func fixture() throws -> GroundContactEvidence {
        let url = try #require(Bundle(for:Resources.self).url(forResource:"edge-floor-evidence-20261110",withExtension:"json"))
        return try JSONDecoder().decode(GroundContactEvidence.self,from:Data(contentsOf:url))
    }
    private func transform(_ source:GroundContactEvidence,
                           _ change:(GroundContactEvidence.Sample)->GroundContactEvidence.Sample) -> GroundContactEvidence {
        GroundContactEvidence(contactMs:source.contactMs,samples:source.samples.map(change))
    }
    @Test func weakEdgeContactNeedsEvidenceAndIsNotAutomaticallyFloor() throws {
        let g = try fixture()
        #expect(g.hasUnresolvedEdgeFoot)
        #expect(!g.confirmsGroundContact(corroboratingWeakAnkles:true,cadenceAware:false))
    }
    @Test func mirroredGeometryHasSameUncertainty() throws {
        let g = try fixture()
        let mirrored = transform(g) { s in
            .init(timestampMs:s.timestampMs,ballX:1-s.ballX,ballY:s.ballY,width:s.width,height:s.height,
                confidence:s.confidence,imageAspect:s.imageAspect,
                ankles:s.ankles.mapValues { .init(x:1-$0.x,y:$0.y,confidence:$0.confidence) },
                hips:s.hips.mapValues { .init(x:1-$0.x,y:$0.y,confidence:$0.confidence) })
        }
        #expect(mirrored.hasUnresolvedEdgeFoot)
    }
    @Test func confidentFootOrMissingSupportCannotTriggerUncertainty() throws {
        let g = try fixture()
        let confident = transform(g) { s in
            .init(timestampMs:s.timestampMs,ballX:s.ballX,ballY:s.ballY,width:s.width,height:s.height,
                confidence:s.confidence,imageAspect:s.imageAspect,
                ankles:s.ankles.mapValues { .init(x:$0.x,y:$0.y,confidence:0.9) },hips:s.hips)
        }
        #expect(!confident.hasUnresolvedEdgeFoot)
        let missing = transform(g) { s in
            .init(timestampMs:s.timestampMs,ballX:s.ballX,ballY:s.ballY,width:s.width,height:s.height,
                confidence:s.confidence,imageAspect:s.imageAspect,
                ankles:s.ankles.filter { $0.key == .right },hips:s.hips)
        }
        #expect(!missing.hasUnresolvedEdgeFoot)
        let noRelease = GroundContactEvidence(contactMs:g.contactMs,samples:g.samples.filter { $0.timestampMs <= g.contactMs })
        #expect(!noRelease.hasUnresolvedEdgeFoot)
    }
}
