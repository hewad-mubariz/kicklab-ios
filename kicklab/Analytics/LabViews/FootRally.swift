// Copied from the Effects Lab (EffectLab/Graphs/FootRally.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import CoreGraphics

/// Foot Rally: the left / right foot sequence as numbered touches on two lanes, with a
/// session bar of every touch so far. Same foot data as the Left · Right challenge
/// (FootChallenge.Session, raised ankle before contact); this card answers "which side do I
/// use and when do I switch" rather than setting a challenge. Lab prototype (2026-11-17).
/// Drawing is a pure function of the playhead, like the other Analytics Motion cards.
nonisolated enum FootRally {
    struct Model {
        let session: FootChallenge.Session
        /// Touches in the session bar, easing as each touch adds a segment.
        let barCount: Motion.Tween
        /// Foot switches up to and including each touch.
        let switches: [Int]

        init(_ session: FootChallenge.Session) {
            self.session = session
            var changes = [(Double, Double)]()
            if let first = session.touches.first { changes.append((first.time - 1e-4, 0)) }
            for (i, touch) in session.touches.enumerated() { changes.append((touch.time, Double(i + 1))) }
            barCount = Motion.Tween(changes, duration: 0.35)
            var total = 0
            switches = session.touches.map { touch in
                if touch.switched { total += 1 }
                return total
            }
        }
    }
}

/// Core Graphics card, 342 x 124 points, top-left origin.
nonisolated enum FootRallyDrawing {
    typealias Pen = AnalyticsMotionDrawing.Pen
    typealias Side = FootChallenge.Side
    static let size = CGSize(width: 342, height: 124)
    static let leftColor = Pen.mint, rightColor = Pen.gold
    static let ink = Pen.col(0.02, 0.09, 0.05)

    static let x0: CGFloat = 64, xEnd: CGFloat = 326, xNow: CGFloat = 290
    static let yL: CGFloat = 40, yR: CGFloat = 64
    static let nodeRadius: CGFloat = 7.6
    static let window = 4.0
    static let linkIn = 0.22

    static func color(_ side: Side?) -> CGColor { side == .left ? leftColor : side == .right ? rightColor : Pen.muted }
    static func laneY(_ side: Side?) -> CGFloat { side == .left ? yL : side == .right ? yR : (yL + yR) / 2 }

    static func draw(in c: CGContext, rect: CGRect, model m: FootRally.Model, time: Double) {
        c.saveGState(); defer { c.restoreGState() }
        c.translateBy(x: rect.minX, y: rect.minY)
        c.scaleBy(x: rect.width / size.width, y: rect.height / size.height)
        c.setAllowsAntialiasing(true); c.setShouldAntialias(true)
        let p = Pen(c), t = max(0, time), s = m.session
        p.card()
        p.header("FOOT RALLY", "Left / right foot sequence")

        let k = s.index(at: t)
        let pxps = (xNow - x0) / CGFloat(window)
        func X(_ time: Double) -> CGFloat { xNow + CGFloat(time - t) * pxps }
        func point(_ touch: FootChallenge.Touch) -> CGPoint { CGPoint(x: X(touch.time), y: laneY(touch.side)) }

        // Lane chips light up when their foot touches; the lanes run to the right edge.
        for (side, name) in [(Side.left, "LEFT"), (.right, "RIGHT")] {
            let hit = s.lastTime(of: side, before: t).map { t - $0 } ?? 9
            chip(p, name, at: CGPoint(x: 35, y: laneY(side)), color: color(side), flash: Motion.flash(hit, decay: 0.28))
            p.line(60, laneY(side), xEnd, laneY(side), Pen.alpha(color(side), 0.13), 0.8)
        }
        p.line(xNow, 29, xNow, 75, Pen.alpha(Pen.white, 0.15), 0.6)

        // Touches fade out before they reach the chips.
        let plot = CGRect(x: 58, y: 26, width: xEnd + 4 - 58, height: 52)
        p.faded(plot, left: 30, right: 8) {
            guard let k else { return }
            let first = max(0, Motion.lastIndex(s.times, atOrBefore: t - window - 1) ?? 0)
            // Waiting for the next touch: a faint tail from the latest touch to the now line.
            let latest = s.touches[k], age = t - latest.time
            if age < FootChallenge.pauseGap {
                let a = point(latest), fade = 1 - Motion.smoothstep(FootChallenge.pauseGap - 0.6, FootChallenge.pauseGap, age)
                let tail = CGMutablePath(); tail.move(to: CGPoint(x: a.x + nodeRadius, y: a.y)); tail.addLine(to: CGPoint(x: xNow, y: a.y))
                if xNow - a.x > nodeRadius + 2 { p.dashed(tail, Pen.alpha(color(latest.side), 0.32 * fade), 1.0) }
            }
            // Links: a thick lane bar for the same foot again, a thin crossing line for a switch.
            if first + 1 <= k {
                for i in (first + 1)...k {
                    let a = s.touches[i - 1], b = s.touches[i]
                    guard b.time - a.time <= FootChallenge.pauseGap else { continue }
                    link(p, from: point(a), to: point(b), a.side, b.side, progress: Motion.easeOut((t - b.time) / linkIn))
                }
            }
            // Numbered touches, newest on top.
            for i in first...k {
                let touch = s.touches[i], a = t - touch.time, at = point(touch)
                guard at.x > x0 - 30 else { continue }
                if a < 0.5 {
                    let f = a / 0.5
                    p.ring(at, nodeRadius + 9 * CGFloat(Motion.easeOut(f)), Pen.alpha(color(touch.side), 0.75 * (1 - f)), 1.2)
                }
                p.glow(at, 15, color(touch.side), 0.45 * Motion.flash(a, decay: 0.22))
                node(p, "\(i + 1)", at: at, side: touch.side, scale: Motion.backOut(a / 0.26),
                     flash: Motion.flash(a, decay: 0.16), latest: i == k && a < FootChallenge.pauseGap)
            }
        }

        sessionBar(p, m, t, k)
        stats(p, m, t, k)
    }

    // MARK: - Pieces

    static func chip(_ p: Pen, _ name: String, at: CGPoint, color: CGColor, flash: Double) {
        let c = p.c, w: CGFloat = 38, h: CGFloat = 13
        c.saveGState(); c.translateBy(x: at.x, y: at.y)
        let scale = CGFloat(1 + 0.08 * flash); c.scaleBy(x: scale, y: scale)
        let r = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        // The label brightens toward white instead of swapping colours, so it reads at every frame.
        p.glow(.zero, 30, color, 0.35 * flash)
        p.fill(r, Pen.alpha(color, 0.16 + 0.2 * flash), radius: 4)
        c.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
        c.setStrokeColor(Pen.alpha(Pen.mix(color, Pen.white, 0.5 * flash), 0.55 + 0.45 * flash)); c.setLineWidth(0.8); c.strokePath()
        p.text(name, 0, -3.4, 6.6, Pen.mix(color, Pen.white, 0.75 * flash), weight: 0.7, align: 0.5, kern: 0.5)
        c.restoreGState()
    }

    static func link(_ p: Pen, from a: CGPoint, to b: CGPoint, _ sa: Side?, _ sb: Side?, progress: Double) {
        guard progress > 0.001 else { return }
        let end = CGPoint(x: a.x + (b.x - a.x) * CGFloat(progress), y: a.y + (b.y - a.y) * CGFloat(progress))
        let path = CGMutablePath(); path.move(to: a); path.addLine(to: end)
        guard let sa, let sb else { p.dashed(path, Pen.alpha(Pen.muted, 0.5), 1.0); return }
        if sa == sb {
            p.stroke(path, Pen.alpha(color(sa), 0.62), 3.4)
            return
        }
        // A switch: the line fades from one foot's colour to the other's.
        let c = p.c
        c.saveGState()
        c.addPath(path); c.setLineWidth(1.7); c.setLineCap(.round); c.replacePathWithStrokedPath(); c.clip()
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [Pen.alpha(color(sa), 0.95), Pen.alpha(color(sb), 0.95)] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.restoreGState()
    }

    static func node(_ p: Pen, _ number: String, at: CGPoint, side: Side?, scale: Double, flash: Double, latest: Bool) {
        guard scale > 0.01 else { return }
        let c = p.c, col = color(side)
        c.saveGState(); c.translateBy(x: at.x, y: at.y); c.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        if side == nil {
            p.circle(.zero, nodeRadius, Pen.alpha(Pen.muted, 0.8), 1.1)
        } else {
            p.dot(.zero, nodeRadius, Pen.mix(col, Pen.white, 0.55 * flash))
        }
        if latest { p.ring(.zero, nodeRadius + 2.2, Pen.alpha(Pen.white, 0.75), 1.0) }
        let size: CGFloat = number.count >= 3 ? 5.6 : 7.0
        p.text(side == nil ? "?" : number, 0, -size * 0.52, size, side == nil ? Pen.muted : ink, weight: 0.72, align: 0.5, mono: true)
        c.restoreGState()
    }

    /// Every touch so far, one segment each, in order. The newest grows in from the right
    /// while the others make room, so the bar never jumps.
    static func sessionBar(_ p: Pen, _ m: FootRally.Model, _ t: Double, _ k: Int?) {
        let c = p.c, s = m.session
        let bar = CGRect(x: 60, y: 81, width: 288 - 60, height: 5)
        p.text("SESSION", 16, 80.6, 5.6, Pen.muted, weight: 0.4, kern: 0.6)
        p.fill(bar, Pen.alpha(Pen.white, 0.08), radius: 2.5)
        guard let k, let e = m.barCount.value(at: t) else { return }
        let n = k + 1, W = bar.width
        let unit = n >= 2 ? W / CGFloat(max(e, 1)) : W
        let newest = n >= 2 ? max(0, W - CGFloat(n - 1) * unit) : W * CGFloat(Motion.clamp(e))
        let gap: CGFloat = unit >= 4 ? 0.6 : 0
        c.saveGState()
        c.addPath(CGPath(roundedRect: bar, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)); c.clip()
        // Runs of the same foot are drawn as one rect when segments get too thin to separate.
        var i = 0
        while i < n - 1 {
            var j = i
            if gap == 0 { while j + 1 < n - 1 && s.touches[j + 1].side == s.touches[i].side { j += 1 } }
            let x = bar.minX + CGFloat(i) * unit
            p.fill(CGRect(x: x + gap, y: bar.minY, width: CGFloat(j - i + 1) * unit - 2 * gap, height: bar.height),
                   Pen.alpha(color(s.touches[i].side), 0.85))
            i = j + 1
        }
        let latest = s.touches[k]
        let flash = Motion.flash(t - latest.time, decay: 0.2)
        p.fill(CGRect(x: bar.minX + W - newest + gap, y: bar.minY, width: max(0, newest - 2 * gap), height: bar.height),
               Pen.mix(Pen.alpha(color(latest.side), 0.85), Pen.white, 0.7 * flash))
        c.restoreGState()

        // Left : right, like the concept's 4 : 3.
        func pop(_ side: Side) -> CGFloat {
            CGFloat(1 + 0.18 * Motion.flash(s.lastTime(of: side, before: t).map { t - $0 } ?? 9, decay: 0.12))
        }
        var r: CGFloat = 326
        r -= p.text("\(latest.right)", r, 79.2, 8.6, rightColor, weight: 0.66, align: 1, mono: true, scale: pop(.right))
        r -= p.text(" : ", r, 79.2, 8.6, Pen.muted, weight: 0.4, align: 1)
        p.text("\(latest.left)", r, 79.2, 8.6, leftColor, weight: 0.66, align: 1, mono: true, scale: pop(.left))
    }

    static func stats(_ p: Pen, _ m: FootRally.Model, _ t: Double, _ k: Int?) {
        let s = m.session
        p.line(16, 96, 326, 96, Pen.alpha(Pen.white, 0.12), 0.5)
        p.line(118, 102, 118, 116, Pen.alpha(Pen.white, 0.14), 0.5)
        p.line(232, 102, 232, 116, Pen.alpha(Pen.white, 0.14), 0.5)
        func pop(_ a: Double?) -> CGFloat { CGFloat(1 + 0.16 * Motion.flash(a ?? 9, decay: 0.12)) }
        func bright(_ col: CGColor, _ a: Double?) -> CGColor { Pen.mix(col, Pen.white, 0.6 * Motion.flash(a ?? 9, decay: 0.15)) }
        let latest = k.map { s.touches[$0] }
        let left = latest?.left ?? 0, right = latest?.right ?? 0, known = left + right
        let leftAge = s.lastTime(of: .left, before: t).map { t - $0 }
        let rightAge = s.lastTime(of: .right, before: t).map { t - $0 }
        func share(_ n: Int) -> String { known > 0 ? String(format: "%.0f%%", Double(n) / Double(known) * 100) : "" }

        var x: CGFloat = 16
        x += p.text("LEFT FOOT", x, 105, 6.6, Pen.muted, weight: 0.35, kern: 0.6) + 6
        x += p.text("\(left)", x, 102, 13.5, bright(leftColor, leftAge), weight: 0.62, mono: true, scale: pop(leftAge)) + 4
        p.text(share(left), x, 105.5, 7.2, Pen.muted)

        x = 128
        x += p.text("RIGHT FOOT", x, 105, 6.6, Pen.muted, weight: 0.35, kern: 0.6) + 6
        x += p.text("\(right)", x, 102, 13.5, bright(rightColor, rightAge), weight: 0.62, mono: true, scale: pop(rightAge)) + 4
        p.text(share(right), x, 105.5, 7.2, Pen.muted)

        let switches = k.map { m.switches[$0] } ?? 0
        let switchAge = k.flatMap { s.touches[$0].switched ? t - s.touches[$0].time : nil }
        var r: CGFloat = 326
        r -= p.text("\(switches)", r, 102, 13.5, bright(switches > 0 ? Pen.lime : Pen.white, switchAge),
                    weight: 0.62, align: 1, mono: true, scale: pop(switchAge)) + 6
        p.text("SWITCHES", r, 105, 6.6, Pen.muted, weight: 0.35, align: 1, kern: 0.6)
    }
}
