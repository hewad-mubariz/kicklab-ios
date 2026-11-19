// Copied from the Effects Lab (EffectLab/Graphs/TechniqueGames.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import CoreGraphics

/// Two games (lab prototype, 2026-11-18):
///   Height Ladder – each bounce must top out inside a target band at your usual height. A hit
///                   climbs a rung and the band narrows (±14 → ±3.5 cm); a miss drops a rung.
///   Beat Game     – a ring closes on your feet exactly when your next touch is due (your own
///                   tempo). On time builds a combo and heats the colours; off time breaks it.
/// All causal and a function of the playhead.
nonisolated enum TechniqueGames {
    // MARK: Height Ladder data

    struct Rung { let target: Double?, halfWidth: Double, rung: Int }
    struct Result { let apexCm: Double, apexTime: Double, shownAt: Double, apexX: Double, apexY: Double, hit: Bool?, diff: Double?, rungAfter: Int }

    final class Ladder {
        static let halfWidths = [14.0, 10.0, 7.0, 5.0, 3.5]
        let start: [Rung]
        let result: [Int: Result]
        let hits: [Int]

        init(_ m: Technique.Model) {
            var apex = [Int: (cm: Double, t: Double, shown: Double, x: Double, y: Double)]()
            for k in 0..<max(0, m.touches.count - 1) {
                let a = m.touches[k], b = m.touches[k + 1]
                guard b - a > 0.2, b - a <= 1.5 else { continue }
                var top: Int?, i = (Motion.lastIndex(m.ball.times, atOrBefore: a) ?? -1) + 1, first = i
                while i < m.ball.times.count && m.ball.times[i] <= b {
                    if top == nil || m.ball.y[i] < m.ball.y[top!] { top = i }
                    i += 1
                }
                guard let top, top > first, let s = m.body.scale(at: m.ball.times[top]) else { continue }
                var shown = b, j = top
                while j < m.ball.times.count && m.ball.times[j] <= b {
                    if m.ball.times[j] >= m.ball.times[top] + 0.05 && m.ball.y[j] > m.ball.y[top] + 2 { shown = m.ball.times[j]; break }
                    j += 1
                }
                first = 0
                apex[k] = ((s.ground - m.ball.y[top]) * m.cmPerPx(at: m.ball.times[top]), m.ball.times[top], shown, m.ball.x[top], m.ball.y[top])
            }
            var start = [Rung](), result = [Int: Result](), hits = [Int]()
            var rung = 0, count = 0, history = [Double]()
            for k in m.touches.indices {
                let target = history.count >= 3 ? history.suffix(8).sorted()[min(history.suffix(8).count - 1, history.suffix(8).count / 2)] : nil
                let hw = Ladder.halfWidths[rung]
                start.append(Rung(target: target, halfWidth: hw, rung: rung))
                if let a = apex[k] {
                    var hit: Bool?, diff: Double?
                    if let target {
                        diff = a.cm - target
                        hit = abs(diff!) <= hw
                        rung = hit! ? min(Ladder.halfWidths.count - 1, rung + 1) : max(0, rung - 1)
                        if hit! { count += 1 }
                    }
                    result[k] = Result(apexCm: a.cm, apexTime: a.t, shownAt: a.shown, apexX: a.x, apexY: a.y, hit: hit, diff: diff, rungAfter: rung)
                    history.append(a.cm)
                }
                hits.append(count)
            }
            self.start = start; self.result = result; self.hits = hits
        }
    }

    // MARK: Beat Game data

    final class Beat {
        /// Per motion touch: combo after it and how it was judged (2 perfect, 1 good, -1 early, -2 late).
        let combo: [Int], grade: [Int?], best: [Int]
        init(_ s: AnalyticsMotion.Session) {
            var combo = [Int](), grade = [Int?](), best = [Int](), c = 0, b = 0
            for touch in s.touches {
                var g: Int?
                if let v = touch.verdict, let e = touch.error, let tol = touch.tolerance {
                    g = v == 0 ? (abs(e) <= tol / 2 ? 2 : 1) : (v < 0 ? -1 : -2)
                    c = v == 0 ? c + 1 : 0
                }
                b = max(b, c)
                combo.append(c); grade.append(g); best.append(b)
            }
            self.combo = combo; self.grade = grade; self.best = best
        }
    }
}

// MARK: - Drawing

nonisolated extension TechniqueDrawing {
    nonisolated(unsafe) static var ladders = [ObjectIdentifier: TechniqueGames.Ladder]()
    nonisolated(unsafe) static var beats = [ObjectIdentifier: TechniqueGames.Beat]()
    // MARK: Height Ladder

    static func heightLadder(_ p: Pen, _ m: Technique.Model, _ t: Double, _ u: CGFloat) {
        let g = ladders[ObjectIdentifier(m)] ?? TechniqueGames.Ladder(m)
        ladders[ObjectIdentifier(m)] = g
        let c = p.c
        guard let k = m.touchIndex(at: t), let s = m.body.scale(at: t), let origin = m.ball.ball(at: m.touches[k]) else { return }
        let age = t - m.touches[k], cm = m.cmPerPx(at: t)
        let rung = g.start[k]
        let result = g.result[k].flatMap { $0.shownAt <= t ? $0 : nil }
        let resultAge = result.map { t - $0.shownAt }
        // The band: at the target height, as wide as the bounce needs; it glides to its new height.
        guard let target = rung.target else {
            if age < 0.6 {
                callout(p, "FINDING YOUR HEIGHT", "\(min(3, g.result.keys.filter { $0 < k }.count))/3", box: CGPoint(x: origin.p.x / u, y: origin.p.y / u - 80),
                        anchor: nil, color: cyan, opacity: 1 - Motion.smoothstep(0.4, 0.6, age))
            }
            return
        }
        let previous = k > 0 ? g.start[k - 1] : rung
        let glide = Motion.easeInOut(age / 0.35)
        let center = (previous.target ?? target) + (target - (previous.target ?? target)) * glide
        let hw = previous.halfWidth + (rung.halfWidth - previous.halfWidth) * Motion.backOut(age / 0.45, overshoot: 1.2)
        var cx = Double(origin.p.x) / Double(u)
        let half = 3.4 * Double(origin.r) / Double(u)
        let miss = result?.hit == false, hit = result?.hit == true
        if miss, let ra = resultAge { cx += 6 * sin(ra * 55) * exp(-ra / 0.12) }
        let yC = (s.ground - center / cm) / Double(u), yT = (s.ground - (center + hw) / cm) / Double(u), yB = (s.ground - (center - hw) / cm) / Double(u)
        let band = CGRect(x: cx - half, y: yT, width: 2 * half, height: yB - yT)
        let flash = resultAge.map { Motion.flash($0, decay: 0.25) } ?? 0
        let col = hit ? Pen.mix(cyan, Pen.lime, 0.4 + 0.6 * flash) : miss ? Pen.mix(cyan, Pen.coral, 0.4 + 0.6 * flash) : cyan
        let appear = Motion.smoothstep(0, 0.2, age + (k > 0 && g.start[k - 1].target != nil ? 1 : 0))
        p.gradient(CGPath(roundedRect: band, cornerWidth: 4, cornerHeight: 4, transform: nil), top: band.minY, bottom: band.maxY, col, (0.22 + 0.25 * flash) * appear)
        for y in [band.minY, band.maxY] {
            glowing(c, Pen.alpha(col, appear), blur: 7) { p.line(band.minX, y, band.maxX, y, Pen.alpha(Pen.mix(col, Pen.white, 0.3), appear), 1.3) }
        }
        c.saveGState(); c.setLineDash(phase: 0, lengths: [3, 3])
        p.line(band.minX, CGFloat(yC), band.maxX, CGFloat(yC), Pen.alpha(Pen.white, 0.55 * appear), 0.7); c.restoreGState()

        // The ladder: five rungs beside the band; the lit rung climbs with a spring.
        let side = outward(m, CGFloat(cx), t, u)
        let lx = side > 0 ? band.maxX + 18 : band.minX - 18
        let litFrom = Double(previous.rung), litTo = Double(result?.rungAfter ?? rung.rung)
        let lit = result != nil ? litFrom + (litTo - litFrom) * Motion.backOut((resultAge ?? 0) / 0.4) : Double(rung.rung)
        for r in 0..<TechniqueGames.Ladder.halfWidths.count {
            let y = band.midY + 26 - CGFloat(r) * 12
            let on = Double(r) <= lit + 0.001
            let near = max(0, 1 - abs(Double(r) - lit))
            p.line(lx - 8, y, lx + 8, y, Pen.alpha(on ? Pen.lime : Pen.white, (on ? 0.9 : 0.35) * appear), on ? 2.4 : 1.4)
            if near > 0.3 { glowing(c, Pen.alpha(Pen.lime, near * appear), blur: 7) { p.line(lx - 8, y, lx + 8, y, Pen.alpha(Pen.lime, near * appear), 2.8) } }
        }
        p.line(lx - 9, band.midY + 31, lx - 9, band.midY - 27, Pen.alpha(Pen.white, 0.45 * appear), 1.0)
        p.line(lx + 9, band.midY + 31, lx + 9, band.midY - 27, Pen.alpha(Pen.white, 0.45 * appear), 1.0)
        callout(p, "TARGET", String(format: "±%.1f cm", rung.halfWidth), box: CGPoint(x: lx + side * 52, y: band.midY - 22), anchor: nil,
                color: Pen.lime, opacity: appear)

        // The verdict at the top of the bounce.
        if let r = result, let ra = resultAge, ra < 1.0, let diff = r.diff, let h = r.hit {
            let at = CGPoint(x: r.apexX / Double(u), y: r.apexY / Double(u))
            if h { star(p, at, CGFloat(4 + 14 * Motion.easeOut(ra / 0.35)), Pen.alpha(Pen.lime, 1 - ra)) }
            let (o, sc) = enter(ra)
            callout(p, h ? "HIT · RUNG \(r.rungAfter + 1)" : diff > 0 ? "TOO HIGH" : "TOO LOW", String(format: "%+.0f cm", diff),
                    box: CGPoint(x: at.x - side * 66, y: at.y - 18), anchor: at, color: h ? Pen.lime : Pen.coral,
                    opacity: o * leave(ra - 0.8), scale: sc, roll: rollIn(ra))
        }
        callout(p, "HITS", "\(g.hits[k])", box: CGPoint(x: lx + side * 52, y: band.midY + 14), anchor: nil, color: Pen.white, opacity: appear,
                scale: 1 + 0.12 * (hit ? Motion.flash(resultAge ?? 9, decay: 0.12) : 0))
    }

    // MARK: Beat Game

    static func beatGame(_ p: Pen, _ m: Technique.Model, _ t: Double, _ u: CGFloat) {
        let s = m.motion
        let g = beats[ObjectIdentifier(m)] ?? TechniqueGames.Beat(s)
        beats[ObjectIdentifier(m)] = g
        let c = p.c
        guard let sc = m.body.scale(at: t) else { return }
        let L = sc.ground - sc.head
        let center = CGPoint(x: sc.rootX / Double(u), y: sc.ground / Double(u))
        let rx = CGFloat(0.3 * L) / u, ry = CGFloat(0.065 * L) / u
        let k = s.touchIndex(at: t)
        let combo = k.map { g.combo[$0] } ?? 0
        let age = k.map { t - s.touchTimes[$0] } ?? 9
        // Heat: cyan → lime → gold → magenta as the combo grows.
        let heatStops = [cyan, Pen.lime, Pen.gold, magenta]
        let heat = min(3, Double(combo) / 5)
        let hi = min(3, Int(heat)), heatCol = hi >= 3 ? magenta : Pen.mix(heatStops[hi], heatStops[min(3, hi + 1)], heat - Double(hi))
        func ellipse(_ scale: CGFloat) -> CGRect { CGRect(x: center.x - rx * scale, y: center.y - ry * scale, width: 2 * rx * scale, height: 2 * ry * scale) }

        // The target ring on the ground, breathing with the tempo.
        let beatLen = s.tempo.value(at: t).map { 60 / $0 } ?? 0.6
        let breathe = 0.5 + 0.5 * cos(2 * Double.pi * age / beatLen)
        c.setFillColor(Pen.alpha(heatCol, 0.10 + 0.08 * breathe + 0.2 * Motion.flash(age, decay: 0.2))); c.fillEllipse(in: ellipse(1))
        glowing(c, heatCol, blur: CGFloat(6 + 6 * min(1, heat))) {
            c.setStrokeColor(Pen.mix(heatCol, Pen.white, 0.3)); c.setLineWidth(1.6 + CGFloat(min(1.5, heat * 0.5))); c.strokeEllipse(in: ellipse(1))
        }
        // The approach ring: shrinks onto the target exactly when the touch is due.
        for gate in s.gates where gate.shownFrom <= t && t <= gate.at + gate.tolerance {
            if let i = gate.touch, s.touches[i].time <= t { continue }
            let f = Motion.clamp((gate.at - t) / max(0.05, gate.at - gate.shownFrom))
            let a = Motion.smoothstep(0, 0.15, t - gate.shownFrom) * (t > gate.at ? 1 - (t - gate.at) / gate.tolerance : 1)
            c.setStrokeColor(Pen.alpha(Pen.white, 0.9 * a)); c.setLineWidth(1.4); c.strokeEllipse(in: ellipse(1 + 1.6 * CGFloat(f)))
            c.setStrokeColor(Pen.alpha(Pen.white, 0.25 * a)); c.setLineWidth(4); c.strokeEllipse(in: ellipse(1 + 1.6 * CGFloat(f)))
        }
        // The touch: a burst in the grade's colour, and the word.
        if let k, age < 0.6, let grade = g.grade[k] {
            let col = grade == 2 ? Pen.gold : grade == 1 ? Pen.lime : Pen.coral
            let e = Motion.easeOut(age / 0.45)
            glowing(c, Pen.alpha(col, 1 - age / 0.6), blur: 10) {
                c.setStrokeColor(Pen.alpha(col, 1 - age / 0.6)); c.setLineWidth(2.2 * CGFloat(1 - e) + 0.5); c.strokeEllipse(in: ellipse(1 + 0.9 * CGFloat(e)))
            }
            if grade > 0 { for n in 0..<6 {
                let ang = Double(n) / 6 * 2 * .pi + 0.4
                let pt = CGPoint(x: center.x + rx * CGFloat(cos(ang) * (1 + 0.8 * e)), y: center.y + ry * CGFloat(sin(ang) * (1 + 0.8 * e)) - CGFloat(20 * e))
                star(p, pt, CGFloat(3.5 * (1 - e) + 0.5), Pen.alpha(col, 1 - e))
            } }
            let word = grade == 2 ? "PERFECT" : grade == 1 ? "GOOD" : grade == -1 ? "EARLY" : "LATE"
            let ms = s.touches[k].error.map { String(format: "%+.0f ms", $0 * 1000) } ?? ""
            let (o, scl) = enter(age)
            callout(p, word, grade > 0 ? "" : ms, box: CGPoint(x: center.x, y: center.y - ry - 18), anchor: nil, color: col,
                    opacity: o * leave(age - 0.45), scale: scl * (1 + 0.2 * Motion.flash(age, decay: 0.1)))
        }
        // Combo and tempo beside the feet.
        let side: CGFloat = center.x > 186 ? -1 : 1
        let hx = center.x + side * (rx + 44)
        let comboAge = k.flatMap { g.grade[$0].map { $0 > 0 ? age : nil } ?? nil }
        callout(p, "COMBO", "×\(combo)", box: CGPoint(x: hx, y: center.y - 118), anchor: nil, color: heatCol, opacity: 1,
                scale: 1 + 0.25 * Motion.flash(comboAge ?? 9, decay: 0.12))
        if let bpm = s.tempo.value(at: t) {
            callout(p, "YOUR TEMPO", String(format: "%.0f BPM", bpm), box: CGPoint(x: hx, y: center.y - 84), anchor: nil, color: Pen.white, opacity: 1)
        }
        if let k, g.best[k] > 0 {
            callout(p, "BEST COMBO", "×\(g.best[k])", box: CGPoint(x: hx, y: center.y - 50), anchor: nil, color: Pen.gold, opacity: 1)
        }
    }
}
