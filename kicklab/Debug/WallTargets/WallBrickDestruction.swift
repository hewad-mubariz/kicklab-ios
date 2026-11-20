#if DEBUG
import CoreGraphics
import Foundation

/// The detected ball's projected radius, mapped into the wall plane. Two basis
/// vectors preserve the local perspective/shear instead of assuming a circle.
/// This is an arcade contact footprint, not measured ball deformation or force.
nonisolated struct WallContactFootprint: Equatable, Sendable {
    let xAxis: CGPoint
    let yAxis: CGPoint
    var determinant: Double { xAxis.x * yAxis.y - xAxis.y * yAxis.x }
    var isValid: Bool {
        [xAxis.x, xAxis.y, yAxis.x, yAxis.y].allSatisfy(\.isFinite)
            && abs(determinant) > 0.000001
            && (0.005...0.5).contains(hypot(xAxis.x, xAxis.y))
            && (0.005...0.5).contains(hypot(yAxis.x, yAxis.y))
    }
    var json: [String: Any] { ["xAxis": [Double(xAxis.x), Double(xAxis.y)], "yAxis": [Double(yAxis.x), Double(yAxis.y)]] }
    static let preview = WallContactFootprint(xAxis: CGPoint(x: 0.14, y: 0), yAxis: CGPoint(x: 0, y: 0.17))

    static func measured(board: WallBoard, point: CGPoint, diameter: Double) -> Self? {
        guard diameter.isFinite, diameter > 0 else { return nil }
        let r = diameter / 2
        let left = board.boardPoint(CGPoint(x: point.x - r, y: point.y))
        let right = board.boardPoint(CGPoint(x: point.x + r, y: point.y))
        let top = board.boardPoint(CGPoint(x: point.x, y: point.y - r))
        let bottom = board.boardPoint(CGPoint(x: point.x, y: point.y + r))
        let f = Self(xAxis: CGPoint(x: (right.x - left.x) / 2, y: (right.y - left.y) / 2),
                     yAxis: CGPoint(x: (bottom.x - top.x) / 2, y: (bottom.y - top.y) / 2))
        return f.isValid ? f : nil
    }

    /// Distance to the nearest point on a brick, in ball-radius units. Transform
    /// its rectangle into a parallelogram in footprint space, then test edges.
    func distance(to rect: CGRect, from centre: CGPoint) -> Double {
        guard isValid else { return .infinity }
        if rect.contains(centre) { return 0 }
        func transformed(_ x: Double, _ y: Double) -> CGPoint {
            let u = x - centre.x, v = y - centre.y
            return CGPoint(x: (u * yAxis.y - v * yAxis.x) / determinant,
                           y: (v * xAxis.x - u * xAxis.y) / determinant)
        }
        let p = [transformed(rect.minX, rect.minY), transformed(rect.maxX, rect.minY),
                 transformed(rect.maxX, rect.maxY), transformed(rect.minX, rect.maxY)]
        return p.indices.map { i in
            let a = p[i], b = p[(i + 1) % p.count], dx = b.x - a.x, dy = b.y - a.y
            let t = max(0, min(1, -(a.x * dx + a.y * dy) / max(1e-12, dx * dx + dy * dy)))
            return hypot(a.x + t * dx, a.y + t * dy)
        }.min() ?? .infinity
    }
}

nonisolated struct WallBrickDamage: Equatable, Sendable, Identifiable {
    let id: Int
    let before: Int
    let after: Int
    var amount: Int { before - after }
    var shattered: Bool { after == 0 }
    var json: [String: Any] { ["brick": id, "before": before, "after": after] }
}

nonisolated enum WallBrickDestruction {
    static let coreRadius = 1.15
    static let shockRadius = 2.0

    static func damage(at centre: CGPoint, footprint: WallContactFootprint,
                       layout: WallTargetLayout, health: [Int: Int]) -> [WallBrickDamage] {
        guard centre.x.isFinite, centre.y.isFinite, (0...3).contains(centre.x),
              (0...2).contains(centre.y), footprint.isValid else { return [] }
        return layout.targets.compactMap { brick in
            let before = health[brick.id] ?? brick.health
            guard before > 0 else { return nil }
            let distance = footprint.distance(to: brick.hitFrame, from: centre)
            guard distance <= shockRadius else { return nil }
            let after = distance <= coreRadius ? 0 : max(0, before - 1)
            return WallBrickDamage(id: brick.id, before: before, after: after)
        }
    }
}
#endif
