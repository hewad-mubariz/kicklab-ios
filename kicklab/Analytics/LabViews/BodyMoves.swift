// Copied from the Effects Lab (EffectLab/Graphs/BodyMoves.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import CoreGraphics

/// Two more body-aware graphs (lab prototype, 2026-11-18):
///   Reach    – how far from the standing foot the ball is met, sideways, in cm; the usual
///              range is shaded and stretches beyond it are called out.
///   Footwork – where the player stood: live feet on a ground line that lift when they kick,
///              a trail of the base (between the feet) over time, how far it drifted and the
///              bigger moves.
/// Distances use the ball as the ruler (a size 5 ball is 22 cm across), measured where the ball
/// and feet are, so they hold at any distance from the camera. A front camera sees sideways
/// distance only: reaching forward or stepping toward the camera is not counted.
nonisolated enum BodyMoves {
    static let ballCentimetres = 22.0

    // MARK: - Reach

    struct ReachTouch {
        let time: Double
        /// Ball centre minus standing ankle, sideways, in cm (+ is screen right).
        let reach: Double
        let stretch: Bool
    }

    final class ReachModel {
        let touches: [ReachTouch]
        let times: [Double]
        /// Usual reach (median of the last ten, from four touches) and its middle half.
        let usual: Motion.Tween
        let low: Motion.Tween
        let high: Motion.Tween
        let stretches: [Int]

        init(body: BodyZones.Body, ball: GraphScene.BallTrack, touchTimes: [Double]) {
            var out = [ReachTouch](), usual = [(Double, Double)](), low = [(Double, Double)](), high = [(Double, Double)]()
            var stretches = [Int](), count = 0
            for t in touchTimes {
                guard let b = ball.ball(at: t),
                      let j = body.joints(near: t - 0.017, needing: ["leftAnkle", "rightAnkle"]) else { continue }
                let a = j["leftAnkle"]!, c = j["rightAnkle"]!
                let stand = a[1] > c[1] ? a : c
                let reach = (Double(b.p.x) - stand[0]) * BodyMoves.ballCentimetres / (2 * Double(b.r))
                let previous = out.suffix(10).map { abs($0.reach) }.sorted()
                let median = previous.count >= 4 ? TimingSpread.quantile(previous, 0.5) : nil
                // A stretch: well past the usual reach for this player, and far in absolute terms.
                let stretch = median.map { abs(reach) > max(45, $0 * 1.6) } ?? false
                if stretch { count += 1 }
                out.append(ReachTouch(time: t, reach: reach, stretch: stretch))
                stretches.append(count)
                let recent = out.suffix(10).map { abs($0.reach) }.sorted()
                if recent.count >= 4, let m = TimingSpread.quantile(recent, 0.5),
                   let lo = TimingSpread.quantile(recent, 0.25), let hi = TimingSpread.quantile(recent, 0.75) {
                    usual.append((t, m)); low.append((t, lo)); high.append((t, hi))
                }
            }
            touches = out; times = out.map(\.time); self.stretches = stretches
            self.usual = Motion.Tween(usual, duration: 0.5)
            self.low = Motion.Tween(low, duration: 0.5)
            self.high = Motion.Tween(high, duration: 0.5)
        }

        func index(at t: Double) -> Int? { Motion.lastIndex(times, atOrBefore: t) }
    }

    // MARK: - Footwork

    final class FootworkModel {
        /// Base (midpoint of the feet while both are down), sideways from where the player
        /// started, in cm, once per gap between touches.
        let base: Motion.Tween
        let stance: Double
        let moves: [(time: Double, delta: Double)]
        let rangeLow: Motion.Tween
        let rangeHigh: Motion.Tween
        let cycleTimes: [Double]
        let drift: [Double]
        /// Live feet, sorted by screen position: offset from the base midpoint (cm) and lift (0…1).
        let feetTimes: [Double]
        let feet: [((x: Double, lift: Double), (x: Double, lift: Double))]

        static let moveThreshold = 10.0

        init(body: BodyZones.Body, ball: GraphScene.BallTrack, touchTimes: [Double]) {
            struct Frame { let t: Double; let a: [Double]; let b: [Double]; let L: Double; let ground: Double }
            var frames = [Frame]()
            for f in body.frames {
                guard let a = f.joints["leftAnkle"], let b = f.joints["rightAnkle"], let n = f.joints["nose"] else { continue }
                let ground = max(a[1], b[1]), L = ground - n[1]
                guard L > 50 else { continue }
                frames.append(Frame(t: f.time, a: a[0] <= b[0] ? a : b, b: a[0] <= b[0] ? b : a, L: L, ground: ground))
            }
            let radii = ball.r.sorted()
            let medianRadius = radii.isEmpty ? 60 : radii[radii.count / 2]
            func cmPerPx(_ t: Double) -> Double { BodyMoves.ballCentimetres / (2 * Double(ball.ball(at: t)?.r ?? CGFloat(medianRadius))) }

            // One base position per gap between touches, from frames with both feet down.
            var changes = [(Double, Double)](), widths = [Double](), moves = [(Double, Double)]()
            var lows = [(Double, Double)](), highs = [(Double, Double)](), cycleTimes = [Double](), drift = [Double]()
            var x = 0.0, previousPx: Double?, lo = 0.0, hi = 0.0
            for (s, e) in zip([-1.0] + touchTimes, touchTimes + [.infinity]) {
                let down = frames.filter { $0.t > s && $0.t < e && abs($0.a[1] - $0.b[1]) < 0.035 * $0.L }
                guard down.count >= 3, let last = down.last else { continue }
                let mids = down.map { ($0.a[0] + $0.b[0]) / 2 }.sorted()
                let px = mids[mids.count / 2], scale = cmPerPx(last.t)
                widths.append(contentsOf: down.map { ($0.b[0] - $0.a[0]) * scale })
                if let previousPx {
                    let delta = (px - previousPx) * scale
                    x += delta
                    if abs(delta) > FootworkModel.moveThreshold { moves.append((last.t, delta)) }
                }
                previousPx = px
                lo = min(lo, x); hi = max(hi, x)
                changes.append((last.t, x))
                // Only real changes, so the drift number pulses when it grows, not every touch.
                if lows.last?.1 != lo { lows.append((last.t, lo)) }
                if highs.last?.1 != hi { highs.append((last.t, hi)) }
                cycleTimes.append(last.t); drift.append(hi - lo)
            }
            base = Motion.Tween(changes, duration: 0.35)
            rangeLow = Motion.Tween(lows, duration: 0.5)
            rangeHigh = Motion.Tween(highs, duration: 0.5)
            stance = widths.sorted().dropFirst(widths.count / 2).first ?? 25
            self.moves = moves; self.cycleTimes = cycleTimes; self.drift = drift

            // Live feet: each ankle's sideways offset from the pair's midpoint, and how high it is.
            var feetTimes = [Double](), feet = [((x: Double, lift: Double), (x: Double, lift: Double))]()
            var smooth: (Double, Double, Double, Double, Double)?
            for f in frames {
                let scale = cmPerPx(f.t), mid = (f.a[0] + f.b[0]) / 2
                let raw = ((f.a[0] - mid) * scale, (f.ground - f.a[1]) / f.L, (f.b[0] - mid) * scale, (f.ground - f.b[1]) / f.L)
                if let s = smooth {
                    let k = 1 - exp(-(f.t - s.0) / 0.04)
                    smooth = (f.t, s.1 + k * (raw.0 - s.1), s.2 + k * (raw.1 - s.2), s.3 + k * (raw.2 - s.3), s.4 + k * (raw.3 - s.4))
                } else { smooth = (f.t, raw.0, raw.1, raw.2, raw.3) }
                feetTimes.append(f.t)
                feet.append(((smooth!.1, max(0, smooth!.2)), (smooth!.3, max(0, smooth!.4))))
            }
            self.feetTimes = feetTimes; self.feet = feet
        }

        func liveFeet(at t: Double) -> ((x: Double, lift: Double), (x: Double, lift: Double))? {
            guard let i = Motion.lastIndex(feetTimes, atOrBefore: t), t - feetTimes[i] <= 0.1 else { return nil }
            return feet[i]
        }
        func cycle(at t: Double) -> Int? { Motion.lastIndex(cycleTimes, atOrBefore: t) }
    }
}

// MARK: - Drawing

nonisolated enum BodyMovesDrawing {
    typealias Pen = AnalyticsMotionDrawing.Pen

    // MARK: Reach

    static func reach(in c: CGContext, rect: CGRect, model m: BodyMoves.ReachModel, time: Double) {
        c.saveGState(); defer { c.restoreGState() }
        let p = BodyZonesDrawing.begin(c, rect), t = max(0, time)
        p.header("REACH", "How far from your standing foot")
        let cx: CGFloat = 171, gy: CGFloat = 80, perCm: CGFloat = 1.45
        func X(_ cm: Double) -> CGFloat { cx + CGFloat(Motion.clamp(cm, -100, 100)) * perCm }
        let k = m.index(at: t)
        let latest = k.map { m.touches[$0] }
        let age = latest.map { t - $0.time } ?? 9

        // The usual reach, both sides of the standing foot.
        if let lo = m.low.value(at: t), let hi = m.high.value(at: t), let firstUsual = m.usual.times.first {
            let appear = Motion.easeOut((t - firstUsual) / 0.5)
            for side in [-1.0, 1.0] {
                let a = X(side * lo), b = X(side * hi)
                p.fill(CGRect(x: min(a, b), y: 30, width: abs(b - a), height: gy - 30), Pen.alpha(Pen.mint, 0.10 * appear), radius: 3)
            }
            p.text("YOUR REACH", X(hi) + 4, 31, 5.4, Pen.alpha(Pen.mint, 0.8 * appear), weight: 0.5, kern: 0.4)
        }
        // Ruler.
        p.line(cx - 148, gy, cx + 148, gy, Pen.alpha(Pen.white, 0.25), 0.7)
        for cm in stride(from: 25.0, through: 100, by: 25) {
            for side in [-1.0, 1.0] {
                let x = X(side * cm)
                p.line(x, gy, x, gy + 3, Pen.alpha(Pen.white, 0.3), 0.6)
                if cm < 100 { p.text(cm == 75 && side > 0 ? "75 cm" : "\(Int(cm))", x, gy + 4.5, 5.2, Pen.alpha(Pen.muted, 0.8), align: 0.5, mono: true) }
            }
        }
        // The standing foot.
        FootChallengeDrawing.footprint(p, CGPoint(x: cx, y: gy - 6), .right, Pen.white, scale: 1.25)
        p.text("STANDING FOOT", cx, gy + 4.5, 5.2, Pen.alpha(Pen.white, 0.7), weight: 0.5, align: 0.5, kern: 0.3)

        // Touches: an arc from the standing foot out to where the ball was met.
        if let k {
            for i in max(0, k - 9)...k {
                let touch = m.touches[i], a = t - touch.time, older = Double(k - i)
                let end = CGPoint(x: X(touch.reach), y: gy - 4)
                let col = touch.stretch ? Pen.coral : Pen.lime
                let alpha = i == k ? 1 : max(0.15, 0.55 - older * 0.05)
                if i == k {
                    let draw = Motion.easeOut(a / 0.25)
                    let start = CGPoint(x: cx, y: gy - 8), control = CGPoint(x: (cx + end.x) / 2, y: gy - 44)
                    let points = (0...24).map { j -> CGPoint in
                        let f = CGFloat(j) / 24 * CGFloat(draw), g = 1 - f
                        return CGPoint(x: g * g * start.x + 2 * g * f * control.x + f * f * end.x, y: g * g * start.y + 2 * g * f * control.y + f * f * end.y)
                    }
                    let path = CGMutablePath(); path.addLines(between: points)
                    let fade = 1 - Motion.smoothstep(0.9, 1.4, a)
                    p.stroke(path, Pen.alpha(col, 0.25 * fade), 4)
                    p.stroke(path, Pen.alpha(col, 0.9 * fade), 1.3)
                    if a < 0.5 { p.ring(end, 3 + 9 * CGFloat(Motion.easeOut(a / 0.5)), Pen.alpha(col, 0.8 * (1 - a / 0.5)), 1.1) }
                    let label = touch.stretch ? String(format: "STRETCH %.0f cm", abs(touch.reach)) : String(format: "%.0f cm", abs(touch.reach))
                    p.pill(label, at: CGPoint(x: end.x, y: gy - 22), color: col, scale: Motion.backOut((a - 0.12) / 0.28),
                           opacity: 1 - Motion.smoothstep(0.9, 1.4, a), maxX: 326)
                }
                p.glow(end, 9, col, 0.5 * Motion.flash(a, decay: 0.25))
                p.dot(end, 2.8 * CGFloat(i == k ? Motion.backOut(a / 0.24) : 1), Pen.alpha(col, alpha))
            }
        }

        let usual = m.usual.value(at: t)
        let stretches = k.map { m.stretches[$0] } ?? 0
        let stretchAge = k.flatMap { m.touches[$0].stretch ? age : nil }
        p.stats(Pen.Stat(label: "USUAL REACH", value: usual.map { String(format: "%.0f", $0) } ?? "—", unit: usual == nil ? "" : "cm",
                         color: Pen.mint, pulse: m.usual.age(at: t)),
                Pen.Stat(label: "STRETCHES", value: "\(stretches)", unit: "", color: stretches > 0 ? Pen.coral : Pen.white, pulse: stretchAge))
    }

    // MARK: Footwork

    static func footwork(in c: CGContext, rect: CGRect, model m: BodyMoves.FootworkModel, time: Double) {
        c.saveGState(); defer { c.restoreGState() }
        let p = BodyZonesDrawing.begin(c, rect), t = max(0, time)
        p.header("FOOTWORK", "Where you stood")
        let cx: CGFloat = 171, gy: CGFloat = 84, perCm: CGFloat = 1.5, window = 5.0, top: CGFloat = 28
        func X(_ cm: Double) -> CGFloat { cx + CGFloat(Motion.clamp(cm, -95, 95)) * perCm }
        func Y(_ time: Double) -> CGFloat { gy - 6 - CGFloat(t - time) / CGFloat(window) * (gy - 6 - top) }

        // The ground you covered so far, and where you started.
        if let lo = m.rangeLow.value(at: t), let hi = m.rangeHigh.value(at: t) {
            p.fill(CGRect(x: X(lo) - 14, y: top, width: X(hi) - X(lo) + 28, height: gy - top), Pen.alpha(Pen.mint, 0.08), radius: 4)
        }
        p.dashed(X(0), top, X(0), gy, Pen.alpha(Pen.white, 0.22))
        p.text("START", X(0) + 3, top - 1, 5.4, Pen.alpha(Pen.muted, 0.8), weight: 0.5, kern: 0.4)
        p.line(cx - 150, gy, cx + 150, gy, Pen.alpha(Pen.white, 0.25), 0.7)
        p.text("NOW", 16, gy - 9, 5.6, Pen.muted, weight: 0.5, kern: 0.4)
        p.text("5 s AGO", 16, top - 1, 5.6, Pen.alpha(Pen.muted, 0.7), weight: 0.5, kern: 0.4)

        // The trail of your base, older higher up.
        if let first = m.base.times.first, t > first {
            var points = [CGPoint]()
            var s = max(first, t - window)
            while s <= t { if let v = m.base.value(at: s) { points.append(CGPoint(x: X(v), y: Y(s))) }; s += 1.0 / 30 }
            if points.count > 1 {
                let path = Pen.smooth(points)
                p.stroke(path, Pen.alpha(Pen.mint, 0.18), 5)
                p.stroke(path, Pen.alpha(Pen.mint, 0.85), 1.4)
            }
        }
        // Bigger moves, where they happened.
        for move in m.moves where move.time <= t && t - move.time < window {
            let a = t - move.time
            guard let v = m.base.value(at: move.time + 0.35) else { continue }
            let at = CGPoint(x: X(v), y: Y(move.time))
            p.dot(at, 2.6, Pen.gold)
            // Beside the trail on the side it moved to, above the feet, and gone before the next one.
            p.pill(String(format: "MOVE %.0f cm", abs(move.delta)), at: CGPoint(x: at.x + (move.delta > 0 ? 44 : -44), y: at.y - 13),
                   color: Pen.gold, scale: Motion.backOut(a / 0.28), opacity: 1 - Motion.smoothstep(1.3, 1.8, a))
        }

        // Your feet, live: they slide with you and lift when you kick.
        if let base = m.base.value(at: t), let feet = m.liveFeet(at: t) {
            for (i, foot) in [feet.0, feet.1].enumerated() {
                let lift = CGFloat(Motion.clamp(foot.lift / 0.25)) * 14
                let at = CGPoint(x: X(base + foot.x), y: gy - 7 - lift)
                // Facing the camera, the foot on screen left is the player's right.
                let side: FootChallenge.Side = i == 0 ? .right : .left
                let col = FootRallyDrawing.color(side)
                if lift > 1 { p.line(at.x - 4, gy - 0.5, at.x + 4, gy - 0.5, Pen.alpha(col, 0.35 * Double(1 - lift / 14)), 1.2) }
                FootChallengeDrawing.footprint(p, at, side, col, scale: 1.25)
            }
        }

        let k = m.cycle(at: t)
        let drift = k.map { m.drift[$0] }
        let moves = m.moves.filter { $0.time <= t }
        p.stats(Pen.Stat(label: "DRIFT", value: drift.map { String(format: "%.0f", $0) } ?? "—", unit: drift == nil ? "" : "cm side to side",
                         color: Pen.mint, pulse: m.rangeHigh.age(at: t).flatMap { a in m.rangeLow.age(at: t).map { min(a, $0) } }),
                Pen.Stat(label: "MOVES OVER 10 cm", value: "\(moves.count)", unit: "", color: moves.isEmpty ? Pen.white : Pen.gold,
                         pulse: moves.last.map { t - $0.time }))
    }
}
