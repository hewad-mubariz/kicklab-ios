import Foundation
import Testing
@testable import kicklab

struct ShortDescentGapTests {
    private final class Resources {}

    @Test func recordedDescentSurvives200msDetectionOutageWithoutLoweringAmplitude() throws {
        let url = try #require(Bundle(for: Resources.self).url(forResource: "final30-descent-gap", withExtension: "json"))
        let inputs = try JSONDecoder().decode([CounterTrace.Input].self, from: Data(contentsOf: url))
        for enabled in [false, true] {
            var config = CounterConfig(); config.preservesFallingArcAcrossShortGap = enabled
            var checked: [Int] = []
            let counter = StreamingCounter(config: config, recordTrace: true,
                allowsBodyContact: { checked.append($0); return false })
            for i in inputs {
                counter.push(frameIndex: i.frameIndex, timestampMs: i.timestampMs,
                    ball: i.ball, person: i.person, cameraOffsetY: i.cameraOffsetY,
                    reliable: i.reliable, sourceFrameIndex: i.sourceFrameIndex)
            }
            counter.flush()
            #expect(checked.contains(1701) == enabled)
            #expect(counter.count == 0, "Recovery must still pass the contact gates")
            let trace = try #require(counter.traceSnapshot())
            #expect(try trace.replay().isEmpty)
        }
    }

    @Test(arguments: ["risingReturn", "longGap", "discontinuity"])
    func unknownReversalOrLongGapCannotReuseOldDescent(kind: String) {
        var config = CounterConfig(); config.preservesFallingArcAcrossShortGap = true
        let machine = TouchStateMachine(config: config)
        func push(_ i: Int, _ ms: Int, _ y: Double, _ motion: MotionState, valid: Bool = true) {
            _ = machine.push(.init(frameIndex: i, timestampMs: ms, x: 0.5,y: y,
                vy: motion == .falling ? 0.4 : -0.4, confidence: 0.9,valid: valid,motion: motion))
        }
        push(0,0,0.4,.falling); push(1,17,0.45,.falling)
        for i in 2...14 { push(i,i*17,0,.unknown,valid:false) }
        if kind == "discontinuity" { machine.discardPendingArc() }
        let time = kind == "longGap" ? 450 : 255
        push(15,time,0.44,.rising); push(16,time+17,0.42,.rising)
        #expect(machine.count == 0)
        #expect(machine.rejected.contains { $0.reason == .trackLost })
    }
}
