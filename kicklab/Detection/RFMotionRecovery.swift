import CoreGraphics
import Foundation

/// Reacquire a measured RF detection after the pixel tracker loses a moving
/// ball. Projection is only an association hint; it never becomes an observation.
nonisolated struct RFMotionRecovery {
    static let signature = "|rf-motion-recovery-v1"
    static func enabled(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        #if DEBUG
        return !arguments.contains("--disable-rf-motion-recovery")
        #else
        return true
        #endif
    }

    private struct Sample { let hit: FollowHit; let time: Double }
    private var previous: Sample?
    private var latest: Sample?

    mutating func observe(_ hit: FollowHit, at time: Double) {
        guard time.isFinite, hit.diameter.isFinite, hit.diameter > 0,
              hit.center.x.isFinite, hit.center.y.isFinite else { return }
        if let latest, time <= latest.time { return }
        previous = latest
        latest = Sample(hit: hit, time: time)
    }

    func select(_ candidates: [AsyncBallCandidate], at time: Double) -> AsyncBallCandidate? {
        guard let previous, let latest else { return nil }
        let interval = latest.time-previous.time, age = time-latest.time
        guard (0.02...0.15).contains(interval), (0.03...0.25).contains(age),
              (0.8...1.25).contains(latest.hit.diameter/previous.hit.diameter) else { return nil }
        let diameter = latest.hit.diameter
        let vx = (latest.hit.center.x-previous.hit.center.x)/interval
        let vy = (latest.hit.center.y-previous.hit.center.y)/interval
        let speed = hypot(vx, vy)
        guard (4...60).contains(speed/diameter) else { return nil }
        let predicted = CGPoint(x: latest.hit.center.x+vx*age, y: latest.hit.center.y+vy*age)
        let eligible = candidates.filter { candidate in
            let hit = candidate.hit
            guard hit.score.isFinite, hit.score >= 0.7,
                  (0.7...1.5).contains(hit.diameter/diameter) else { return false }
            let dx = hit.center.x-latest.hit.center.x, dy = hit.center.y-latest.hit.center.y
            let forward = (dx*vx+dy*vy)/speed
            let sideways = abs(dx*vy-dy*vx)/speed
            // A short corridor allows acceleration while excluding a stationary
            // spare ball, opposite motion and a remote ball elsewhere in frame.
            return forward >= 0.5*diameter && sideways <= diameter
                && hypot(dx, dy) <= 10*diameter
                && hypot(hit.center.x-predicted.x, hit.center.y-predicted.y) <= 3*diameter
        }
        // Ambiguous recovery waits for more evidence; score alone cannot choose
        // between two physically plausible balls.
        return eligible.count == 1 ? eligible[0] : nil
    }
}
