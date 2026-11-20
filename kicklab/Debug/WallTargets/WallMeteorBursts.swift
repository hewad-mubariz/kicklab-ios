#if DEBUG && BALL_DETECTION_DEBUG
import SwiftUI

/// The same extruded, rotating-fragment approach as Brick Blast, with larger
/// molten faces and a short central flash. No particle world runs between hits.
struct WallMeteorBursts: View {
    let events: [WallArcadeEvent]
    let time: Double
    static let duration = 1.35

    var body: some View {
        Canvas { context, size in
            for event in events.suffix(12) {
                let age = time - event.time
                guard age >= 0, age < Self.duration, let point = event.point,
                      event.kind == "meteor_destroyed" || event.kind == "city_hit" else { continue }
                let origin = CGPoint(x: point.x / 3 * size.width, y: point.y / 2 * size.height)
                Self.draw(in: &context, at: origin, height: size.height, age: age, seed: event.id)
            }
        }.allowsHitTesting(false)
    }

    private static func draw(in context: inout GraphicsContext, at origin: CGPoint, height h: Double, age: Double, seed: Int) {
        let life = min(1, max(0, (duration - age) / 0.5))
        let flash = pow(max(0, 1 - age / 0.5), 0.6)
        let radius = h * (0.07 + age * 0.16)
        context.fill(Path(ellipseIn: CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2)),
            with: .radialGradient(Gradient(stops: [
                .init(color: .white.opacity(flash), location: 0),
                .init(color: .yellow.opacity(flash * 0.9), location: 0.20),
                .init(color: .orange.opacity(life * 0.32), location: 0.55),
                .init(color: .orange.opacity(0), location: 1)]),
                center: origin, startRadius: 0, endRadius: radius))
        // Asymmetric white-hot rays make the first instant read as a fracture.
        for i in 0..<9 where flash > 0 {
            let angle = Double(i) * .pi * 2 / 9 + Double(seed) * 0.3 + noise(i * 13 + seed) * 0.5
            let length = h * (0.09 + noise(i + seed) * 0.07) * (0.6 + flash)
            let width = h * 0.018 * flash
            let tip = CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
            let ray = polygon([CGPoint(x: origin.x - sin(angle) * width, y: origin.y + cos(angle) * width),
                               tip, CGPoint(x: origin.x + sin(angle) * width, y: origin.y - cos(angle) * width)])
            context.fill(ray, with: .linearGradient(Gradient(colors: [.white.opacity(flash), .yellow.opacity(flash * 0.8), .orange.opacity(0)]),
                startPoint: origin, endPoint: tip))
        }
        // Sixteen solid, bevelled chunks stay large enough to read on a wall.
        for i in 0..<16 {
            chunk(in: &context, origin: origin, height: h, age: age, life: life, index: i, seed: seed)
        }
        for i in 0..<24 {
            let angle = Double(i) * 2.39996 + Double(seed)
            let distance = h * (0.06 + age * (0.25 + noise(i * 7 + seed) * 0.25))
            let p = CGPoint(x: origin.x + cos(angle) * distance,
                            y: origin.y + sin(angle) * distance + h * age * age * 0.14)
            let side = h * (0.0025 + noise(i + 91) * 0.003) * life
            var trail = Path(); trail.move(to: p)
            trail.addLine(to: CGPoint(x: p.x - cos(angle) * side * 7, y: p.y - sin(angle) * side * 7))
            context.stroke(trail, with: .color(.orange.opacity(life * 0.65)), lineWidth: side * 1.6)
            context.fill(Path(ellipseIn: CGRect(x: p.x - side, y: p.y - side, width: side * 2, height: side * 2)),
                         with: .color(.yellow.opacity(life)))
        }
    }

    private static func chunk(in context: inout GraphicsContext, origin: CGPoint, height h: Double,
                              age: Double, life: Double, index i: Int, seed: Int) {
        let n = noise(i * 17 + seed * 71)
        let angle = Double(i) * 2.39996 + Double(seed) * 0.37
        let travel = h * (0.008 + age * (0.055 + n * 0.49))
        let x = origin.x + cos(angle) * travel
        let y = origin.y + sin(angle) * travel + h * (age * age * 0.20 - age * 0.06)
        let radius = h * (0.012 + noise(i * 31 + seed * 5) * 0.029)
        let pitch = angle + age * (1.8 + n * 3), yaw = age * (n - 0.5) * 8, roll = angle - age * 2
        let thickness = radius * 0.85
        func rotate(_ p: SIMD3<Double>) -> SIMD3<Double> {
            let a = SIMD3(p.x, p.y * cos(pitch) - p.z * sin(pitch), p.y * sin(pitch) + p.z * cos(pitch))
            let b = SIMD3(a.x * cos(yaw) + a.z * sin(yaw), a.y, -a.x * sin(yaw) + a.z * cos(yaw))
            return SIMD3(b.x * cos(roll) - b.y * sin(roll), b.x * sin(roll) + b.y * cos(roll), b.z)
        }
        func project(_ p: SIMD3<Double>) -> CGPoint {
            let scale = h * 1.2 / (h * 1.2 + p.z - h * age * n * 0.12)
            return CGPoint(x: x + p.x * scale, y: y + p.y * scale)
        }
        let sides = 3 + i % 3
        let vertices = (0..<sides).map { j -> SIMD3<Double> in
            let a = Double(j) * .pi * 2 / Double(sides)
            let r = radius * (0.55 + noise(i * 19 + j * 7) * 0.65)
            return SIMD3(cos(a) * r, sin(a) * r, 0)
        }
        let front = vertices.map { rotate(SIMD3($0.x * 0.82, $0.y * 0.82, -thickness / 2)) }
        let rim = vertices.map { rotate(SIMD3($0.x, $0.y, -thickness * 0.25)) }
        let back = vertices.map { rotate(SIMD3($0.x * 0.9, $0.y * 0.9, thickness / 2)) }
        // Face, luminous bevel, and darker side have distinct materials.
        var faces: [([SIMD3<Double>], Int)] = [(front, 0), (Array(back.reversed()), 0)]
        for j in 0..<sides {
            let k = (j + 1) % sides
            faces.append(([front[j], front[k], rim[k], rim[j]], 1))
            faces.append(([rim[j], rim[k], back[k], back[j]], 2))
        }
        faces.sort { $0.0.map(\.z).reduce(0, +) / Double($0.0.count) > $1.0.map(\.z).reduce(0, +) / Double($1.0.count) }
        context.fill(Path(ellipseIn: CGRect(x: x - radius * 2, y: y - radius * 2, width: radius * 4, height: radius * 4)),
            with: .radialGradient(Gradient(colors: [.orange.opacity(life * 0.28), .orange.opacity(0)]),
                center: CGPoint(x: x, y: y), startRadius: 0, endRadius: radius * 2))
        for (face, material) in faces {
            let a = face[1] - face[0], b = face[2] - face[0]
            var normal = SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
            let centre = face.reduce(SIMD3<Double>.zero, +) / Double(face.count)
            if normal.x * centre.x + normal.y * centre.y + normal.z * centre.z < 0 { normal = -normal }
            normal /= max(0.00001, sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z))
            guard normal.z < 0 else { continue }
            let light = 0.35 + 0.65 * max(0, -normal.x * 0.4 - normal.y * 0.6 - normal.z * 0.7)
            let bright = Color(red: 1, green: 0.30 + light * 0.40, blue: 0.03 + light * 0.12)
            let dark = Color(red: 0.45 + light * 0.40, green: 0.10 + light * 0.23, blue: 0.02)
            let bevel = Color(red: 1, green: 0.70 + light * 0.25, blue: 0.16 + light * 0.32)
            let colors = material == 1 ? [bevel, bright] : material == 2 ? [dark, bright] : [bright, dark]
            let shape = polygon(face.map(project))
            var layer = context; layer.opacity = life
            layer.fill(shape, with: .linearGradient(Gradient(colors: colors),
                startPoint: CGPoint(x: x - radius, y: y - radius), endPoint: CGPoint(x: x + radius, y: y + radius)))
            layer.stroke(shape, with: .color(.yellow.opacity(0.8)), lineWidth: max(0.7, h * 0.002))
            if material == 0 {
                let seam = polygon([project(centre), project(face[0] * 0.75 + centre * 0.25),
                                    project(face[1] * 0.45 + centre * 0.55)])
                layer.fill(seam, with: .color(.white.opacity(0.12)))
            }
        }
    }
    private static func polygon(_ points: [CGPoint]) -> Path {
        Path { p in
            guard let first = points.first else { return }
            p.move(to: first)
            for point in points.dropFirst() { p.addLine(to: point) }
            p.closeSubpath()
        }
    }
    private static func noise(_ index: Int) -> Double {
        let v = sin(Double(index) * 12.9898) * 43758.5453
        return v - floor(v)
    }
}
#endif
