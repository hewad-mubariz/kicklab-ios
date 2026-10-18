#if DEBUG
import CoreGraphics
import Foundation

/// Explicit samples of the same ball touching six target centres. Diameters are
/// fractions of camera width, so the profile survives a pixel-resolution change.
nonisolated struct WallBallReference: Equatable, Sendable {
    let diameters: [Double]

    init?(_ diameters: [Double]) {
        guard diameters.count == 6, diameters.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 0.5 }),
              diameters.max()! / diameters.min()! <= 2 else { return nil }
        self.diameters = diameters
    }

    func diameter(u: Double, v: Double, imageWidth: Double) -> Double {
        let x = max(0, min(2, u - 0.5)), y = max(0, min(1, v - 0.5))
        let left = min(1, Int(x)), blend = x - Double(left)
        let top = diameters[left] * (1 - blend) + diameters[left + 1] * blend
        let bottom = diameters[left + 3] * (1 - blend) + diameters[left + 4] * blend
        return (top * (1 - y) + bottom * y) * imageWidth
    }
}

/// A guided hold, not a contact detector. Missing/noisy frames never advance a
/// timer on their own; the ball must remain visible at the requested centre.
nonisolated struct WallReferenceCollector: Sendable {
    struct Sample: Sendable { let t, x, y, d, score, aspect: Double }
    struct Update: Sendable { let progress: Double; let diameter: Double? }
    var board: WallBoard
    var target: Int
    var imageWidth: Double
    private var samples: [Sample] = []
    private var lastAccepted: Double?
    static let holdDuration = 3.0

    init(board: WallBoard, target: Int, imageWidth: Double) {
        self.board = board; self.target = target; self.imageWidth = imageWidth
    }

    mutating func add(_ sample: Sample?, now: Double) -> Update {
        if let lastAccepted, now - lastAccepted > 0.5 { samples = []; self.lastAccepted = nil }
        let retainedProgress = samples.first.map { min(0.99, max(0, (lastAccepted ?? now) - $0.t) / Self.holdDuration) } ?? 0
        guard let s = sample, (1...6).contains(target),
              [s.t, s.x, s.y, s.d, s.score, s.aspect].allSatisfy(\.isFinite),
              s.d > 0, s.score >= 0.45, (0.65...1.55).contains(s.aspect) else {
            return .init(progress: retainedProgress, diameter: nil)
        }
        let u = Double((target - 1) % 3) + 0.5, v = Double((target - 1) / 3) + 0.5
        let mapped = board.boardPoint(CGPoint(x: s.x, y: s.y))
        let top = board.imagePoint(u: u, v: v - 0.5), bottom = board.imagePoint(u: u, v: v + 0.5)
        let left = board.imagePoint(u: u - 0.5, v: v), right = board.imagePoint(u: u + 0.5, v: v)
        let cellSize = min(hypot(top.x - bottom.x, top.y - bottom.y), hypot(left.x - right.x, left.y - right.y))
        guard abs(mapped.x - u) <= 0.32, abs(mapped.y - v) <= 0.32, s.d <= cellSize * 0.85 else {
            return .init(progress: retainedProgress, diameter: nil)
        }
        if !samples.isEmpty {
            let d = Self.median(samples.map(\.d)), x = Self.median(samples.map(\.x)), y = Self.median(samples.map(\.y))
            if abs(s.d / d - 1) > 0.25 || hypot(s.x - x, s.y - y) > d * 0.6 {
                // One bad box must not restart a careful hold. Sustained motion
                // expires the accepted samples through the 0.5 s gap above.
                return .init(progress: retainedProgress, diameter: nil)
            }
        }
        guard samples.last.map({ s.t > $0.t }) ?? true else { return .init(progress: 0, diameter: nil) }
        samples.append(s); lastAccepted = now
        if samples.count > 240 { samples.removeFirst(samples.count - 240) }
        let elapsed = s.t - samples[0].t
        let median = Self.median(samples.map(\.d))
        let mad = Self.median(samples.map { abs($0.d - median) })
        guard elapsed >= Self.holdDuration, samples.count >= 25, mad / median < 0.10 else {
            return .init(progress: min(0.99, elapsed / Self.holdDuration), diameter: nil)
        }
        return .init(progress: 1, diameter: median / imageWidth)
    }

    private static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
}
#endif
