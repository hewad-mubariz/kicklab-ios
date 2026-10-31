import Foundation

@main struct ShortRiseContracts {
    static func main() throws {
        let balls = try JSONDecoder().decode([BallObservation].self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let trace = try PropertyListDecoder().decode(CounterTrace.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        var checks = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw NSError(domain: name, code: checks) }
            checks += 1
        }
        func turn(_ views: [BallObservation], _ through: Int = 4733) -> ObservedFallAmplitude.Turn? {
            ObservedFallAmplitude.turn(views, contactFrame: 139, through: through)
        }
        let measured = turn(balls)!
        try check(measured.contact.timestampMs == 4633, "Measured impact")
        try check(measured.rise >= 0.007 && measured.impulse >= 0.2, "Ordinary motion floors")
        try check(turn(balls,4666) == nil, "One release view cannot qualify")
        for frame in [137,138,139,140,141] {
            try check(turn(balls.filter { $0.frameIndex != frame },4700) == nil, "Missing real view")
        }
        try check(turn(balls.map { var x=$0;x.y=0.5;return x }) == nil, "Stationary ball")
        try check(turn(balls.map { var x=$0;if x.frameIndex==139 { x.x=0 };return x }) == nil, "Clipped impact")
        try check(turn(balls.map { var x=$0;if x.frameIndex==139 { x.confidence=0.69 };return x }) == nil, "Weak impact")
        let shifted=balls.map { var x=$0;x.timestampMs+=10000;return x }
        try check(abs(turn(shifted,14733)!.impulse-measured.impulse)<0.000001, "No clip-time condition")
        try check(CounterConfig().recoversObservedShortRise != true, "Default off")

        // Intentionally deny every foot proof. A new candidate must not turn
        // measured ball motion into a count without actual foot evidence.
        func run(_ enabled: Bool) -> CounterTrace {
            var config=trace.config;config.recoversObservedShortRise=enabled
            let counter=StreamingCounter(config:config, rejectsHandContact:{ _ in false },
                recordTrace:true,footContactEvidence:{ _ in nil },allowsBodyContact:{ _ in true })
            for o in trace.operations {
                if o.flush { counter.flush() }
                else if let x=o.input {
                    counter.push(frameIndex:x.frameIndex,timestampMs:x.timestampMs,ball:x.ball,
                        person:x.person,cameraOffsetY:x.cameraOffsetY,reliable:x.reliable,
                        sourceFrameIndex:x.sourceFrameIndex,player:x.player)
                }
            }
            return counter.traceSnapshot()!
        }
        let before=run(false),after=run(true)
        try check(!before.decisions.contains { $0.value.timestampMs==4633 }, "Previously unproposed turn")
        let proposal=after.decisions.first { $0.value.timestampMs==4633 }!
        try check(proposal.value.observedImpulse != nil, "Measured proposal recorded")
        try check(proposal.value.rejection == .amplitudeTooSmall && proposal.value.footConfirmed == false,
                  "Foot evidence remains mandatory")
        try check(!after.touches.contains { $0.timestampMs==4633 }, "No count without foot proof")
        for ms in [4300,4900] {
            try check(before.touches.contains { $0.timestampMs==ms }
                      && after.touches.contains { $0.timestampMs==ms }, "Neighbor preserved after failed probe")
        }
        try check(after.decisions.filter { $0.value.timestampMs==4633 && $0.value.observedImpulse != nil }.count==1,
                  "Bounded single probe")
        print("PASS: \(checks) observed short-rise contracts")
    }
}
