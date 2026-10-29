import Foundation

/// Recheck an earlier measured reversal when a tracking gap delayed the
/// smoothed proposal. Hand clearance must pass at that actual impact; it is
/// never inferred from the ball simply being away from a hand later on.
nonisolated enum MeasuredImpactAlignmentRules {
    static func contactTime(_ input: [ContactPoseSample], proposedMs: Int) -> Int? {
        let samples = input.sorted { $0.timestampMs < $1.timestampMs }
        guard samples.count <= 24, Set(samples.map(\.timestampMs)).count == samples.count else { return nil }
        func visible(_ s: ContactPoseSample) -> Bool {
            [s.ball.x,s.ball.y,s.width,s.height,s.confidence].allSatisfy(\.isFinite)
                && s.confidence >= 0.7 && s.width > 0 && s.height > 0
                && s.ball.x-s.width/2 >= 0 && s.ball.x+s.width/2 <= 1
                && s.ball.y-s.height/2 >= 0 && s.ball.y+s.height/2 <= 1
        }
        for impact in samples.reversed() where (68...100).contains(proposedMs-impact.timestampMs) && visible(impact) {
            guard let before = samples.last(where: { (40...134).contains(impact.timestampMs-$0.timestampMs) }),
                  let after = samples.first(where: { (25...67).contains($0.timestampMs-impact.timestampMs) }),
                  [before,after].allSatisfy(visible),
                  [before,impact,after].map(\.height).max()! <= 1.35*[before,impact,after].map(\.height).min()!,
                  [before,impact,after].map(\.width).max()! <= 1.35*[before,impact,after].map(\.width).min()!,
                  impact.ball.y-before.ball.y >= 0.35*impact.height,
                  impact.ball.y-after.ball.y >= 0.12*impact.height,
                  RestrictedTouchPolicy.region(ball: impact.ball, width: impact.width, height: impact.height,
                    joints: impact.joints, imageAspect: impact.imageAspect) != nil,
                  ClearHandsContactRules.handFailure(in: impact) == nil,
                  ClearHandsContactRules.handFailure(in: after) == nil else { continue }
            return impact.timestampMs
        }
        return nil
    }
}
