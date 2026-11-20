#if DEBUG
import CoreGraphics
import Foundation

/// Measured boxes only. Prediction associates weak observations; it never
/// supplies a position or a diameter to the wall-contact rules.
nonisolated struct WallBallTracker {
    struct Sample { let t: Double; let ball: Detection }
    private(set) var previous: Sample?
    private(set) var latest: Sample?
    private var stationaryAnchor: Sample?
    private var stationarySamples = 0
    private var stationaryLastSeen = -Double.infinity
    private var stationaryObjects: [Detection] = []

    static func crop(corners: [CGPoint], size: CGSize) -> CGRect? {
        guard WallBoard.validCalibration(corners), size.width > 0, size.height > 0 else { return nil }
        let xs = corners.map { $0.x * size.width }, ys = corners.map { $0.y * size.height }
        let board = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        // Include the approach and the first part of the rebound, especially
        // below the bottom row. Keep this same view during reference sampling.
        return board.insetBy(dx: -board.width * 0.12, dy: -board.height * 0.30)
            .integral.intersection(CGRect(origin: .zero, size: size))
    }

    /// Sample the held ball at the same pixel scale as a wall-depth follow crop.
    /// The wide board view can underestimate a small, partly hand-covered ball.
    /// The hold still requires the measured ball at the calibrated wall centre.
    static func referenceCrop(corners: [CGPoint], size: CGSize) -> CGRect? {
        guard WallBoard.validCalibration(corners), size.width > 0, size.height > 0 else { return nil }
        let p = corners.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard let board = WallBoard(topLeft: p[0], topRight: p[1], bottomRight: p[2], bottomLeft: p[3]) else { return nil }
        let centre = board.imagePoint(u: 1.5, v: 1)
        let edge = min(size.width * 0.30, size.height)
        return CGRect(x: max(0, min(size.width - edge, centre.x - edge / 2)),
                      y: max(0, min(size.height - edge, centre.y - edge / 2)), width: edge, height: edge)
            .integral.intersection(CGRect(origin: .zero, size: size))
    }

    /// Spend the CPU model's pixels on the measured ball during a shot. Keep
    /// enough margin for a reversal and one missing frame. This predicts only
    /// the camera region to inspect, never a ball observation or a wall hit.
    func followCrop(at t: Double, size: CGSize, motionRegion: CGRect? = nil,
                    allowStationaryReacquisition: Bool = false) -> CGRect? {
        if allowStationaryReacquisition && hasWeakStationaryIdentity(at: t) { return nil }
        guard let latest, t > latest.t, t - latest.t <= 0.20,
              size.width > 0, size.height > 0 else { return nil }
        let b = latest.ball
        let diameter = (b.width * size.width + b.height * size.height) / 2
        guard diameter.isFinite, diameter > 0 else { return nil }
        var x = b.x * size.width, y = b.y * size.height
        let minimum = size.width * 0.30
        if let previous, latest.t > previous.t, latest.t - previous.t <= 0.15 {
            let lead = (t - latest.t) / (latest.t - previous.t)
            let limit = minimum * 0.25
            x += max(-limit, min(limit, (b.x - previous.ball.x) * size.width * lead))
            y += max(-limit, min(limit, (b.y - previous.ball.y) * size.height * lead))
        }
        // A first observation has no velocity yet. A measured motion region
        // can centre the next inspection on the incoming ball. It is only a
        // search hint; RF must still identify and measure the ball in this view.
        if previous == nil, let motionRegion, motionRegion.width > 0, motionRegion.height > 0,
           hypot(motionRegion.midX - b.x * size.width, motionRegion.midY - b.y * size.height)
                <= Self.acquisitionTravel(diameter: diameter, elapsed: t - latest.t),
           hypot(motionRegion.midX - x, motionRegion.midY - y) <= minimum / 2 {
            x = motionRegion.midX; y = motionRegion.midY
        }
        let edge = min(size.width, size.height, max(minimum, min(size.width * 0.5, diameter * 5)))
        guard x.isFinite, y.isFinite, edge >= 1 else { return nil }
        return CGRect(x: max(0, min(size.width - edge, x - edge / 2)),
                      y: max(0, min(size.height - edge, y - edge / 2)), width: edge, height: edge)
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

    func select(_ candidates: [Detection], at t: Double, size: CGSize,
                allowStationaryReacquisition: Bool = false) -> Detection? {
        // A projected O can keep scoring just above the weak continuation floor.
        // Once it has stayed still, do not let that identity's travel gate reject
        // a fresh ball elsewhere. Acquisition still requires a real >=0.20 box.
        let reacquire = allowStationaryReacquisition && hasWeakStationaryIdentity(at: t)
        let recent = reacquire ? nil : latest.flatMap { t > $0.t && t - $0.t <= 0.20 ? $0 : nil }
        var best: (Detection, Double)?
        for ball in candidates {
            let w = ball.width * size.width, h = ball.height * size.height
            guard [ball.score, ball.x, ball.y, w, h].allSatisfy(\.isFinite), w >= 3, h >= 3,
                  (0...1).contains(ball.x), (0...1).contains(ball.y),
                  (0.55...1.8).contains(w / h), ball.score >= (recent == nil ? 0.20 : 0.08) else { continue }
            if allowStationaryReacquisition, ball.score < 0.35,
               stationaryObjects.contains(where: { Self.matchesStationary(ball, $0) }) { continue }
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
                // At 8 fps a newly acquired ball travels farther between model
                // frames than at 60 fps. Bound that distance by elapsed time,
                // still inside the 200 ms identity lifetime. Weak observations
                // retain the stricter one-diameter residual gate below.
                guard hypot(dx, dy) <= max(Self.acquisitionTravel(diameter: diameter, elapsed: dt),
                                          hypot(vx, vy) * dt * 2 + diameter) else { continue }
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

    private static func acquisitionTravel(diameter: Double, elapsed: Double) -> Double {
        2 * diameter * max(1, min(2, elapsed / 0.1))
    }

    mutating func accept(_ ball: Detection?, at t: Double) {
        guard let ball else {
            if let latest, t - latest.t > 0.20 {
                // Drop motion continuity, but remember a settled weak object.
                // A brief score dropout must not renew its identity lock when
                // the same projected mark is measured again. Explicit reset
                // on a new setup/geometry still clears all this evidence.
                previous = nil; self.latest = nil
            }
            return
        }
        let established = stationaryAnchor.map {
            stationarySamples >= 6 && stationaryLastSeen - $0.t >= 0.50 && $0.ball.score < 0.35
        } ?? false
        let contiguous = latest.map { t > $0.t && t - $0.t <= 0.20 } ?? false
        if let anchor = stationaryAnchor, t > stationaryLastSeen, (contiguous || established),
           Self.matchesStationary(ball, anchor.ball) {
            stationarySamples += 1
        } else {
            stationaryAnchor = Sample(t: t, ball: ball)
            stationarySamples = 1
        }
        stationaryLastSeen = t
        previous = latest; latest = Sample(t: t, ball: ball)
        if let anchor = stationaryAnchor, stationarySamples >= 6, t - anchor.t >= 0.50,
           anchor.ball.score < 0.35, ball.score < 0.35,
           !stationaryObjects.contains(where: { Self.matchesStationary(ball, $0) }) {
            stationaryObjects.append(anchor.ball)
            if stationaryObjects.count > 8 { stationaryObjects.removeFirst() }
        }
    }

    private func hasWeakStationaryIdentity(at t: Double) -> Bool {
        guard let latest, latest.ball.score < 0.35, t > latest.t, t - latest.t <= 0.20 else { return false }
        // Keep bounded hints across real shots too. A strong measured ball at
        // the same position remains eligible; this is not a permanent region mask.
        return stationaryObjects.contains { Self.matchesStationary(latest.ball, $0) }
    }

    private static func matchesStationary(_ ball: Detection, _ anchor: Detection) -> Bool {
        anchor.width > 0 && anchor.height > 0
            && abs(ball.x - anchor.x) <= anchor.width * 0.12
            && abs(ball.y - anchor.y) <= anchor.height * 0.12
            && (0.65...1.5).contains(ball.width / anchor.width)
            && (0.65...1.5).contains(ball.height / anchor.height)
    }

    mutating func reset() {
        previous = nil; latest = nil; stationaryAnchor = nil; stationarySamples = 0
        stationaryLastSeen = -.infinity
        stationaryObjects = []
    }
}
#endif
