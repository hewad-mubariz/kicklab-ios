// Copied from the Effects Lab (EffectLab/Graphs/TechniqueViews.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import CoreGraphics

/// Four more technique views on the video (lab prototype, 2026-11-18), from the owner's sheets:
///   Ball Flight    (03) – the flight traced as it happens, ball height in metres with a
///                  dimension line, the launch speed and the apex. Metres come from the ball
///                  as a ruler, corrected so the falling ball accelerates at 9.81 m/s².
///   Touch Chain    (11) – the last five touches as L/R-numbered points where they happened,
///                  joined in order with the time between them.
///   Recovery Chain (19) – when the ball drifts out of the player's lane, the bounces that
///                  brought it back, numbered, with how far off the line each one peaked.
///   Control Window (08 + 16) – the player's window (their lane, from just above the feet to
///                  just over their usual top) with how much of the last 10 s the ball stayed in.
/// Shared motion: everything enters with TechniqueDrawing.enter and leaves with .leave, labels
/// are laid out together and drawn on whole pixels.
nonisolated extension TechniqueDrawing {

    // MARK: Ball Flight

    static func ballFlight(_ p: Pen, _ m: Technique.Model, _ t: Double, _ u: CGFloat, _ P: (Double, Double) -> CGPoint) {
        guard let k = m.touchIndex(at: t) else { return }
        // The bounce that just ended leaves while the new one starts.
        if k > 0, t - m.touches[k] < 0.2 { flight(p, m, k - 1, t, u, P, leaving: t - m.touches[k]) }
        flight(p, m, k, t, u, P, leaving: nil)
    }

    private static func flight(_ p: Pen, _ m: Technique.Model, _ k: Int, _ t: Double, _ u: CGFloat,
                               _ P: (Double, Double) -> CGPoint, leaving: Double?) {
        let a = m.touches[k], end = k + 1 < m.touches.count ? m.touches[k + 1] : .infinity
        let now = min(t, end), age = now - a
        guard age > 0.02, let s = m.body.scale(at: now) else { return }
        let fade = leave(leaving), cm = m.cmPerPx(at: now)
        var ts = [Double](), points = [CGPoint](), ys = [Double]()
        var i = (Motion.lastIndex(m.ball.times, atOrBefore: a) ?? -1) + 1
        while i < m.ball.times.count && m.ball.times[i] <= now {
            ts.append(m.ball.times[i] - a); ys.append(m.ball.y[i]); points.append(P(m.ball.x[i], m.ball.y[i])); i += 1
        }
        guard points.count > 2 else { return }
        let ball = m.ball.ball(at: now)
        // The trace: dots every other frame, brighter toward the ball, kept off the ball.
        GraphScene.withBallCut(p, ball.map { (CGPoint(x: $0.p.x / u, y: $0.p.y / u), $0.r / u) }) {
            glowing(p.c, Pen.alpha(Pen.lime, fade), blur: 7) { p.stroke(Pen.smooth(points), Pen.alpha(Pen.lime, 0.9 * fade), 1.6) }
            for (n, pt) in points.enumerated() where n % 4 == 0 {
                glowing(p.c, Pen.alpha(Pen.lime, fade), blur: 4) { p.dot(pt, 2.1, Pen.alpha(Pen.mix(Pen.lime, Pen.white, 0.5), fade)) }
            }
        }
        // Launch speed from the first tenth of a second.
        if age >= 0.13, let fit = quadratic(Array(ts.prefix(9)), Array(ys.prefix(9))) {
            // Scaled at the launch, so the number never changes once it is shown.
            let rise = -fit.b * m.cmPerPx(at: a + 0.05) / 100
            let (o, sc) = enter(age - 0.13)
            callout(p, "LAUNCH", String(format: "%.1f m/s", rise), box: CGPoint(x: points[0].x + outward(m, points[0].x, a, u) * 64, y: points[0].y - 6),
                    anchor: points[min(3, points.count - 1)], color: Pen.lime, opacity: o * fade, scale: sc, roll: rollIn(age - 0.13))
        }
        // The top, once the ball is on its way down.
        if let top = ys.indices.min(by: { ys[$0] < ys[$1] }), age - ts[top] > 0.05, ys.last! > ys[top] + 2 {
            let apexTime = a + ts[top]
            let apex = points[top], meters = (s.ground - ys[top]) * m.cmPerPx(at: apexTime) / 100
            let (o, sc) = enter(age - ts[top] - 0.05)
            p.ring(apex, 3.2, Pen.alpha(Pen.gold, o * fade), 1.1)
            callout(p, "APEX", String(format: "%.2f m", meters), box: CGPoint(x: apex.x + outward(m, apex.x, a, u) * 58, y: apex.y - 18),
                    anchor: apex, color: Pen.gold, opacity: o * fade, scale: sc, roll: rollIn(age - ts[top] - 0.05))
        }
        // Height now: a dimension line from the ground to the ball.
        guard leaving == nil, let b = ball else { return }
        let center = CGPoint(x: b.p.x / u, y: b.p.y / u), ground = CGFloat(s.ground) / u
        let side = outward(m, center.x, now, u)
        let x = center.x + side * (b.r / u + 9)
        let (o, _) = enter(age - 0.05)
        glowing(p.c, Pen.col(0, 0, 0, 0.6), blur: 3) {
            p.line(x, ground, x, center.y, Pen.alpha(Pen.white, 0.95 * o), 1.1)
            for (y, dir) in [(ground, CGFloat(-1)), (center.y, CGFloat(1))] {
                p.line(x - 4, y, x + 4, y, Pen.alpha(Pen.white, 0.95 * o), 1.1)
                p.line(x, y, x - 2.5, y + dir * 4, Pen.alpha(Pen.white, 0.95 * o), 1.1)
                p.line(x, y, x + 2.5, y + dir * 4, Pen.alpha(Pen.white, 0.95 * o), 1.1)
            }
        }
        p.dashed(center.x - 30, ground, x + 10, ground, Pen.alpha(Pen.white, 0.6 * o), 0.8)
        p.dashed(center.x + side * (b.r / u), center.y, x, center.y, Pen.alpha(Pen.white, 0.6 * o), 0.7)
        let height = (s.ground - Double(b.p.y)) * cm / 100
        callout(p, "BALL HEIGHT", String(format: "%.2f m", height), box: CGPoint(x: x + side * 40, y: (ground + center.y) / 2),
                anchor: CGPoint(x: x, y: (ground + center.y) / 2), color: Pen.white, opacity: o, scale: 1, roll: rollIn(age - 0.05))
    }

    // MARK: Touch Chain

    static func touchChain(_ p: Pen, _ m: Technique.Model, _ t: Double, _ u: CGFloat, _ P: (Double, Double) -> CGPoint) {
        guard let k = m.touchIndex(at: t) else { return }
        let first = max(0, k - 2)
        func contact(_ i: Int) -> CGPoint? {
            m.ball.ball(at: m.touches[i]).map { CGPoint(x: $0.p.x / u, y: ($0.p.y + $0.r * 0.78) / u) }
        }
        // Links in order, each with the time it took; the newest draws itself in.
        if first < k {
            for i in (first + 1)...k {
                guard let a = contact(i - 1), let b = contact(i), m.touches[i] - m.touches[i - 1] <= 2 else { continue }
                let age = t - m.touches[i], older = Double(k - i)
                let fadeOld = i == first + 1 && k - first == 2 ? 1 - Motion.smoothstep(0, 0.25, t - m.touches[k]) : 1
                let alpha = max(0.25, 1 - older * 0.18) * fadeOld
                let dip = max(14, abs(b.x - a.x) * 0.35 + 10)
                let control = CGPoint(x: (a.x + b.x) / 2 + (abs(b.x - a.x) < 6 ? 16 : 0), y: max(a.y, b.y) + dip)
                let draw = Motion.easeOut(age / 0.28)
                let pts = (0...24).map { j -> CGPoint in
                    let f = CGFloat(j) / 24 * CGFloat(draw), g = 1 - f
                    return CGPoint(x: g * g * a.x + 2 * g * f * control.x + f * f * b.x, y: g * g * a.y + 2 * g * f * control.y + f * f * b.y)
                }
                let path = CGMutablePath(); path.addLines(between: pts)
                p.dashed(path, Pen.alpha(Pen.white, 0.75 * alpha), 0.9)
                if draw > 0.98, let tip = pts.last {
                    let back = pts[pts.count - 3], ang = atan2(tip.y - back.y, tip.x - back.x)
                    for da in [-0.5, 0.5] {
                        p.line(tip.x, tip.y, tip.x - 4 * cos(ang + CGFloat(da)), tip.y - 4 * sin(ang + CGFloat(da)), Pen.alpha(Pen.white, 0.8 * alpha), 0.9)
                    }
                }
                guard i == k else { continue }
                let mid = CGPoint(x: 0.25 * a.x + 0.5 * control.x + 0.25 * b.x, y: 0.25 * a.y + 0.5 * control.y + 0.25 * b.y)
                let gap = String(format: "%.2f s", m.touches[i] - m.touches[i - 1])
                let (o, _) = enter(age - 0.18)
                let w = width(gap, 6.2, 0.6, 0) + 8
                p.fill(snap(p.c, CGRect(x: mid.x - w / 2, y: mid.y - 1, width: w, height: 10)), Pen.alpha(ink, o * alpha), radius: 3)
                p.text(gap, mid.x, mid.y + 0.6, 6.2, Pen.alpha(Pen.white, o * alpha), weight: 0.6, align: 0.5, mono: true)
            }
        }
        // Each touch: a chip with the foot and the touch number, where it happened.
        var placed = [CGRect]()
        for i in stride(from: k, through: first, by: -1) {
            guard let at = contact(i) else { continue }
            let side = i < m.sides.count ? m.sides[i] : nil
            let name = (side == .left ? "L" : side == .right ? "R" : "·") + "\(i + 1)"
            let col = FootRallyDrawing.color(side)
            let age = t - m.touches[i], older = Double(k - i)
            let (o, sc) = enter(age)
            let alpha = max(0.3, 1 - older * 0.17) * (i == first && k - first == 2 ? 1 - Motion.smoothstep(0, 0.25, t - m.touches[k]) : 1)
            let w = width(name, 7, 0.75, 0.3) + 10
            var r = CGRect(x: at.x - w / 2, y: at.y - 6, width: w, height: 12)
            // Newer chips keep their place; an older one at the same spot steps aside.
            while placed.contains(where: { $0.insetBy(dx: -1.5, dy: -1.5).intersects(r) }) { r.origin.y += 13.5 }
            placed.append(r)
            if r.midY != at.y { p.line(at.x, at.y, r.midX, r.minY, Pen.alpha(col, 0.5 * alpha * o), 0.6) }
            p.c.saveGState(); p.c.setAlpha(CGFloat(o * alpha))
            if sc < 0.999 { p.c.translateBy(x: r.midX, y: r.midY); p.c.scaleBy(x: CGFloat(sc), y: CGFloat(sc)); p.c.translateBy(x: -r.midX, y: -r.midY) }
            let rr = sc < 0.999 ? r : snap(p.c, r)
            p.fill(rr, Pen.alpha(col, 0.95), radius: 6)
            p.text(name, rr.midX, rr.minY + 2.6, 7, Pen.col(0.02, 0.09, 0.05), weight: 0.75, align: 0.5, kern: 0.3, mono: true)
            p.c.restoreGState()
            if i == k, age < 0.45 { p.ring(at, 4 + 10 * CGFloat(Motion.easeOut(age / 0.45)), Pen.alpha(col, 0.8 * (1 - age / 0.45)), 1.1) }
        }
    }

    // MARK: Recovery Chain

    static func recoveryChain(_ p: Pen, _ m: Technique.Model, _ t: Double, _ u: CGFloat, _ P: (Double, Double) -> CGPoint) {
        let s = m.motion
        // The excursion on show: the latest one that has started, until shortly after its return.
        // Only drifts played back with the same foot: the player's line is built from their usual
        // foot, so a ball taken with the other foot sits off it without being a drift.
        guard let e = s.excursions.last(where: { $0.shownFrom <= t && sameFoot(m, $0) }) else { return }
        let ended = e.confirmed ?? e.censoredAt
        if let ended, t > ended + 1.6 { return }
        let fade = ended.map { leave(t - $0 - 1.4) } ?? 1
        guard let k0 = m.touchIndex(at: e.start) else { return }
        let lastTouch = m.touchIndex(at: t) ?? k0
        // Up to the bounce that started after the ball was back in (shown as "back in").
        let backTouch = e.reentry.flatMap { r in m.touches.firstIndex { $0 >= r } } ?? .max
        let k1 = min(lastTouch, backTouch, k0 + 3)
        var previousOff: Double?
        let colors = [Pen.gold, violet, cyan, cyan]
        let ballD = s.track.ballDiameter
        let cmPerDiameter = 22 * (Motion.lastIndex(m.gravityTimes, atOrBefore: t).map { m.gravityFactor[$0] } ?? 1)

        // The player's line, as a dashed vertical at its position now.
        if let line = s.line.value(at: t), let body = s.track.ball(at: t), let sc = m.body.scale(at: t) {
            let x = CGFloat(body.personX + line * ballD) / u
            p.dashed(x, CGFloat(sc.ground) / u, x, CGFloat(sc.head) / u, Pen.alpha(Pen.white, 0.55 * fade), 0.9)
            p.text("YOUR LINE", x + 3, CGFloat(sc.head) / u - 2, 5.6, Pen.alpha(Pen.white, 0.75 * fade), weight: 0.6, kern: 0.5)
        }
        for (n, j) in (k0...k1).enumerated() {
            let a = m.touches[j], end = j + 1 < m.touches.count ? min(m.touches[j + 1], t) : t
            guard a <= t, end > a else { continue }
            let col = colors[min(n, 3)]
            let pts = m.ball.path(from: a, to: end).map { CGPoint(x: $0.x / u, y: $0.y / u) }
            guard pts.count > 2 else { continue }
            for (q, pt) in pts.enumerated() where q % 2 == 0 { p.dot(pt, 1.4, Pen.alpha(col, 0.9 * fade)) }
            // Number at the touch that started this bounce.
            let age = t - a
            let (o, sc) = enter(age)
            p.c.saveGState(); p.c.setAlpha(CGFloat(o * fade))
            p.c.translateBy(x: pts[0].x, y: pts[0].y); p.c.scaleBy(x: CGFloat(sc), y: CGFloat(sc))
            p.dot(.zero, 5.6, ink); p.ring(.zero, 5.6, col, 1.2)
            p.text("\(n + 1)", 0, -3.6, 7, col, weight: 0.75, align: 0.5, mono: true)
            p.c.restoreGState()
            // How far off the line this bounce peaked.
            guard let top = pts.indices.min(by: { pts[$0].y < pts[$1].y }), top < pts.count - 3 else { continue }
            let apexTime = a + Double(top) / 60
            guard let off = s.sideOffset(at: apexTime) else { continue }
            let cmOff = abs(off) * cmPerDiameter
            let returned = e.reentry.map { apexTime >= $0 } ?? false
            // Named by what the bounce did, not by its place in the chain.
            let title = returned ? "BACK IN" : n == 0 ? "WIDE" : (previousOff.map { cmOff < $0 - 2 } ?? false) ? "CORRECTING" : "STILL WIDE"
            previousOff = cmOff
            let (lo, lsc) = enter(t - apexTime - 0.05)
            let side = outward(m, pts[top].x, apexTime, u)
            callout(p, title, String(format: "%.0f cm", cmOff), box: CGPoint(x: pts[top].x + side * 50, y: pts[top].y - 14), anchor: pts[top],
                    color: col, opacity: lo * fade, scale: lsc)
        }
        if let back = e.confirmed, t >= back {
            let n = e.touches.count
            let (o, sc) = enter(t - back)
            callout(p, "RECOVERED", n == 1 ? "IN 1 TOUCH" : "IN \(n) TOUCHES", box: CGPoint(x: 300, y: 120), anchor: nil,
                    color: cyan, opacity: o * fade, scale: sc)
        }
    }

    /// True when every touch from the one that sent the ball out to the one after it came back
    /// was made with the same foot.
    static func sameFoot(_ m: Technique.Model, _ e: AnalyticsMotion.Excursion) -> Bool {
        guard let k0 = m.touchIndex(at: e.start) else { return false }
        let end = (e.reentry ?? e.censoredAt ?? e.start).advanced(by: 0)
        let k1 = m.touches.firstIndex { $0 >= end } ?? m.touches.count - 1
        let feet = Set((k0...max(k0, k1)).compactMap { $0 < m.sides.count ? m.sides[$0] : nil }.map { $0 == .left ? 0 : 1 })
        return feet.count <= 1
    }

    // MARK: Control Window

    static func controlWindow(_ p: Pen, _ m: Technique.Model, _ t: Double, _ u: CGFloat, _ P: (Double, Double) -> CGPoint) {
        let s = m.motion
        guard let line = s.line.value(at: t), let firstLine = s.line.times.first, let body = s.track.ball(at: t),
              let sc = m.body.scale(at: t), let usual = m.usualApex(at: t) else { return }
        let L = sc.ground - sc.head, D = s.track.ballDiameter, hw = AnalyticsMotion.laneHalfWidth
        let box = CGRect(x: CGFloat(body.personX + (line - hw) * D) / u, y: CGFloat(sc.ground - (usual + 0.1) * L) / u,
                         width: CGFloat(2 * hw * D) / u, height: CGFloat((usual + 0.1 - 0.08) * L) / u)
        let appear = Motion.easeOut((max(firstLine, m.apexEnds[2]) - t) * -2)
        let offset = s.sideOffset(at: t)
        let ball = m.ball.ball(at: t).map { CGPoint(x: $0.p.x / u, y: $0.p.y / u) }
        let outside = ball.map { !box.insetBy(dx: -1, dy: -1).contains($0) } ?? false
        let edgeColor = outside ? Pen.coral : Pen.mint

        // Body landmarks: knee, waist and chest heights on the player's centre line.
        let cx = CGFloat(sc.rootX) / u
        p.dashed(cx, CGFloat(sc.ground) / u, cx, CGFloat(sc.ground - 0.95 * L) / u, Pen.alpha(Pen.white, 0.35 * appear), 0.6)
        for (h, name) in [(m.body.knee, "KNEE"), (m.body.hip, "WAIST"), (m.body.shoulder, "CHEST")] {
            let y = CGFloat(sc.ground - h * L) / u, dir: CGFloat = box.midX > cx ? -1 : 1
            p.line(cx - 3, y, cx + 3, y, Pen.alpha(Pen.white, 0.7 * appear), 0.8)
            p.text(name, cx + dir * 5, y - 3.2, 5.6, Pen.alpha(Pen.white, 0.8 * appear), weight: 0.6, align: dir > 0 ? 0 : 1, kern: 0.5)
        }
        // The window: soft fill and corner brackets that turn coral when the ball is out.
        p.fill(box, Pen.alpha(Pen.mint, 0.07 * appear), radius: 3)
        let arm: CGFloat = 9
        for (x, y, dx, dy) in [(box.minX, box.minY, 1.0, 1.0), (box.maxX, box.minY, -1.0, 1.0), (box.minX, box.maxY, 1.0, -1.0), (box.maxX, box.maxY, -1.0, -1.0)] {
            let near = ball.map { hypot($0.x - x, $0.y - y) < box.width } ?? false
            let col = outside && near ? Pen.coral : Pen.mint
            p.line(x, y, x + CGFloat(dx) * arm, y, Pen.alpha(col, 0.95 * appear), 1.4)
            p.line(x, y, x, y + CGFloat(dy) * arm, Pen.alpha(col, 0.95 * appear), 1.4)
        }
        // The last third of a second of the ball, inside the window.
        var q = t - 0.3
        while q <= t {
            if let b = m.ball.ball(at: q) {
                let pt = CGPoint(x: b.p.x / u, y: b.p.y / u), f = 1 - (t - q) / 0.3
                p.dot(pt, 1.2 + CGFloat(f), Pen.alpha(box.contains(pt) ? Pen.mint : Pen.coral, 0.25 + 0.6 * f))
            }
            q += 2.0 / 60
        }
        if outside, let b = ball {
            let tag = b.y < box.minY ? "HIGH" : (offset ?? 0) > 0 ? "WIDE →" : "← WIDE"
            callout(p, tag, "", box: CGPoint(x: b.x, y: b.y - 26), anchor: nil, color: Pen.coral, opacity: appear, scale: 1)
        }
        if let share = s.inLane(at: t) {
            // Time in the window over the last 10 s, from the same lane as Control Surf plus the height limits.
            let inZone = zoneShare(m, t, u)
            let side: CGFloat = box.midX > cx ? 1 : -1
            callout(p, "IN ZONE · 10 s", String(format: "%.0f%%", inZone ?? share), box: CGPoint(x: (side > 0 ? box.maxX : box.minX) + side * 40, y: box.minY + 4),
                    anchor: CGPoint(x: side > 0 ? box.maxX : box.minX, y: box.minY), color: edgeColor, opacity: appear, scale: 1)
        }
    }

    /// Share of tracked ball time in the window over the last 10 s, judged frame by frame with
    /// the window as it was then.
    static func zoneShare(_ m: Technique.Model, _ t: Double, _ u: CGFloat) -> Double? {
        let s = m.motion
        var inside = 0, total = 0
        var i = (Motion.lastIndex(m.ball.times, atOrBefore: t - 10) ?? -1) + 1
        while i < m.ball.times.count && m.ball.times[i] <= t {
            let time = m.ball.times[i]
            if let line = s.line.value(at: time), let body = s.track.ball(at: time), let sc = m.body.scale(at: time), let usual = m.usualApex(at: time) {
                let L = sc.ground - sc.head, D = s.track.ballDiameter, hw = AnalyticsMotion.laneHalfWidth
                let x = m.ball.x[i], y = m.ball.y[i]
                let inX = abs(x - (body.personX + line * D)) <= hw * D
                let inY = y >= sc.ground - (usual + 0.1) * L && y <= sc.ground - 0.08 * L
                total += 1; if inX && inY { inside += 1 }
            }
            i += 1
        }
        return total >= 60 ? Double(inside) / Double(total) * 100 : nil
    }
}
