#if DEBUG && BALL_DETECTION_DEBUG
import SwiftUI

/// A static bright masonry face. Idle bricks have no clock or particle emitter.
struct WallBrickTile: View {
    let health: Int
    let initialHealth: Int
    var seed = 1
    var impact = CGPoint(x: 0.5, y: 0.5)

    static func rgb(for seed: Int) -> SIMD3<Double> {
        let palette = [0, 1, 2, 2, 1, 2, 0, 1, 1, 0, 1, 2, 1, 2, 1,
                       2, 0, 2, 0, 1, 2, 1, 2, 0, 2, 1, 0, 2, 1, 0]
        switch palette[(max(1, seed) - 1) % palette.count] {
        case 0: return SIMD3(1, 0.38, 0.22)
        case 1: return SIMD3(1, 0.78, 0.07)
        default: return SIMD3(0.025, 0.78, 1)
        }
    }
    static func tint(for seed: Int) -> Color {
        let c = rgb(for: seed)
        return Color(red: c.x, green: c.y, blue: c.z)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let h = size.height
            if health > 0 {
                ZStack(alignment: .topTrailing) {
                    // Solid side faces extend into the mortar gap. The front
                    // remains exactly the shared hit/damage rectangle.
                    let r = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.025, dy: h * 0.025)
                    let depth = h * 0.14
                    let c = Self.rgb(for: seed)
                    Path { p in
                        p.move(to: CGPoint(x: r.maxX, y: r.minY + h * 0.035))
                        for point in [CGPoint(x: r.maxX + depth, y: r.minY + depth + h * 0.035),
                                      CGPoint(x: r.maxX + depth, y: r.maxY + depth),
                                      CGPoint(x: r.maxX, y: r.maxY)] { p.addLine(to: point) }
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [Self.tint(for: seed).opacity(0.8),
                        Color(red: c.x * 0.43, green: c.y * 0.43, blue: c.z * 0.43)], startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: CGPoint(x: r.minX + h * 0.035, y: r.maxY))
                        for point in [CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.maxX + depth, y: r.maxY + depth),
                                      CGPoint(x: r.minX + depth + h * 0.035, y: r.maxY + depth)] { p.addLine(to: point) }
                        p.closeSubpath()
                    }
                    .fill(Color(red: c.x * 0.42 + 0.08, green: c.y * 0.42 + 0.08, blue: c.z * 0.42 + 0.08))
                    Rectangle().fill(.white)
                        .colorEffect(ShaderLibrary.wallBrickMaterial(
                            .float2(size), .color(Self.tint(for: seed)), .float(Float(seed)),
                            .float(initialHealth == 2 && health == 1 ? 1 : 0), .float(0),
                            .float2(Float(impact.x), Float(impact.y))))

                }
                .frame(width: size.width, height: h)
            }
        }
        .accessibilityLabel(health == 0 ? "Broken brick" : health == initialHealth ? "Solid brick" : "Cracked brick")
    }
}

/// One coordinated explosion per contact, covering all affected material.
/// Convex shards are extruded and rotated in 3D, then projected into a Canvas.
/// No physics world runs between contacts; 60 chunks max, 30 fps, 1.55 seconds.
struct WallBrickExplosion: View {
    static let duration = 1.55
    struct Brick {
        let id: Int
        let frame: CGRect
        let shattered: Bool
    }
    private struct Chunk {
        let centre: CGPoint
        let polygon: [CGPoint]
        let height: Double
        let seed: Int
        let colour: SIMD3<Double>
    }
    let origin: CGPoint
    let ballRadius: CGFloat
    let strength: Double
    private let previewAge: Double?
    private let chunks: [Chunk]
    private let colours: [Color]
    @State private var born = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(bricks: [Brick], origin: CGPoint, ballRadius: CGFloat, strength: Double, previewAge: Double? = nil) {
        self.origin = origin; self.ballRadius = ballRadius; self.strength = strength
        self.previewAge = previewAge
        colours = bricks.map { WallBrickTile.tint(for: $0.id) }
        let broken = max(1, bricks.filter(\.shattered).count)
        let count = max(3, min(8, 40 / broken))
        var pieces: [Chunk] = []
        for brick in bricks.sorted(by: { $0.shattered && !$1.shattered }) {
            let polygons = Self.fragments(in: brick.frame, seed: brick.id, count: brick.shattered ? count : 4)
            for (index, polygon) in polygons.enumerated() where pieces.count < 60 {
                let centre = CGPoint(x: polygon.map(\.x).reduce(0, +) / Double(polygon.count),
                                     y: polygon.map(\.y).reduce(0, +) / Double(polygon.count))
                let scale = brick.shattered ? 1.0 : 0.24
                pieces.append(Chunk(centre: centre,
                    polygon: polygon.map { CGPoint(x: ($0.x - centre.x) * scale, y: ($0.y - centre.y) * scale) },
                    height: brick.frame.height * (brick.shattered ? 1 : 0.32), seed: brick.id * 31 + index,
                    colour: WallBrickTile.rgb(for: brick.id)))
            }
        }
        chunks = pieces
    }

    var body: some View {
        Group {
            if let previewAge {
                Canvas { context, _ in draw(in: &context, age: previewAge) }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
                    Canvas { context, _ in
                        draw(in: &context, age: reduceMotion ? 0.12 : max(0, timeline.date.timeIntervalSince(born)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(in context: inout GraphicsContext, age: Double) {
        let life = max(0, min(1, (Self.duration - age) / 0.40))
        let flash = sqrt(max(0, 1 - age / 0.75))
        let radius = ballRadius * (1.6 + age * 4.0)
        let cyan = Color(red: 0.1, green: 0.85, blue: 1)
        let glow = CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: glow), with: .radialGradient(
            Gradient(stops: [.init(color: .white.opacity(flash), location: 0),
                             .init(color: cyan.opacity(flash * 0.85), location: 0.25),
                             .init(color: cyan.opacity(0), location: 1)]),
            center: origin, startRadius: 0, endRadius: radius))
        // A white-hot core and pointed rays read as an impact on a lit wall.
        // Local to the hit: no permanent full-screen bloom or animated fog.
        let core = ballRadius * (0.22 + flash * 0.30)
        context.fill(Path(ellipseIn: CGRect(x: origin.x - core, y: origin.y - core,
                                           width: core * 2, height: core * 2)), with: .radialGradient(
            Gradient(stops: [.init(color: .white.opacity(flash), location: 0),
                             .init(color: .white.opacity(flash), location: 0.23),
                             .init(color: cyan.opacity(flash * 0.85), location: 0.50),
                             .init(color: cyan.opacity(0), location: 1)]),
            center: origin, startRadius: 0, endRadius: core))
        for i in 0..<8 {
            let angle = Double(i) * .pi / 4 + 0.18
            let length = ballRadius * (i.isMultiple(of: 2) ? 1.2 : 0.75) * (0.7 + flash)
            let tip = CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
            let side = ballRadius * 0.14 * flash
            let ray = Self.path([CGPoint(x: origin.x - sin(angle) * side, y: origin.y + cos(angle) * side),
                                tip, CGPoint(x: origin.x + sin(angle) * side, y: origin.y - cos(angle) * side)])
            context.fill(ray, with: .linearGradient(Gradient(colors: [.white.opacity(flash), cyan.opacity(0)]),
                startPoint: origin, endPoint: tip))
        }
        guard !reduceMotion else { return }
        // Small, local puffs behind the chunks reveal the direction of the
        // fracture. They fade quickly and never cover the whole play surface.
        for i in 0..<6 {
            let n = Self.noise(i + 731), angle = Double(i) * 2.39996
            let drift = ballRadius * age * (0.9 + n)
            let centre = CGPoint(x: origin.x + cos(angle) * drift, y: origin.y + sin(angle) * drift)
            let r = ballRadius * (0.35 + age * 1.5)
            let opacity = sin(min(1, age / 0.85) * .pi) * 0.18
            let tint = colours.isEmpty ? cyan : colours[i % colours.count]
            context.fill(Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)),
                         with: .radialGradient(Gradient(colors: [tint.opacity(opacity), tint.opacity(0)]),
                            center: centre, startRadius: 0, endRadius: r))
        }
        for chunk in chunks { draw(chunk, in: &context, age: age, life: life) }
        // Hot fragments and short luminous streaks shoot from the common impact.
        for i in 0..<32 {
            let n = Self.noise(i + 83), angle = Double(i) * 2.39996
            let distance = ballRadius * (2.5 + n * 3.0) * (0.8 + strength) * age
            let p = CGPoint(x: origin.x + cos(angle) * distance,
                            y: origin.y + sin(angle) * distance + ballRadius * age * age * 2)
            let tint = i.isMultiple(of: 3) ? Color(red: 1, green: 0.65, blue: 0.15)
                : (colours.isEmpty ? cyan : colours[i % colours.count])
            let side = ballRadius * (0.025 + n * 0.055)
            var trail = Path()
            trail.move(to: p)
            trail.addLine(to: CGPoint(x: p.x - cos(angle) * side * 4, y: p.y - sin(angle) * side * 4))
            context.stroke(trail, with: .color(tint.opacity(life * 0.65)), lineWidth: side)
            context.fill(Self.path([CGPoint(x: p.x, y: p.y - side), CGPoint(x: p.x + side, y: p.y),
                                   CGPoint(x: p.x, y: p.y + side), CGPoint(x: p.x - side, y: p.y)]),
                         with: .color((i % 3 == 0 ? Color.white : tint).opacity(life)))
        }
    }

    private func draw(_ chunk: Chunk, in context: inout GraphicsContext, age: Double, life: Double) {
        let h = chunk.height, n = Self.noise(chunk.seed)
        let dx = chunk.centre.x - origin.x, dy = chunk.centre.y - origin.y
        let length = max(1, hypot(dx, dy))
        let flight = max(0, age - min(0.065, length / max(ballRadius, 1) * 0.018) - n * 0.02)
        let angle = atan2(dy, dx) + (Self.noise(chunk.seed + 9) - 0.5) * 0.75
        let travel = h * (1.2 + strength * 1.9) * (0.45 + n * 1.25)
        let x = chunk.centre.x + cos(angle) * travel * flight
        let y = chunk.centre.y + (sin(angle) * travel - h * (0.4 + n)) * flight + h * 2.5 * flight * flight
        let pitch = flight * (1.0 + Self.noise(chunk.seed + 1) * 5)
        let yaw = flight * (n - 0.5) * 10
        let roll = flight * (Self.noise(chunk.seed + 2) - 0.5) * 7
        let thickness = h * (0.22 + n * 0.20)
        let zFlight = -h * (0.9 + n * 1.4) * sin(min(1, flight / 1.4) * .pi)
        let focal = h * 7
        func rotate(_ p: SIMD3<Double>) -> SIMD3<Double> {
            let a = SIMD3(p.x, p.y * cos(pitch) - p.z * sin(pitch), p.y * sin(pitch) + p.z * cos(pitch))
            let b = SIMD3(a.x * cos(yaw) + a.z * sin(yaw), a.y, -a.x * sin(yaw) + a.z * cos(yaw))
            return SIMD3(b.x * cos(roll) - b.y * sin(roll), b.x * sin(roll) + b.y * cos(roll), b.z)
        }
        func project(_ v: SIMD3<Double>) -> CGPoint {
            let perspective = focal / max(focal * 0.3, focal + v.z + zFlight)
            return CGPoint(x: x + v.x * perspective, y: y + v.y * perspective)
        }
        // Inset face, bevel ring, and tapered sides make each piece a chunk
        // of masonry instead of a flat polygon with a rectangular extrusion.
        let front = chunk.polygon.map { rotate(SIMD3($0.x * 0.83, $0.y * 0.83, -thickness / 2)) }
        let rim = chunk.polygon.map { rotate(SIMD3($0.x, $0.y, -thickness * 0.25)) }
        let back = chunk.polygon.map { rotate(SIMD3($0.x * 0.90, $0.y * 0.90, thickness / 2)) }
        var faces: [(points: [SIMD3<Double>], textured: Bool)] = [(front, true), (Array(back.reversed()), true)]
        for i in front.indices {
            let j = (i + 1) % front.count
            faces.append(([front[i], front[j], rim[j], rim[i]], false))
            faces.append(([rim[i], rim[j], back[j], back[i]], false))
        }
        faces.sort { $0.points.map(\.z).reduce(0, +) / Double($0.points.count)
            > $1.points.map(\.z).reduce(0, +) / Double($1.points.count) }
        for item in faces {
            let face = item.points
            let a = face[1] - face[0], b = face[2] - face[0]
            var normal = SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
            let centre = face.reduce(SIMD3<Double>.zero, +) / Double(face.count)
            if normal.x * centre.x + normal.y * centre.y + normal.z * centre.z < 0 { normal = -normal }
            let norm = max(0.001, sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z))
            normal /= norm
            // Cull hidden faces before painting. Only the solid exterior is
            // visible; back edges must not read as a wireframe or paper shard.
            guard normal.z < 0 else { continue }
            let lighting = 0.38 + 0.62 * max(0, -normal.x * 0.35 - normal.y * 0.65 - normal.z * 0.68)
            let c = chunk.colour * lighting + SIMD3<Double>(repeating: 0.07 * lighting)
            let polygon = face.map(project)
            let path = Self.path(polygon)
            var layer = context; layer.opacity = life
            layer.fill(path, with: .linearGradient(Gradient(colors: [
                Color(red: min(1, c.x + 0.18), green: min(1, c.y + 0.18), blue: min(1, c.z + 0.18)),
                Color(red: min(1, c.x), green: min(1, c.y), blue: min(1, c.z))]),
                startPoint: CGPoint(x: x, y: y - h * 0.25), endPoint: CGPoint(x: x, y: y + h * 0.25)))
            layer.stroke(path, with: .color(.white.opacity(0.08 + 0.28 * lighting)), lineWidth: max(0.5, h * 0.008))
            if item.textured {
                // Sparse mineral patches follow the rotating face in 3D.
                // Five small fills per visible front/back, no texture allocation.
                layer.clip(to: path)
                for i in 0..<5 {
                    let a = face[i % face.count], b = face[(i + 1) % face.count]
                    let t = 0.25 + Self.noise(chunk.seed + i * 17) * 0.6
                    let p = centre * (1 - t) + (a * 0.7 + b * 0.3) * t
                    let fleck = Self.path([project(p), project(p + (a - centre) * 0.15), project(p + (b - centre) * 0.12)])
                    layer.fill(fleck, with: .color(i.isMultiple(of: 2) ? .white.opacity(0.20) : .black.opacity(0.16)))
                }
            }
        }
    }

    private static func path(_ points: [CGPoint]) -> Path {
        Path { p in guard let first = points.first else { return }; p.move(to: first)
            // addLines starts a subpath at its first element. Append individual
            // edges so the original vertex is retained for triangles and quads.
            for point in points.dropFirst() { p.addLine(to: point) }
            p.closeSubpath() }
    }
    private static func noise(_ index: Int) -> Double {
        let v = sin(Double(index) * 12.9898) * 43758.5453
        return v - floor(v)
    }
    private static func fragments(in brick: CGRect, seed: Int, count: Int) -> [[CGPoint]] {
        let r = brick.insetBy(dx: brick.width * 0.025, dy: brick.height * 0.025)
        // Farthest-of-three seeded samples avoid a regular grid of mini bricks.
        // The resulting convex Voronoi cells still exactly cover the old face.
        var sites: [CGPoint] = []
        for i in 0..<count {
            let candidates = (0..<3).map { k in CGPoint(
                x: r.minX + (0.05 + noise(seed * 193 + i * 11 + k * 31) * 0.9) * r.width,
                y: r.minY + (0.05 + noise(seed * 337 + i * 23 + k * 47) * 0.9) * r.height) }
            let best = candidates.max { a, b in
                let da = sites.map { hypot($0.x - a.x, $0.y - a.y) }.min() ?? 0
                let db = sites.map { hypot($0.x - b.x, $0.y - b.y) }.min() ?? 0
                return da < db
            }!
            sites.append(best)
        }
        return sites.indices.map { i in
            var poly = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                        CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            for j in sites.indices where j != i {
                let a = sites[i], b = sites[j], nx = b.x - a.x, ny = b.y - a.y
                let threshold = (b.x * b.x + b.y * b.y - a.x * a.x - a.y * a.y) / 2
                var clipped: [CGPoint] = []
                for k in poly.indices {
                    let p = poly[k], q = poly[(k + 1) % poly.count]
                    let dp = p.x * nx + p.y * ny - threshold, dq = q.x * nx + q.y * ny - threshold
                    if dp <= 0 { clipped.append(p) }
                    if (dp <= 0) != (dq <= 0) {
                        let t = dp / (dp - dq)
                        clipped.append(CGPoint(x: p.x + t * (q.x - p.x), y: p.y + t * (q.y - p.y)))
                    }
                }
                poly = clipped
            }
            return poly
        }.filter { $0.count >= 3 }
    }
}
#endif
