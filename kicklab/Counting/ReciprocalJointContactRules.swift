import Foundation

/// A single-frame reciprocal wrist/ankle exchange can be checked against the
/// observed limb paths on BOTH sides. Raw pose is never changed or interpolated.
/// Missing landmarks alone, wrist proximity alone and a ball rebound alone do
/// not establish a leg contact. Independent hand/holding vetoes still follow.
nonisolated enum ReciprocalJointContactRules {
    static func contactTime(_ samples: [FootPoseSample], at time: Int) -> Int? {
        let views = samples.sorted { $0.pose.timestampMs < $1.pose.timestampMs }
        guard (7...10).contains(views.count),
              Set(views.map { $0.pose.timestampMs }).count == views.count,
              views.allSatisfy({ (-200...150).contains($0.pose.timestampMs-time) }),
              zip(views,views.dropFirst()).allSatisfy({ (1...100).contains($1.pose.timestampMs-$0.pose.timestampMs) }),
              TemporalContactEvidence.supportsBallTrack(views.map(\.pose)),
              TemporalContactEvidence.stableSize(views.map(\.pose)),
              let contact = views.first(where: { $0.pose.timestampMs == time }) else { return nil }
        let aspect = contact.pose.imageAspect
        let scale = max(contact.pose.width*aspect, contact.pose.height)
        guard scale.isFinite, scale > 0 else { return nil }
        func point(_ view: FootPoseSample, _ joint: BodyJoint, _ confidence: Double) -> PosePoint? {
            guard let p = view.landmarks[joint],
                  [p.x,p.y,p.confidence].allSatisfy(\.isFinite), p.confidence >= confidence,
                  (0...1).contains(p.x), (0...1).contains(p.y) else { return nil }
            return .init(x: p.x*aspect, y: p.y)
        }
        func distance(_ a: PosePoint, _ b: PosePoint) -> Double { hypot(a.x-b.x,a.y-b.y) }
        func ball(_ view: FootPoseSample) -> PosePoint { .init(x: view.pose.ball.x*aspect, y: view.pose.ball.y) }
        for side in BodySide.allCases {
            guard let exchangedFoot = point(contact,side.wrist,0.5),
                  let exchangedHand = point(contact,side.ankle,0.1),
                  let ankleConfidence = contact.landmarks[side.ankle]?.confidence, ankleConfidence < 0.35,
                  let hip = point(contact,side.hip,0.3),
                  let support = point(contact,side.opposite.ankle,0.5) else { continue }
            let before = views.filter { (-200 ... -50).contains($0.pose.timestampMs-time)
                && point($0,side.ankle,0.5) != nil && point($0,side.wrist,0.6) != nil }
            let after = views.filter { (67...150).contains($0.pose.timestampMs-time)
                && point($0,side.ankle,0.5) != nil && point($0,side.wrist,0.6) != nil }
            guard before.count >= 2, after.count >= 2,
                  let a = before.last, let c = after.first,
                  time-a.pose.timestampMs <= 100, c.pose.timestampMs-time <= 100,
                  let aFoot = point(a,side.ankle,0.5), let cFoot = point(c,side.ankle,0.5),
                  let aHand = point(a,side.wrist,0.6), let cHand = point(c,side.wrist,0.6),
                  let aHip = point(a,side.hip,0.3), let cHip = point(c,side.hip,0.3) else { continue }
            // The low-confidence "ankle" lands on a stable hand path, while
            // the "wrist" follows a foot that rises into impact and recoils.
            guard distance(aHand,cHand) <= 0.25*scale,
                  distance(exchangedHand,aHand) <= 0.25*scale,
                  distance(exchangedHand,cHand) <= 0.25*scale,
                  distance(exchangedFoot,aHand) >= 0.7*scale,
                  distance(exchangedFoot,cHand) >= 0.7*scale,
                  abs(exchangedFoot.x-aFoot.x) <= 0.35*scale,
                  abs(exchangedFoot.x-cFoot.x) <= 0.35*scale,
                  (0.3*scale...1.5*scale).contains(aFoot.y-exchangedFoot.y),
                  (0.2*scale...1.2*scale).contains(cFoot.y-exchangedFoot.y),
                  distance(aHip,hip) <= 0.35*scale, distance(cHip,hip) <= 0.35*scale,
                  exchangedFoot.y < support.y-0.75*scale,
                  abs(exchangedFoot.y-hip.y) <= 0.75*scale else { continue }
            let p = ball(contact)
            guard distance(p,exchangedFoot) <= 0.65*scale,
                  p.y <= exchangedFoot.y, p.y+scale/2 < support.y-0.5*scale,
                  p.y-ball(a).y >= 0.2*scale, p.y-ball(c).y >= 0.2*scale,
                  distance(ball(a),aFoot)-distance(p,exchangedFoot) >= 0.3*scale,
                  distance(ball(c),cFoot)-distance(p,exchangedFoot) >= 0.3*scale else { continue }
            let local = views.filter { abs($0.pose.timestampMs-time) <= 100 }
            guard local.allSatisfy({ view in
                guard let otherHand = point(view,side.opposite.wrist,0.6),
                      let foot = point(view,side.opposite.ankle,0.5) else { return false }
                return distance(otherHand,ball(view)) > 0.65*scale && distance(foot,support) <= 0.2*scale
            }) else { continue }
            return time
        }
        return nil
    }
}
