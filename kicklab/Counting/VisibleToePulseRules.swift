import Foundation

/// A small toe tap can lift and settle between the broad 100 ms pose samples.
/// Require observed neighbors on BOTH sides of impact to reject a single pose
/// spike, plus foot lift relative to hip/support and two separating releases.
nonisolated enum VisibleToePulseRules {
    typealias Sample = FootContactRules.Sample
    typealias Proof = VisibleForefootContactRules.Proof

    static func proof(_ input: [Sample], proposedMs: Int) -> Proof? {
        let samples=input.filter { abs($0.timestampMs-proposedMs) <= 235 }
            .sorted { $0.timestampMs < $1.timestampMs }
        guard samples.count <= 24, Set(samples.map(\.timestampMs)).count == samples.count else { return nil }
        for b in samples where abs(b.timestampMs-proposedMs) <= 50 && visible(b) {
            let neighbors=samples.filter { (20...40).contains(abs($0.timestampMs-b.timestampMs)) && visible($0) }
            guard neighbors.contains(where: { $0.timestampMs < b.timestampMs }),
                  neighbors.contains(where: { $0.timestampMs > b.timestampMs }) else { continue }
            let before=samples.filter { (65...134).contains(b.timestampMs-$0.timestampMs) && visible($0) }
            let after=samples.filter { (65...167).contains($0.timestampMs-b.timestampMs) && visible($0) }
            for a in before { for c in after { for d in after
                where (25...70).contains(d.timestampMs-c.timestampMs) {
                let views=[a,b,c,d], w=b.width, h=b.height
                guard views.map(\.width).max()! <= 1.35*views.map(\.width).min()!,
                      views.map(\.height).max()! <= 1.35*views.map(\.height).min()!,
                      b.ballY-a.ballY >= 0.35*h,
                      [c,d].allSatisfy({ b.ballY-$0.ballY >= 0.25*h }) else { continue }
                for side in BodySide.allCases {
                    let feet=views.map { $0.ankles[side]! }, support=views.map { $0.ankles[side.opposite]! }
                    guard neighbors.allSatisfy({ s in
                        let foot=s.ankles[side]!
                        return hypot((foot.x-feet[1].x)/w,(foot.y-feet[1].y)/h) <= 0.25
                    }), hypot((b.ballX-feet[1].x)/w,(b.ballY-feet[1].y)/h) <= 0.75,
                        b.ballY-feet[1].y <= 0.5*h,
                        support.map(\.x).max()!-support.map(\.x).min()! <= 0.25*w,
                        support.map(\.y).max()!-support.map(\.y).min()! <= 0.25*h,
                        feet[0].y-feet[1].y >= 0.12*h,
                        (feet[0].y-a.hips[side]!.y)-(feet[1].y-b.hips[side]!.y) >= 0.08*h,
                        (feet[0].y-support[0].y)-(feet[1].y-support[1].y) >= 0.05*h,
                        [c,d].allSatisfy({ s in
                            let foot=s.ankles[side]!, other=s.ankles[side.opposite]!
                            return foot.y-feet[1].y >= 0.12*h
                                && (foot.y-other.y)-(feet[1].y-support[1].y) >= 0.05*h
                                && (b.ballY-feet[1].y)-(s.ballY-foot.y) >= 0.25*h
                        }) else { continue }
                    return .init(side:side,before:a,contact:b,release:c,continuation:d)
                }
            } } }
        }
        return nil
    }

    private static func visible(_ s: Sample) -> Bool {
        [s.ballX,s.ballY,s.width,s.height,s.confidence].allSatisfy(\.isFinite)
            && s.width > 0 && s.height > 0 && (0.7...1).contains(s.confidence)
            && s.ballX-s.width/2 >= 0 && s.ballX+s.width/2 <= 1
            && s.ballY-s.height/2 >= 0 && s.ballY+s.height/2 <= 1
            && BodySide.allCases.allSatisfy { side in
                guard let foot=s.ankles[side],let hip=s.hips[side] else { return false }
                return [foot,hip].allSatisfy {
                    [$0.x,$0.y,$0.confidence].allSatisfy(\.isFinite)
                        && (0...1).contains($0.x) && (0...1).contains($0.y)
                        && (0.5...1).contains($0.confidence)
                } && foot.y > hip.y
            }
    }
}
