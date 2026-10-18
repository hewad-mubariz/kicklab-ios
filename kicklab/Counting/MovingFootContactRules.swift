import Foundation

/// Positive raised-foot evidence when a side-on pose loses a wrist or a turned
/// foot does not continue along the shin. This supplies body eligibility only;
/// the caller must still apply the ground gates and the hand veto.
nonisolated enum MovingFootContactRules {
    typealias Sample = FootPoseSample
    typealias Point = PosePoint

    static func contactTime(_ input: [Sample], at timestampMs: Int, usePoseContinuity: Bool = true,
                            allowsLiftedFoot: Bool = false) -> Int? {
        // Preserve the strict evidence path. Continuity can only recover a
        // rejected candidate, never move or remove an existing contact.
        if usePoseContinuity, let time = contactTime(input, at: timestampMs,
            usePoseContinuity: false, allowsLiftedFoot: allowsLiftedFoot) { return time }
        let samples = input.sorted { $0.pose.timestampMs < $1.pose.timestampMs }
        guard (3...7).contains(samples.count),
              Set(samples.map { $0.pose.timestampMs }).count == samples.count,
              samples.contains(where: { $0.pose.timestampMs == timestampMs }),
              samples.allSatisfy({ s in
                  let p = s.pose
                  return (-100...150).contains(p.timestampMs-timestampMs)
                    && [p.ball.x,p.ball.y,p.width,p.height,p.confidence,p.imageAspect].allSatisfy(\.isFinite)
                    && (0...1).contains(p.ball.x) && (0...1).contains(p.ball.y)
                    && p.width > 0 && p.width <= 1 && p.height > 0 && p.height <= 1
                    && p.confidence >= 0.5 && p.imageAspect > 0
              }) else { return nil }
        func point(_ sample: Sample, _ name: BodyJoint) -> Point? {
            guard let p = sample.pose.joints[name], [p.x,p.y].allSatisfy(\.isFinite),
                  (0...1).contains(p.x), (0...1).contains(p.y) else { return nil }
            return .init(x: p.x*sample.pose.imageAspect, y: p.y)
        }
        func ankle(_ sample: Sample, _ side: BodySide) -> Point? {
            guard let p = sample.ankles[side], [p.x,p.y,p.confidence].allSatisfy(\.isFinite),
                  (0...1).contains(p.x), (0...1).contains(p.y), (0.1...1).contains(p.confidence) else { return nil }
            let observed = Point(x: p.x*sample.pose.imageAspect, y: p.y)
            if p.confidence >= 0.3 || sample.corroboratedAnkles.contains(side) { return observed }
            guard usePoseContinuity,
                  let before = samples.last(where: { $0.pose.timestampMs < sample.pose.timestampMs && ($0.ankles[side]?.confidence ?? 0) >= 0.5 }),
                  let after = samples.first(where: { $0.pose.timestampMs > sample.pose.timestampMs && ($0.ankles[side]?.confidence ?? 0) >= 0.5 }),
                  let a = ankle(before, side), let c = ankle(after, side),
                  let ah = point(before, side.hip), let h = point(sample, side.hip),
                  let ch = point(after, side.hip) else { return nil }
            let gap = after.pose.timestampMs-before.pose.timestampMs
            guard gap <= 150 else { return nil }
            let fraction = Double(sample.pose.timestampMs-before.pose.timestampMs)/Double(gap)
            let expected = Point(x: h.x+(a.x-ah.x)*(1-fraction)+(c.x-ch.x)*fraction,
                                 y: h.y+(a.y-ah.y)*(1-fraction)+(c.y-ch.y)*fraction)
            let diameter = max(sample.pose.width*sample.pose.imageAspect, sample.pose.height)
            // Keep the actually observed weak ankle, only when two confident
            // views bracket and corroborate it. Never fill a missing ankle.
            return distance(observed, expected) <= 0.25*diameter ? observed : nil
        }
        func ball(_ s: Sample) -> Point { .init(x: s.pose.ball.x*s.pose.imageAspect, y: s.pose.ball.y) }
        func distance(_ a: Point, _ b: Point) -> Double { hypot(a.x-b.x,a.y-b.y) }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted(), middle = sorted.count/2
            return sorted.count.isMultiple(of: 2) ? (sorted[middle-1]+sorted[middle])/2 : sorted[middle]
        }
        func standingKnee(_ sample: Sample, _ side: BodySide) -> Point? {
            let raw = point(sample, side.knee)
            guard usePoseContinuity, let hip = point(sample, side.hip) else { return raw }
            let views = samples.compactMap { view -> (knee: Double, thigh: Double, ankle: Double)? in
                guard abs(view.pose.timestampMs-sample.pose.timestampMs) <= 150,
                      let h = point(view, side.hip), let k = point(view, side.knee),
                      (view.ankles[side]?.confidence ?? 0) >= 0.5, let a = ankle(view, side) else { return nil }
                let thigh = distance(h,k)
                guard thigh > 0.04, thigh < 0.45, k.y-h.y > 0.7*thigh, a.y > k.y+0.03 else { return nil }
                return (k.y-h.y, thigh, a.y-h.y)
            }
            guard views.count >= 3 else { return raw }
            let length = median(views.map(\.thigh))
            guard views.map(\.knee).max()!-views.map(\.knee).min()! <= 0.25*length,
                  views.map(\.ankle).max()!-views.map(\.ankle).min()! <= 0.25*length else { return raw }
            // This reference height is supported by at least three observed,
            // extended-leg poses. One knee jumping up to the ball cannot move it.
            return .init(x: 0, y: hip.y+median(views.map(\.knee)))
        }

        // Smoothing may put the candidate one observation before the impact.
        // Search only already-buffered real views, never an off-camera contact.
        for contact in samples where (0...100).contains(contact.pose.timestampMs-timestampMs) {
            let p = ball(contact), diameter = max(contact.pose.width*contact.pose.imageAspect,contact.pose.height)
            let radius = diameter/2
            for (side,other) in [(BodySide.left, BodySide.right), (.right, .left)] {
                guard let hip = point(contact, side.hip), let knee = point(contact, side.knee),
                      let standingKnee = standingKnee(contact, other), let foot = ankle(contact, side) else { continue }
                let shin = distance(knee,foot), near = distance(p,foot)
                let kneeHigh = foot.y <= standingKnee.y+0.25*shin
                // This is a raised-leg exception, never evidence for a low
                // floor bounce. Toes can project sideways from the ankle.
                guard shin > 0.04, shin < 0.45, radius <= 0.8*shin,
                      knee.y < standingKnee.y-0.15*shin, kneeHigh || allowsLiftedFoot,
                      p.y+radius >= hip.y, p.y <= foot.y+0.25*radius,
                      near <= min(radius+0.45*shin,1.2*diameter) else { continue }
                for before in samples where (50...130).contains(contact.pose.timestampMs-before.pose.timestampMs) {
                    for after in samples where (25...130).contains(after.pose.timestampMs-contact.pose.timestampMs)
                        && after.pose.timestampMs-before.pose.timestampMs <= 230 {
                        guard let ah = point(before, side.hip), let ch = point(after, side.hip),
                              let af = ankle(before, side), let cf = ankle(after, side) else { continue }
                        let views = [before,contact,after]
                        if !kneeHigh {
                            // A kick can lift the foot clear of the floor while
                            // staying below the supporting knee. Require a
                            // confident, stable supporting ankle in all three
                            // views, plus visible clearance of foot AND ball.
                            let supports = views.compactMap { view -> (foot: Point, hip: Point)? in
                                guard (view.ankles[other]?.confidence ?? 0) >= 0.5,
                                      let a = ankle(view, other), let h = point(view, other.hip) else { return nil }
                                return (a,h)
                            }
                            guard supports.count == 3,
                                  foot.y <= supports[1].foot.y-0.6*diameter,
                                  p.y+radius <= supports[1].foot.y-0.25*diameter else { continue }
                            let heights = supports.map { $0.foot.y-$0.hip.y }
                            guard heights.max()!-heights.min()! <= 0.2*diameter else { continue }
                        }
                        guard views.filter({ ($0.ankles[side]?.confidence ?? 0) >= 0.5 }).count >= 2,
                              views.map({ $0.pose.width }).max()! <= 1.35*views.map({ $0.pose.width }).min()!,
                              views.map({ $0.pose.height }).max()! <= 1.35*views.map({ $0.pose.height }).min()!,
                              max(distance(ah,hip),distance(ah,ch)) <= 0.35*diameter else { continue }
                        // Observed motion relative to the hip must persist
                        // after impact; a single jittering ankle cannot qualify.
                        let rise = (af.y-ah.y)-(foot.y-hip.y)
                        guard rise >= 0.2*diameter, rise <= 2*diameter,
                              (af.y-ah.y)-(cf.y-ch.y) >= 0.15*diameter else { continue }
                        let a = ball(before), c = ball(after)
                        // Both the raw ball reversal and approach/separation
                        // from the SAME moving foot must be resolved.
                        guard (p.y-hip.y)-(a.y-ah.y) >= 0.12*diameter,
                              (p.y-hip.y)-(c.y-ch.y) >= 0.12*diameter,
                              distance(a,af)-near >= 0.25*diameter,
                              distance(c,cf)-near >= 0.12*diameter else { continue }
                        return contact.pose.timestampMs
                    }
                }
            }
        }
        return nil
    }
}
