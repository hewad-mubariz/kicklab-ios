#if DEBUG
import CoreGraphics
import Foundation

/// A single central wall hold for new games; legacy six-point profiles remain
/// readable for saved recordings. Calibration never defines the game targets.
/// Diameters are fractions of camera width, independent of capture resolution.
nonisolated struct WallBallReference: Equatable, Sendable {
    let diameters: [Double]

    init?(_ diameters: [Double]) {
        guard [1, 6].contains(diameters.count), diameters.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 0.5 }),
              diameters.max()! / diameters.min()! <= 2 else { return nil }
        self.diameters = diameters
    }

    func diameter(u: Double, v: Double, imageWidth: Double) -> Double {
        if diameters.count == 1 { return diameters[0] * imageWidth }
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
    typealias Sample = WallBallHold.Sample
    typealias Update = WallBallHold.Update
    var board: WallBoard
    var target: Int
    var imageWidth: Double
    private var hold = WallBallHold(duration: holdDuration, minimumSamples: 25)
    static let holdDuration = 3.0
    /// Calibration anchor ID, never a gameplay target. Legacy IDs 1...6 are replay-only.
    static let wallCentre = 0

    init(board: WallBoard, target: Int, imageWidth: Double) {
        self.board = board; self.target = target; self.imageWidth = imageWidth
    }

    mutating func add(_ sample: Sample?, now: Double) -> Update {
        guard let s = sample, (0...6).contains(target), s.usable else {
            return hold.add(nil, now: now)
        }
        let u = target == Self.wallCentre ? 1.5 : Double((target - 1) % 3) + 0.5
        let v = target == Self.wallCentre ? 1.0 : Double((target - 1) / 3) + 0.5
        let mapped = board.boardPoint(CGPoint(x: s.x, y: s.y))
        let top = board.imagePoint(u: u, v: v - 0.5), bottom = board.imagePoint(u: u, v: v + 0.5)
        let left = board.imagePoint(u: u - 0.5, v: v), right = board.imagePoint(u: u + 0.5, v: v)
        let cellSize = min(hypot(top.x - bottom.x, top.y - bottom.y), hypot(left.x - right.x, left.y - right.y))
        guard abs(mapped.x - u) <= 0.32, abs(mapped.y - v) <= 0.32, s.d <= cellSize * 0.85 else {
            return hold.add(nil, now: now)
        }
        let update = hold.add(s, now: now)
        return .init(progress: update.progress, diameter: update.diameter.map { $0 / imageWidth })
    }
}
#endif
