import Foundation

/// Eligibility across a short detector hole using the two actual exposures
/// that bracket it. No ball position or body landmark is interpolated. The
/// caller must still check ground, hands and holding at these observed views.
nonisolated enum ObservedGapContactRules {
    static func contactTime(_ samples: [FootPoseSample], at time: Int) -> Int? {
        guard let before = samples.filter({ $0.pose.timestampMs < time })
            .max(by: { $0.pose.timestampMs < $1.pose.timestampMs }),
              let after = samples.filter({ $0.pose.timestampMs > time })
            .min(by: { $0.pose.timestampMs < $1.pose.timestampMs }),
              time-before.pose.timestampMs <= 133, after.pose.timestampMs-time <= 100,
              after.pose.timestampMs-before.pose.timestampMs <= 200 else { return nil }
        let views = [before,after]
        guard views.allSatisfy({ s in
            let p = s.pose
            return [p.width,p.height,p.confidence,p.imageAspect].allSatisfy(\.isFinite)
                && p.confidence >= 0.4 && p.width > 0 && p.height > 0 && p.imageAspect > 0
        }),
              abs(before.pose.imageAspect-after.pose.imageAspect) < 0.001,
              max(before.pose.width,after.pose.width) <= 1.6*min(before.pose.width,after.pose.width),
              max(before.pose.height,after.pose.height) <= 1.6*min(before.pose.height,after.pose.height) else { return nil }
        let regions = views.compactMap { s in
            RestrictedTouchPolicy.region(ball: s.pose.ball,width: s.pose.width,height: s.pose.height,
                joints: s.pose.joints,imageAspect: s.pose.imageAspect)
        }
        guard regions.count == 2, regions.contains(.foot),
              regions.allSatisfy({ $0 == .foot || $0 == .knee }) else { return nil }
        let diameter = max(after.pose.width*after.pose.imageAspect,after.pose.height)
        // A low bounce cannot qualify by merely passing near an ankle. Both
        // observed ball centers must remain above the visible ankle line.
        for s in views {
            let ankles = BodySide.allCases.compactMap { s.landmarks[$0.ankle] }
            guard ankles.count == 2, ankles.allSatisfy({ usable($0) }),
                  s.pose.ball.y < ankles.map(\.y).max()! else { return nil }
        }
        // Require a measured foot lifting relative to its hip across the hole.
        // Whole-person translation and a stationary foot do not establish this.
        for side in BodySide.allCases {
            guard let a = before.landmarks[side.ankle], let b = after.landmarks[side.ankle],
                  let ah = before.landmarks[side.hip], let bh = after.landmarks[side.hip],
                  [a,b,ah,bh].allSatisfy({ usable($0) }), max(a.confidence,b.confidence) >= 0.5,
                  hypot((bh.x-ah.x)*after.pose.imageAspect,bh.y-ah.y) <= 0.35*diameter else { continue }
            let lift = (a.y-ah.y)-(b.y-bh.y)
            if a.y-b.y >= 0.1*diameter && lift >= 0.1*diameter && lift <= 1.5*diameter {
                return after.pose.timestampMs
            }
        }
        return nil
    }

    private static func usable(_ p: PoseLandmark) -> Bool {
        [p.x,p.y,p.confidence].allSatisfy(\.isFinite)
            && (0...1).contains(p.x) && (0...1).contains(p.y) && (0.3...1).contains(p.confidence)
    }
}
