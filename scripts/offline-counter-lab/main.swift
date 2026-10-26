import Foundation

/// Offline counter lab: evaluate saved counter traces with the production
/// counting sources on macOS. Numeric evidence only; no Vision, no detector.
///
///   counterlab ground  <trace> <frame>...        print saved ground evidence and the rule verdicts
///   counterlab hand    <trace> <frame>...        print saved handling (wrist) evidence and the grip verdict
///   counterlab list    <trace> [accepted|rejected] list every decision with its reason
///   counterlab replay  [--v18] [--v19] [--grip-v2] [--gap-gate] <trace>...   replay saved traces, optionally with new evidence flags
@main struct CounterLab {
    static func load(_ path: String) throws -> CounterTrace {
        let url = URL(fileURLWithPath: path)
        if url.pathExtension == "json" {
            struct Archive: Decodable { let trace: CounterTrace }
            return try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url)).trace
        }
        return try PropertyListDecoder().decode(CounterTrace.self, from: Data(contentsOf: url))
    }
    static func f(_ v: Double?, _ digits: Int = 3) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "nil" }

    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { print("usage: counterlab ground|hand|list|replay ..."); return }
        args.removeFirst()
        switch command {
        case "list": try list(args)
        case "ground": try ground(args)
        case "hand": try hand(args)
        case "replay": try replay(args)
        default: print("unknown command \(command)")
        }
    }

    static func list(_ args: [String]) throws {
        let trace = try load(args[0])
        let filter = args.count > 1 ? args[1] : nil
        for row in trace.decisions {
            let d = row.value
            let accepted = d.rejection == nil
            if filter == "accepted" && !accepted { continue }
            if filter == "rejected" && accepted { continue }
            print("frame \(d.frameIndex) t=\(d.timestampMs)ms \(accepted ? "ACCEPTED" : String(describing: d.rejection!))"
                + " body=\(d.bodyContactAllowed.map(String.init) ?? "-") hand=\(d.handRejected.map(String.init) ?? "-")"
                + " foot=\(d.footConfirmed.map(String.init) ?? "-") planted=\(d.plantedFeetConfirmed.map(String.init) ?? "-")"
                + " handling=\(d.handlingEvidence?.state.rawValue ?? "-")")
        }
        print("\(trace.touches.count) touches, \(trace.decisions.count) decisions")
    }

    static func ground(_ args: [String]) throws {
        let trace = try load(args[0])
        let frames = args.dropFirst().compactMap { Int($0) }
        for row in trace.decisions where frames.contains(row.value.frameIndex) {
            let d = row.value
            print("=== frame \(d.frameIndex) t=\(d.timestampMs) \(d.rejection.map { String(describing: $0) } ?? "ACCEPTED")"
                + " body=\(String(describing: d.bodyContactAllowed)) hand=\(String(describing: d.handRejected))"
                + " foot=\(String(describing: d.footConfirmed)) planted=\(String(describing: d.plantedFeetConfirmed))")
            print(" floor line=\(f(d.ground)) observed ball bottom=\(f(d.observedBallBottom)) fall=\(f(d.fall)) rise=\(f(d.rise)) impulse=\(f(d.impulse))")
            guard let g = d.groundEvidence else { print(" (no ground evidence saved: the candidate never reached the floor checks)"); continue }
            print(" saved flags: belowFeet=\(String(describing: g.checksBallBelowFeet)) lowCenter=\(String(describing: g.requiresLowBallCenter)) localSize=\(String(describing: g.usesLocalImpactSize)) positiveLow=\(String(describing: g.requiresPositiveLowContact)) gap=\(String(describing: g.toleratesApproachGap)) beside=\(String(describing: g.checksBallBesideFeet))")
            var v18 = g; v18.toleratesApproachGap = true; v18.checksBallBesideFeet = true
            print(" verdicts: ground=\(g.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true)) planted=\(g.confirmsPlantedFeet(corroboratingWeakAnkles: true)) belowFeet=\(g.confirmsBallBelowFeet) | with V18 flags: belowFeet=\(v18.confirmsBallBelowFeet) besideFeet=\(v18.confirmsBallBesideFeet)")
            let s = g.samples.sorted { $0.timestampMs < $1.timestampMs }
            let scale = s.map(\.height).sorted()[s.count/2]
            print(" \(s.count) views, ball height \(f(scale, 4)) (all distances below are in ball heights)")
            for v in s {
                func j(_ p: PoseLandmark?) -> String { p.map { String(format: "(%.3f,%.3f c%.2f)", $0.x, $0.y, $0.confidence) } ?? "missing" }
                let la = v.ankles[.left], ra = v.ankles[.right]
                let lowest = max(la?.y ?? -1, ra?.y ?? -1)
                let strong = v.confidence >= 0.5 && [la, ra, v.hips[.left], v.hips[.right]].allSatisfy { ($0?.confidence ?? 0) >= 0.5 }
                print(String(format: "  %+5d ms ball(%.3f,%.3f) bottom=%.3f | ankleL %@ ankleR %@ | %@ | ball bottom vs lowest ankle %+.2f",
                    v.timestampMs-g.contactMs, v.ballX, v.ballY, v.ballY+v.height/2, j(la), j(ra), strong ? "confident" : "WEAK", ((v.ballY+v.height/2)-lowest)/scale))
            }
        }
    }

    static func hand(_ args: [String]) throws {
        let trace = try load(args[0])
        let frames = args.dropFirst().compactMap { Int($0) }
        for row in trace.decisions where frames.contains(row.value.frameIndex) {
            let d = row.value
            print("=== frame \(d.frameIndex) t=\(d.timestampMs) \(d.rejection.map { String(describing: $0) } ?? "ACCEPTED") body=\(String(describing: d.bodyContactAllowed)) handVeto=\(String(describing: d.handRejected))")
            guard let h = d.handlingEvidence else { print(" (no handling evidence saved: the candidate never reached the holding check)"); continue }
            var v2 = h; v2.bridgesGripJitter = true
            print(" holding verdict: saved=\(h.state.rawValue) | with V16 grip bridge: \(v2.state.rawValue) | observedImpact=\(String(describing: h.observedImpactMs))")
            let s = h.samples.sorted { $0.timestampMs < $1.timestampMs }
            print(" \(s.count) views (wrist offsets are from the ball center, in ball diameters; |d|<=1.15 is a grip wrist)")
            for v in s {
                let dia = max(v.width*v.imageAspect, v.height)
                func w(_ p: PoseLandmark?) -> String {
                    guard let p else { return "missing" }
                    let dx = (p.x-v.ball.x)*v.imageAspect/dia, dy = (p.y-v.ball.y)/dia
                    return String(format: "dx%+.2f dy%+.2f |d|%.2f c%.2f", dx, dy, hypot(dx, dy), p.confidence)
                }
                print(String(format: "  %+5d ms ball(%.3f,%.3f) h=%.3f | L %@ | R %@", v.timestampMs-h.contactMs, v.ball.x, v.ball.y, v.height, w(v.wrists[.left]), w(v.wrists[.right])))
            }
        }
    }

    static func replay(_ args: [String]) throws {
        let v18 = args.contains("--v18") || args.contains("--v19"), v19 = args.contains("--v19"), grip = args.contains("--grip-v2"), gapGate = args.contains("--gap-gate") || args.contains("--gap-gate-wide"), wideGate = args.contains("--gap-gate-wide")
        for path in args where !path.hasPrefix("--") {
            let trace = try load(path)
            let base = run(trace, v18: false, v19: false, grip: false, gapGate: false, wideGate: false)
            let after = run(trace, v18: v18, v19: v19, grip: grip, gapGate: gapGate, wideGate: wideGate)
            let lost = Set(base.touches.map(\.frameIndex)).subtracting(after.touches.map(\.frameIndex)).sorted()
            let added = Set(after.touches.map(\.frameIndex)).subtracting(base.touches.map(\.frameIndex)).sorted()
            let reasons = lost.map { fr in "\(fr):\(after.decisions.first { $0.frameIndex == fr }?.rejection.map { String(describing: $0) } ?? "?")" }
            print("\(URL(fileURLWithPath: path).lastPathComponent): saved=\(trace.touches.count) replay=\(base.touches.count) exact=\(base.touches == trace.touches) after=\(after.touches.count) lost=\(reasons) added=\(added)")
        }
    }

    /// Saved evidence keyed by (operation, frame): a changed verdict earlier in
    /// the clip must not shift which record a later candidate reads.
    static func run(_ trace: CounterTrace, v18: Bool, v19: Bool, grip: Bool, gapGate: Bool, wideGate: Bool) -> (touches: [Touch], decisions: [CounterDecision]) {
        func find<T>(_ rows: [CounterTrace.Decision], _ op: Int, _ frame: Int, _ f: (CounterDecision) -> T) -> T? {
            rows.first { $0.operation == op && $0.value.frameIndex == frame }.map { f($0.value) }
        }
        var op = -1
        // The V17 gap gate from the trace inputs alone: every analysed input is
        // an original exposure here (no rechecked images in a compact-tier trace).
        let inputs = trace.operations.compactMap(\.input)
        // The verifier's "original timestamps" are the stored contact frames,
        // which exist only for inputs that carried a ball.
        let inputTimes = inputs.filter { $0.ball != nil }.map(\.timestampMs)
        let missingTimes = inputs.filter { $0.ball == nil }.map(\.timestampMs)
        let hand = trace.decisions.filter { $0.value.handRejected != nil }
        let foot = trace.decisions.filter { $0.value.footConfirmed != nil }
        let body = trace.decisions.filter { $0.value.bodyContactAllowed != nil }
        let ground = trace.decisions.filter { $0.value.plantedFeetConfirmed != nil }
        let handling = trace.decisions.filter { $0.value.handlingChecked == true }
        let counter = StreamingCounter(config: trace.config,
            rejectsHandContact: trace.usesHandVerifier ? { find(hand, op, $0) { $0.handRejected! } ?? false } : nil,
            recordTrace: true, traceLimit: max(1, trace.operations.count),
            footContactEvidence: trace.usesFootVerifier ? { find(foot, op, $0) { $0.footEvidence } ?? nil } : nil,
            allowsBodyContact: trace.usesBodyVerifier == true ? { find(body, op, $0) { $0.bodyContactAllowed! } ?? false } : nil,
            groundPolicy: .corroboratedFeet,
            groundContactEvidence: trace.usesGroundVerifier == true ? { frame in
                find(ground, op, frame) { d -> GroundContactEvidence? in
                    guard var g = d.groundEvidence else { return nil }
                    if v18 { g.toleratesApproachGap = true; g.checksBallBesideFeet = true }
                    if v19 { g.toleratesPlantedApproachGap = true; g.requiresMovingAnkleForRescue = true; g.allowsStationaryHole = true; g.checksDeepFloorContact = true }
                    if gapGate {
                        let gap = wideGate
                            ? GroundContactEvidence.hasImpactTrackingGap(contactMs: g.contactMs, originalTimestampsMs: inputTimes,
                                missingBallTimestampsMs: missingTimes, approachMs: 134)
                            : GroundContactEvidence.hasImpactTrackingGap(contactMs: g.contactMs, originalTimestampsMs: inputTimes,
                                missingBallTimestampsMs: missingTimes)
                        g.requiresPositiveLowContact = gap ? true : nil
                    }
                    return g
                } ?? nil } : nil,
            handlingEvidence: trace.usesHandlingVerifier == true ? { frame in
                find(handling, op, frame) { d -> BallHandlingEvidence? in
                    guard var h = d.handlingEvidence else { return nil }
                    if grip { h.bridgesGripJitter = true }
                    return h
                } ?? nil } : nil)
        for (i, o) in trace.operations.enumerated() {
            op = i
            if o.flush { counter.flush() } else if let input = o.input {
                counter.push(frameIndex: input.frameIndex, timestampMs: input.timestampMs, ball: input.ball, person: input.person,
                    cameraOffsetY: input.cameraOffsetY, reliable: input.reliable, sourceFrameIndex: input.sourceFrameIndex, player: input.player)
            }
        }
        return (counter.touches, counter.traceSnapshot()?.decisions.map(\.value) ?? [])
    }
}
