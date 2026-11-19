// Copied from the Effects Lab (EffectLab/Graphs/FootChallenge.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import CoreGraphics

/// Left · Right: which foot made each touch, the switch streak (left-right-left…) and the
/// weak-foot share. Built once per session; drawing is a pure function of the playhead.
/// Lab prototype (2026-11-17). Foot sides come from scripts/graphs/feet/classify.py.
nonisolated enum FootChallenge {
    struct Input: Decodable {
        struct Touch: Decodable { let time: Double; let side: String }
        let touches: [Touch]
    }

    enum Side { case left, right }

    struct Touch {
        let time: Double
        let side: Side?
        /// Different known foot from the touch before, inside the same run.
        let switched: Bool
        /// Consecutive switches ending at this touch.
        let streak: Int
        let best: Int
        let left: Int
        let right: Int
    }

    /// A gap longer than this starts a new run (the ball was dropped or caught).
    static let pauseGap = 2.0

    struct Session {
        let touches: [Touch]
        let times: [Double]
        /// Share of known touches made with the right foot, easing after each touch.
        let rightShare: Motion.Tween

        init(_ input: Input) {
            var out = [Touch]()
            var streak = 0, best = 0, left = 0, right = 0
            for (i, raw) in input.touches.sorted(by: { $0.time < $1.time }).enumerated() {
                let side: Side? = raw.side == "L" ? .left : raw.side == "R" ? .right : nil
                if side == .left { left += 1 } else if side == .right { right += 1 }
                let previous = i > 0 ? out[i - 1] : nil
                let sameRun = previous.map { raw.time - $0.time <= FootChallenge.pauseGap } ?? false
                let switched = sameRun && side != nil && previous?.side != nil && side != previous?.side
                streak = switched ? streak + 1 : 0
                best = max(best, streak)
                out.append(Touch(time: raw.time, side: side, switched: switched, streak: streak, best: best, left: left, right: right))
            }
            touches = out
            times = out.map(\.time)
            rightShare = Motion.Tween(out.compactMap { t in
                let known = t.left + t.right
                return known > 0 ? (t.time, Double(t.right) / Double(known)) : nil
            }, duration: 0.5)
        }

        func index(at t: Double) -> Int? { Motion.lastIndex(times, atOrBefore: t) }
        func lastTime(of side: Side, before t: Double) -> Double? {
            touches.last { $0.time <= t && $0.side == side }?.time
        }
    }
}

/// Core Graphics card, 342 x 124 points, top-left origin, in the Analytics Motion style.
nonisolated enum FootChallengeDrawing {
    typealias Pen = AnalyticsMotionDrawing.Pen
    static let size = CGSize(width: 342, height: 124)
    static let leftColor = Pen.mint, rightColor = Pen.gold

    static func color(_ side: FootChallenge.Side?) -> CGColor {
        side == .left ? leftColor : side == .right ? rightColor : Pen.muted
    }

    static func draw(in c: CGContext, rect: CGRect, session s: FootChallenge.Session, time: Double) {
        c.saveGState(); defer { c.restoreGState() }
        c.translateBy(x: rect.minX, y: rect.minY)
        c.scaleBy(x: rect.width / size.width, y: rect.height / size.height)
        c.setAllowsAntialiasing(true); c.setShouldAntialias(true)
        let p = Pen(c), t = max(0, time)
        p.card()
        p.header("LEFT · RIGHT", "Which foot, every touch")

        let x0: CGFloat = 44, x1: CGFloat = 326, xNow: CGFloat = 288
        let yL: CGFloat = 44, yR: CGFloat = 74, yMid = (yL + yR) / 2
        let pxps = (xNow - x0) / 4.0
        func X(_ time: Double) -> CGFloat { xNow + CGFloat(time - t) * pxps }
        func Y(_ side: FootChallenge.Side?) -> CGFloat { side == .left ? yL : side == .right ? yR : yMid }
        let k = s.index(at: t)
        let latest = k.map { s.touches[$0] }
        let age = latest.map { t - $0.time } ?? 9

        // Lane labels light up when their foot touches.
        for (side, y, name) in [(FootChallenge.Side.left, yL, "L"), (.right, yR, "R")] {
            let hit = s.lastTime(of: side, before: t).map { t - $0 } ?? 9
            let col = color(side)
            p.glow(CGPoint(x: 24, y: y), 16, col, 0.55 * Motion.flash(hit, decay: 0.22))
            p.circle(CGPoint(x: 24, y: y), 8.5, Pen.alpha(col, 0.55 + 0.45 * Motion.flash(hit, decay: 0.3)), 1.3)
            p.text(name, 24, y - 4.6, 9, col, weight: 0.62, align: 0.5,
                   scale: CGFloat(1 + 0.18 * Motion.flash(hit, decay: 0.14)))
            p.dashed(x0, y, x1, y, Pen.alpha(Pen.white, 0.09))
        }

        let plot = CGRect(x: x0, y: 26, width: x1 - x0, height: 66)
        p.faded(plot, left: 30, right: 10) {
            // Links between touches: lime when the foot switched, faint when it repeated.
            for i in s.touches.indices.dropFirst() where s.touches[i].time <= t {
                let a = s.touches[i - 1], b = s.touches[i]
                guard b.time - a.time <= FootChallenge.pauseGap else { continue }
                let pa = CGPoint(x: X(a.time), y: Y(a.side)), pb = CGPoint(x: X(b.time), y: Y(b.side))
                guard pb.x > x0 - 30 else { continue }
                let path = CGMutablePath(); path.move(to: pa)
                let mx = (pa.x + pb.x) / 2
                path.addCurve(to: pb, control1: CGPoint(x: mx, y: pa.y), control2: CGPoint(x: mx, y: pb.y))
                let fade = Motion.easeOut((t - b.time) / 0.18)
                if b.switched {
                    p.stroke(path, Pen.alpha(Pen.lime, 0.28 * fade), 4.5)
                    p.stroke(path, Pen.alpha(Pen.lime, 0.9 * fade), 1.5)
                } else {
                    p.stroke(path, Pen.alpha(Pen.white, 0.22 * fade), 1.0)
                }
            }
            // Footprints stamped at the now line, then scrolling away.
            for touch in s.touches where touch.time <= t {
                let x = X(touch.time)
                guard x > x0 - 20 else { continue }
                let pt = CGPoint(x: x, y: Y(touch.side)), a = t - touch.time, col = color(touch.side)
                if a < 0.45 {
                    let f = a / 0.45
                    p.ring(pt, 4 + 10 * CGFloat(Motion.easeOut(f)), Pen.alpha(col, 0.8 * (1 - f)), 1.2)
                }
                p.glow(pt, 11, col, 0.4 * Motion.flash(a, decay: 0.25))
                footprint(p, pt, touch.side, col, scale: Motion.backOut(a / 0.22))
            }
        }

        // The challenge cue: the other foot's lane, at the now line, waits for the next touch.
        if let latest, let side = latest.side, age < FootChallenge.pauseGap {
            let target = CGPoint(x: xNow, y: side == .left ? yR : yL)
            let other = color(side == .left ? .right : .left)
            let appear = Motion.easeOut((age - 0.12) / 0.3)
            let breathe = 0.5 + 0.5 * sin(2 * Double.pi * (age - 0.12) / 0.9)
            p.ring(target, 7 + CGFloat(1.5 * breathe), Pen.alpha(other, appear * (0.35 + 0.3 * breathe)), 1.1)
            p.text("NEXT", xNow + 13, target.y - 3.4, 6.0, Pen.alpha(other, appear * 0.8), weight: 0.5, kern: 0.5)
        }
        p.line(xNow, 28, xNow, 90, Pen.alpha(Pen.white, 0.16), 0.6)

        // Streak call-out above the latest touch.
        if let latest, latest.streak >= 2, age < 1.5 {
            let pop = Motion.backOut(age / 0.28), out = 1 - Motion.smoothstep(1.1, 1.5, age)
            p.pill("\(latest.streak) SWITCHES", at: CGPoint(x: X(latest.time) - 2, y: 30), color: Pen.lime,
                   scale: pop, opacity: out, maxX: 326)
        }

        stats(p, s, t, latest)
    }

    /// A small sole with toes, pointing up: drawn as a right foot, mirrored for the left.
    static func footprint(_ p: Pen, _ at: CGPoint, _ side: FootChallenge.Side?, _ col: CGColor, scale: Double) {
        guard scale > 0.01 else { return }
        let c = p.c
        c.saveGState(); c.translateBy(x: at.x, y: at.y); c.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        guard let side else { p.dot(.zero, 2.6, col); c.restoreGState(); return }
        if side == .left { c.scaleBy(x: -1, y: 1) }   // big toe on the inside of each foot
        c.setFillColor(col)
        c.fillEllipse(in: CGRect(x: -3.2, y: -3.6, width: 6.0, height: 8.4))     // sole
        c.fillEllipse(in: CGRect(x: -2.6, y: -7.6, width: 2.6, height: 2.6))      // big toe
        c.fillEllipse(in: CGRect(x: 0.4, y: -7.0, width: 2.0, height: 2.0))
        c.fillEllipse(in: CGRect(x: 2.4, y: -5.9, width: 1.6, height: 1.6))
        c.restoreGState()
    }

    static func stats(_ p: Pen, _ s: FootChallenge.Session, _ t: Double, _ latest: FootChallenge.Touch?) {
        p.line(16, 96, 326, 96, Pen.alpha(Pen.white, 0.12), 0.5)
        p.line(178, 102, 178, 116, Pen.alpha(Pen.white, 0.14), 0.5)
        func pop(_ a: Double?) -> CGFloat { CGFloat(1 + 0.16 * Motion.flash(a ?? 9, decay: 0.12)) }
        func bright(_ col: CGColor, _ a: Double?) -> CGColor { Pen.mix(col, Pen.white, 0.6 * Motion.flash(a ?? 9, decay: 0.15)) }
        let leftAge = s.lastTime(of: .left, before: t).map { t - $0 }
        let rightAge = s.lastTime(of: .right, before: t).map { t - $0 }

        // Left half: the two counts and a balance bar between the feet.
        var x: CGFloat = 16
        x += p.text("LEFT", x, 105, 6.6, Pen.muted, weight: 0.35, kern: 0.6) + 5
        x += p.text("\(latest?.left ?? 0)", x, 102, 13.5, bright(leftColor, leftAge), weight: 0.62, mono: true, scale: pop(leftAge)) + 10
        x += p.text("RIGHT", x, 105, 6.6, Pen.muted, weight: 0.35, kern: 0.6) + 5
        x += p.text("\(latest?.right ?? 0)", x, 102, 13.5, bright(rightColor, rightAge), weight: 0.62, mono: true, scale: pop(rightAge)) + 10
        let bar = CGRect(x: x, y: 106, width: max(20, 166 - x), height: 4)
        let share = s.rightShare.value(at: t) ?? 0.5
        p.fill(bar, Pen.alpha(Pen.white, 0.10), radius: 2)
        if latest != nil {
            let split = bar.minX + bar.width * CGFloat(1 - share)
            p.fill(CGRect(x: bar.minX, y: bar.minY, width: split - bar.minX, height: bar.height), Pen.alpha(leftColor, 0.85), radius: 2)
            p.fill(CGRect(x: split, y: bar.minY, width: bar.maxX - split, height: bar.height), Pen.alpha(rightColor, 0.85), radius: 2)
            p.text(String(format: "%.0f%% right", share * 100), bar.maxX, 99.5, 5.6, Pen.muted, align: 1)
        }

        // Right half: the switch streak now, and the best this session.
        let streakAge = latest.map { t - $0.time }
        var r: CGFloat = 326
        r -= p.text("best \(latest?.best ?? 0)", r, 105.5, 7.2, Pen.muted, align: 1) + 5
        let streak = latest?.streak ?? 0
        r -= p.text("\(streak)", r, 102, 13.5, bright(streak > 0 ? Pen.lime : Pen.white, streak > 0 ? streakAge : nil),
                    weight: 0.62, align: 1, mono: true, scale: pop(streak > 0 ? streakAge : nil)) + 6
        p.text("SWITCH STREAK", r, 105, 6.6, Pen.muted, weight: 0.35, align: 1, kern: 0.6)
    }
}
