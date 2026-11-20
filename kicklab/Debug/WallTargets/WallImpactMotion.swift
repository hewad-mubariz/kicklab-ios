#if DEBUG
import Foundation

/// Cosmetic motion estimate. Never used by the contact gates or damage rules.
/// A single camera does not supply calibrated 3D speed or impact force.
nonisolated enum WallImpactMotion {
    static func approachSpeed(_ observations: [WallImpactDetector.Observation],
                              contact: WallImpactDetector.Observation) -> Double? {
        guard contact.t.isFinite, contact.d.isFinite, contact.d > 0 else { return nil }
        let samples = observations.filter { $0.t <= contact.t && contact.t - $0.t <= 0.20 }
        guard samples.count >= 4, let first = samples.first, let last = samples.last,
              last.t - first.t >= 0.065,
              samples.allSatisfy({ $0.t.isFinite && $0.x.isFinite && $0.y.isFinite && $0.hand == .clear }),
              zip(samples, samples.dropFirst()).allSatisfy({ $1.t > $0.t && $1.t - $0.t <= 0.085 }) else { return nil }
        let n = Double(samples.count)
        let mt = samples.reduce(0) { $0 + ($1.t - contact.t) } / n
        let mx = samples.reduce(0) { $0 + $1.x } / n
        let my = samples.reduce(0) { $0 + $1.y } / n
        let variance = samples.reduce(0) { $0 + pow(($1.t - contact.t) - mt, 2) }
        guard variance > 0 else { return nil }
        let vx = samples.reduce(0) { $0 + (($1.t - contact.t) - mt) * ($1.x - mx) } / variance
        let vy = samples.reduce(0) { $0 + (($1.t - contact.t) - mt) * ($1.y - my) } / variance
        let residual = samples.reduce(0) {
            $0 + pow($1.x - mx - vx * (($1.t - contact.t) - mt), 2)
                + pow($1.y - my - vy * (($1.t - contact.t) - mt), 2)
        }
        // Reject jitter, identity jumps and highly curved/ambiguous approaches.
        guard sqrt(residual / n) <= contact.d * 0.30 else { return nil }
        let speed = hypot(vx, vy) / contact.d
        return speed.isFinite ? speed : nil
    }

    static func strength(for speed: Double?) -> Double {
        guard let speed, speed.isFinite, speed >= 0 else { return 0.65 }
        return 0.45 + 0.55 * min(1, max(0, (speed - 2) / 18))
    }
}
#endif
