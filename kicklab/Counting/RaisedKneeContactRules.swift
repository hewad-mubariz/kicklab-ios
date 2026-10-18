import Foundation

/// Candidate-only recovery for a raised knee projected over the torso. A ball
/// reversal alone is insufficient: two nearby views must show the same raised
/// knee moving up toward the ball, with both wrists visibly clear of it.
nonisolated enum RaisedKneeContactRules {
    typealias Point = PosePoint
    typealias Sample = ContactPoseSample

    static func confirms(_ input: [Sample], at timestampMs: Int) -> Bool {
        let samples = input.filter { sample in
            (-50...150).contains(sample.timestampMs - timestampMs)
                && [sample.ball.x, sample.ball.y, sample.width, sample.height,
                    sample.confidence, sample.imageAspect].allSatisfy(\.isFinite)
                && sample.confidence >= 0.5 && sample.imageAspect > 0
                && (0...1).contains(sample.ball.x) && (0...1).contains(sample.ball.y)
                && sample.width > 0 && sample.width <= 1 && sample.height > 0 && sample.height <= 1
                && sample.joints.values.allSatisfy { $0.x.isFinite && $0.y.isFinite }
        }.sorted { $0.timestampMs < $1.timestampMs }
        guard samples.count >= 2,
              samples.map(\.width).max()! <= 1.35 * samples.map(\.width).min()!,
              samples.map(\.height).max()! <= 1.35 * samples.map(\.height).min()! else { return false }
        func distance(_ a: Point, _ b: Point) -> Double { hypot(a.x-b.x, a.y-b.y) }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        func point(_ name: BodyJoint, in sample: Sample) -> Point? {
            sample.joints[name].map { .init(x: $0.x * sample.imageAspect, y: $0.y) }
        }

        for (side, supporting) in [(BodySide.left, BodySide.right), (.right, .left)] {
            // Use the extended supporting shin as the scale. The raised thigh
            // foreshortens, and its hip often disappears under loose clothing.
            // Pool observed support joints so one low-confidence frame cannot
            // erase otherwise consistent evidence. Never fill in the raised knee.
            let support = samples.compactMap { sample -> (length: Double, knee: Double, ankle: Double)? in
                guard let knee = point(supporting.knee, in: sample),
                      let ankle = point(supporting.ankle, in: sample) else { return nil }
                let length = distance(knee, ankle)
                guard length > 0.03, length < 0.5, ankle.y-knee.y > 0.7*length else { return nil }
                return (length, knee.y, ankle.y)
            }
            guard support.count >= 2 else { continue }
            let shin = median(support.map(\.length))
            let standingKnee = median(support.map(\.knee)), standingAnkle = median(support.map(\.ankle))
            var evidence: [(time: Int, knee: Point, shoulders: Point)] = []
            for sample in samples {
                guard let knee = point(side.knee, in: sample), let ankle = point(side.ankle, in: sample),
                      let ls = point(.leftShoulder, in: sample), let rs = point(.rightShoulder, in: sample),
                      let lw = point(.leftWrist, in: sample), let rw = point(.rightWrist, in: sample) else { continue }
                let ball = Point(x: sample.ball.x * sample.imageAspect, y: sample.ball.y)
                let radius = max(sample.width * sample.imageAspect, sample.height) / 2
                guard distance(ls, rs) > 0.01, radius <= 0.6*shin,
                      standingAnkle-ankle.y >= 0.5*shin,
                      standingKnee-knee.y >= 0.5*shin, ankle.y-knee.y >= 0.25*shin,
                      ball.y <= knee.y + radius*0.25,
                      abs(ball.x-knee.x) <= radius + 0.2*shin,
                      distance(ball, knee) <= radius + 0.6*shin,
                      min(distance(ball, lw), distance(ball, rw)) >= 1.8*radius else { continue }
                // The proximity allowance covers pose lag under clothing; the
                // second view, rising knee and clear hands are mandatory.
                evidence.append((sample.timestampMs, knee, .init(x: (ls.x+rs.x)/2, y: (ls.y+rs.y)/2)))
            }
            for (index, first) in evidence.enumerated() {
                for second in evidence.dropFirst(index+1) {
                    let gap = second.time-first.time
                    if gap > 0 && gap <= 100,
                       first.knee.y-second.knee.y >= 0.03*shin,
                       abs(first.knee.x-second.knee.x) <= 0.5*shin,
                       distance(first.shoulders, second.shoulders) <= 0.35*shin { return true }
                }
            }
        }
        return false
    }
}
