// Copied from the Effects Lab (EffectLab/Graphs/GraphScene.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import CoreGraphics
import CoreText

/// Effects on the video itself that match each Analytics Motion card, so the graph at the
/// bottom and the picture above it tell the same story at the same moment:
///   Foot Rally   – a contact flash at the foot in that foot's colour, the ball's trail in the
///                  colour of the foot that kicked it, an arc between the two feet on a switch.
///   Beat Gates   – an approach ring that closes on the ball when the next touch is due, and a
///                  burst coloured on beat / early / late when it comes.
///   Arc Match    – the bounce traced in the scene, the usual height as a line, and the change
///                  pinned at the apex.
///   Control Surf – the player's lane drawn in the scene; the ball turns coral outside it.
/// Numbers and judgements come from the same sessions as the cards; only positions come from
/// the app's 60 fps ball track. Every value is a function of the playhead. Lab prototype, 2026-11-17.
nonisolated enum GraphScene {
    enum Graph: String, CaseIterable { case footRally = "foot-rally", beatGates = "beat-gates", arcMatch = "arc-match", controlSurf = "control-surf" }

    /// The app's own ball track for the clip (analysis-native.json `track`), in source pixels.
    struct BallTrack {
        struct Row: Decodable {
            let time: Double
            let x: Double?, y: Double?, width: Double?
            let personX: Double?, personY: Double?, personHeight: Double?
        }
        struct File: Decodable { let track: [Row] }

        let times: [Double], x: [Double], y: [Double], r: [Double]
        /// Body centre and the ground under the feet, smoothed (τ 0.15 s, causal).
        let bodyX: [Double], ground: [Double]

        init(_ file: File, width: Double, height: Double) {
            let rows = file.track.filter { $0.x != nil && $0.y != nil && $0.width != nil && $0.time.isFinite }.sorted { $0.time < $1.time }
            times = rows.map(\.time)
            x = rows.map { $0.x! * width }
            y = rows.map { $0.y! * height }
            r = rows.map { $0.width! * width / 2 }
            var bx = [Double](), gy = [Double](), last: (Double, Double, Double)?
            for row in rows {
                let px = (row.personX ?? 0.5) * width
                let g = ((row.personY ?? 0.5) + (row.personHeight ?? 0.5) / 2) * height
                if let (t0, x0, g0) = last {
                    let k = 1 - exp(-(row.time - t0) / 0.15)
                    last = (row.time, x0 + k * (px - x0), g0 + k * (g - g0))
                } else { last = (row.time, px, g) }
                bx.append(last!.1); gy.append(last!.2)
            }
            bodyX = bx; ground = gy
        }

        private func index(_ t: Double) -> (Int, Double)? {
            guard let i = Motion.lastIndex(times, atOrBefore: t) else { return nil }
            if i + 1 < times.count, times[i + 1] - times[i] <= 0.04 { return (i, (t - times[i]) / (times[i + 1] - times[i])) }
            return t - times[i] <= 0.025 ? (i, 0) : nil
        }
        private func value(_ a: [Double], _ i: Int, _ f: Double) -> Double { f > 0 ? Motion.lerp(a[i], a[i + 1], f) : a[i] }

        /// Ball centre and radius at `t`; nil in a tracking gap.
        func ball(at t: Double) -> (p: CGPoint, r: CGFloat)? {
            guard let (i, f) = index(t) else { return nil }
            return (CGPoint(x: value(x, i, f), y: value(y, i, f)), CGFloat(value(r, i, f)))
        }
        func body(at t: Double) -> (x: Double, ground: Double)? {
            guard let (i, f) = index(t) else { return nil }
            return (value(bodyX, i, f), value(ground, i, f))
        }
        /// Ball centres from `a` to `t`, frame by frame; only the part after the last gap.
        func path(from a: Double, to t: Double) -> [CGPoint] {
            guard t > a else { return [] }
            var out = [CGPoint](), previous = a
            if let s = ball(at: a) { out.append(s.p) }
            var i = (Motion.lastIndex(times, atOrBefore: a) ?? -1) + 1
            while i < times.count && times[i] < t {
                if times[i] - previous > 0.05 { out = [] }
                out.append(CGPoint(x: x[i], y: y[i])); previous = times[i]; i += 1
            }
            if t - previous <= 0.05, let h = ball(at: t) { out.append(h.p) }
            return out
        }
    }

    typealias Pen = AnalyticsMotionDrawing.Pen

    /// Drawing units: about one card point, so text and strokes match the card's scale.
    struct Scene {
        let track: BallTrack
        let u: CGFloat
        func ball(at t: Double) -> (p: CGPoint, r: CGFloat)? { track.ball(at: t).map { (CGPoint(x: $0.p.x / u, y: $0.p.y / u), $0.r / u) } }
        func path(from a: Double, to t: Double) -> [CGPoint] { track.path(from: a, to: t).map { CGPoint(x: $0.x / u, y: $0.y / u) } }
        func bodyX(at t: Double) -> CGFloat? { track.body(at: t).map { CGFloat($0.x) / u } }
        func ground(at t: Double) -> CGFloat? { track.body(at: t).map { CGFloat($0.ground) / u } }
        /// +1 when `x` is right of the body: labels go on the outside, away from the player.
        func outward(_ x: CGFloat, at t: Double) -> CGFloat { x >= (bodyX(at: t) ?? x) ? 1 : -1 }
    }

    /// Draws the layer for `graph` over a frame of `size` pixels, top-left origin.
    static func draw(_ graph: Graph, in c: CGContext, size: CGSize, track: BallTrack,
                     motion: AnalyticsMotion.Session, rally: FootRally.Model, time: Double) {
        let u = size.width / 372
        c.saveGState(); defer { c.restoreGState() }
        c.scaleBy(x: u, y: u)
        c.setAllowsAntialiasing(true); c.setShouldAntialias(true)
        let p = Pen(c), sc = Scene(track: track, u: u), t = max(0, time)
        switch graph {
        case .footRally: footRally(p, sc, rally, t)
        case .beatGates: beatGates(p, sc, motion, t)
        case .arcMatch: arcMatch(p, sc, motion, t)
        case .controlSurf: controlSurf(p, sc, motion, t)
        }
    }

    // MARK: - Foot Rally

    static func footRally(_ p: Pen, _ sc: Scene, _ m: FootRally.Model, _ t: Double) {
        let s = m.session
        guard let k = s.index(at: t) else { return }
        let latest = s.touches[k], age = t - latest.time

        // The ball in flight carries the colour of the foot that kicked it.
        if let side = latest.side, age < FootChallenge.pauseGap, let b = sc.ball(at: t) {
            let col = FootRallyDrawing.color(side)
            let stay = 1 - Motion.smoothstep(1.2, FootChallenge.pauseGap, age)
            trail(p, sc.path(from: max(latest.time, t - 0.2), to: t), ball: b, color: col, width: b.r * 0.62, alpha: 0.55 * stay)
            p.glow(b.p, b.r * 1.7, col, 0.3 * Motion.flash(age, decay: 0.25))
            p.ring(b.p, b.r * 1.06, Pen.alpha(col, min(1, 0.95 * Motion.flash(age, decay: 0.3) + 0.4 * stay)), 1.0)
        }

        for i in max(0, k - 2)...k {
            let touch = s.touches[i], a = t - touch.time
            guard a < 1.1, let side = touch.side, let hit = sc.ball(at: touch.time) else { continue }
            let col = FootRallyDrawing.color(side)
            let contact = CGPoint(x: hit.p.x, y: hit.p.y + hit.r * 0.78)

            // A switch: a step from where the other foot touched to where this one did. It dips
            // below the contacts, so it never crosses the ball.
            if touch.switched, i > 0, let from = sc.ball(at: s.touches[i - 1].time) {
                let start = CGPoint(x: from.p.x, y: from.p.y + from.r * 0.78)
                let fade = 1 - Motion.smoothstep(0.35, 0.6, a)
                let dip = abs(contact.x - start.x) * 0.3 + 12
                let control = CGPoint(x: (start.x + contact.x) / 2, y: max(start.y, contact.y) + dip)
                let draw = Motion.easeOut(a / 0.24)
                let points = (0...28).map { j -> CGPoint in
                    let f = CGFloat(j) / 28 * CGFloat(draw), g = 1 - f
                    return CGPoint(x: g * g * start.x + 2 * g * f * control.x + f * f * contact.x,
                                   y: g * g * start.y + 2 * g * f * control.y + f * f * contact.y)
                }
                let path = CGMutablePath(); path.addLines(between: points)
                p.stroke(path, Pen.alpha(Pen.lime, 0.28 * fade), 4.5)
                p.stroke(path, Pen.alpha(Pen.lime, 0.95 * fade), 1.4)
                p.dot(start, 1.8, Pen.alpha(FootRallyDrawing.color(s.touches[i - 1].side), 0.9 * fade))
                let bottom = CGPoint(x: control.x, y: (start.y + contact.y) / 4 + control.y / 2 + 9)
                p.pill("SWITCH", at: bottom, color: Pen.lime, scale: Motion.backOut((a - 0.1) / 0.26), opacity: fade)
            }

            // Contact flash at the foot, and which foot it was.
            if a < 0.5 {
                let f = a / 0.5
                p.ring(contact, hit.r * (0.35 + 0.75 * CGFloat(Motion.easeOut(f))), Pen.alpha(col, 0.95 * (1 - f)), 1.6 * CGFloat(1 - f) + 0.4)
            }
            p.glow(contact, hit.r * 1.1, col, 0.55 * Motion.flash(a, decay: 0.16))
            // Gone before the next touch, so labels never stack up.
            let name = side == .left ? "LEFT" : "RIGHT"
            let out = sc.outward(contact.x, at: touch.time)
            let label = CGPoint(x: contact.x + out * (hit.r * 0.7 + 6 + halfWidth(name, 1.15)), y: contact.y + 2)
            p.pill(name, at: label, color: col, scale: 1.15 * Motion.backOut(a / 0.26), opacity: 1 - Motion.smoothstep(0.35, 0.55, a))
        }
    }

    // MARK: - Beat Gates

    static func beatGates(_ p: Pen, _ sc: Scene, _ s: AnalyticsMotion.Session, _ t: Double) {
        // The approach ring closes onto the ball exactly when the next touch is due.
        let lead = 0.45
        for gate in s.gates where gate.shownFrom <= t && t >= gate.at - lead && t <= gate.at + gate.tolerance + 0.2 {
            if let i = gate.touch, s.touches[i].time <= t { continue }
            guard let b = sc.ball(at: t) else { continue }
            let f = Motion.clamp((gate.at - t) / lead)
            let appear = Motion.smoothstep(0, 0.3, 1 - f) * Motion.smoothstep(0, 0.12, t - gate.shownFrom)
            let fade = t > gate.at ? 1 - Motion.clamp((t - gate.at) / (gate.tolerance + 0.2)) : 1
            let target = b.r * 1.22
            p.ring(b.p, target, Pen.alpha(Pen.white, 0.3 * appear * fade), 0.7)
            p.ring(b.p, target + b.r * 1.5 * CGFloat(Motion.easeInOut(f)), Pen.alpha(Pen.white, 0.9 * appear * fade), 1.2)
        }

        guard let k = s.touchIndex(at: t) else { return }
        for i in max(0, k - 1)...k {
            let touch = s.touches[i], a = t - touch.time
            guard a < 1.0, let hit = sc.ball(at: touch.time) else { continue }
            let col = Pen.verdict(touch.verdict)
            let target = hit.r * 1.22
            if a < 0.45 {
                let f = a / 0.45
                p.ring(hit.p, target + hit.r * 0.9 * CGFloat(Motion.easeOut(f)), Pen.alpha(col, 0.95 * (1 - f)), 2.0 * CGFloat(1 - f) + 0.5)
            }
            p.glow(hit.p, hit.r * 1.8, col, 0.4 * Motion.flash(a, decay: 0.18))
            guard let verdict = touch.verdict, let error = touch.error else { continue }
            let ms = abs(Int((error * 1000).rounded()))
            let label = verdict == 0 ? "ON BEAT" : verdict < 0 ? "EARLY \(ms) ms" : "LATE \(ms) ms"
            let out = sc.outward(hit.p.x, at: touch.time)
            p.pill(label, at: CGPoint(x: hit.p.x + out * (target + 6 + halfWidth(label, 1.15)), y: hit.p.y), color: col,
                   scale: 1.15 * Motion.backOut(a / 0.26), opacity: 1 - Motion.smoothstep(0.3, 0.45, a))
        }
    }

    // MARK: - Arc Match

    static func arcMatch(_ p: Pen, _ sc: Scene, _ s: AnalyticsMotion.Session, _ t: Double) {
        guard let k = s.touchIndex(at: t) else { return }
        let age = t - s.touchTimes[k]
        // The bounce that just ended gives way to the new one.
        if k > 0, age < 0.3 { flight(p, sc, s, k - 1, until: s.touchTimes[k], opacity: 1 - Motion.easeInOut(age / 0.3)) }
        // One usual line, gliding from the last bounce's height to this one's.
        if let now = usualLine(sc, s, k) {
            var y = now.y, cx = now.cx, appear = Motion.easeOut(age / 0.3)
            if k > 0, let before = usualLine(sc, s, k - 1) {
                let f = Motion.easeInOut(age / 0.3)
                y = before.y + (now.y - before.y) * CGFloat(f); cx = before.cx + (now.cx - before.cx) * CGFloat(f); appear = 1
            }
            p.dashed(cx - now.half, y, cx + now.half, y, Pen.alpha(Pen.gold, 0.9 * appear), 1.1)
            p.text("USUAL", cx + now.half, y - 9.5, 5.8, Pen.alpha(Pen.gold, appear), weight: 0.6, align: 1, kern: 0.5)
        }
        flight(p, sc, s, k, until: t, opacity: 1)
    }

    /// Where the usual apex sits for the bounce starting at touch `k`, in scene units.
    static func usualLine(_ sc: Scene, _ s: AnalyticsMotion.Session, _ k: Int) -> (y: CGFloat, cx: CGFloat, half: CGFloat)? {
        guard let u = s.usual[k], u.apex > 0.01, let origin = s.track.ball(at: s.touchTimes[k]), let touch = sc.ball(at: s.touchTimes[k]) else { return nil }
        let y = CGFloat(origin.y) / sc.u - CGFloat(u.apex) * CGFloat(s.track.bodyHeight) / sc.u
        return (y, touch.p.x, touch.r * 3.4)
    }

    /// One bounce: its trace and, once it has peaked, the change against the usual, pinned at the apex.
    static func flight(_ p: Pen, _ sc: Scene, _ s: AnalyticsMotion.Session, _ k: Int, until end: Double, opacity: Double) {
        let start = s.touchTimes[k]
        guard opacity > 0.01, let origin = s.track.ball(at: start) else { return }
        let bodyHeight = CGFloat(s.track.bodyHeight) / sc.u
        let originY = CGFloat(origin.y) / sc.u

        // The trace, out of the ball's way.
        let points = sc.path(from: start, to: end)
        if points.count > 1, let head = sc.ball(at: end) {
            withBallCut(p, opacity >= 1 ? head : nil) {
                let curve = Pen.smooth(points)
                p.stroke(curve, Pen.alpha(Pen.lime, 0.22 * opacity), 4.5)
                p.stroke(curve, Pen.alpha(Pen.lime, 0.9 * opacity), 1.3)
            }
        }

        // At the apex: the same rule and number as the card.
        guard let line = usualLine(sc, s, k), let u = s.usual[k],
              let path = s.track.risePath(from: start, to: end), let top = path.max(by: { $0.1 < $1.1 }),
              end - top.0 > 0.05, path.last!.1 < top.1 - 0.004, let apex = sc.ball(at: top.0) else { return }
        let apexAge = end - top.0 - 0.05
        let change = (top.1 / u.apex - 1) * 100
        let col = abs(change) <= 10 ? Pen.lime : Pen.gold
        let y = line.y, ay = originY - CGFloat(top.1) * bodyHeight
        let grow = Motion.easeOut(apexAge / 0.25)
        p.line(apex.p.x, y, apex.p.x, y + (ay - y) * CGFloat(grow), Pen.alpha(col, 0.95 * opacity), 1.2)
        p.line(apex.p.x - 3.5, y, apex.p.x + 3.5, y, Pen.alpha(col, 0.95 * opacity * grow), 1.2)
        p.dot(CGPoint(x: apex.p.x, y: ay), 2.0, Pen.alpha(col, opacity * grow))
        let label = String(format: "%+.0f%%", change)
        let out = sc.outward(apex.p.x, at: top.0)
        p.pill(label, at: CGPoint(x: apex.p.x + out * (apex.r + 6 + halfWidth(label, 1.2)), y: (y + ay) / 2),
               color: col, scale: 1.2 * Motion.backOut(apexAge / 0.3), opacity: opacity)
    }

    // MARK: - Control Surf

    static func controlSurf(_ p: Pen, _ sc: Scene, _ s: AnalyticsMotion.Session, _ t: Double) {
        guard let line = s.line.value(at: t), let firstLine = s.line.times.first,
              let body = s.track.ball(at: t), let ground = sc.ground(at: t) else { return }
        let c = p.c, hw = AnalyticsMotion.laneHalfWidth
        let diameter = CGFloat(s.track.ballDiameter) / sc.u
        let cx = (CGFloat(body.personX) + CGFloat(line) * CGFloat(s.track.ballDiameter)) / sc.u
        let left = cx - CGFloat(hw) * diameter, right = cx + CGFloat(hw) * diameter
        let top = ground - CGFloat(s.track.bodyHeight) / sc.u * 0.9
        let appear = Motion.easeOut((t - firstLine) / 0.5)

        let active = s.excursions.first { $0.shownFrom <= t && ($0.confirmed.map { $0 > t } ?? true) && ($0.censoredAt.map { $0 > t } ?? true) }
        let lastBack = s.excursions.compactMap(\.confirmed).filter { $0 <= t }.max()
        let backFlash = lastBack.map { Motion.flash(t - $0, decay: 0.3) } ?? 0
        let offset = s.sideOffset(at: t)
        let outSide: CGFloat? = active != nil ? ((offset ?? 0) >= 0 ? 1 : -1) : nil

        // The lane, rising from the ground and fading upward.
        let band = CGRect(x: left, y: top, width: right - left, height: ground - top)
        let space = CGColorSpaceCreateDeviceRGB()
        func fade(_ rect: CGRect, _ color: CGColor, _ strength: Double) {
            c.saveGState(); c.clip(to: rect)
            let g = CGGradient(colorsSpace: space, colors: [Pen.alpha(color, 0), Pen.alpha(color, strength)] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
            c.restoreGState()
        }
        fade(band, Pen.mint, (0.13 + 0.2 * backFlash) * appear)
        for (x, side) in [(left, CGFloat(-1)), (right, CGFloat(1))] {
            let hot = outSide == side ? 1.0 : 0.0
            fade(CGRect(x: x - 0.6, y: top, width: 1.2, height: ground - top), Pen.mix(Pen.mint, Pen.coral, hot), (0.55 + 0.4 * hot) * appear)
        }
        // Where the lane meets the ground.
        let floor = CGRect(x: left, y: ground - diameter * 0.16, width: right - left, height: diameter * 0.32)
        c.setFillColor(Pen.alpha(Pen.mint, 0.10 * appear)); c.fillEllipse(in: floor)
        c.setStrokeColor(Pen.alpha(Pen.mint, 0.5 * appear)); c.setLineWidth(0.8); c.strokeEllipse(in: floor)

        // Outside the lane: the ball turns coral and points back.
        if let active, let b = sc.ball(at: t), let side = outSide {
            let on = Motion.easeOut((t - active.shownFrom) / 0.2)
            p.glow(b.p, b.r * 1.6, Pen.coral, 0.25 * on)
            p.ring(b.p, b.r * 1.07, Pen.alpha(Pen.coral, 0.95 * on), 1.2)
            let tip = CGPoint(x: b.p.x - side * (b.r + 9), y: b.p.y)
            for dy in [CGFloat(-4.5), 4.5] {
                p.line(tip.x + side * 4.5, tip.y + dy, tip.x, tip.y, Pen.alpha(Pen.coral, on), 1.4)
            }
            p.text(String(format: "%.1f s", t - active.start), b.p.x, b.p.y - b.r - 13, 6.6, Pen.alpha(Pen.coral, on),
                   weight: 0.62, align: 0.5, mono: true)
        }
        // Back in: the same badge as the card, riding above the ball. Only the latest return
        // keeps it, and it leaves if the ball goes out again.
        if active == nil, let e = s.excursions.last(where: { ($0.confirmed ?? .infinity) <= t }), let back = e.confirmed,
           t - back < 1.1, let b = sc.ball(at: t) ?? sc.ball(at: back) {
            let a = t - back, n = e.touches.count
            p.pill(n == 1 ? "BACK · 1 touch" : "BACK · \(n) touches", at: CGPoint(x: b.p.x, y: b.p.y - b.r - 12), color: Pen.mint,
                   scale: 1.15 * Motion.backOut(a / 0.3), opacity: 1 - Motion.smoothstep(0.75, 1.1, a))
        }
    }

    // MARK: - Helpers

    /// Half the width of a Pen pill at `scale`, so a label can sit beside something without covering it.
    static func halfWidth(_ string: String, _ scale: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): Pen.font(6.6, 0.62, mono: true),
                                                     .init(kCTKernAttributeName as String): 0.3]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
        return (CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + 10) / 2 * scale
    }

    /// A tapering trail behind the ball, kept off the ball itself.
    static func trail(_ p: Pen, _ points: [CGPoint], ball: (p: CGPoint, r: CGFloat), color: CGColor, width: CGFloat, alpha: Double) {
        guard points.count > 1, alpha > 0.01 else { return }
        withBallCut(p, ball) {
            for i in 0..<(points.count - 1) {
                let f = Double(i + 1) / Double(points.count - 1)
                p.line(points[i].x, points[i].y, points[i + 1].x, points[i + 1].y, Pen.alpha(color, alpha * f * f), width * CGFloat(0.25 + 0.75 * f))
            }
        }
    }

    /// Draws `body` everywhere except inside the ball.
    static func withBallCut(_ p: Pen, _ ball: (p: CGPoint, r: CGFloat)?, _ body: () -> Void) {
        guard let ball else { body(); return }
        let c = p.c
        c.saveGState()
        c.addRect(CGRect(x: -10_000, y: -10_000, width: 20_000, height: 20_000))
        c.addEllipse(in: CGRect(x: ball.p.x - ball.r, y: ball.p.y - ball.r, width: 2 * ball.r, height: 2 * ball.r))
        c.clip(using: .evenOdd)
        body()
        c.restoreGState()
    }
}
