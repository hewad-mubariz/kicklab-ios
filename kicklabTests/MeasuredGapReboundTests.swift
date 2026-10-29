import Foundation
import Testing
@testable import kicklab

struct MeasuredGapReboundTests {
    private final class Resources {}
    private struct Fixture: Decodable {
        var config: CounterConfig
        let operations: [CounterTrace.Operation]
        let foot: FootContactEvidence
        let frame, timestampMs: Int
    }
    private func run(enabled: Bool, foot: Bool = true, hand: Bool = false,
                     body: Bool = true, removeRelease: Bool = false, holding: Bool = false) throws -> CounterTrace {
        let url = try #require(Bundle(for:Resources.self).url(forResource:"outdoor-three-minute-gap-20261028",withExtension:"json"))
        var f = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:url))
        f.config.recoversMeasuredGapRebound = enabled ? true : nil
        let held = BallHandlingEvidence(contactMs:f.timestampMs,samples:[-100,-50,0,50,100].map { dt in
            .init(timestampMs:f.timestampMs+dt,ball:.init(x:0.5,y:0.6),width:0.18,height:0.1,
                confidence:0.9,imageAspect:0.5625,
                wrists:[.left:.init(x:0.4,y:0.56,confidence:0.9),.right:.init(x:0.6,y:0.56,confidence:0.9)])
        })
        #expect(held.state == .held)
        let c=StreamingCounter(config:f.config,rejectsHandContact:{_ in hand},recordTrace:true,
            footContactEvidence:{frame in foot && frame==f.frame ? f.foot : nil},
            allowsBodyContact:{_ in body},handlingEvidence:{_ in holding ? held : nil})
        for o in f.operations {if let i=o.input {
            c.push(frameIndex:i.frameIndex,timestampMs:i.timestampMs,
                ball:removeRelease && i.timestampMs==42213 ? nil:i.ball,person:i.person,
                cameraOffsetY:i.cameraOffsetY,reliable:i.reliable,sourceFrameIndex:i.sourceFrameIndex,player:i.player)
        }}
        c.flush();let t=try #require(c.traceSnapshot());#expect(try t.replay()==t.touches);return t
    }
    @Test func rawTurnOnlyRequestsMeasuredFootProofAndKeepsEveryVeto() throws {
        #expect(try !run(enabled:false).touches.contains{$0.timestampMs==41980})
        #expect(try run(enabled:true).touches.filter{$0.timestampMs==41980}.count==1)
        #expect(try !run(enabled:true,foot:false).touches.contains{$0.timestampMs==41980})
        #expect(try !run(enabled:true,hand:true).touches.contains{$0.timestampMs==41980})
        #expect(try !run(enabled:true,body:false).touches.contains{$0.timestampMs==41980})
        #expect(try !run(enabled:true,removeRelease:true).touches.contains{$0.timestampMs==41980})
        #expect(try !run(enabled:true,holding:true).touches.contains{$0.timestampMs==41980})
        #expect(!ObservedContactRecoveryPolicy.gapRebound(arguments:[]))
    }
}
