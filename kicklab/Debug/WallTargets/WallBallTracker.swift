#if DEBUG
import CoreGraphics
import Foundation

/// Measured boxes only. Prediction associates weak observations; it never
/// supplies a position or a diameter to the wall-contact rules.
nonisolated struct WallBallTracker {
    struct Sample { let t: Double; let ball: Detection }
    private(set) var previous: Sample?
    private(set) var latest: Sample?

    static func crop(corners: [CGPoint], size: CGSize) -> CGRect? {
        guard WallBoard.validCalibration(corners), size.width > 0, size.height > 0 else { return nil }
        let xs = corners.map { $0.x * size.width }, ys = corners.map { $0.y * size.height }
        let board = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        // Include the approach and the first part of the rebound, especially
        // below the bottom row. Keep this same view during reference sampling.
        return board.insetBy(dx: -board.width * 0.12, dy: -board.height * 0.30)
            .integral.intersection(CGRect(origin: .zero, size: size))
    }

    static func map(_ ball: Detection, from crop: CGRect, size: CGSize) -> Detection? {
        // A box cut by an artificial crop edge has a false (smaller) diameter.
        let left = ball.x - ball.width / 2, right = ball.x + ball.width / 2
        let top = ball.y - ball.height / 2, bottom = ball.y + ball.height / 2
        guard !(crop.minX > 0 && left <= 0.01), !(crop.maxX < size.width && right >= 0.99),
              !(crop.minY > 0 && top <= 0.01), !(crop.maxY < size.height && bottom >= 0.99) else { return nil }
        return Detection(score: ball.score, x: (crop.minX + ball.x * crop.width) / size.width,
                         y: (crop.minY + ball.y * crop.height) / size.height,
                         width: ball.width * crop.width / size.width, height: ball.height * crop.height / size.height)
    }

    func select(_ candidates: [Detection], at t: Double, size: CGSize) -> Detection? {
        let recent = latest.flatMap { t > $0.t && t - $0.t <= 0.20 ? $0 : nil }
        var best: (Detection, Double)?
        for ball in candidates {
            let w = ball.width * size.width, h = ball.height * size.height
            guard [ball.score, ball.x, ball.y, w, h].allSatisfy(\.isFinite), w >= 3, h >= 3,
                  (0...1).contains(ball.x), (0...1).contains(ball.y),
                  (0.55...1.8).contains(w / h), ball.score >= (recent == nil ? 0.20 : 0.08) else { continue }
            var cost = -log(max(ball.score, 0.001))
            if let recent {
                let old = recent.ball, diameter = (old.width * size.width + old.height * size.height) / 2
                let dt = t - recent.t, ratio = (w + h) / 2 / diameter
                guard (0.50...1.9).contains(ratio) else { continue }
                var vx = 0.0, vy = 0.0
                if let previous, recent.t - previous.t <= 0.15, recent.t > previous.t {
                    vx = (old.x - previous.ball.x) * size.width / (recent.t - previous.t)
                    vy = (old.y - previous.ball.y) * size.height / (recent.t - previous.t)
                }
                let dx = (ball.x - old.x) * size.width, dy = (ball.y - old.y) * size.height
                guard hypot(dx, dy) <= max(2 * diameter, hypot(vx, vy) * dt * 2 + diameter) else { continue }
                // Permit a genuine reversal; a weak box still has to remain
                // near the last measured ball, with a plausible diameter.
                let residual = min(hypot(dx - vx * dt, dy - vy * dt), hypot(dx, dy)) / diameter
                if ball.score < 0.20 && (residual > 1.0 || !(0.70...1.45).contains(ratio)) { continue }
                cost += residual * 0.5 + abs(log(ratio))
            }
            if best == nil || cost < best!.1 { best = (ball, cost) }
        }
        return best?.0
    }

    mutating func accept(_ ball: Detection?, at t: Double) {
        guard let ball else {
            if let latest, t - latest.t > 0.20 { reset() }
            return
        }
        previous = latest; latest = Sample(t: t, ball: ball)
    }

    mutating func reset() { previous = nil; latest = nil }
}
#endif
