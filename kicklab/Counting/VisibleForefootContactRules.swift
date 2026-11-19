import Foundation

/// A forefoot may extend beyond the ankle landmark and rotate with little
/// vertical ankle travel. Require directed foot approach, braking at contact,
/// stable support and two real ball departures. Proximity alone cannot pass.
nonisolated enum VisibleForefootContactRules {
    typealias Sample = FootContactRules.Sample
    struct Proof: Equatable, Sendable {
        let side: BodySide
        let before, contact, release, continuation: Sample
    }

    static func proof(_ input: [Sample], proposedMs: Int, observesToes: Bool = false) -> Proof? {
        let samples = input.filter { abs($0.timestampMs-proposedMs) <= 235 }
            .sorted { $0.timestampMs < $1.timestampMs }
        guard samples.count <= 24, Set(samples.map(\.timestampMs)).count == samples.count else { return nil }
        let impacts = samples.filter { abs($0.timestampMs-proposedMs) <= 50 }.sorted {
            let a=abs($0.timestampMs-proposedMs), b=abs($1.timestampMs-proposedMs)
            return a == b ? $0.timestampMs < $1.timestampMs : a < b
        }
        for contact in impacts {
            let before = samples.filter { (65...134).contains(contact.timestampMs-$0.timestampMs) }
            let after = samples.filter { (65...167).contains($0.timestampMs-contact.timestampMs) }
            for a in before { for c in after { for d in after
                where (25...70).contains(d.timestampMs-c.timestampMs) {
                for side in BodySide.allCases {
                    let value = Proof(side:side,before:a,contact:contact,release:c,continuation:d)
                    if confirms(value, observesToes: observesToes) { return value }
                }
            } } }
        }
        return nil
    }

    static func confirms(_ p: Proof, observesToes: Bool = false) -> Bool {
        let a=p.before, b=p.contact, c=p.release, d=p.continuation, side=p.side
        let views=[a,b,c,d], w=b.width, h=b.height
        guard (65...134).contains(b.timestampMs-a.timestampMs),
              (65...167).contains(c.timestampMs-b.timestampMs),
              (65...167).contains(d.timestampMs-b.timestampMs),
              (25...70).contains(d.timestampMs-c.timestampMs),
              views.allSatisfy(visible),
              views.map(\.width).max()! <= 1.35*views.map(\.width).min()!,
              views.map(\.height).max()! <= 1.35*views.map(\.height).min()!,
              b.ballY-a.ballY >= 0.35*h,
              [c,d].allSatisfy({ b.ballY-$0.ballY >= 0.2*h }) else { return false }
        let feet=views.map { $0.ankles[side]! }, support=views.map { $0.ankles[side.opposite]! }
        guard support.map(\.x).max()!-support.map(\.x).min()! <= 0.25*w,
              support.map(\.y).max()!-support.map(\.y).min()! <= 0.25*h else { return false }
        let near=hypot((b.ballX-feet[1].x)/w,(b.ballY-feet[1].y)/h)
        guard near <= 1.1, b.ballY-feet[1].y <= 0.5*h else { return false }
        let incoming=(feet[1].x-feet[0].x)/w
        let relative=((feet[1].x-b.hips[side]!.x)-(feet[0].x-a.hips[side]!.x))/w
        // An ankle approaches the forefoot contact region from outside it.
        // A directly observed TOE can already overlap the ball's central disk
        // at impact, having crossed its centre between exposures. It must have
        // approached that point from the correct side and still satisfy all
        // braking, support, ball approach and two-release requirements below.
        let arrivedInsideBall = observesToes && near <= 0.5
            && incoming*(b.ballX-feet[0].x) > 0
        guard abs(incoming) >= 0.12, abs(relative) >= 0.12,
              incoming*relative > 0,
              incoming*(b.ballX-feet[1].x) > 0 || arrivedInsideBall else { return false }
        let outgoing=(feet[2].x-feet[1].x)/w
        // A foot chasing a ball after a floor rebound must not supply contact.
        if outgoing*incoming > 0,
           abs(outgoing)/Double(c.timestampMs-b.timestampMs)
            > 0.6*abs(incoming)/Double(b.timestampMs-a.timestampMs) { return false }
        guard hypot((a.ballX-feet[0].x)/w,(a.ballY-feet[0].y)/h)-near >= 0.25,
              [c,d].allSatisfy({ s in
                  ((b.ballY-feet[1].y)-(s.ballY-s.ankles[side]!.y))/h >= 0.2
              }) else { return false }
        return true
    }

    private static func visible(_ s: Sample) -> Bool {
        [s.ballX,s.ballY,s.width,s.height,s.confidence].allSatisfy(\.isFinite)
            && s.width > 0 && s.height > 0 && (0.7...1).contains(s.confidence)
            && s.ballX-s.width/2 >= 0 && s.ballX+s.width/2 <= 1
            && s.ballY-s.height/2 >= 0 && s.ballY+s.height/2 <= 1
            && BodySide.allCases.allSatisfy { side in
                guard let foot=s.ankles[side], let hip=s.hips[side] else { return false }
                return [foot,hip].allSatisfy {
                    [$0.x,$0.y,$0.confidence].allSatisfy(\.isFinite)
                        && (0...1).contains($0.x) && (0...1).contains($0.y)
                        && (0.5...1).contains($0.confidence)
                } && foot.y > hip.y
            }
    }
}

nonisolated enum VisibleFootRecoveryPolicy {
    static func signature(arguments: [String]) -> String {
        enabled(arguments:arguments) ? "|visible-forefoot-recovery-v1"
            + (toePulse(arguments:arguments) ? "|visible-toe-pulse-v1" : "") : ""
    }
    static func enabled(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--visible-foot-recovery-v1") || toePulse(arguments:arguments)
        #else
        return false
        #endif
    }
    static func toePulse(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--visible-foot-recovery-v2")
        #else
        return false
        #endif
    }
}
