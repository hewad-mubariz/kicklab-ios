import Foundation

/// A turned foot can hide its ankle behind the ball at impact. Recover only a
/// measured raised-leg rebound bracketed by reliable moving-ankle observations.
/// This supplies body eligibility, never an exemption from hand/holding/floor checks.
nonisolated enum RaisedFootReboundRules {
    typealias Sample = FootPoseSample
    typealias Point = PosePoint

    static func contactTime(_ input: [Sample], at timestampMs: Int) -> Int? {
        let samples = input.sorted { $0.pose.timestampMs < $1.pose.timestampMs }
        guard (3...9).contains(samples.count),
              Set(samples.map { $0.pose.timestampMs }).count == samples.count,
              samples.contains(where: { $0.pose.timestampMs == timestampMs }),
              samples.allSatisfy({ (-201...201).contains($0.pose.timestampMs-timestampMs) }),
              TemporalContactEvidence.supportsBallTrack(samples.map(\.pose)) else { return nil }
        for contact in samples where (0...101).contains(contact.pose.timestampMs-timestampMs) {
            let p = ball(contact), diameter = max(contact.pose.height, contact.pose.width*contact.pose.imageAspect)
            let radius = diameter/2
            for side in BodySide.allCases {
                guard let hip = point(contact, side.hip),
                      let otherHip = point(contact, side.opposite.hip),
                      let otherKnee = point(contact, side.opposite.knee) else { continue }
                let scale = distance(otherHip, otherKnee)
                guard (0.05...0.4).contains(scale), otherKnee.y-otherHip.y >= 0.65*scale,
                      radius <= 0.65*scale, p.y+radius >= min(hip.y,otherHip.y),
                      p.y+radius <= otherKnee.y+0.1*scale else { continue }
                for before in samples where (50...201).contains(contact.pose.timestampMs-before.pose.timestampMs) {
                    for after in samples where (33...151).contains(after.pose.timestampMs-contact.pose.timestampMs)
                        && after.pose.timestampMs-before.pose.timestampMs <= 301 {
                        let views = [before,contact,after]
                        guard TemporalContactEvidence.stableSize(views.map(\.pose)),
                              let aHip = point(before,side.hip), let cHip = point(after,side.hip),
                              let a = point(before,side.ankle,minimum:0.4),
                              let c = point(after,side.ankle,minimum:0.4),
                              let aKnee = point(before,side.knee), let cKnee = point(after,side.knee),
                              max(distance(aHip,hip),distance(cHip,hip)) <= 0.35*diameter,
                              stableSupport(views,side:side.opposite,diameter:diameter),
                              (a.y-aHip.y)-(c.y-cHip.y) >= 0.1*scale,
                              c.y <= otherKnee.y+0.35*scale,
                              cKnee.y <= otherKnee.y-0.4*scale,
                              abs(cKnee.x-cHip.x) >= 0.2*scale,
                              (0.35...1.8).contains(distance(a,aKnee)/scale),
                              (0.35...1.8).contains(distance(c,cKnee)/scale) else { continue }
                        let aBall = ball(before), cBall = ball(after)
                        guard (p.y-hip.y)-(aBall.y-aHip.y) >= 0.12*diameter,
                              (p.y-hip.y)-(cBall.y-cHip.y) >= 0.12*diameter else { continue }
                        // Use a measured ankle when it agrees with the leg.
                        // Otherwise bridge only an occluded/weak impact between
                        // two observed raised-leg positions, relative to the hip.
                        // Never replace a confident contradictory ankle.
                        var feet: [Point] = []
                        if let foot = point(contact,side.ankle,minimum:0.1),
                           let knee = point(contact,side.knee,minimum:0.2),
                           (0.35...1.8).contains(distance(foot,knee)/scale) { feet.append(foot) }
                        if (contact.landmarks[side.ankle]?.confidence ?? 0) < 0.5,
                           (aKnee.y-aHip.y)-(cKnee.y-cHip.y) >= 0.08*scale {
                            let fraction = Double(contact.pose.timestampMs-before.pose.timestampMs)
                                / Double(after.pose.timestampMs-before.pose.timestampMs)
                            feet.append(.init(x:hip.x+(a.x-aHip.x)*(1-fraction)+(c.x-cHip.x)*fraction,
                                              y:hip.y+(a.y-aHip.y)*(1-fraction)+(c.y-cHip.y)*fraction))
                        }
                        guard feet.contains(where: { foot in
                            foot.y <= otherKnee.y+0.35*scale && p.y <= foot.y+0.25*radius
                                && distance(p,foot) <= radius+0.65*scale
                                && (a.y-aHip.y)-(foot.y-hip.y) >= 0.06*scale
                                && distance(aBall,a)-distance(p,foot) >= 0.25*diameter
                                && distance(cBall,c)-distance(p,foot) >= 0.12*diameter
                        }) else { continue }
                        return contact.pose.timestampMs
                    }
                }
            }
        }
        return nil
    }

    private static func stableSupport(_ views: [Sample], side: BodySide, diameter: Double) -> Bool {
        let offsets = views.compactMap { s -> Point? in
            guard let hip = point(s,side.hip), let knee = point(s,side.knee) else { return nil }
            return .init(x:knee.x-hip.x,y:knee.y-hip.y)
        }
        return offsets.count == views.count && offsets.allSatisfy { a in
            offsets.allSatisfy { distance(a,$0) <= 0.3*diameter }
        }
    }
    private static func point(_ s: Sample, _ name: BodyJoint, minimum: Double = 0.3) -> Point? {
        guard let p = s.landmarks[name], [p.x,p.y,p.confidence].allSatisfy(\.isFinite),
              (0...1).contains(p.x), (0...1).contains(p.y), (minimum...1).contains(p.confidence) else { return nil }
        return .init(x:p.x*s.pose.imageAspect,y:p.y)
    }
    private static func ball(_ s: Sample) -> Point { .init(x:s.pose.ball.x*s.pose.imageAspect,y:s.pose.ball.y) }
    private static func distance(_ a: Point, _ b: Point) -> Double { hypot(a.x-b.x,a.y-b.y) }
}
