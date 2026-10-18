import Foundation

/// A raised, inward-turned foot can project over the hips. Resolve that case
/// with observed ankle motion, not the assumption that a foot continues along
/// the shin. This only supplies body eligibility; hand/ground gates still apply.
nonisolated enum RaisedFootContactRules {
    typealias Point = PosePoint
    typealias Sample = FootPoseSample
    private struct Evidence {
        let time: Int
        let ankle, hip: Point
        let confidence: Double
        let close: Bool
    }

    static func confirms(_ input: [Sample], at timestampMs: Int) -> Bool {
        let samples = input.filter { sample in
            let s = sample.pose
            return (-100...150).contains(s.timestampMs - timestampMs)
                && [s.ball.x, s.ball.y, s.width, s.height, s.confidence, s.imageAspect].allSatisfy(\.isFinite)
                && s.confidence >= 0.5 && s.imageAspect > 0
                && (0...1).contains(s.ball.x) && (0...1).contains(s.ball.y)
                && s.width > 0 && s.width <= 1 && s.height > 0 && s.height <= 1
                && s.joints.values.allSatisfy { $0.x.isFinite && $0.y.isFinite }
        }.sorted { $0.pose.timestampMs < $1.pose.timestampMs }
        guard samples.count >= 2,
              samples.map({ $0.pose.width }).max()! <= 1.35 * samples.map({ $0.pose.width }).min()!,
              samples.map({ $0.pose.height }).max()! <= 1.35 * samples.map({ $0.pose.height }).min()! else { return false }

        func distance(_ a: Point, _ b: Point) -> Double { hypot(a.x-b.x, a.y-b.y) }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted(), middle = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[middle-1]+sorted[middle])/2 : sorted[middle]
        }
        func point(_ name: BodyJoint, in sample: Sample) -> Point? {
            sample.pose.joints[name].map { .init(x: $0.x * sample.pose.imageAspect, y: $0.y) }
        }
        // Judge torso height at the proposed impact, not after the ball has
        // already risen away from the foot in the confirmation frames.
        guard let contact = samples.first(where: { $0.pose.timestampMs == timestampMs }),
              let lh = point(.leftHip, in: contact), let rh = point(.rightHip, in: contact),
              contact.pose.ball.y + max(contact.pose.width*contact.pose.imageAspect, contact.pose.height)/2
                >= (lh.y+rh.y)/2 else { return false }

        for (side, supporting) in [(BodySide.left, BodySide.right), (.right, .left)] {
            // Supporting ankles often leave the image. Scale using the visible,
            // extended thigh, pooling observations rather than filling joints.
            let support = samples.compactMap { sample -> (length: Double, knee: Double)? in
                guard let hip = point(supporting.hip, in: sample),
                      let knee = point(supporting.knee, in: sample) else { return nil }
                let length = distance(hip, knee)
                guard length > 0.04, length < 0.45, knee.y-hip.y > 0.7*length else { return nil }
                return (length, knee.y)
            }
            guard support.count >= 2 else { continue }
            let scale = median(support.map(\.length)), standingKnee = median(support.map(\.knee))
            var raisedLeg = false
            var evidence: [Evidence] = []
            for sample in samples {
                let s = sample.pose
                guard let raw = sample.ankles[side],
                      [raw.x, raw.y, raw.confidence].allSatisfy(\.isFinite),
                      (0...1).contains(raw.x), (0...1).contains(raw.y), (0.1...1).contains(raw.confidence),
                      let hip = point(side.hip, in: sample),
                      point(.leftHip, in: sample) != nil, point(.rightHip, in: sample) != nil,
                      let ls = point(.leftShoulder, in: sample), let rs = point(.rightShoulder, in: sample),
                      let lw = point(.leftWrist, in: sample), let rw = point(.rightWrist, in: sample) else { continue }
                let ankle = Point(x: raw.x*s.imageAspect, y: raw.y)
                let ball = Point(x: s.ball.x*s.imageAspect, y: s.ball.y)
                let radius = max(s.width*s.imageAspect, s.height)/2
                guard distance(ls, rs) > 0.01, radius <= 0.65*scale,
                      ankle.y <= standingKnee + 0.35*scale,
                      min(distance(ball, lw), distance(ball, rw)) >= 1.8*radius else { continue }
                if let knee = point(side.knee, in: sample),
                   knee.y < standingKnee - 0.4*scale, abs(knee.x-hip.x) > 0.3*scale,
                   distance(knee, ankle) < 1.8*scale { raisedLeg = true }
                // Only recover hip-height/lower contacts. The upper torso is
                // still excluded even if a raised foot happens to be visible.
                let close = (0...100).contains(s.timestampMs-timestampMs)
                    && ball.y <= ankle.y+radius*0.25
                    && distance(ball, ankle) <= radius+0.35*scale
                evidence.append(.init(time: s.timestampMs, ankle: ankle, hip: hip,
                                      confidence: raw.confidence, close: close))
            }
            guard raisedLeg else { continue }
            func rising(_ a: Evidence, _ b: Evidence) -> Bool {
                let gap = b.time-a.time
                let rise = (a.ankle.y-a.hip.y)-(b.ankle.y-b.hip.y)
                let sideways = abs((a.ankle.x-a.hip.x)-(b.ankle.x-b.hip.x))
                return gap > 0 && gap <= 150 && rise >= 0.06*scale && rise <= 0.9*scale
                    && sideways < 0.65*scale && distance(a.hip, b.hip) < 0.3*scale
            }
            func nearContact(_ a: Evidence, _ b: Evidence) -> Bool {
                if b.close { return true }
                // The ball can hide the ankle at impact. Bridge only a short
                // gap bracketed by observed ankle positions, relative to the
                // hip, and only inside an otherwise verified moving-foot track.
                // Never overwrite a confident but contradictory ankle estimate.
                for sample in samples {
                    let s = sample.pose
                    guard s.timestampMs > a.time, s.timestampMs < b.time,
                          (0...100).contains(s.timestampMs-timestampMs),
                          (sample.ankles[side]?.confidence ?? 0) < 0.3,
                          let hip = point(side.hip, in: sample),
                          let lw = point(.leftWrist, in: sample), let rw = point(.rightWrist, in: sample) else { continue }
                    let ball = Point(x: s.ball.x*s.imageAspect, y: s.ball.y)
                    let radius = max(s.width*s.imageAspect, s.height)/2
                    guard radius <= 0.65*scale, min(distance(ball, lw), distance(ball, rw)) >= 1.8*radius else { continue }
                    let t = Double(s.timestampMs-a.time)/Double(b.time-a.time)
                    let ankle = Point(x: hip.x+(a.ankle.x-a.hip.x)*(1-t)+(b.ankle.x-b.hip.x)*t,
                                      y: hip.y+(a.ankle.y-a.hip.y)*(1-t)+(b.ankle.y-b.hip.y)*t)
                    if ball.y <= ankle.y+radius*0.25, distance(ball, ankle) <= radius+0.35*scale { return true }
                }
                return false
            }
            for (i, a) in evidence.enumerated() {
                for (j, b) in evidence.enumerated() where j > i && rising(a, b) {
                    if min(a.confidence, b.confidence) >= 0.3, nearContact(a, b) { return true }
                    // A single weak ankle cannot bypass the torso guard. Require
                    // two agreeing upward steps and a confident track anchor.
                    for c in evidence.dropFirst(j+1) where c.time-a.time <= 200 {
                        if max(a.confidence, max(b.confidence, c.confidence)) >= 0.3,
                           rising(b, c), nearContact(a, b) || nearContact(b, c) { return true }
                    }
                }
            }
        }
        return false
    }
}
