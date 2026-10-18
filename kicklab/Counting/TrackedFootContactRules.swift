import Foundation

/// Pixel motion can corroborate a foot whose pose disappears at impact. It is
/// separate from raw pose: no inferred ankle is inserted into Vision landmarks.
nonisolated enum TrackedFootContactRules {
    private typealias Point = PosePoint

    struct Plan {
        let side: BodySide
        let seedMs: Int
        let seed: PosePoint
        let shin: Double
    }
    struct Observation: Codable, Sendable {
        let timestampMs: Int
        let point: PosePoint
        let roundTripError: Double
        let spread: Double
        let retainedPoints: Int
    }

    static func plan(_ samples: [FootPoseSample], at time: Int) -> Plan? {
        let sorted = samples.sorted { $0.pose.timestampMs < $1.pose.timestampMs }
        guard (5...7).contains(sorted.count),
              Set(sorted.map { $0.pose.timestampMs }).count == sorted.count,
              sorted.allSatisfy({ (-200...120).contains($0.pose.timestampMs-time) }),
              zip(sorted,sorted.dropFirst()).allSatisfy({ (1...85).contains($1.pose.timestampMs-$0.pose.timestampMs) }),
              TemporalContactEvidence.supportsBallTrack(sorted.map(\.pose)),
              TemporalContactEvidence.stableSize(sorted.map(\.pose)),
              let contact = sorted.first(where: { $0.pose.timestampMs == time }),
              let last = sorted.last, last.pose.timestampMs-time >= 67 else { return nil }
        let diameter = size(contact)
        var choices: [(Plan,Double)] = []
        for side in BodySide.allCases {
            // The opposite planted foot may be stable against either visible
            // hip when one side of the pelvis is briefly hidden. Use one hip
            // consistently across the track; never switch anchors per frame.
            let hasStableSupport = [side.hip,side.opposite.hip].contains { hipName in
                let anchors = sorted.compactMap { s -> (Int,Point)? in
                    guard let support = point(s,side.opposite.ankle,minimum:0.5),
                          let hip = point(s,hipName) else { return nil }
                    return (s.pose.timestampMs,relative(support,hip))
                }
                guard anchors.count >= max(5,sorted.count-1),
                      let first = anchors.first, let last = anchors.last,
                      first.0-sorted[0].pose.timestampMs <= 80,
                      sorted[sorted.count-1].pose.timestampMs-last.0 <= 80,
                      zip(anchors,anchors.dropFirst()).allSatisfy({ $1.0-$0.0 <= 100 }) else { return false }
                return anchors.allSatisfy { a in anchors.allSatisfy { distance(a.1,$0.1) <= 0.25*diameter } }
            }
            guard hasStableSupport else { continue }
            for seed in sorted where (50...200).contains(time-seed.pose.timestampMs) {
                guard let ankle = point(seed,side.ankle,minimum:0.5),
                      let knee = point(seed,side.knee), let hip = point(seed,side.hip),
                      let support = point(seed,side.opposite.ankle,minimum:0.5) else { continue }
                let shin = distance(knee,ankle)
                guard (0.06...0.45).contains(shin), diameter/2 <= 0.8*shin,
                      ankle.y >= hip.y, ankle.y < support.y-0.2*diameter,
                      distance(ball(seed),ankle) >= 1.2*diameter else { continue }
                choices.append((.init(side:side,seedMs:seed.pose.timestampMs,
                    seed:.init(x:ankle.x/seed.pose.imageAspect,y:ankle.y),shin:shin),
                    seed.landmarks[side.ankle]!.confidence))
            }
        }
        return choices.max { $0.1 < $1.1 }?.0
    }

    static func contactTime(_ samples: [FootPoseSample], track: [Observation], plan: Plan, at time: Int) -> Int? {
        let views = samples.sorted { $0.pose.timestampMs < $1.pose.timestampMs }
        guard let seed = views.first(where: { $0.pose.timestampMs == plan.seedMs }),
              let seedHip = point(seed,plan.side.hip),
              let seedFoot = point(seed,plan.side.ankle,minimum:0.5),
              track.count >= 4, track.first?.timestampMs == plan.seedMs,
              Set(track.map(\.timestampMs)).count == track.count else { return nil }
        let diameter = size(seed), aspect = seed.pose.imageAspect
        let lowSupport = track.filter { $0.retainedPoints < 6 }
        guard track.allSatisfy({ observation in
            let p = observation.point
            return [p.x,p.y,observation.roundTripError,observation.spread].allSatisfy(\.isFinite)
                && (0...1).contains(p.x) && (0...1).contains(p.y)
                && (0...0.08*diameter).contains(observation.roundTripError)
                && (0...(observation.retainedPoints < 6 ? 0.15 : 0.2)*diameter).contains(observation.spread)
                && observation.retainedPoints >= 5
                && (observation.retainedPoints >= 6 || observation.timestampMs == time)
        }), lowSupport.count <= 1,
              zip(track,track.dropFirst()).allSatisfy({ (1...85).contains($1.timestampMs-$0.timestampMs) }) else { return nil }
        func tracked(_ ms: Int) -> PosePoint? {
            guard let p = track.first(where: { $0.timestampMs == ms })?.point else { return nil }
            return .init(x:p.x*aspect,y:p.y)
        }
        for contact in views where (0...67).contains(contact.pose.timestampMs-time) {
            guard let foot = tracked(contact.pose.timestampMs), let hip = point(contact,plan.side.hip),
                  let support = point(contact,plan.side.opposite.ankle,minimum:0.5),
                  distance(seedHip,hip) <= 0.35*diameter else { continue }
            let p = ball(contact), radius = size(contact)/2, near = distance(p,foot)
            // The ankle landmark is not the contact surface. A stable pixel
            // track gets a modest localization margin without relaxing the
            // required ball departure or foot-recoil checks below.
            guard near <= radius+0.6*plan.shin,
                  p.y <= foot.y+0.25*radius,
                  p.y+radius >= hip.y,
                  foot.y <= support.y-0.2*diameter,
                  p.y+radius <= support.y-0.4*diameter,
                  distance(relative(seedFoot,seedHip),relative(foot,hip)) >= 0.2*diameter,
                  (p.y-hip.y)-(ball(seed).y-seedHip.y) >= 0.12*diameter,
                  distance(ball(seed),seedFoot)-near >= 0.25*diameter else { continue }
            for after in views where (33...100).contains(after.pose.timestampMs-contact.pose.timestampMs) {
                guard let cFoot = tracked(after.pose.timestampMs), let cHip = point(after,plan.side.hip),
                      distance(cHip,hip) <= 0.35*diameter else { continue }
                let cBall = ball(after)
                // The foot must recoil downward while the ball leaves upward.
                // Tracking a held ball or following the ball itself cannot pass.
                guard (cFoot.y-cHip.y)-(foot.y-hip.y) >= 0.05*diameter,
                      (p.y-hip.y)-(cBall.y-cHip.y) >= 0.12*diameter,
                      distance(cBall,cFoot)-near >= 0.12*diameter else { continue }
                return contact.pose.timestampMs
            }
        }
        return nil
    }

    private static func size(_ s: FootPoseSample) -> Double { max(s.pose.height,s.pose.width*s.pose.imageAspect) }
    private static func ball(_ s: FootPoseSample) -> PosePoint { .init(x:s.pose.ball.x*s.pose.imageAspect,y:s.pose.ball.y) }
    private static func point(_ s: FootPoseSample,_ name: BodyJoint,minimum: Double = 0.3) -> PosePoint? {
        guard let p = s.landmarks[name], [p.x,p.y,p.confidence].allSatisfy(\.isFinite),
              (0...1).contains(p.x), (0...1).contains(p.y), (minimum...1).contains(p.confidence) else { return nil }
        return .init(x:p.x*s.pose.imageAspect,y:p.y)
    }
    private static func relative(_ p: PosePoint,_ anchor: PosePoint) -> PosePoint { .init(x:p.x-anchor.x,y:p.y-anchor.y) }
    private static func distance(_ a: PosePoint,_ b: PosePoint) -> Double { hypot(a.x-b.x,a.y-b.y) }
}
