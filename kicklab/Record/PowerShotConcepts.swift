#if DEBUG
import SwiftUI
import UIKit

/// Power Shot effect directions, for review only. Launch with
/// --session-design powershot-effects --concept <effect> --shot-scene <image path>.
struct PowerShotEffectConceptView: View {
    let effect: String
    let scenePath: String?

    var body: some View {
        GeometryReader { geometry in
            let shot = ShotPath(size: geometry.size)
            ZStack {
                ShotScene(path: scenePath, manga: effect == "impact")
                Canvas { context, _ in
                    switch effect {
                    case "comet": ShotEffects.comet(context, shot, head: 0.42)
                    case "fire": ShotEffects.fire(context, shot, head: 0.42)
                    case "lightning": ShotEffects.lightning(context, shot, head: 0.42)
                    case "impact": ShotEffects.impact(context, shot)
                    case "boom": ShotEffects.sonicBoom(context, shot, head: 0.2)
                    case "strobe": ShotEffects.strobe(context, shot, head: 0.48)
                    case "ribbon": ShotEffects.ribbon(context, shot)
                    default: ShotEffects.tracer(context, shot, head: 0.42)
                    }
                }
                labels(shot)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private func labels(_ shot: ShotPath) -> some View {
        switch effect {
        case "tracer":
            let ball = shot.point(0.42)
            ShotTag(text: "94 km/h", lime: true)
                .position(x: ball.x + 54, y: ball.y - 26)
        case "boom":
            let ball = shot.point(0.2)
            ShotTag(text: "112 km/h", lime: false)
                .position(x: ball.x - 70, y: ball.y - 40)
        case "ribbon":
            let mark = shot.widestBend()
            ShotTag(text: "Banana · 1.8 m bend", lime: true)
                .position(x: (mark.onPath.x + mark.onChord.x) / 2 - 12, y: (mark.onPath.y + mark.onChord.y) / 2 + 30)
        default:
            EmptyView()
        }
    }
}

let shotLime = TrainingHomeStyle.lime

struct ShotTag: View {
    let text: String
    let lime: Bool

    var body: some View {
        Text(text)
            .font(TrainingHomeStyle.display(20, relativeTo: .headline))
            .padding(.top, 3)
            .foregroundStyle(lime ? TrainingHomeStyle.buttonInk : .white)
            .padding(.horizontal, 12).frame(height: 30)
            .background(lime ? AnyShapeStyle(shotLime) : AnyShapeStyle(.black.opacity(0.55)), in: .capsule)
            .overlay { Capsule().strokeBorder(.white.opacity(lime ? 0.4 : 0.5)) }
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
    }
}

/// The empty stadium seen from behind the shooter, pulled in on the goal.
struct ShotScene: View {
    let path: String?
    var manga = false
    var zoom: CGFloat = 1.75
    var anchorY: CGFloat = 0.48
    var shift: CGFloat = -0.08

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let path, let image = UIImage(contentsOfFile: path) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [.black, Color(red: 0.05, green: 0.3, blue: 0.1)], startPoint: .top, endPoint: .bottom)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .scaleEffect(zoom, anchor: UnitPoint(x: 0.5, y: anchorY))
            .offset(y: geometry.size.height * shift)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .grayscale(manga ? 1 : 0)
            .contrast(manga ? 1.9 : 1.05)
            .brightness(manga ? -0.2 : -0.1)
            .overlay {
                LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0), .init(color: .clear, location: 0.22),
                                       .init(color: .clear, location: 0.75), .init(color: .black.opacity(0.35), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

/// A curled strike from just in front of the camera into the top corner.
struct ShotPath {
    let size: CGSize
    let p0, p1, p2, p3: CGPoint

    let ballScale: CGFloat

    /// Control points as fractions of the frame.
    init(size: CGSize, points: [CGPoint] = [CGPoint(x: 0.3, y: 0.88), CGPoint(x: 0.9, y: 0.66),
                                             CGPoint(x: 0.88, y: 0.4), CGPoint(x: 0.62, y: 0.41)],
         ballScale: CGFloat = 0.1) {
        self.size = size
        self.ballScale = ballScale
        let scaled = points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        p0 = scaled[0]; p1 = scaled[1]; p2 = scaled[2]; p3 = scaled[3]
    }

    func point(_ t: Double) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                       y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    func tangent(_ t: Double) -> CGVector {
        let a = point(max(0, t - 0.002)), b = point(min(1, t + 0.002))
        let dx = b.x - a.x, dy = b.y - a.y, length = max(0.0001, hypot(dx, dy))
        return CGVector(dx: dx / length, dy: dy / length)
    }

    func normal(_ t: Double) -> CGVector { let v = tangent(t); return CGVector(dx: -v.dy, dy: v.dx) }

    /// Perspective: big at the foot, small at the goal.
    func radius(_ t: Double) -> CGFloat { size.width * ballScale / (1 + 3.4 * t) }

    func line(from a: Double, to b: Double, steps: Int = 90) -> Path {
        var path = Path()
        for i in 0...steps {
            let p = point(a + (b - a) * Double(i) / Double(steps))
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        return path
    }

    /// A band along the flight whose half-width is given per point.
    func band(from a: Double, to b: Double, steps: Int = 90, halfWidth: (Double, Double) -> CGFloat) -> Path {
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in 0...steps {
            let s = Double(i) / Double(steps), t = a + (b - a) * s
            let p = point(t), n = normal(t), w = halfWidth(t, s)
            left.append(CGPoint(x: p.x + n.dx * w, y: p.y + n.dy * w))
            right.append(CGPoint(x: p.x - n.dx * w, y: p.y - n.dy * w))
        }
        var path = Path()
        path.addLines(left + right.reversed())
        path.closeSubpath()
        return path
    }

    /// Where the flight strays furthest from the straight line between foot and goal.
    func widestBend() -> (onPath: CGPoint, onChord: CGPoint, t: Double) {
        let dx = p3.x - p0.x, dy = p3.y - p0.y, length2 = dx * dx + dy * dy
        var best = (onPath: p0, onChord: p0, t: 0.0, distance: CGFloat(0))
        for i in 0...200 {
            let t = Double(i) / 200, p = point(t)
            let k = max(0, min(1, ((p.x - p0.x) * dx + (p.y - p0.y) * dy) / length2))
            let foot = CGPoint(x: p0.x + dx * k, y: p0.y + dy * k)
            let distance = hypot(p.x - foot.x, p.y - foot.y)
            if distance > best.distance { best = (p, foot, t, distance) }
        }
        return (best.onPath, best.onChord, best.t)
    }
}

private struct Seeded {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func unit() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func gauss() -> Double { (unit() + unit() + unit() - 1.5) / 0.75 }
}

enum ShotEffects {
    static func ball(_ c: GraphicsContext, at p: CGPoint, radius: CGFloat, angle: Double = 0.6,
                     squash: CGFloat = 1, opacity: Double = 1) {
        var layer = c
        layer.opacity = opacity
        layer.translateBy(x: p.x, y: p.y)
        layer.rotate(by: .radians(angle))
        layer.scaleBy(x: squash, y: 1 / squash)
        let image = layer.resolve(Image("signin-ball"))
        layer.draw(image, in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
    }

    static func glow(_ c: GraphicsContext, at p: CGPoint, radius: CGFloat, colors: [Color]) {
        c.fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)),
               with: .radialGradient(Gradient(colors: colors), center: p, startRadius: 0, endRadius: radius))
    }

    static func groundRing(_ c: GraphicsContext, at p: CGPoint, width: CGFloat, color: Color, line: CGFloat) {
        let ring = Path(ellipseIn: CGRect(x: p.x - width / 2, y: p.y - width * 0.11, width: width, height: width * 0.22))
        c.drawLayer { l in
            l.addFilter(.blur(radius: 6))
            l.stroke(ring, with: .color(color.opacity(0.8)), lineWidth: line * 2.5)
        }
        c.stroke(ring, with: .color(color), lineWidth: line)
    }

    // MARK: Trails

    static func tracer(_ c: GraphicsContext, _ s: ShotPath, head: Double) {
        let band = s.band(from: 0, to: head) { t, _ in 1.2 + s.radius(t) * 0.09 }
        c.drawLayer { l in
            l.addFilter(.blur(radius: 8))
            l.fill(s.band(from: 0, to: head) { t, _ in 3 + s.radius(t) * 0.2 }, with: .color(shotLime.opacity(0.7)))
        }
        c.fill(band, with: .color(shotLime))
        c.fill(s.band(from: 0, to: head) { t, _ in 0.4 + s.radius(t) * 0.025 }, with: .color(.white.opacity(0.9)))
        groundRing(c, at: s.point(0), width: 70, color: shotLime, line: 1.6)
        let p = s.point(head)
        glow(c, at: p, radius: s.radius(head) * 2.4, colors: [shotLime.opacity(0.6), .clear])
        ball(c, at: p, radius: s.radius(head))
    }

    static func comet(_ c: GraphicsContext, _ s: ShotPath, head: Double) {
        let ice = Color(red: 0.55, green: 0.88, blue: 1)
        let tail = s.point(0), tip = s.point(head)
        c.drawLayer { l in
            l.addFilter(.blur(radius: 16))
            l.fill(s.band(from: 0, to: head) { t, f in s.radius(t) * 2.2 * pow(f, 0.7) }, with: .color(ice.opacity(0.55)))
        }
        c.drawLayer { l in
            l.blendMode = .plusLighter
            l.addFilter(.blur(radius: 2.5))
            l.fill(s.band(from: 0, to: head) { t, f in s.radius(t) * 1.05 * pow(f, 0.8) },
                   with: .linearGradient(Gradient(colors: [ice.opacity(0), ice.opacity(0.75), .white]), startPoint: tail, endPoint: tip))
            l.fill(s.band(from: head * 0.35, to: head) { t, f in s.radius(t) * 0.42 * pow(f, 1.2) }, with: .color(.white.opacity(0.95)))
        }
        var g = Seeded(11)
        c.drawLayer { l in
            l.blendMode = .plusLighter
            for _ in 0..<70 {
                let t = head * (1 - pow(g.unit(), 1.4)), f = t / head
                let p = s.point(t), n = s.normal(t)
                let off = g.gauss() * s.radius(t) * 1.4
                let q = CGPoint(x: p.x + n.dx * off, y: p.y + n.dy * off)
                let r = (0.6 + g.unit() * 1.6) * (0.4 + f)
                l.fill(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.3 + 0.6 * f)))
            }
        }
        glow(c, at: tip, radius: s.radius(head) * 4, colors: [.white.opacity(0.9), ice.opacity(0.35), .clear])
        ball(c, at: tip, radius: s.radius(head))
    }

    static func fire(_ c: GraphicsContext, _ s: ShotPath, head: Double) {
        var g = Seeded(3)
        // Scorched turf where the ball was struck.
        let k = s.point(0)
        c.drawLayer { l in
            l.addFilter(.blur(radius: 7))
            l.fill(Path(ellipseIn: CGRect(x: k.x - 52, y: k.y - 11, width: 104, height: 22)), with: .color(.black.opacity(0.65)))
            l.stroke(Path(ellipseIn: CGRect(x: k.x - 48, y: k.y - 10, width: 96, height: 20)), with: .color(.orange.opacity(0.9)), lineWidth: 4)
        }
        // Smoke behind the flames.
        c.drawLayer { l in
            l.addFilter(.blur(radius: 10))
            for _ in 0..<40 {
                let t = head * g.unit() * 0.6, p = s.point(t), n = s.normal(t)
                let off = g.gauss() * s.radius(t) * 0.9
                let r = s.radius(t) * (0.6 + g.unit())
                l.fill(Path(ellipseIn: CGRect(x: p.x + n.dx * off - r, y: p.y + n.dy * off - r - 6, width: r * 2, height: r * 2)),
                       with: .color(Color(white: 0.25).opacity(0.22)))
            }
        }
        func flames(count: Int, blur: CGFloat, scale: CGFloat, seed: UInt64) {
            var g = Seeded(seed)
            c.drawLayer { l in
                l.blendMode = .plusLighter
                l.addFilter(.blur(radius: blur))
                for _ in 0..<count {
                    let t = head * (1 - pow(g.unit(), 1.7)), f = t / head
                    let p = s.point(t), n = s.normal(t), tan = s.tangent(t)
                    let spread = s.radius(t) * (0.3 + 0.8 * (1 - f))
                    let off = g.gauss() * spread, back = g.unit() * s.radius(t) * 0.9
                    let q = CGPoint(x: p.x + n.dx * off - tan.dx * back, y: p.y + n.dy * off - tan.dy * back - (1 - f) * 10)
                    let r = s.radius(t) * (0.3 + 0.7 * g.unit()) * (0.45 + 0.65 * f) * scale
                    let color: Color = f > 0.86 ? Color(red: 1, green: 0.95, blue: 0.7)
                        : f > 0.6 ? Color(red: 1, green: 0.72, blue: 0.22)
                        : f > 0.3 ? Color(red: 1, green: 0.42, blue: 0.08)
                        : Color(red: 0.8, green: 0.16, blue: 0.04)
                    l.fill(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2)),
                           with: .color(color.opacity(0.18 + 0.45 * f)))
                }
            }
        }
        flames(count: 160, blur: 12, scale: 1.8, seed: 5)
        flames(count: 420, blur: 2.2, scale: 1, seed: 9)
        c.drawLayer { l in
            l.blendMode = .plusLighter
            for _ in 0..<80 {
                let t = head * g.unit(), p = s.point(t), n = s.normal(t)
                let off = g.gauss() * s.radius(t) * 2.4
                let r = 0.6 + g.unit() * 1.6
                l.fill(Path(ellipseIn: CGRect(x: p.x + n.dx * off - r, y: p.y + n.dy * off - r - g.unit() * 14, width: r * 2, height: r * 2)),
                       with: .color(Color(red: 1, green: 0.65 + g.unit() * 0.3, blue: 0.2)))
            }
        }
        let tip = s.point(head)
        glow(c, at: tip, radius: s.radius(head) * 3.2, colors: [Color(red: 1, green: 0.85, blue: 0.4).opacity(0.9), .orange.opacity(0.3), .clear])
        ball(c, at: tip, radius: s.radius(head))
        c.drawLayer { l in
            l.blendMode = .plusLighter
            glow(l, at: tip, radius: s.radius(head) * 1.1, colors: [.orange.opacity(0.0), .orange.opacity(0.45)])
        }
    }

    static func lightning(_ c: GraphicsContext, _ s: ShotPath, head: Double) {
        let bolt = Color(red: 1, green: 0.86, blue: 0.3)
        var g = Seeded(21)
        func jagged(from a: Double, to b: Double, segments: Int, amplitude: CGFloat) -> Path {
            var path = Path()
            for i in 0...segments {
                let t = a + (b - a) * Double(i) / Double(segments)
                let p = s.point(t), n = s.normal(t)
                let off = (i == 0 || i == segments) ? 0 : (g.unit() - 0.5) * 2 * s.radius(t) * amplitude
                let q = CGPoint(x: p.x + n.dx * off, y: p.y + n.dy * off)
                i == 0 ? path.move(to: q) : path.addLine(to: q)
            }
            return path
        }
        var bolts = jagged(from: 0, to: head, segments: 26, amplitude: 0.5)
        bolts.addPath(jagged(from: 0.06, to: head, segments: 18, amplitude: 0.85))
        var branches = Path()
        for _ in 0..<5 {
            let t = head * (0.25 + g.unit() * 0.7)
            var p = s.point(t)
            let n = s.normal(t), tan = s.tangent(t), side: CGFloat = g.unit() < 0.5 ? -1 : 1
            branches.move(to: p)
            for _ in 0..<4 {
                let step = s.radius(t) * (0.45 + g.unit() * 0.5)
                p = CGPoint(x: p.x + (n.dx * side * 0.9 - tan.dx * 0.5) * step + (g.unit() - 0.5) * step,
                            y: p.y + (n.dy * side * 0.9 - tan.dy * 0.5) * step + (g.unit() - 0.5) * step)
                branches.addLine(to: p)
            }
        }
        let joins = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
        c.drawLayer { l in
            l.blendMode = .plusLighter
            l.addFilter(.blur(radius: 12))
            l.stroke(bolts, with: .color(bolt.opacity(0.9)), style: joins.with(width: 12))
            l.stroke(branches, with: .color(bolt.opacity(0.6)), style: joins.with(width: 6))
        }
        c.drawLayer { l in
            l.blendMode = .plusLighter
            l.stroke(bolts, with: .color(bolt), style: joins.with(width: 3.4))
            l.stroke(branches, with: .color(bolt.opacity(0.85)), style: joins.with(width: 1.6))
            l.stroke(bolts, with: .color(.white), style: joins.with(width: 1.3))
        }
        let k = s.point(0)
        c.drawLayer { l in
            l.blendMode = .plusLighter
            for i in 0..<9 {
                let angle = Double.pi * (1.1 + 0.8 * Double(i) / 8), length = 10 + g.unit() * 16
                var spark = Path()
                spark.move(to: CGPoint(x: k.x + cos(angle) * 10, y: k.y + sin(angle) * 4))
                spark.addLine(to: CGPoint(x: k.x + cos(angle) * length * 1.6, y: k.y + sin(angle) * length * 0.7))
                l.stroke(spark, with: .color(bolt), lineWidth: 1.4)
            }
        }
        let tip = s.point(head)
        glow(c, at: tip, radius: s.radius(head) * 5, colors: [.white, bolt.opacity(0.5), .clear])
        ball(c, at: tip, radius: s.radius(head))
    }

    // MARK: Moments

    static func impact(_ c: GraphicsContext, _ s: ShotPath) {
        let p = s.point(0.015), r = s.radius(0.015)
        var g = Seeded(31)
        // Manga speed lines rushing out of the strike.
        c.drawLayer { l in
            for _ in 0..<85 {
                let angle = g.unit() * 2 * .pi, inner = r * (2.6 + g.unit() * 4), width = 0.4 + g.unit() * 2.6
                let dir = CGVector(dx: cos(angle), dy: sin(angle)), perp = CGVector(dx: -dir.dy, dy: dir.dx)
                var wedge = Path()
                wedge.move(to: CGPoint(x: p.x + dir.dx * inner, y: p.y + dir.dy * inner))
                wedge.addLine(to: CGPoint(x: p.x + dir.dx * 1400 + perp.dx * width * 6, y: p.y + dir.dy * 1400 + perp.dy * width * 6))
                wedge.addLine(to: CGPoint(x: p.x + dir.dx * 1400 - perp.dx * width * 6, y: p.y + dir.dy * 1400 - perp.dy * width * 6))
                wedge.closeSubpath()
                l.fill(wedge, with: .color(.white.opacity(0.25 + g.unit() * 0.45)))
            }
        }
        // Burst behind the ball.
        var star = Path()
        for i in 0..<24 {
            let angle = Double(i) / 24 * 2 * .pi, radius = i % 2 == 0 ? r * 2.6 : r * 1.4
            let q = CGPoint(x: p.x + cos(angle) * radius, y: p.y + sin(angle) * radius)
            i == 0 ? star.move(to: q) : star.addLine(to: q)
        }
        star.closeSubpath()
        c.fill(star, with: .color(.white))
        groundRing(c, at: CGPoint(x: p.x, y: p.y + r * 0.9), width: 190, color: shotLime, line: 3)
        groundRing(c, at: CGPoint(x: p.x, y: p.y + r * 0.9), width: 300, color: shotLime.opacity(0.5), line: 1.4)
        // Turf thrown up by the strike.
        for _ in 0..<70 {
            let angle = -.pi * (0.1 + g.unit() * 0.8), distance = r * (1.4 + g.unit() * 4)
            let q = CGPoint(x: p.x + cos(angle) * distance * 1.6, y: p.y + r * 0.6 + sin(angle) * distance)
            var fleck = Path(roundedRect: CGRect(x: -1.2, y: -4, width: 2.4, height: 8), cornerRadius: 1)
            fleck = fleck.applying(CGAffineTransform(rotationAngle: g.unit() * .pi).concatenating(CGAffineTransform(translationX: q.x, y: q.y)))
            c.fill(fleck, with: .color(g.unit() < 0.7 ? Color(red: 0.35, green: 0.75, blue: 0.3) : .white))
        }
        ball(c, at: p, radius: r, angle: 0.2, squash: 1.16)
    }

    static func sonicBoom(_ c: GraphicsContext, _ s: ShotPath, head: Double) {
        let p = s.point(head), r = s.radius(head), tan = s.tangent(head), n = s.normal(head)
        let angle = atan2(tan.dy, tan.dx)
        // A thin contrail back to the strike.
        c.drawLayer { l in
            l.addFilter(.blur(radius: 3))
            l.fill(s.band(from: 0, to: head) { t, f in s.radius(t) * 0.3 * f }, with: .color(.white.opacity(0.4)))
        }
        // The vapour cone, opening behind the ball.
        var cone = Path()
        cone.move(to: CGPoint(x: p.x + tan.dx * r * 0.4, y: p.y + tan.dy * r * 0.4))
        cone.addQuadCurve(to: CGPoint(x: p.x - tan.dx * r * 5 + n.dx * r * 3.2, y: p.y - tan.dy * r * 5 + n.dy * r * 3.2),
                          control: CGPoint(x: p.x - tan.dx * r * 1.2 + n.dx * r * 2.4, y: p.y - tan.dy * r * 1.2 + n.dy * r * 2.4))
        cone.addQuadCurve(to: CGPoint(x: p.x - tan.dx * r * 5 - n.dx * r * 3.2, y: p.y - tan.dy * r * 5 - n.dy * r * 3.2),
                          control: CGPoint(x: p.x - tan.dx * r * 6.2, y: p.y - tan.dy * r * 6.2))
        cone.addQuadCurve(to: CGPoint(x: p.x + tan.dx * r * 0.4, y: p.y + tan.dy * r * 0.4),
                          control: CGPoint(x: p.x - tan.dx * r * 1.2 - n.dx * r * 2.4, y: p.y - tan.dy * r * 1.2 - n.dy * r * 2.4))
        cone.closeSubpath()
        c.drawLayer { l in
            l.addFilter(.blur(radius: 6))
            l.fill(cone, with: .linearGradient(Gradient(colors: [.white.opacity(0.9), .white.opacity(0.35), .white.opacity(0)]),
                                                startPoint: p, endPoint: CGPoint(x: p.x - tan.dx * r * 5.5, y: p.y - tan.dy * r * 5.5)))
        }
        for k in 1...3 {
            let centre = CGPoint(x: p.x - tan.dx * r * 1.7 * CGFloat(k), y: p.y - tan.dy * r * 1.7 * CGFloat(k))
            let along = r * (0.32 + 0.12 * CGFloat(k)), across = r * (1.5 + 0.75 * CGFloat(k))
            let ring = Path(ellipseIn: CGRect(x: -along, y: -across, width: along * 2, height: across * 2))
                .applying(CGAffineTransform(rotationAngle: angle).concatenating(CGAffineTransform(translationX: centre.x, y: centre.y)))
            c.drawLayer { l in
                l.addFilter(.blur(radius: 2))
                l.stroke(ring, with: .color(.white.opacity(0.85 - Double(k) * 0.2)), lineWidth: 4)
            }
            c.stroke(ring, with: .color(.white.opacity(0.85 - Double(k) * 0.2)), lineWidth: 1.4)
        }
        let k = s.point(0)
        groundRing(c, at: k, width: 150, color: .white.opacity(0.7), line: 1.4)
        groundRing(c, at: k, width: 240, color: .white.opacity(0.35), line: 1)
        glow(c, at: p, radius: r * 2.2, colors: [.white.opacity(0.6), .clear])
        ball(c, at: p, radius: r)
    }

    // MARK: Showing the shot

    static func strobe(_ c: GraphicsContext, _ s: ShotPath, head: Double) {
        c.stroke(s.line(from: 0, to: head), with: .color(.white.opacity(0.55)),
                 style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [1.5, 6]))
        let count = 9
        for i in 0..<count {
            let t = head * Double(i) / Double(count - 1), last = i == count - 1
            let opacity = last ? 1 : 0.22 + 0.5 * Double(i) / Double(count - 1)
            if last { glow(c, at: s.point(t), radius: s.radius(t) * 2.2, colors: [shotLime.opacity(0.55), .clear]) }
            ball(c, at: s.point(t), radius: s.radius(t), angle: Double(i) * 0.9, opacity: opacity)
            let ring = Path(ellipseIn: CGRect(x: s.point(t).x - s.radius(t) - 1.5, y: s.point(t).y - s.radius(t) - 1.5,
                                              width: s.radius(t) * 2 + 3, height: s.radius(t) * 2 + 3))
            c.stroke(ring, with: .color(shotLime.opacity(last ? 1 : opacity * 0.8)), lineWidth: last ? 2 : 1.2)
        }
    }

    static func ribbon(_ c: GraphicsContext, _ s: ShotPath) {
        var chord = Path()
        chord.move(to: s.p0)
        chord.addLine(to: s.p3)
        c.stroke(chord, with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [6, 6]))
        // A twisting band: the lit face and the back face swap as it turns, which reads as spin.
        let steps = 160
        for i in 0..<steps {
            let a = Double(i) / Double(steps), b = Double(i + 1) / Double(steps)
            let phaseA = a * .pi * 5, phaseB = b * .pi * 5
            func edge(_ t: Double, _ phase: Double, _ side: CGFloat) -> CGPoint {
                let p = s.point(t), n = s.normal(t), w = s.radius(t) * 1.15 * max(0.1, abs(cos(phase)))
                return CGPoint(x: p.x + n.dx * w * side, y: p.y + n.dy * w * side)
            }
            var quad = Path()
            quad.addLines([edge(a, phaseA, 1), edge(b, phaseB, 1), edge(b, phaseB, -1), edge(a, phaseA, -1)])
            quad.closeSubpath()
            let front = cos((phaseA + phaseB) / 2) > 0
            c.fill(quad, with: .color(front ? shotLime.opacity(0.62) : Color(red: 0.38, green: 0.5, blue: 0.12).opacity(0.7)))
        }
        c.stroke(s.line(from: 0, to: 1), with: .color(shotLime), lineWidth: 1.2)
        let mark = s.widestBend()
        var arrow = Path()
        arrow.move(to: mark.onChord)
        arrow.addLine(to: mark.onPath)
        c.stroke(arrow, with: .color(.white), lineWidth: 1.6)
        for end in [mark.onChord, mark.onPath] {
            c.fill(Path(ellipseIn: CGRect(x: end.x - 3.5, y: end.y - 3.5, width: 7, height: 7)), with: .color(.white))
        }
        ball(c, at: s.p3, radius: s.radius(1))
    }
}

private extension StrokeStyle {
    func with(width: CGFloat) -> StrokeStyle { var copy = self; copy.lineWidth = width; return copy }
}
#endif
