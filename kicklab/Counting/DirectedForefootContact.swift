import Foundation

/// A toe can extend beyond the ankle-sized contact circle. Require a directed
/// approach, a visible ankle lift while the ball settles, two release views,
/// and stable opposite support. This never overrides a resolved floor proof.
nonisolated enum DirectedForefootContact {
    static func impact(_ evidence: FootContactEvidence) -> Int? {
        guard let g = evidence.compactGroundEvidence,
              g.contactMs == evidence.candidateTimestampMs,
              !g.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true),
              MeasuredFootImpactRules.resolvedFloorTime(g) == nil else { return nil }
        let views = (g.compactFootSamples ?? g.samples).filter {
            (-134...134).contains($0.timestampMs-g.contactMs)
        }.sorted { $0.timestampMs < $1.timestampMs }
        guard Set(views.map(\.timestampMs)).count == views.count,
              let b = views.first(where: { $0.timestampMs == g.contactMs }),
              let n = views.first(where: { (25...50).contains($0.timestampMs-b.timestampMs) })
        else { return nil }
        let before = views.filter { (65...134).contains(b.timestampMs-$0.timestampMs) }
        let after = views.filter { (65...134).contains($0.timestampMs-b.timestampMs) }
        guard before.count >= 2, after.count >= 2, views.count >= 7,
              zip(views,views.dropFirst()).allSatisfy({ (25...67).contains($1.timestampMs-$0.timestampMs) }),
              views.allSatisfy({ s in
                  [s.ballX,s.ballY,s.width,s.height,s.confidence].allSatisfy(\.isFinite)
                    && s.width > 0 && s.height > 0 && (0.7...1).contains(s.confidence)
                    && s.ballX-s.width/2 >= 0 && s.ballX+s.width/2 <= 1
                    && s.ballY-s.height/2 >= 0 && s.ballY+s.height/2 <= 1
              }), views.map(\.width).max()! <= 1.25*views.map(\.width).min()!,
              views.map(\.height).max()! <= 1.25*views.map(\.height).min()!,
              abs(n.ballY-b.ballY) <= 0.1*b.height,
              before.allSatisfy({ b.ballY-$0.ballY >= 0.2*b.height }),
              after.allSatisfy({ b.ballY-$0.ballY >= 0.15*b.height }) else { return nil }
        func reliable(_ p: PoseLandmark) -> Bool {
            [p.x,p.y,p.confidence].allSatisfy(\.isFinite)
                && (0...1).contains(p.x) && (0...1).contains(p.y) && (0.5...1).contains(p.confidence)
        }
        for side in BodySide.allCases {
            guard views.allSatisfy({ s in
                guard let foot=s.ankles[side], let hip=s.hips[side], let support=s.ankles[side.opposite]
                else { return false }
                return reliable(foot) && reliable(hip) && reliable(support) && foot.y > hip.y
            }) else { continue }
            let foot=b.ankles[side]!, next=n.ankles[side]!
            guard [b,n].allSatisfy({ s in
                let ankle=s.ankles[side]!, support=s.ankles[side.opposite]!
                return s.ballY <= min(ankle.y,support.y)
                    && hypot((s.ballX-ankle.x)/s.width,(s.ballY-ankle.y)/s.height) <= 0.9
            }), foot.y-next.y >= 0.05*b.height,
                // The opposite ankle anchors this short lift. Hip motion can
                // follow the torso while the planted foot remains stationary.
                (foot.y-b.ankles[side.opposite]!.y)-(next.y-n.ankles[side.opposite]!.y)
                    >= 0.05*b.height else { continue }
            let supports=views.map { $0.ankles[side.opposite]! }
            let xs=supports.map(\.x).sorted(), ys=supports.map(\.y).sorted()
            guard supports.allSatisfy({ abs($0.x-xs[xs.count/2]) <= 0.15*b.width
                && abs($0.y-ys[ys.count/2]) <= 0.15*b.height }) else { continue }
            if before.contains(where: { a in
                let old=a.ankles[side]!, hip=a.hips[side]!
                let travel=(foot.x-old.x)/b.width
                let relative=((foot.x-b.hips[side]!.x)-(old.x-hip.x))/b.width
                return abs(travel) >= 0.3 && abs(relative) >= 0.3 && travel*relative > 0
                    && travel*(b.ballX-foot.x) > 0
                    && (abs(a.ballX-old.x)-abs(b.ballX-foot.x))/b.width >= 0.3
            }) { return b.timestampMs }
        }
        return nil
    }
}
