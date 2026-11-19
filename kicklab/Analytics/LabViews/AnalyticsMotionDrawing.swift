// Copied from the Effects Lab (EffectLab/Graphs/AnalyticsMotionDrawing.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import CoreGraphics
import CoreText
#if canImport(UIKit)
import UIKit
private typealias PlatformFont = UIFont
#else
import AppKit
private typealias PlatformFont = NSFont
#endif

/// Core Graphics renderer for the on-video analytics strip. Top-left coordinates in a
/// 342 x 124 point card. Everything moves as a function of `time` only.
nonisolated enum AnalyticsMotionDrawing {
    static let size = CGSize(width: 342, height: 124)

    static func draw(in c: CGContext, rect: CGRect, graph: Int, session: AnalyticsMotion.Session, time: Double) {
        c.saveGState(); defer { c.restoreGState() }
        c.translateBy(x: rect.minX, y: rect.minY)
        c.scaleBy(x: rect.width / size.width, y: rect.height / size.height)
        c.setAllowsAntialiasing(true); c.setShouldAntialias(true)
        let pen = Pen(c)
        pen.card()
        switch graph {
        case 0: beatGates(pen, session, max(0, time))
        case 1: arcMatch(pen, session, max(0, time))
        case 2: controlSurf(pen, session, max(0, time))
        default: break
        }
    }

    // MARK: - 01 Beat Gates

    /// A rhythm lane scrolling right to left. The gate for the next touch slides in from the
    /// right, the touch stamps a dot at the now line and the dot springs to early or late.
    static func beatGates(_ p: Pen, _ s: AnalyticsMotion.Session, _ t: Double) {
        p.header("BEAT GATES", "Touch timing")
        let x0: CGFloat = 58, x1: CGFloat = 326, xNow: CGFloat = 288, mid: CGFloat = 60, span: CGFloat = 23
        let pxps = (xNow - x0) / 4.0
        func X(_ time: Double) -> CGFloat { xNow + CGFloat(time - t) * pxps }
        func Y(_ error: Double) -> CGFloat { mid + CGFloat(Motion.clamp(error / 0.2, -1, 1)) * span }
        let window = s.tolerance.value(at: t) ?? 0.06

        p.text("EARLY", 16, mid - span - 4, 6.4, Pen.muted, weight: 0.3, kern: 0.5)
        p.text("ON BEAT", 16, mid - 4, 6.4, Pen.lime, weight: 0.4, kern: 0.5)
        p.text("LATE", 16, mid + span - 4, 6.4, Pen.muted, weight: 0.3, kern: 0.5)
        p.dashed(x0, mid - span, x1, mid - span, Pen.alpha(Pen.white, 0.10))
        p.dashed(x0, mid + span, x1, mid + span, Pen.alpha(Pen.white, 0.10))

        let plot = CGRect(x: x0, y: 28, width: x1 - x0, height: 64)
        p.faded(plot, left: 34, right: 10) {
            p.fill(CGRect(x: x0, y: Y(-window), width: x1 - x0, height: Y(window) - Y(-window)), Pen.alpha(Pen.lime, 0.10), radius: 3)
            p.line(x0, mid, x1, mid, Pen.alpha(Pen.lime, 0.30), 0.7)

            // Gates: muted while waiting, coloured by the touch that answered them.
            for gate in s.gates where gate.shownFrom <= t {
                let x = X(gate.at)
                guard x > x0 - 12, x < x1 + 12 else { continue }
                let appear = Motion.easeOut((t - gate.shownFrom) / 0.3)
                let answered = gate.touch.flatMap { s.touches[$0].time <= t ? s.touches[$0] : nil }
                let color = answered.map { Pen.verdict($0.verdict) } ?? Pen.white
                let hitAge = answered.map { t - $0.time }
                let top = Y(-gate.tolerance) - 6, bottom = Y(gate.tolerance) + 6
                if let age = hitAge, age < 0.6 {
                    p.line(x, top, x, bottom, Pen.alpha(color, 0.35 * Motion.flash(age, decay: 0.2)), 7)
                }
                let a = appear * (answered == nil ? 0.55 : 0.95)
                p.line(x, top, x, bottom, Pen.alpha(color, a), 1.6)
                p.line(x - 3, top, x + 3, top, Pen.alpha(color, a), 1.6)
                p.line(x - 3, bottom, x + 3, bottom, Pen.alpha(color, a), 1.6)
            }

            // Touch dots: stamped on the lane at the now line, then springing to early/late.
            var runs: [[CGPoint]] = [[]]
            var dots: [(CGPoint, Double, Int?)] = []
            for touch in s.touches where touch.time <= t {
                let x = X(touch.time)
                guard x > x0 - 40 else { continue }
                guard let error = touch.error else {
                    if !(runs.last?.isEmpty ?? true) { runs.append([]) }
                    continue
                }
                let age = t - touch.time
                let y = mid + (Y(error) - mid) * CGFloat(Motion.backOut(age / 0.26))
                let point = CGPoint(x: x, y: y)
                runs[runs.count - 1].append(point)
                dots.append((point, age, touch.verdict))
            }
            for run in runs where run.count > 1 {
                p.stroke(Pen.smooth(run), Pen.alpha(Pen.white, 0.34), 1.2)
            }
            for (point, age, verdict) in dots {
                let color = Pen.verdict(verdict)
                if age < 0.45 {
                    let f = age / 0.45
                    p.ring(point, 3 + 9 * CGFloat(Motion.easeOut(f)), Pen.alpha(color, 0.75 * (1 - f)), 1.2)
                }
                p.glow(point, 9, color, 0.35 * Motion.flash(age, decay: 0.25))
                p.dot(point, 3.1 * CGFloat(0.35 + 0.65 * Motion.backOut(age / 0.22)), color)
            }
        }

        // The now line and the cursor riding the lane.
        p.line(xNow, 30, xNow, 90, Pen.alpha(Pen.white, 0.16), 0.6)
        let lastAge = s.touchIndex(at: t).map { t - s.touchTimes[$0] } ?? 9
        p.glow(CGPoint(x: xNow, y: mid), 8, Pen.white, 0.45 * Motion.flash(lastAge, decay: 0.18))
        p.dot(CGPoint(x: xNow, y: mid), 2.2, Pen.white)

        let judged = s.touches.filter { $0.time <= t && $0.verdict != nil }.suffix(10)
        let on = judged.filter { $0.verdict == 0 }.count
        let onAge = judged.last.map { t - $0.time }
        p.stats(Pen.Stat(label: "TEMPO", value: s.tempo.value(at: t).map { String(format: "%.0f", $0) } ?? "—",
                         unit: "/min", color: Pen.white, pulse: s.tempo.age(at: t)),
                Pen.Stat(label: "ON BEAT · LAST 10", value: judged.isEmpty ? "—" : "\(on)/\(judged.count)",
                         unit: "", color: Pen.lime, pulse: onAge))
    }

    // MARK: - 02 Arc Match

    /// The live bounce draws itself with the ball. The player's usual bounce sits behind it.
    static func arcMatch(_ p: Pen, _ s: AnalyticsMotion.Session, _ t: Double) {
        p.header("ARC MATCH", "Each bounce vs your usual")
        let x0: CGFloat = 30, x1: CGFloat = 312, base: CGFloat = 82, top: CGFloat = 32
        func X(_ phase: Double) -> CGFloat { x0 + CGFloat(phase) * (x1 - x0) }
        func Y(_ rise: Double) -> CGFloat { max(24, base - CGFloat(max(-0.05, rise) / s.riseScale) * (base - top)) }
        let k = s.touchIndex(at: t)
        let start = k.map { s.touchTimes[$0] }
        let age = start.map { t - $0 } ?? 9

        // Legend.
        let lx: CGFloat = 326
        var w = p.text("USUAL", lx, 11.5, 6.4, Pen.muted, weight: 0.3, align: 1, kern: 0.5)
        p.dashed(lx - w - 18, 15, lx - w - 5, 15, Pen.gold, 1.4)
        w += p.text("NOW", lx - w - 26, 11.5, 6.4, Pen.muted, weight: 0.3, align: 1, kern: 0.5) + 26
        p.line(lx - w - 16, 15, lx - w - 4, 15, Pen.lime, 1.6)

        p.line(x0, base, x1, base, Pen.alpha(Pen.white, 0.16), 0.6)

        // The usual bounce eases from the previous version to the new one after each touch.
        let current = k.flatMap { s.usual[$0] }
        let previous = k.flatMap { $0 > 0 ? s.usual[$0 - 1] : nil }
        var usualCurve: [Double]?, usualApexPhase = 0.5
        if let current {
            let f = previous == nil ? 1 : Motion.easeInOut(age / 0.5)
            usualCurve = current.curve.indices.map { Motion.lerp(previous?.curve[$0] ?? current.curve[$0], current.curve[$0], f) }
            usualApexPhase = Motion.lerp(previous?.apexPhase ?? current.apexPhase, current.apexPhase, f)
        }
        let usualIn = current == nil ? 0 : (previous == nil ? Motion.easeOut(age / 0.4) : 1)
        if let curve = usualCurve {
            let points = curve.indices.map { CGPoint(x: X(Double($0) / Double(curve.count - 1)), y: Y(curve[$0])) }
            p.dashed(Pen.smooth(points), Pen.alpha(Pen.gold, 0.9 * usualIn), 1.5)
            let apex = CGPoint(x: X(usualApexPhase), y: Y(curve.max() ?? 0))
            p.dashed(apex.x, apex.y + 4, apex.x, base, Pen.alpha(Pen.white, 0.16 * usualIn), 0.6)
        }
        p.text("TOUCH", x0 - 10, base + 4.5, 6, Pen.muted, weight: 0.3, align: 0, kern: 0.4)
        p.text("APEX", X(usualApexPhase), base + 4.5, 6, Pen.alpha(Pen.muted, 0.35 + 0.65 * usualIn), weight: 0.3, align: 0.5, kern: 0.4)
        p.text("NEXT TOUCH", x1 + 10, base + 4.5, 6, Pen.muted, weight: 0.3, align: 1, kern: 0.4)

        // The bounce that just ended settles to its true length and fades.
        if let k, k > 0, let flight = s.flights[k - 1], age < 0.55 {
            let usualBefore = s.usual[k - 1]
            let drawnWith = max(usualBefore?.duration ?? flight.duration, flight.duration / 0.98)
            let span = Motion.lerp(drawnWith, flight.duration, Motion.easeOut(age / 0.25))
            let points = flight.path.map { CGPoint(x: X(($0.0 - flight.start) / span), y: Y($0.1)) }
            let fade = 1 - Motion.easeInOut(age / 0.55)
            p.stroke(Pen.smooth(points), Pen.alpha(Pen.lime, 0.8 * fade), 1.6)
            if let u = usualBefore, u.apex > 0.01 {
                let change = (flight.apex / u.apex - 1) * 100
                p.pill(String(format: "%+.0f%%", change),
                       at: CGPoint(x: X((flight.apexTime - flight.start) / span), y: Y(flight.apex) - 10),
                       color: abs(change) <= 10 ? Pen.lime : Pen.gold, scale: 1, opacity: 1 - Motion.easeInOut(age / 0.28))
            }
            p.ring(CGPoint(x: x1, y: base), 3 + 8 * CGFloat(Motion.easeOut(age / 0.4)), Pen.alpha(Pen.white, 0.7 * (1 - Motion.clamp(age / 0.4))), 1.1)
        }

        // The live bounce.
        if let start, let k {
            let usualDuration = s.usual[k]?.duration ?? (k > 0 ? start - s.touchTimes[k - 1] : 0.6)
            let span = max(usualDuration, age / 0.98)
            if let path = s.track.risePath(from: start, to: t), path.count > 1 {
                let points = path.map { CGPoint(x: X(($0.0 - start) / span), y: Y($0.1)) }
                let curve = Pen.smooth(points)
                let area = CGMutablePath(); area.addPath(curve)
                area.addLine(to: CGPoint(x: points.last!.x, y: base)); area.addLine(to: CGPoint(x: points[0].x, y: base)); area.closeSubpath()
                p.gradient(area, top: top, bottom: base, Pen.lime, 0.24)
                p.stroke(curve, Pen.alpha(Pen.lime, 0.25), 5)
                p.stroke(curve, Pen.lime, 2)
                let head = points.last!
                // At the apex: how this bounce compares with the usual one.
                if let u = s.usual[k], let top = path.max(by: { $0.1 < $1.1 }), t - top.0 > 0.05,
                   path.last!.1 < top.1 - 0.004, u.apex > 0.01 {
                    let apexAge = t - top.0 - 0.05
                    let change = (top.1 / u.apex - 1) * 100
                    let anchor = CGPoint(x: X((top.0 - start) / span), y: Y(top.1))
                    p.pill(String(format: "%+.0f%%", change), at: CGPoint(x: anchor.x, y: anchor.y - 10),
                           color: abs(change) <= 10 ? Pen.lime : Pen.gold, scale: Motion.backOut(apexAge / 0.3))
                }
                p.glow(head, 11, Pen.white, 0.45)
                p.dot(head, 3.3, Pen.white)
            }
            if age < 0.4 { p.ring(CGPoint(x: x0, y: base), 3 + 8 * CGFloat(Motion.easeOut(age / 0.4)), Pen.alpha(Pen.lime, 0.8 * (1 - age / 0.4)), 1.2) }
        }
        p.circle(CGPoint(x: x0, y: base), 2.6, Pen.white, 1)
        p.circle(CGPoint(x: x1, y: base), 2.6, Pen.white, 1)

        if current == nil {
            let have = k.map { k in s.flights.keys.filter { $0 < k }.count } ?? 0
            p.text("Learning your usual bounce · \(min(have, 3))/3", 171, 23, 7, Pen.muted, weight: 0.23, align: 0.5)
        }
        let rise = s.riseChange.value(at: t), flight = s.flightChange.value(at: t)
        p.stats(Pen.Stat(label: "RISE", value: rise.map { String(format: "%+.0f", $0) } ?? "—", unit: rise == nil ? "" : "% vs usual",
                         color: Pen.white, pulse: s.riseChange.age(at: t)),
                Pen.Stat(label: "FLIGHT", value: flight.map { String(format: "%+.2f", $0) } ?? "—", unit: flight == nil ? "" : "s",
                         color: Pen.gold, pulse: s.flightChange.age(at: t)))
    }

    // MARK: - 03 Control Surf

    /// Side-to-side ball position against the player's own line, scrolling. Leaving the lane
    /// opens a bracket that counts up; coming back pops a return badge.
    static func controlSurf(_ p: Pen, _ s: AnalyticsMotion.Session, _ t: Double) {
        p.header("CONTROL SURF", "Side to side vs your line")
        let x0: CGFloat = 62, x1: CGFloat = 326, xNow: CGFloat = 316, mid: CGFloat = 65, span: CGFloat = 20
        let window = 5.0, pxps = (xNow - x0) / CGFloat(window)
        func X(_ time: Double) -> CGFloat { xNow + CGFloat(time - t) * pxps }
        func Y(_ offset: Double) -> CGFloat { mid - CGFloat(Motion.clamp(offset / 2.4, -1.15, 1.15)) * span }
        let hw = AnalyticsMotion.laneHalfWidth

        p.text("RIGHT", 16, mid - span - 4, 6.4, Pen.muted, weight: 0.3, kern: 0.5)
        p.text("YOUR LINE", 16, mid - 4, 6.4, Pen.mint, weight: 0.4, kern: 0.5)
        p.text("LEFT", 16, mid + span - 4, 6.4, Pen.muted, weight: 0.3, kern: 0.5)
        let ready = s.line.value(at: t) != nil
        let laneIn = s.line.age(at: t).map { s.line.times.first == s.line.times.last(where: { $0 <= t }) ? Motion.easeOut($0 / 0.5) : 1 } ?? 0
        p.fill(CGRect(x: x0, y: Y(hw), width: x1 - x0, height: Y(-hw) - Y(hw)), Pen.alpha(Pen.mint, 0.11 * laneIn), radius: 4)
        p.dashed(x0, Y(hw), x1, Y(hw), Pen.alpha(Pen.mint, 0.28 * laneIn), 0.6)
        p.dashed(x0, Y(-hw), x1, Y(-hw), Pen.alpha(Pen.mint, 0.28 * laneIn), 0.6)
        if !ready {
            let have = s.touchIndex(at: t).map { $0 + 1 } ?? 0
            p.text("Finding your line · \(min(have, 3))/3 touches", 194, 61, 7, Pen.muted, weight: 0.23, align: 0.5)
        }

        let plot = CGRect(x: x0, y: 22, width: x1 - x0, height: 71)
        p.faded(plot, left: 34, right: 6) {
            // Touch ticks along the floor of the plot.
            for time in s.touchTimes where time <= t && X(time) > x0 - 4 {
                let a = Motion.flash(t - time, decay: 0.25)
                p.line(X(time), 88, X(time), 92, Pen.alpha(Pen.white, 0.22 + 0.6 * a), 1)
            }
            // The line, coloured by distance from the lane, with a soft glow under it.
            let lo = Motion.lastIndex(s.sideTimes, atOrBefore: t - window - 0.3) ?? 0
            var segments: [[(CGPoint, Double)]] = [[]]
            if let hi = Motion.lastIndex(s.sideTimes, atOrBefore: t), hi >= lo {
                for i in lo...hi {
                    if !s.side[i].continues, !(segments.last?.isEmpty ?? true) { segments.append([]) }
                    segments[segments.count - 1].append((CGPoint(x: X(s.side[i].time), y: Y(s.side[i].offset)), s.side[i].offset))
                }
                if let head = s.sideOffset(at: t), t > s.side[hi].time { segments[segments.count - 1].append((CGPoint(x: xNow, y: Y(head)), head)) }
            }
            for segment in segments where segment.count > 1 {
                let points = segment.map(\.0)
                p.stroke(Pen.smooth(points), Pen.alpha(Pen.mint, 0.13), 6)
                for i in 0..<(points.count - 1) {
                    let off = Motion.smoothstep(hw * 0.95, hw * 1.3, abs((segment[i].1 + segment[i + 1].1) / 2))
                    p.stroke(Pen.segment(points, i), Pen.mix(Pen.mint, Pen.coral, off), 1.9)
                }
            }

            // Excursions: a bracket above that counts up, numbered touches on the line, and a
            // return badge once the ball is confirmed back.
            for e in s.excursions where e.shownFrom <= t {
                let endTime = e.confirmed.map { $0 <= t ? e.reentry! : t } ?? (e.censoredAt.map { min(t, $0) } ?? t)
                guard X(endTime) > x0 - 30 else { continue }
                let cancelled = e.censoredAt.map { t >= $0 } ?? false
                let fade = cancelled ? 1 - Motion.clamp((t - e.censoredAt!) / 0.3) : 1
                guard fade > 0 else { continue }
                let returned = e.confirmed.map { $0 <= t } ?? false
                let settle = returned ? Motion.easeOut((t - e.confirmed!) / 0.2) : 0
                let open = Motion.easeOut((t - e.shownFrom) / 0.2)
                let a = X(e.start), b = returned ? Motion.lerp(Double(X(t)), Double(X(endTime)), settle) : Double(X(endTime))
                let bx = CGFloat(b), y: CGFloat = 37
                let color = returned ? Pen.mix(Pen.coral, Pen.mint, settle) : Pen.coral
                p.line(a, y, a + (bx - a) * CGFloat(open), y, Pen.alpha(color, 0.9 * fade), 1.3)
                p.line(a, y - 3, a, y + 3, Pen.alpha(color, 0.9 * fade), 1.3)
                if open >= 1 { p.line(bx, y - 3, bx, y + 3, Pen.alpha(color, 0.9 * fade), 1.3) }
                let seconds = (returned ? e.reentry! : min(t, e.censoredAt ?? t)) - e.start
                if !returned {
                    p.text(String(format: "%.2f s", seconds), (a + bx) / 2, y - 10, 6.6, Pen.alpha(Pen.coral, fade), weight: 0.4, align: 0.5, mono: true)
                }
                for (n, time) in s.touchTimes.filter({ $0 > e.start && $0 <= min(t, e.reentry ?? t) }).enumerated() {
                    guard let off = sideAt(s, time) else { continue }
                    let pop = Motion.backOut((t - time) / 0.28)
                    p.badge("\(n + 1)", at: CGPoint(x: X(time), y: Y(off)), color: Pen.coral, scale: pop)
                }
                if returned, let back = e.reentry {
                    // Only the latest return keeps its badge; an older one gives way.
                    let newer = s.excursions.compactMap(\.confirmed).filter { $0 > e.confirmed! && $0 <= t }.min()
                    let stay = newer.map { 1 - Motion.easeInOut((t - $0) / 0.25) } ?? 1
                    let pop = Motion.backOut((t - e.confirmed!) / 0.32)
                    let touches = e.touches.count
                    let label = touches == 1 ? "BACK · 1 touch" : "BACK · \(touches) touches"
                    p.pill(label, at: CGPoint(x: X(back), y: y - 7.5), color: Pen.mint, scale: pop, opacity: stay, maxX: x1 - 2)
                }
            }
        }

        // Head on the now line.
        if let head = s.sideOffset(at: t) {
            let off = Motion.smoothstep(hw * 0.95, hw * 1.3, abs(head))
            let point = CGPoint(x: xNow, y: Y(head)), color = Pen.mix(Pen.mint, Pen.coral, off)
            p.glow(point, 10, color, 0.5)
            p.dot(point, 3.2, Pen.white)
        }

        let lane = s.inLane(at: t), back = s.returnSeconds.value(at: t), touches = s.returnTouches.target(at: t)
        p.stats(Pen.Stat(label: "IN LANE · LAST 10 s", value: lane.map { String(format: "%.0f", $0) } ?? "—", unit: lane == nil ? "" : "%",
                         color: Pen.white, pulse: nil),
                Pen.Stat(label: "LAST RETURN", value: back.map { String(format: "%.2f", $0) } ?? "—",
                         unit: back == nil ? "" : (Int(touches ?? 0) == 1 ? "s · 1 touch" : "s · \(Int(touches ?? 0)) touches"), color: Pen.mint, pulse: s.returnSeconds.age(at: t)))
    }

    private static func sideAt(_ s: AnalyticsMotion.Session, _ time: Double) -> Double? { s.sideOffset(at: time) }

    // MARK: - Pen

    final class Pen {
        let c: CGContext
        init(_ c: CGContext) { self.c = c }

        static func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
        static let white = col(0.97, 0.99, 0.97), muted = col(0.70, 0.79, 0.74)
        static let lime = col(0.69, 1, 0.27), mint = col(0.42, 0.96, 0.70)
        static let gold = col(1, 0.80, 0.30), coral = col(1, 0.45, 0.45)
        static func alpha(_ color: CGColor, _ a: Double) -> CGColor { color.copy(alpha: color.alpha * CGFloat(Motion.clamp(a)))! }
        static func mix(_ a: CGColor, _ b: CGColor, _ f: Double) -> CGColor {
            let x = a.components ?? [1, 1, 1, 1], y = b.components ?? [1, 1, 1, 1], f = CGFloat(Motion.clamp(f))
            return col(x[0] + (y[0] - x[0]) * f, x[1] + (y[1] - x[1]) * f, x[2] + (y[2] - x[2]) * f, x[3] + (y[3] - x[3]) * f)
        }
        static func verdict(_ v: Int?) -> CGColor { v == 0 ? lime : v == -1 ? gold : v == 1 ? coral : muted }

        struct Stat {
            let label: String, value: String, unit: String
            let color: CGColor
            /// Seconds since the value last changed.
            let pulse: Double?
        }

        // Fonts are cached; system font with monospaced digits for numbers.
        private static var fonts: [String: CTFont] = [:]
        static func font(_ size: CGFloat, _ weight: CGFloat, mono: Bool) -> CTFont {
            let key = "\(size)|\(weight)|\(mono)"
            if let f = fonts[key] { return f }
            let w = PlatformFont.Weight(rawValue: weight)
            let f = (mono ? PlatformFont.monospacedDigitSystemFont(ofSize: size, weight: w) : PlatformFont.systemFont(ofSize: size, weight: w)) as CTFont
            fonts[key] = f
            return f
        }

        private func ctLine(_ string: String, _ size: CGFloat, _ color: CGColor, _ weight: CGFloat, _ kern: CGFloat, _ mono: Bool) -> CTLine {
            let attrs: [NSAttributedString.Key: Any] = [
                .init(kCTFontAttributeName as String): Pen.font(size, weight, mono: mono),
                .init(kCTForegroundColorAttributeName as String): color,
                .init(kCTKernAttributeName as String): kern,
            ]
            return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
        }

        /// Draws text with its top near `y`; returns its width.
        @discardableResult
        func text(_ string: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: CGColor,
                  weight: CGFloat = 0.23, align: CGFloat = 0, kern: CGFloat = 0, mono: Bool = false, scale: CGFloat = 1) -> CGFloat {
            let l = ctLine(string, size, color, weight, kern, mono)
            let width = CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
            c.saveGState()
            c.translateBy(x: x, y: y + size * 0.5)
            c.scaleBy(x: scale, y: scale)
            c.translateBy(x: -width * align, y: size * 0.45)
            c.scaleBy(x: 1, y: -1)
            c.textPosition = .zero
            CTLineDraw(l, c)
            c.restoreGState()
            return width
        }

        func card() {
            let r = CGRect(origin: .zero, size: AnalyticsMotionDrawing.size)
            let path = CGPath(roundedRect: r, cornerWidth: 18, cornerHeight: 18, transform: nil)
            c.saveGState(); c.addPath(path); c.clip()
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [Pen.col(0.01, 0.05, 0.035, 0.40), Pen.col(0.01, 0.04, 0.03, 0.62)] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: r.height), options: [])
            c.restoreGState()
            c.addPath(CGPath(roundedRect: r.insetBy(dx: 0.3, dy: 0.3), cornerWidth: 18, cornerHeight: 18, transform: nil))
            c.setStrokeColor(Pen.alpha(Pen.white, 0.12)); c.setLineWidth(0.6); c.strokePath()
        }

        func header(_ title: String, _ caption: String) {
            let w = text(title, 16, 9.5, 10.5, Pen.white, weight: 0.62, kern: 0.5)
            text(caption, 16 + w + 8, 10.6, 7.6, Pen.muted, weight: 0.23)
        }

        func stats(_ left: Stat, _ right: Stat) {
            line(16, 96, 326, 96, Pen.alpha(Pen.white, 0.12), 0.5)
            line(171, 102, 171, 116, Pen.alpha(Pen.white, 0.14), 0.5)
            func pop(_ age: Double?) -> CGFloat { CGFloat(1 + 0.14 * Motion.flash(age ?? 9, decay: 0.12)) }
            func bright(_ color: CGColor, _ age: Double?) -> CGColor { Pen.mix(color, Pen.white, 0.6 * Motion.flash(age ?? 9, decay: 0.15)) }
            var x: CGFloat = 16
            x += text(left.label, x, 105, 6.6, Pen.muted, weight: 0.35, kern: 0.6) + 6
            x += text(left.value, x, 102, 13.5, bright(left.color, left.pulse), weight: 0.62, mono: true, scale: pop(left.pulse)) + 3
            text(left.unit, x, 105.5, 7.2, Pen.muted)
            var r: CGFloat = 326
            if !right.unit.isEmpty { r -= text(right.unit, r, 105.5, 7.2, Pen.muted, align: 1) + 3 }
            r -= text(right.value, r, 102, 13.5, bright(right.color, right.pulse), weight: 0.62, align: 1, mono: true, scale: pop(right.pulse)) + 6
            text(right.label, r, 105, 6.6, Pen.muted, weight: 0.35, align: 1, kern: 0.6)
        }

        func line(_ x: CGFloat, _ y: CGFloat, _ xx: CGFloat, _ yy: CGFloat, _ color: CGColor, _ width: CGFloat = 1) {
            c.setStrokeColor(color); c.setLineWidth(width); c.setLineCap(.round)
            c.move(to: CGPoint(x: x, y: y)); c.addLine(to: CGPoint(x: xx, y: yy)); c.strokePath()
        }
        func dashed(_ x: CGFloat, _ y: CGFloat, _ xx: CGFloat, _ yy: CGFloat, _ color: CGColor, _ width: CGFloat = 0.6) {
            let p = CGMutablePath(); p.move(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: xx, y: yy))
            dashed(p, color, width)
        }
        func dashed(_ path: CGPath, _ color: CGColor, _ width: CGFloat) {
            c.saveGState(); c.setLineDash(phase: 0, lengths: [3, 3])
            stroke(path, color, width); c.restoreGState()
        }
        func stroke(_ path: CGPath, _ color: CGColor, _ width: CGFloat) {
            c.addPath(path); c.setStrokeColor(color); c.setLineWidth(width)
            c.setLineCap(.round); c.setLineJoin(.round); c.strokePath()
        }
        func fill(_ r: CGRect, _ color: CGColor, radius: CGFloat = 0) {
            c.addPath(CGPath(roundedRect: r.standardized, cornerWidth: radius, cornerHeight: radius, transform: nil))
            c.setFillColor(color); c.fillPath()
        }
        func dot(_ p: CGPoint, _ r: CGFloat, _ color: CGColor) {
            c.setFillColor(color); c.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
        func ring(_ p: CGPoint, _ r: CGFloat, _ color: CGColor, _ width: CGFloat) {
            c.setStrokeColor(color); c.setLineWidth(width); c.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
        func circle(_ p: CGPoint, _ r: CGFloat, _ color: CGColor, _ width: CGFloat) {
            c.setFillColor(Pen.col(0.02, 0.06, 0.04, 0.9)); c.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            ring(p, r, color, width)
        }
        func glow(_ p: CGPoint, _ r: CGFloat, _ color: CGColor, _ strength: Double) {
            guard strength > 0.005 else { return }
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [Pen.alpha(color, strength), Pen.alpha(color, 0)] as CFArray, locations: [0, 1])!
            c.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: r, options: [])
        }
        func gradient(_ area: CGPath, top: CGFloat, bottom: CGFloat, _ color: CGColor, _ strength: Double) {
            c.saveGState(); c.addPath(area); c.clip()
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [Pen.alpha(color, strength), Pen.alpha(color, 0)] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(g, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
            c.restoreGState()
        }
        /// A rounded label that springs in.
        func pill(_ string: String, at p: CGPoint, color: CGColor, scale: Double, opacity: Double = 1, maxX: CGFloat = .infinity) {
            guard scale > 0.01, opacity > 0.01 else { return }
            let w = CGFloat(CTLineGetTypographicBounds(ctLine(string, 6.6, Pen.white, 0.62, 0.3, true), nil, nil, nil)) + 10
            let x = min(p.x, maxX - w / 2)
            c.saveGState(); c.setAlpha(CGFloat(Motion.clamp(opacity)))
            c.translateBy(x: x, y: p.y); c.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            fill(CGRect(x: -w / 2, y: -6, width: w, height: 12), Pen.alpha(color, 0.92), radius: 6)
            text(string, 0, -3.6, 6.6, Pen.col(0.02, 0.09, 0.05), weight: 0.62, align: 0.5, kern: 0.3, mono: true)
            c.restoreGState()
        }
        /// A numbered circle that springs in.
        func badge(_ string: String, at p: CGPoint, color: CGColor, scale: Double) {
            guard scale > 0.01 else { return }
            c.saveGState(); c.translateBy(x: p.x, y: p.y); c.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            dot(.zero, 5.4, Pen.col(0.02, 0.06, 0.04, 0.95)); ring(.zero, 5.4, color, 1.2)
            text(string, 0, -3.4, 6.4, Pen.white, weight: 0.62, align: 0.5, mono: true)
            c.restoreGState()
        }

        /// Clips drawing to `rect` and fades it out at the left and right edges.
        func faded(_ rect: CGRect, left: CGFloat, right: CGFloat, _ body: () -> Void) {
            let width = 512
            let mask = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            let data = mask.data!.assumingMemoryBound(to: UInt8.self)
            for i in 0..<width {
                let x = CGFloat(i) / CGFloat(width - 1) * rect.width
                let v = Motion.smoothstep(0, Double(left), Double(x)) * Motion.smoothstep(0, Double(right), Double(rect.width - x))
                data[i] = UInt8(Motion.clamp(v) * 255)
            }
            c.saveGState(); c.clip(to: rect, mask: mask.makeImage()!)
            body()
            c.restoreGState()
        }

        /// A smooth curve through points (Catmull-Rom as cubic Béziers).
        static func smooth(_ points: [CGPoint]) -> CGMutablePath {
            let path = CGMutablePath()
            guard let first = points.first else { return path }
            path.move(to: first)
            for i in 0..<max(0, points.count - 1) { appendSegment(path, points, i) }
            return path
        }
        /// Points along the smooth curve through `points` (8 per segment), to continue another path.
        static func smoothPoints(_ points: [CGPoint]) -> [CGPoint] {
            guard points.count > 1 else { return points }
            var out = [points[0]]
            for i in 0..<(points.count - 1) {
                let p0 = points[max(0, i - 1)], p1 = points[i], p2 = points[i + 1], p3 = points[min(points.count - 1, i + 2)]
                let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                for k in 1...8 {
                    let f = CGFloat(k) / 8, g = 1 - f
                    out.append(CGPoint(x: g * g * g * p1.x + 3 * g * g * f * c1.x + 3 * g * f * f * c2.x + f * f * f * p2.x,
                                       y: g * g * g * p1.y + 3 * g * g * f * c1.y + 3 * g * f * f * c2.y + f * f * f * p2.y))
                }
            }
            return out
        }
        static func segment(_ points: [CGPoint], _ i: Int) -> CGMutablePath {
            let path = CGMutablePath(); path.move(to: points[i]); appendSegment(path, points, i); return path
        }
        private static func appendSegment(_ path: CGMutablePath, _ pts: [CGPoint], _ i: Int) {
            let p0 = pts[max(0, i - 1)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(pts.count - 1, i + 2)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
    }
}
