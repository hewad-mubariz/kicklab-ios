import Foundation

/// Positive evidence for a high knee impact when the supporting foot is below
/// the image. A visible rising knee, a ball rebound and clearance above the
/// opposite hip/knee are mandatory. Missing ankles alone cannot reject it.
/// This establishes eligibility; confirmed hands, holding and ground still veto.
nonisolated enum RaisedKneeReboundRules {
    static func contactTime(_ input: [FootPoseSample], at timestampMs: Int) -> Int? {
        let samples = input.sorted { $0.pose.timestampMs < $1.pose.timestampMs }
        guard (3...9).contains(samples.count),
              Set(samples.map { $0.pose.timestampMs }).count == samples.count,
              samples.contains(where: { $0.pose.timestampMs == timestampMs }),
              samples.allSatisfy({ (-201...201).contains($0.pose.timestampMs-timestampMs)
                  && $0.pose.confidence >= 0.5 }),
              TemporalContactEvidence.supportsBallTrack(samples.map(\.pose)) else { return nil }
        for contact in samples where (0...101).contains(contact.pose.timestampMs-timestampMs) {
            let ball = scaledBall(contact), diameter = max(contact.pose.width*contact.pose.imageAspect, contact.pose.height)
            let radius = diameter/2
            for side in BodySide.allCases {
                guard let knee = point(contact, side.knee, minimum: 0.4),
                      let hip = point(contact, side.opposite.hip, minimum: 0.4),
                      let otherKnee = point(contact, side.opposite.knee, minimum: 0.4),
                      let anchor = shoulders(contact) else { continue }
                let torso = distance(anchor, hip)
                guard (0.08...0.5).contains(torso), radius <= 0.4*torso,
                      knee.y <= hip.y+0.15*torso,
                      otherKnee.y-knee.y >= 0.3*torso,
                      ball.y+radius <= hip.y,
                      ball.y <= knee.y+0.25*radius,
                      // Vision locates the knee joint, not the top of the
                      // kneecap. Allow body-scaled reach, then demand a measured
                      // approach, rising knee and separation across three views.
                      distance(ball,knee) <= radius+0.25*torso else { continue }
                for before in samples where (50...201).contains(contact.pose.timestampMs-before.pose.timestampMs) {
                    for after in samples where (33...151).contains(after.pose.timestampMs-contact.pose.timestampMs)
                        && after.pose.timestampMs-before.pose.timestampMs <= 301 {
                        let views = [before,contact,after]
                        guard TemporalContactEvidence.stableSize(views.map(\.pose)),
                              let a = point(before,side.knee,minimum:0.4),
                              let c = point(after,side.knee,minimum:0.4),
                              let aShoulders = shoulders(before), let cShoulders = shoulders(after),
                              views.filter({ point($0,side.knee,minimum:0.5) != nil }).count >= 1,
                              max(distance(aShoulders,anchor),distance(cShoulders,anchor)) <= 0.2*diameter,
                              (a.y-aShoulders.y)-(knee.y-anchor.y) >= 0.2*diameter,
                              (a.y-aShoulders.y)-(c.y-cShoulders.y) >= 0.15*diameter else { continue }
                        let aBall = scaledBall(before), cBall = scaledBall(after)
                        guard (ball.y-anchor.y)-(aBall.y-aShoulders.y) >= 0.12*diameter,
                              (ball.y-anchor.y)-(cBall.y-cShoulders.y) >= 0.12*diameter,
                              distance(aBall,a)-distance(ball,knee) >= 0.25*diameter,
                              distance(cBall,c)-distance(ball,knee) >= 0.12*diameter else { continue }
                        return contact.pose.timestampMs
                    }
                }
            }
        }
        return nil
    }

    private static func point(_ s: FootPoseSample, _ name: BodyJoint, minimum: Double) -> PosePoint? {
        guard let p = s.landmarks[name], [p.x,p.y,p.confidence].allSatisfy(\.isFinite),
              (0...1).contains(p.x), (0...1).contains(p.y), (minimum...1).contains(p.confidence) else { return nil }
        return .init(x:p.x*s.pose.imageAspect,y:p.y)
    }
    private static func shoulders(_ s: FootPoseSample) -> PosePoint? {
        guard let a = point(s,.leftShoulder,minimum:0.4), let b = point(s,.rightShoulder,minimum:0.4),
              distance(a,b) > 0.02 else { return nil }
        return .init(x:(a.x+b.x)/2,y:(a.y+b.y)/2)
    }
    private static func scaledBall(_ s: FootPoseSample) -> PosePoint {
        .init(x:s.pose.ball.x*s.pose.imageAspect,y:s.pose.ball.y)
    }
    private static func distance(_ a: PosePoint, _ b: PosePoint) -> Double { hypot(a.x-b.x,a.y-b.y) }
}
