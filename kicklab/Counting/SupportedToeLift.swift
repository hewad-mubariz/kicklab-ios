import Foundation

/// A brief toe flick can finish between the ordinary 100 ms foot samples.
/// Keep the original ball impact, and require the same foot to lift before it,
/// continue lifting while the ball reverses, then settle as the ball departs.
/// The opposite foot anchors motion when the hip follows the kicking leg.
nonisolated enum SupportedToeLift {
    static func confirms(_ evidence: FootContactEvidence) -> Bool {
        guard let ground = evidence.compactGroundEvidence,
              ground.contactMs == evidence.candidateTimestampMs,
              evidence.contact.timestampMs == ground.contactMs,
              MeasuredFootImpactRules.resolvedFloorTime(ground) == nil else { return false }
        let views = (ground.compactFootSamples ?? ground.samples).filter {
            (-134...134).contains($0.timestampMs-ground.contactMs)
        }.sorted { $0.timestampMs < $1.timestampMs }
        guard (7...10).contains(views.count), Set(views.map(\.timestampMs)).count == views.count,
              zip(views, views.dropFirst()).allSatisfy({ (25...50).contains($1.timestampMs-$0.timestampMs) }),
              views.allSatisfy({ s in
                  [s.ballX,s.ballY,s.width,s.height,s.confidence].allSatisfy(\.isFinite)
                    && s.width > 0 && s.height > 0 && (0.7...1).contains(s.confidence)
                    && s.ballX-s.width/2 >= 0 && s.ballX+s.width/2 <= 1
                    && s.ballY-s.height/2 >= 0 && s.ballY+s.height/2 <= 1
              }), views.map(\.width).max()! <= 1.25*views.map(\.width).min()!,
              views.map(\.height).max()! <= 1.25*views.map(\.height).min()!,
              let impact = views.first(where: { $0.timestampMs == ground.contactMs }),
              let next = views.first(where: { (25...50).contains($0.timestampMs-impact.timestampMs) }),
              abs(next.ballY-impact.ballY) <= 0.1*impact.height else { return false }
        let approach = views.filter { (65...134).contains(impact.timestampMs-$0.timestampMs) }
        let release = views.filter { (65...134).contains($0.timestampMs-impact.timestampMs) }
        guard approach.count >= 2, release.count >= 2,
              approach.allSatisfy({ impact.ballY-$0.ballY >= 0.2*impact.height }),
              release.allSatisfy({ impact.ballY-$0.ballY >= 0.2*impact.height }) else { return false }
        func reliable(_ p: PoseLandmark?) -> Bool {
            guard let p else { return false }
            return [p.x,p.y,p.confidence].allSatisfy(\.isFinite)
                && (0...1).contains(p.x) && (0...1).contains(p.y) && (0.5...1).contains(p.confidence)
        }
        for side in BodySide.allCases {
            guard views.allSatisfy({ reliable($0.ankles[side.opposite]) }),
                  [impact,next].allSatisfy({ reliable($0.ankles[side]) && reliable($0.hips[side]) })
            else { continue }
            let support = views.map { $0.ankles[side.opposite]! }
            guard support.map(\.x).max()!-support.map(\.x).min()! <= 0.25*impact.width,
                  support.map(\.y).max()!-support.map(\.y).min()! <= 0.25*impact.height else { continue }
            let foot = impact.ankles[side]!, lifted = next.ankles[side]!
            // The contacting ankle must overlap the ball, rather than sit
            // entirely above a turf rebound beside the foot.
            guard impact.ballY-impact.height/2 <= foot.y,
                  hypot((impact.ballX-foot.x)/impact.width,(impact.ballY-foot.y)/impact.height) <= 0.75,
                  foot.y <= impact.ankles[side.opposite]!.y-0.15*impact.height,
                  foot.y-lifted.y >= max(0.0035,0.1*impact.height),
                  (foot.y-impact.ankles[side.opposite]!.y)-(lifted.y-next.ankles[side.opposite]!.y)
                    >= 0.05*impact.height else { continue }
            let beforeLift = approach.contains { s in
                guard reliable(s.ankles[side]), reliable(s.hips[side]) else { return false }
                let ankle = s.ankles[side]!
                return ankle.y-foot.y >= max(0.0035,0.1*impact.height)
                    && (ankle.y-s.ankles[side.opposite]!.y)-(foot.y-impact.ankles[side.opposite]!.y)
                        >= 0.15*impact.height
            }
            // Two confident later views must independently show ball departure
            // and the kicking foot returning; a single ankle spike cannot pass.
            let settledRelease = release.filter { s in
                guard reliable(s.ankles[side]), reliable(s.hips[side]) else { return false }
                let ankle = s.ankles[side]!, other = s.ankles[side.opposite]!
                return ankle.y-lifted.y >= 0.1*impact.height
                    && abs(ankle.y-other.y) <= 0.25*impact.height
                    && s.ballY <= min(ankle.y,other.y)-0.2*impact.height
            }
            if beforeLift && settledRelease.count >= 2 { return true }
        }
        return false
    }
}
