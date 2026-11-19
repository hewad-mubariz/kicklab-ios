// Copied from the Effects Lab (EffectLab/Graphs/TechniqueTopography.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import CoreGraphics

/// Control Topography (concept 16), lab prototype 2026-11-18.
/// Where the ball has been over the last 10 s, as a density cloud with contour lines. The outer
/// contour encloses 90% of the ball's time: the player's control zone. Its width, how far its
/// centre has moved, and how long the ball took to come back when it left are measured from it.
/// Only past positions are used; every frame is a function of the playhead.
nonisolated final class Topography {
    static let window = 10.0, fadeSpan = 2.0
    static let masses: [Float] = [0.9, 0.72, 0.52, 0.32, 0.14]

    let ball: GraphScene.BallTrack
    let cell: Double, cols: Int, rows: Int
    let sigma: Double
    /// Ball inside the 90% zone of its own moment, per ball sample (nil before there is enough data).
    let inside: [Bool?]
    let recoveries: [(start: Double, back: Double)]

    struct Field {
        let values: [Float]
        let c0: Int, r0: Int, w: Int, h: Int
        let thresholds: [Float]
        let total: Float
    }

    init(ball: GraphScene.BallTrack, width: Double, height: Double) {
        self.ball = ball
        cell = 12
        cols = Int((width / cell).rounded(.up)); rows = Int((height / cell).rounded(.up))
        let radii = ball.r.sorted()
        sigma = 1.1 * (radii.isEmpty ? 62 : radii[radii.count / 2]) / cell * 0.55
        var flags = [Bool?](), recoveries = [(Double, Double)]()
        var outSince: Double?, inSince: Double?, out: Double?
        for i in ball.times.indices {
            let t = ball.times[i]
            guard let f = Topography.field(ball, t, cell: cell, cols: cols, rows: rows, sigma: sigma), f.total > 300 else { flags.append(nil); continue }
            let isIn = Topography.value(f, x: ball.x[i], y: ball.y[i], cell: cell) >= f.thresholds[0]
            flags.append(isIn)
            // Out after 0.1 s outside, back after 0.1 s inside.
            if !isIn {
                inSince = nil
                if out == nil { outSince = outSince ?? t; if t - outSince! >= 0.1 { out = outSince } }
            } else {
                outSince = nil
                if let o = out { inSince = inSince ?? t; if t - inSince! >= 0.1 { if inSince! - o >= 0.25 { recoveries.append((o, inSince!)) }; out = nil; inSince = nil } }
            }
        }
        inside = flags
        self.recoveries = recoveries
    }

    /// Density of ball positions over the last window before `t`, blurred, with the levels that
    /// enclose each share of the ball's time.
    static func field(_ ball: GraphScene.BallTrack, _ t: Double, cell: Double, cols: Int, rows: Int, sigma: Double) -> Field? {
        let lo = (Motion.lastIndex(ball.times, atOrBefore: t - window) ?? -1) + 1
        guard let hi = Motion.lastIndex(ball.times, atOrBefore: t), hi > lo else { return nil }
        let pad = Int((3 * sigma).rounded(.up)) + 2
        var minC = Int.max, maxC = Int.min, minR = Int.max, maxR = Int.min
        for i in lo...hi {
            let c = Int(ball.x[i] / cell), r = Int(ball.y[i] / cell)
            minC = min(minC, c); maxC = max(maxC, c); minR = min(minR, r); maxR = max(maxR, r)
        }
        let c0 = max(0, minC - pad), r0 = max(0, minR - pad), c1 = min(cols - 1, maxC + pad), r1 = min(rows - 1, maxR + pad)
        let w = c1 - c0 + 1, h = r1 - r0 + 1
        guard w > 2, h > 2 else { return nil }
        var grid = [Float](repeating: 0, count: w * h)
        var total: Float = 0
        for i in lo...hi {
            let age = t - ball.times[i]
            let weight = Float(1 - Motion.smoothstep(window - fadeSpan, window, age))
            let gx = ball.x[i] / cell - 0.5 - Double(c0), gy = ball.y[i] / cell - 0.5 - Double(r0)
            let ix = Int(gx.rounded(.down)), iy = Int(gy.rounded(.down))
            let fx = Float(gx - Double(ix)), fy = Float(gy - Double(iy))
            for (dx, dy, k) in [(0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)] {
                let x = ix + dx, y = iy + dy
                if x >= 0, x < w, y >= 0, y < h { grid[y * w + x] += weight * k }
            }
            total += weight
        }
        // Separable Gaussian blur.
        let radius = Int((3 * sigma).rounded(.up))
        let kernel = (-radius...radius).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let norm = kernel.reduce(0, +)
        var tmp = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for k in -radius...radius { let xx = x + k; if xx >= 0 && xx < w { s += grid[y * w + xx] * kernel[k + radius] } }
                tmp[y * w + x] = s / norm
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for k in -radius...radius { let yy = y + k; if yy >= 0 && yy < h { s += tmp[yy * w + x] * kernel[k + radius] } }
                grid[y * w + x] = s / norm
            }
        }
        let sorted = grid.sorted(by: >)
        let sum = sorted.reduce(0, +)
        guard sum > 0 else { return nil }
        // Walk from the densest cell down; smaller shares are reached first.
        var byMass = [Float: Float](), acc: Float = 0, idx = 0
        for mass in masses.sorted() {
            while idx < sorted.count && acc < mass * sum { acc += sorted[idx]; idx += 1 }
            byMass[mass] = sorted[max(0, idx - 1)]
        }
        let thresholds = masses.map { byMass[$0]! }
        return Field(values: grid, c0: c0, r0: r0, w: w, h: h, thresholds: thresholds, total: total)
    }

    static func value(_ f: Field, x: Double, y: Double, cell: Double) -> Float {
        let gx = x / cell - 0.5 - Double(f.c0), gy = y / cell - 0.5 - Double(f.r0)
        let ix = Int(gx.rounded(.down)), iy = Int(gy.rounded(.down))
        guard ix >= 0, iy >= 0, ix + 1 < f.w, iy + 1 < f.h else { return 0 }
        let fx = Float(gx - Double(ix)), fy = Float(gy - Double(iy))
        let a = f.values[iy * f.w + ix], b = f.values[iy * f.w + ix + 1], c = f.values[(iy + 1) * f.w + ix], d = f.values[(iy + 1) * f.w + ix + 1]
        return a * (1 - fx) * (1 - fy) + b * fx * (1 - fy) + c * (1 - fx) * fy + d * fx * fy
    }

    func field(at t: Double) -> Field? { Topography.field(ball, t, cell: cell, cols: cols, rows: rows, sigma: sigma) }
    func isInside(at t: Double) -> Bool? {
        guard let i = Motion.lastIndex(ball.times, atOrBefore: t) else { return nil }
        return inside[i]
    }

    /// Contour segments at `level`, in source pixels (marching squares, linear interpolation).
    func contour(_ f: Field, _ level: Float) -> [(CGPoint, CGPoint)] {
        var out = [(CGPoint, CGPoint)]()
        func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: (x + 0.5 + Double(f.c0)) * cell, y: (y + 0.5 + Double(f.r0)) * cell) }
        for y in 0..<(f.h - 1) {
            for x in 0..<(f.w - 1) {
                let a = f.values[y * f.w + x], b = f.values[y * f.w + x + 1]
                let c = f.values[(y + 1) * f.w + x + 1], d = f.values[(y + 1) * f.w + x]
                let code = (a >= level ? 8 : 0) | (b >= level ? 4 : 0) | (c >= level ? 2 : 0) | (d >= level ? 1 : 0)
                if code == 0 || code == 15 { continue }
                func lerp(_ p: Float, _ q: Float) -> Double { Double(p == q ? 0.5 : (level - p) / (q - p)) }
                let top = P(Double(x) + lerp(a, b), Double(y)), right = P(Double(x + 1), Double(y) + lerp(b, c))
                let bottom = P(Double(x) + lerp(d, c), Double(y + 1)), left = P(Double(x), Double(y) + lerp(a, d))
                switch code {
                case 1, 14: out.append((left, bottom))
                case 2, 13: out.append((bottom, right))
                case 3, 12: out.append((left, right))
                case 4, 11: out.append((top, right))
                case 5: out.append((left, top)); out.append((bottom, right))
                case 6, 9: out.append((top, bottom))
                case 7, 8: out.append((left, top))
                case 10: out.append((top, right)); out.append((left, bottom))
                default: break
                }
            }
        }
        return out
    }
}

nonisolated extension TechniqueDrawing {
    nonisolated(unsafe) static var topographies = [ObjectIdentifier: Topography]()

    static func topography(_ m: Technique.Model, _ size: CGSize) -> Topography {
        if let t = topographies[ObjectIdentifier(m)] { return t }
        let t = Topography(ball: m.ball, width: Double(size.width), height: Double(size.height))
        topographies[ObjectIdentifier(m)] = t
        return t
    }

    static let topoColors: [CGColor] = [Pen.col(0.36, 0.14, 0.82), Pen.col(0.30, 0.26, 0.95), Pen.col(0.16, 0.46, 1), Pen.col(0.12, 0.74, 1), Pen.col(0.45, 0.95, 1)]

    static func controlTopography(_ p: Pen, _ m: Technique.Model, _ t: Double, _ u: CGFloat, size: CGSize) {
        let c = p.c, topo = topography(m, size)
        guard let f = topo.field(at: t), f.total > 30 else { return }
        let grow = Motion.smoothstep(30, 240, Double(f.total))
        let cell = CGFloat(topo.cell) / u
        let rect = CGRect(x: CGFloat(f.c0) * cell, y: CGFloat(f.r0) * cell, width: CGFloat(f.w) * cell, height: CGFloat(f.h) * cell)
        let ball = m.ball.ball(at: t).map { (CGPoint(x: $0.p.x / u, y: $0.p.y / u), $0.r / u) }

        GraphScene.withBallCut(p, ball) {
            // Filled bands: one colour per contour level, soft at the edges.
            var pixels = [UInt8](repeating: 0, count: f.w * f.h * 4)
            for i in 0..<(f.w * f.h) {
                let v = f.values[i]
                var level = -1
                for (k, th) in f.thresholds.enumerated() where v >= th { level = k }
                guard level >= 0 else { continue }
                // Within a band, brighten a little toward the next level for depth.
                let nextT = level + 1 < f.thresholds.count ? f.thresholds[level + 1] : f.thresholds[level] * 1.6
                let within = Double(min(1, max(0, (v - f.thresholds[level]) / max(1e-6, nextT - f.thresholds[level]))))
                let col = Pen.mix(topoColors[level], topoColors[min(level + 1, topoColors.count - 1)], within * 0.5).components!
                let alpha = (0.3 + 0.08 * Double(level) + 0.05 * within) * grow
                pixels[i * 4] = UInt8(min(255, col[0] * 255 * CGFloat(alpha)))
                pixels[i * 4 + 1] = UInt8(min(255, col[1] * 255 * CGFloat(alpha)))
                pixels[i * 4 + 2] = UInt8(min(255, col[2] * 255 * CGFloat(alpha)))
                pixels[i * 4 + 3] = UInt8(min(255, 255 * alpha))
            }
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            let image = CGImage(width: f.w, height: f.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: f.w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
            c.saveGState(); c.interpolationQuality = .high
            c.translateBy(x: rect.minX, y: rect.maxY); c.scaleBy(x: 1, y: -1)
            c.draw(image, in: CGRect(origin: .zero, size: rect.size))
            c.restoreGState()

            // Contour lines: the 90% line strongest, inner lines finer.
            for (k, th) in f.thresholds.enumerated() {
                let segs = topo.contour(f, th)
                let path = CGMutablePath()
                for (a, b) in segs { path.move(to: CGPoint(x: a.x / u, y: a.y / u)); path.addLine(to: CGPoint(x: b.x / u, y: b.y / u)) }
                let col = Pen.mix(topoColors[k], Pen.white, 0.55)
                if k == 0 {
                    glowing(c, Pen.alpha(Pen.col(0.6, 0.4, 1), 1 * grow), blur: 8) { p.stroke(path, Pen.alpha(col, grow), 1.3) }
                } else {
                    glowing(c, Pen.alpha(topoColors[k], 0.8 * grow), blur: 3) { p.stroke(path, Pen.alpha(col, (0.7 + 0.06 * Double(k)) * grow), 0.8) }
                }
            }
            // The positions themselves, as fine dots.
            var i = (Motion.lastIndex(m.ball.times, atOrBefore: t - Topography.window) ?? -1) + 1
            while i < m.ball.times.count && m.ball.times[i] <= t {
                let age = t - m.ball.times[i]
                if i % 3 == 0 {
                    let a = 0.5 * (1 - Motion.smoothstep(Topography.window - Topography.fadeSpan, Topography.window, age))
                    p.dot(CGPoint(x: m.ball.x[i] / u, y: m.ball.y[i] / u), 0.8, Pen.alpha(Pen.white, 1.4 * a * grow))
                }
                i += 1
            }
        }

        // The live bounce from the last touch: white inside the zone, gold outside, with time marks.
        if let k = m.touchIndex(at: t) {
            let start = m.touches[k]
            var pts = [(CGPoint, Bool)](), i = (Motion.lastIndex(m.ball.times, atOrBefore: start) ?? -1) + 1
            while i < m.ball.times.count && m.ball.times[i] <= t {
                pts.append((CGPoint(x: m.ball.x[i] / u, y: m.ball.y[i] / u), topo.inside[i] ?? true)); i += 1
            }
            if let head = ball?.0 { pts.append((head, topo.isInside(at: t) ?? true)) }
            GraphScene.withBallCut(p, ball) {
                for j in 1..<max(1, pts.count) {
                    let col = pts[j].1 ? Pen.white : Pen.gold
                    glowing(c, Pen.alpha(col, 0.8), blur: 5) { p.line(pts[j - 1].0.x, pts[j - 1].0.y, pts[j].0.x, pts[j].0.y, col, 1.6) }
                }
            }
            if let first = pts.first { glowing(c, Pen.white, blur: 6) { p.dot(first.0, 2.4, Pen.white) } }
            c.saveGState(); c.setShadow(offset: CGSize(width: 0, height: 0.6), blur: 4, color: Pen.col(0, 0, 0, 0.8))
            for (n, mark) in [0.0, 0.1, 0.2, 0.3].enumerated() where start + mark <= t {
                guard let b = m.ball.ball(at: start + mark) else { continue }
                let at = CGPoint(x: b.p.x / u, y: b.p.y / u)
                if n > 0 { glowing(c, Pen.white, blur: 4) { p.dot(at, 2.0, Pen.white) } }
                let (o, _) = enter(t - start - mark)
                let side: CGFloat = n % 2 == 0 ? 1 : -1
                p.text(String(format: "t +%.2f s", mark), at.x + side * 6, at.y - 4.5, 6.4, Pen.alpha(Pen.white, o), weight: 0.6,
                       align: side > 0 ? 0 : 1, mono: true)
            }
            c.restoreGState()
        }

        // Numbers.
        let segs90 = topo.contour(f, f.thresholds[0]).flatMap { [$0.0, $0.1] }
        guard !segs90.isEmpty else { return }
        let xs = segs90.map(\.x), cm = m.cmPerPx(at: t)
        let widthCm = Double(xs.max()! - xs.min()!) * cm
        let leftmost = segs90.min { $0.x < $1.x }!, rightmost = segs90.max { $0.x < $1.x }!
        let cx = CGFloat(m.body.scale(at: t)?.rootX ?? 540)
        let anchorL = (cx - leftmost.x) > (rightmost.x - cx) ? leftmost : rightmost
        let sideL: CGFloat = anchorL.x < cx ? -1 : 1
        callout(p, "90% CONTROL ZONE", String(format: "%.0f cm wide", widthCm), box: CGPoint(x: anchorL.x / u + sideL * 52, y: anchorL.y / u - 8),
                anchor: CGPoint(x: anchorL.x / u, y: anchorL.y / u), color: Pen.gold, opacity: grow, scale: 1)
        // Centre drift: the zone's centre now against where it was 5 s ago.
        if let then = topo.field(at: t - 5), then.total > 180 {
            func centroid(_ f: Topography.Field) -> (Double, Double) {
                var sx = 0.0, sy = 0.0, s = 0.0
                for y in 0..<f.h { for x in 0..<f.w where f.values[y * f.w + x] >= f.thresholds[0] {
                    let v = Double(f.values[y * f.w + x]); sx += v * (Double(x + f.c0) + 0.5) * topo.cell; sy += v * (Double(y + f.r0) + 0.5) * topo.cell; s += v
                } }
                return s > 0 ? (sx / s, sy / s) : (0, 0)
            }
            let a = centroid(then), b = centroid(f)
            let drift = hypot(b.0 - a.0, b.1 - a.1) * cm
            let at = CGPoint(x: b.0 / Double(u), y: b.1 / Double(u))
            p.ring(at, 2.2, Pen.alpha(Pen.white, 0.9), 1)
            callout(p, "CENTER DRIFT · 5 s", String(format: "%.0f cm", drift), box: CGPoint(x: at.x - sideL * 70, y: at.y + 60),
                    anchor: at, color: Pen.gold, opacity: grow, scale: 1)
        }
        // The latest return to the zone, while it is recent.
        if let r = topo.recoveries.last(where: { $0.back <= t }), t - r.back < 2.5, let b = m.ball.ball(at: r.back) {
            let (o, sc) = enter(t - r.back)
            let at = CGPoint(x: b.p.x / u, y: b.p.y / u)
            callout(p, "RECOVERY", String(format: "%.2f s", r.back - r.start), box: CGPoint(x: at.x + outward(m, at.x, t, u) * 60, y: at.y - 40),
                    anchor: at, color: Pen.gold, opacity: o * leave(t - r.back - 2.3), scale: sc, roll: rollIn(t - r.back))
        }
    }
}
