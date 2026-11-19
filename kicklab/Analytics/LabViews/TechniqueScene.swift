// Copied from the Effects Lab (EffectLab/Graphs/TechniqueScene.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import CoreGraphics
import CoreText

/// Technique views drawn on the video, from the owner's Body / Motion and Spatial Analysis
/// concept sheets (lab prototype, 2026-11-18). Positions come from the app's 60 fps ball track
/// and Apple Vision body pose on every frame; distances use the ball as a 22 cm ruler.
///   Next Touch      (concepts 09 + 23) – while the ball comes down: its projected path with
///                   +0.1 s marks, the stretch where this player usually meets it (contact window),
///                   the landing spot and how far the nearer foot is from it. Sideways the landing
///                   is predictable to about 3 cm 0.25 s ahead; the moment only to about ±30 ms,
///                   because players meet the ball at different heights, so time is a window.
///   Touch Signature (14 + 21) – the last twelve bounces drawn from the current contact point,
///                   with rings at three heights showing how far apart they spread.
///   Leg Swing       (07 + 13 + 01) – echoes of the kicking leg, the foot's path coloured by
///                   speed, how high the foot lifts and how fast it is back down after the touch.
/// Everything is a function of the playhead and uses only what has happened so far.
nonisolated enum Technique {
    enum View: String, CaseIterable {
        case nextTouch = "next-touch", touchSignature = "touch-signature", legSwing = "leg-swing"
        case ballFlight = "ball-flight", touchChain = "touch-chain", recoveryChain = "recovery-chain", controlWindow = "control-window"
        case controlTopography = "control-topography"
        case ghostBall = "ghost-ball", lightPainting = "light-painting", zoneGame = "zone-game"
        case heightLadder = "height-ladder", beatGame = "beat-game", touchLens = "touch-lens"
    }

    struct Leg {
        let hip: CGPoint, knee: CGPoint, ankle: CGPoint
        /// Raised ankle above the standing one, in cm.
        let lift: Double
        let ground: Double
    }

    struct Kick {
        let start: Double, end: Double
        let peak: Double, peakTime: Double
        let touch: Double?
        /// Seconds from the touch until the foot is down again.
        let reset: Double?
    }

    struct Flight {
        let start: Double, apexTime: Double
        /// Rising part, relative to the contact point: cm sideways (+ right) and cm up.
        let path: [(t: Double, x: Double, y: Double)]
        let apex: Double
    }

    final class Model {
        let body: BodyZones.Body
        let ball: GraphScene.BallTrack
        let touches: [Double]
        let contactHeights: [Double]
        let flights: [Int: Flight]
        let legTimes: [Double]
        let legs: [Leg?]
        let kicks: [Kick]
        let kickStarts: [Double]
        let motion: AnalyticsMotion.Session
        let sides: [FootChallenge.Side?]
        /// Gravity calibration: the falling ball must accelerate at 9.81 m/s². The factor that
        /// makes the ball-as-ruler scale agree, from bounces finished so far (median, from three).
        let gravityTimes: [Double]
        let gravityFactor: [Double]
        /// Each finished bounce's top, ground 0 … nose 1, by end time.
        let apexEnds: [Double]
        let apexHeights: [Double]

        init(body: BodyZones.Body, ball: GraphScene.BallTrack, touches: [Double], motion: AnalyticsMotion.Session, sides: [FootChallenge.Side?]) {
            self.body = body; self.ball = ball; self.touches = touches; self.motion = motion; self.sides = sides
            var gravityTimes = [Double](), gravityFactor = [Double](), factors = [Double]()
            var apexEnds = [Double](), apexHeights = [Double]()
            for (a, b) in zip(touches, touches.dropFirst()) where b - a > 0.2 && b - a <= 1.5 {
                var ts = [Double](), ys = [Double](), radii = [Double](), top: (Double, Double)?
                var i = (Motion.lastIndex(ball.times, atOrBefore: a + 0.04) ?? -1) + 1
                while i < ball.times.count && ball.times[i] <= b - 0.04 {
                    ts.append(ball.times[i] - a); ys.append(ball.y[i]); radii.append(ball.r[i])
                    if top == nil || ball.y[i] < top!.1 { top = (ball.times[i], ball.y[i]) }
                    i += 1
                }
                if let top, let h = body.height(ofY: top.1, at: top.0) { apexEnds.append(b); apexHeights.append(h) }
                guard ts.count >= 10, let fit = TechniqueDrawing.quadratic(ts, ys), fit.a > 0 else { continue }
                let r = radii.sorted()[radii.count / 2]
                let g = 2 * fit.a * 22 / (2 * r) / 100
                factors.append(9.81 / g)
                if factors.count >= 3 {
                    let sorted = factors.sorted()
                    gravityTimes.append(b); gravityFactor.append(min(1.2, max(0.85, sorted[sorted.count / 2])))
                }
            }
            self.gravityTimes = gravityTimes; self.gravityFactor = gravityFactor
            self.apexEnds = apexEnds; self.apexHeights = apexHeights
            func cmPerPx(_ t: Double) -> Double { 22 / (2 * Double(ball.ball(at: t)?.r ?? 62)) }

            contactHeights = touches.map { t in
                guard let b = ball.ball(at: t), let h = body.height(ofY: Double(b.p.y), at: t) else { return .nan }
                return h
            }

            // Rising part of every bounce, relative to where it was touched.
            var flights = [Int: Flight]()
            for (k, (a, b)) in zip(touches, touches.dropFirst()).enumerated() where b - a > 0.15 && b - a <= 1.5 {
                guard let origin = ball.ball(at: a) else { continue }
                let scale = 22 / (2 * Double(origin.r))
                var path = [(t: Double, x: Double, y: Double)](), previous = a, ok = true
                var i = (Motion.lastIndex(ball.times, atOrBefore: a) ?? -1) + 1
                while i < ball.times.count && ball.times[i] <= b {
                    if ball.times[i] - previous > 0.05 { ok = false; break }
                    path.append((ball.times[i], (ball.x[i] - Double(origin.p.x)) * scale, (Double(origin.p.y) - ball.y[i]) * scale))
                    previous = ball.times[i]; i += 1
                }
                guard ok, path.count >= 6, let top = path.indices.max(by: { path[$0].y < path[$1].y }) else { continue }
                flights[k] = Flight(start: a, apexTime: path[top].t, path: Array(path[...top]), apex: path[top].y)
            }
            self.flights = flights

            // The raised leg on every frame. Joint names are not trusted: the raised ankle is the
            // higher one, its knee the nearer knee, its hip the hip nearer that knee.
            var legTimes = [Double](), legs = [Leg?]()
            for f in body.frames {
                let j = f.joints
                guard let la = j["leftAnkle"], let ra = j["rightAnkle"], let nose = j["nose"],
                      let lk = j["leftKnee"], let rk = j["rightKnee"], let lh = j["leftHip"], let rh = j["rightHip"] else {
                    legTimes.append(f.time); legs.append(nil); continue
                }
                let ground = max(la[1], ra[1]), L = ground - nose[1]
                let up = la[1] < ra[1] ? la : ra
                let liftPx = ground - up[1]
                legTimes.append(f.time)
                guard L > 50, liftPx > 0.045 * L else { legs.append(nil); continue }
                func d(_ a: [Double], _ b: [Double]) -> Double { hypot(a[0] - b[0], a[1] - b[1]) }
                let knee = d(lk, up) < d(rk, up) ? lk : rk
                let hip = d(lh, knee) < d(rh, knee) ? lh : rh
                legs.append(Leg(hip: CGPoint(x: hip[0], y: hip[1]), knee: CGPoint(x: knee[0], y: knee[1]), ankle: CGPoint(x: up[0], y: up[1]),
                                lift: liftPx * cmPerPx(f.time), ground: ground))
            }
            self.legTimes = legTimes; self.legs = legs

            // Kicks: runs of raised frames (gaps up to two frames bridged).
            var kicks = [Kick](), run: (start: Double, end: Double, peak: Double, peakTime: Double)?, missing = 0
            func close() {
                guard let r = run, r.end - r.start >= 0.08 else { run = nil; return }
                let touch = touches.first { $0 >= r.start - 0.03 && $0 <= r.end + 0.03 }
                kicks.append(Kick(start: r.start, end: r.end, peak: r.peak, peakTime: r.peakTime, touch: touch,
                                  reset: touch.map { max(0, r.end - $0) }))
                run = nil
            }
            for (t, leg) in zip(legTimes, legs) {
                if let leg {
                    missing = 0
                    if run == nil { run = (t, t, leg.lift, t) }
                    run!.end = t
                    if leg.lift > run!.peak { run!.peak = leg.lift; run!.peakTime = t }
                } else if run != nil {
                    missing += 1
                    if missing > 2 { close() }
                }
            }
            close()
            self.kicks = kicks
            kickStarts = kicks.map(\.start)
        }

        func touchIndex(at t: Double) -> Int? { Motion.lastIndex(touches, atOrBefore: t) }
        /// Centimetres per source pixel at the ball now: ball as a 22 cm ruler, corrected by gravity.
        func cmPerPx(at t: Double) -> Double {
            let factor = Motion.lastIndex(gravityTimes, atOrBefore: t).map { gravityFactor[$0] } ?? 1
            return 22 / (2 * Double(ball.ball(at: t)?.r ?? 62)) * factor
        }
        /// Usual top of a bounce so far (median of the last ten), ground 0 … nose 1.
        func usualApex(at t: Double) -> Double? {
            guard let i = Motion.lastIndex(apexEnds, atOrBefore: t), i >= 2 else { return nil }
            let recent = apexHeights[max(0, i - 9)...i].sorted()
            return recent[recent.count / 2]
        }
        func leg(at t: Double) -> Leg? {
            guard let i = Motion.lastIndex(legTimes, atOrBefore: t), t - legTimes[i] <= 0.03 else { return nil }
            return legs[i]
        }
        func kick(at t: Double) -> Kick? {
            guard let i = Motion.lastIndex(kickStarts, atOrBefore: t) else { return nil }
            return kicks[i]
        }
    }
}

// MARK: - Drawing

nonisolated enum TechniqueDrawing {
    typealias Pen = AnalyticsMotionDrawing.Pen
    static let cyan = Pen.col(0.35, 0.92, 1), violet = Pen.col(0.68, 0.52, 1), ink = Pen.col(0.02, 0.06, 0.05, 0.82)

    static func draw(_ view: Technique.View, in c: CGContext, size: CGSize, model m: Technique.Model, time: Double) {
        let u = size.width / 372
        c.saveGState(); defer { c.restoreGState() }
        c.scaleBy(x: u, y: u)
        c.setAllowsAntialiasing(true); c.setShouldAntialias(true)
        let p = Pen(c), t = max(0, time)
        func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: CGFloat(x) / u, y: CGFloat(y) / u) }
        pending = []
        switch view {
        case .nextTouch: nextTouch(p, m, t, u, P)
        case .touchSignature: touchSignature(p, m, t, u, P)
        case .legSwing: legSwing(p, m, t, u, P)
        case .ballFlight: ballFlight(p, m, t, u, P)
        case .touchChain: touchChain(p, m, t, u, P)
        case .recoveryChain: recoveryChain(p, m, t, u, P)
        case .controlWindow: controlWindow(p, m, t, u, P)
        case .controlTopography: controlTopography(p, m, t, u, size: size)
        case .ghostBall: ghostBall(p, m, t, u)
        case .lightPainting: lightPainting(p, m, t, u, size: size)
        case .zoneGame: zoneGame(p, m, t, u)
        case .heightLadder: heightLadder(p, m, t, u)
        case .beatGame: beatGame(p, m, t, u)
        case .touchLens: touchLens(p, m, t, u)
        }
        var avoid = [CGRect]()
        if let b = m.ball.ball(at: t) { avoid.append(CGRect(x: (b.p.x - b.r) / u, y: (b.p.y - b.r) / u, width: 2 * b.r / u, height: 2 * b.r / u)) }
        // The player's torso and standing leg: labels sit beside them, not on them.
        if let j = m.body.joints(near: t, needing: ["leftShoulder", "rightShoulder", "leftHip", "rightHip", "nose", "leftAnkle", "rightAnkle"]) {
            let xs = ["leftShoulder", "rightShoulder", "leftHip", "rightHip"].map { j[$0]![0] }
            let ground = max(j["leftAnkle"]![1], j["rightAnkle"]![1])
            avoid.append(CGRect(x: CGFloat(xs.min()!) / u - 4, y: CGFloat(j["nose"]![1]) / u - 12, width: CGFloat(xs.max()! - xs.min()!) / u + 8,
                                height: CGFloat(ground - j["nose"]![1]) / u + 12))
        }
        if view == .legSwing, let leg = m.leg(at: t) {
            let xs = [leg.hip.x, leg.knee.x, leg.ankle.x].map { $0 / u }, ys = [leg.hip.y, leg.knee.y, leg.ankle.y].map { $0 / u }
            avoid.append(CGRect(x: xs.min()! - 6, y: ys.min()! - 6, width: xs.max()! - xs.min()! + 12, height: ys.max()! - ys.min()! + 12))
        }
        let shown = visible.map { CGRect(x: $0.minX / u, y: $0.minY / u, width: $0.width / u, height: $0.height / u) }
            ?? CGRect(x: 0, y: 0, width: 372, height: size.height / u)
        let margin = 6 * shown.width / 372
        layoutLabels(p, bounds: shown.insetBy(dx: margin, dy: margin), avoid: avoid)
    }

    // MARK: Labels

    /// Every view asks for labels while it draws; they are laid out together at the end so they
    /// never overlap each other or leave the frame, then drawn on whole device pixels.
    struct Label {
        let title: String, value: String
        var box: CGPoint
        let anchor: CGPoint?
        let color: CGColor
        let opacity: Double, scale: Double
        /// 0…1: the number rolls up from zero to its value as this goes to 1.
        var roll: Double = 1
        var size: CGSize = .zero
    }
    nonisolated(unsafe) static var pending = [Label]()
    /// What the camera shows, in source pixels; labels are kept inside it.
    nonisolated(unsafe) static var visible: CGRect?

    /// The number roll: 0.4 s ease-out from zero, for a label first shown `age` seconds ago.
    static func rollIn(_ age: Double) -> Double { Motion.easeOut(age / 0.4) }

    /// `value` with its first number scaled by `f`, keeping its sign, decimals and units.
    static func rolled(_ value: String, _ f: Double) -> String {
        guard f < 0.999 else { return value }
        let chars = Array(value)
        guard let start = chars.firstIndex(where: { $0.isNumber }) else { return value }
        var end = start
        while end < chars.count && (chars[end].isNumber || chars[end] == ".") { end += 1 }
        let digits = String(chars[start..<end])
        guard let number = Double(digits) else { return value }
        let decimals = digits.split(separator: ".").count > 1 ? digits.split(separator: ".")[1].count : 0
        return String(chars[..<start]) + String(format: "%.\(decimals)f", number * f) + String(chars[end...])
    }

    /// The shared entrance: fade in over 0.12 s while springing from 86% to full size.
    static func enter(_ age: Double) -> (opacity: Double, scale: Double) {
        (Motion.smoothstep(0, 0.12, age), age >= 0.26 ? 1 : 0.86 + 0.14 * Motion.backOut(age / 0.26))
    }
    /// The shared exit: fade out over 0.2 s.
    static func leave(_ age: Double?) -> Double { age.map { 1 - Motion.smoothstep(0, 0.2, $0) } ?? 1 }

    static func layoutLabels(_ p: Pen, bounds: CGRect, avoid: [CGRect] = []) {
        var items = pending.filter { $0.opacity > 0.01 && $0.scale > 0.01 }
        for i in items.indices {
            let w = max(width(items[i].title, 7, 0.62, 0.8), width(items[i].value, 15, 0.78, 0)) + 4
            items[i].size = CGSize(width: ceil(w), height: items[i].value.isEmpty ? 12 : 27)
        }
        func rect(_ l: Label) -> CGRect { CGRect(x: l.box.x - l.size.width / 2, y: l.box.y - l.size.height / 2, width: l.size.width, height: l.size.height) }
        func clamp(_ l: inout Label) {
            l.box.x = min(max(l.box.x, bounds.minX + l.size.width / 2), bounds.maxX - l.size.width / 2)
            l.box.y = min(max(l.box.y, bounds.minY + l.size.height / 2), bounds.maxY - l.size.height / 2)
        }
        // Top to bottom; a label that would touch one above it moves down by just enough.
        items.sort { $0.box.y < $1.box.y }
        for i in items.indices {
            clamp(&items[i])
            // Repeat until nothing overlaps: off the ball sideways (away from its centre), below any
            // label already placed. A move for one can create the other, so check both each pass.
            for _ in 0..<6 {
                var moved = false
                for o in avoid where rect(items[i]).insetBy(dx: -3, dy: -3).intersects(o) {
                    // Nearest free side first; if the frame edge pushes it back, try the others.
                    let l = items[i], w = l.size.width, h = l.size.height
                    let right = CGPoint(x: o.maxX + 4 + w / 2, y: l.box.y), left = CGPoint(x: o.minX - 4 - w / 2, y: l.box.y)
                    let above = CGPoint(x: l.box.x, y: o.minY - 4 - h / 2), below = CGPoint(x: l.box.x, y: o.maxY + 4 + h / 2)
                    for candidate in (l.box.x >= o.midX ? [right, left, above, below] : [left, right, above, below]) {
                        var trial = l; trial.box = candidate; clamp(&trial)
                        if !rect(trial).insetBy(dx: -3, dy: -3).intersects(o) { items[i] = trial; break }
                    }
                    moved = true
                }
                for j in 0..<i where rect(items[i]).insetBy(dx: -3, dy: -3).intersects(rect(items[j])) {
                    items[i].box.y = rect(items[j]).maxY + 4 + items[i].size.height / 2
                    clamp(&items[i]); moved = true
                }
                if !moved { break }
            }
        }
        for l in items { drawLabel(p, l) }
        pending = []
    }

    static func callout(_ p: Pen, _ title: String, _ value: String, box: CGPoint, anchor: CGPoint?, color: CGColor,
                        opacity: Double, scale: Double = 1, roll: Double = 1) {
        pending.append(Label(title: title, value: value, box: box, anchor: anchor, color: color, opacity: opacity, scale: scale, roll: roll))
    }

    /// Rounds a rectangle to whole device pixels, so 2 px borders land exactly on pixels.
    static func snap(_ c: CGContext, _ r: CGRect) -> CGRect {
        let d = c.convertToDeviceSpace(r).standardized
        return c.convertToUserSpace(CGRect(x: d.minX.rounded(), y: d.minY.rounded(), width: d.width.rounded(), height: d.height.rounded())).standardized
    }

    /// Spatial Analysis style: no box. A small white title over a big value in the label's
    /// colour, both with a soft dark shadow so they read on any background, joined to what they
    /// describe by a hairline that ends in a dot.
    static func drawLabel(_ p: Pen, _ l: Label) {
        let c = p.c, w = l.size.width, h = l.size.height
        let px = 1 / abs(c.userSpaceToDeviceSpaceTransform.a)
        c.saveGState(); c.setAlpha(CGFloat(Motion.clamp(l.opacity)))
        let alignRight = l.anchor.map { $0.x < l.box.x } == false
        let left = l.box.x - w / 2, top = l.box.y - h / 2
        if let anchor = l.anchor {
            // The leader leaves from the value's baseline side nearest the anchor.
            let start = CGPoint(x: anchor.x < l.box.x ? left - 3 : left + w + 3, y: top + h - 7)
            let knee = CGPoint(x: start.x + (anchor.x < l.box.x ? -10 : 10), y: start.y)
            c.setShadow(offset: .zero, blur: 3, color: Pen.col(0, 0, 0, 0.7))
            let path = CGMutablePath(); path.move(to: start); path.addLine(to: knee); path.addLine(to: anchor)
            p.stroke(path, Pen.alpha(Pen.white, 0.9), max(0.8, 2 * px))
            p.dot(anchor, 2.0, Pen.white)
        }
        if l.scale < 0.999 {
            c.translateBy(x: l.box.x, y: l.box.y); c.scaleBy(x: CGFloat(l.scale), y: CGFloat(l.scale)); c.translateBy(x: -l.box.x, y: -l.box.y)
        }
        c.setShadow(offset: CGSize(width: 0, height: 0.6), blur: 5, color: Pen.col(0, 0, 0, 0.75))
        let x = alignRight ? left + w : left, align: CGFloat = alignRight ? 1 : 0
        if l.value.isEmpty {
            p.text(l.title, x, top + 1, 7.6, l.color, weight: 0.75, align: align, kern: 0.8)
        } else {
            p.text(l.title, x, top, 7, Pen.alpha(Pen.white, 0.95), weight: 0.62, align: align, kern: 0.8)
            p.text(rolled(l.value, l.roll), x, top + 9.5, 15, l.color, weight: 0.78, align: align, mono: true)
        }
        c.restoreGState()
    }

    /// Strokes with a coloured glow around them.
    static func glowing(_ c: CGContext, _ color: CGColor, blur: CGFloat, _ body: () -> Void) {
        c.saveGState(); c.setShadow(offset: .zero, blur: blur, color: color); body(); c.restoreGState()
    }

    static func width(_ s: String, _ size: CGFloat, _ weight: CGFloat, _ kern: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): Pen.font(size, weight, mono: false),
                                                     .init(kCTKernAttributeName as String): kern]
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs)), nil, nil, nil))
    }

    /// +1 when `x` is right of the player's body: labels go on the outside, off the player.
    static func outward(_ m: Technique.Model, _ x: CGFloat, _ t: Double, _ u: CGFloat) -> CGFloat {
        guard let s = m.body.scale(at: t) else { return x > 186 ? 1 : -1 }
        return x >= CGFloat(s.rootX) / u ? 1 : -1
    }

    // MARK: Next Touch

    /// Next Touch is on all the time: the contact area stays put, the forecast for the bounce
    /// in the air fades in right after the touch (dimmer while the ball is still rising, when it
    /// is less certain) and the previous forecast fades out over the touch, so they overlap.
    static func nextTouch(_ p: Pen, _ m: Technique.Model, _ t: Double, _ u: CGFloat, _ P: (Double, Double) -> CGPoint) {
        guard let k = m.touchIndex(at: t) else { return }
        let age = t - m.touches[k]
        contactArea(p, m, k, t, u)
        if k > 0, age < 0.3 { forecast(p, m, k - 1, until: m.touches[k], t: t, u: u, P, fade: 1 - Motion.easeInOut(age / 0.3), labels: false) }
        forecast(p, m, k, until: t, t: t, u: u, P, fade: Motion.smoothstep(0.12, 0.3, age), labels: true)
    }

    /// Where this player met the ball on the last ten touches (sideways spread and height range),
    /// as a curved mesh at the foot. It glides to its new place after each touch.
    static func contactArea(_ p: Pen, _ m: Technique.Model, _ k: Int, _ t: Double, _ u: CGFloat) {
        func area(_ k: Int) -> (xl: Double, xr: Double, yt: Double, yb: Double)? {
            let xs = (max(0, k - 9)...k).compactMap { m.ball.ball(at: m.touches[$0]).map { Double($0.p.x) } }.sorted()
            let hs = m.contactHeights[max(0, k - 9)...k].filter { $0.isFinite }.sorted()
            guard xs.count >= 3, hs.count >= 3, let s = m.body.scale(at: m.touches[k]),
                  let x15 = TimingSpread.quantile(xs, 0.15), let x85 = TimingSpread.quantile(xs, 0.85),
                  let lo = TimingSpread.quantile(hs, 0.25), let hi = TimingSpread.quantile(hs, 0.75) else { return nil }
            let r = Double(m.ball.ball(at: m.touches[k])?.r ?? 62), L = s.ground - s.head, d = Double(u)
            return ((x15 - 0.4 * r) / d, (x85 + 0.4 * r) / d, (s.ground - hi * L) / d - 0.6 * r / d, (s.ground - lo * L) / d + 0.9 * r / d)
        }
        guard let now = area(k) else { return }
        let age = t - m.touches[k], f = Motion.easeInOut(age / 0.35)
        let was = k > 0 ? area(k - 1) ?? now : now
        let xl = Motion.lerp(was.xl, now.xl, f), xr = Motion.lerp(was.xr, now.xr, f)
        let yt = Motion.lerp(was.yt, now.yt, f), yb = Motion.lerp(was.yb, now.yb, f)
        let appear = k >= 3 ? 1.0 : 0.0
        guard appear > 0 else { return }
        func M(_ fx: Double, _ fy: Double) -> CGPoint {
            let widen = 0.12 * fy, x = Motion.lerp(xl - (xr - xl) * widen, xr + (xr - xl) * widen, fx)
            let bow = sin(fx * .pi)
            return CGPoint(x: x, y: Motion.lerp(yt, yb, fy) - 7 * bow * (1 - fy) + 6 * bow * fy)
        }
        var edge = [CGPoint]()
        for n in 0...12 { edge.append(M(Double(n) / 12, 0)) }
        for n in 0...12 { edge.append(M(1, Double(n) / 12)) }
        for n in 0...12 { edge.append(M(1 - Double(n) / 12, 1)) }
        for n in 0...12 { edge.append(M(0, 1 - Double(n) / 12)) }
        let outline = CGMutablePath(); outline.addLines(between: edge); outline.closeSubpath()
        // A touch lights the area up for a moment.
        let lit = Motion.flash(age, decay: 0.25)
        p.gradient(outline, top: CGFloat(yt), bottom: CGFloat(yb), Pen.mix(cyan, Pen.lime, lit), (0.3 + 0.25 * lit) * appear)
        for j in 0...6 { let path = CGMutablePath(); path.addLines(between: (0...12).map { M(Double(j) / 6, Double($0) / 12) }); p.stroke(path, Pen.alpha(cyan, 0.45 * appear), 0.5) }
        for j in 0...4 { let path = CGMutablePath(); path.addLines(between: (0...12).map { M(Double($0) / 12, Double(j) / 4) }); p.stroke(path, Pen.alpha(cyan, 0.45 * appear), 0.5) }
        glowing(p.c, Pen.alpha(Pen.mix(cyan, Pen.lime, lit), appear), blur: 6) { p.stroke(outline, Pen.alpha(Pen.mix(cyan, Pen.lime, lit), 0.9 * appear), 1.0) }
    }

    /// The forecast for the bounce that started at touch `k`, fitted on the flight up to `until`.
    static func forecast(_ p: Pen, _ m: Technique.Model, _ k: Int, until: Double, t: Double, u: CGFloat,
                         _ P: (Double, Double) -> CGPoint, fade: Double, labels: Bool) {
        guard fade > 0.01 else { return }
        let a = m.touches[k]
        var ts = [Double](), xs = [Double](), ys = [Double]()
        var i = (Motion.lastIndex(m.ball.times, atOrBefore: a + 0.05) ?? -1) + 1
        while i < m.ball.times.count && m.ball.times[i] <= until { ts.append(m.ball.times[i] - until); xs.append(m.ball.x[i]); ys.append(m.ball.y[i]); i += 1 }
        guard ts.count >= 6, let fit = quadratic(ts, ys), fit.a > 0 else { return }
        let vx = slope(ts, xs), x0 = xs.reduce(0, +) / Double(xs.count) - vx * ts.reduce(0, +) / Double(ts.count)
        let recent = m.contactHeights[max(0, k - 9)...k].filter { $0.isFinite }.sorted()
        guard recent.count >= 3, let s = m.body.scale(at: until),
              let lo = TimingSpread.quantile(recent, 0.25), let mid = TimingSpread.quantile(recent, 0.5), let hi = TimingSpread.quantile(recent, 0.75) else { return }
        let L = s.ground - s.head
        func cross(_ h: Double) -> Double? {
            let target = s.ground - h * L, disc = fit.b * fit.b - 4 * fit.a * (fit.c - target)
            guard disc >= 0 else { return nil }
            return (-fit.b + disc.squareRoot()) / (2 * fit.a)
        }
        guard let tMid = cross(mid), tMid > -0.05, let tLow = cross(lo) else { return }
        let tHigh = max(0, cross(hi) ?? 0)
        func at(_ dt: Double) -> CGPoint { P(x0 + vx * dt, fit.a * dt * dt + fit.b * dt + fit.c) }
        // Dimmer while the ball is still going up (fit.b < 0 in pixels per second, y down).
        let falling = Motion.smoothstep(-250, 0, fit.b)
        let appear = fade * (0.5 + 0.5 * falling)
        let r = m.ball.ball(at: until).map { Double($0.r) } ?? 62
        let rr = CGFloat(r) / u

        // The projected path as a tube: rings every 0.1 s ahead, joined by soft walls.
        let marks = [0.1, 0.2, 0.3].filter { $0 < tLow }
        let ringPts = marks.map { at($0) }
        if !ringPts.isEmpty {
            let all = [at(0)] + ringPts
            let wall = CGMutablePath()
            wall.addLines(between: all.map { CGPoint(x: $0.x - rr * 0.8, y: $0.y) } + all.reversed().map { CGPoint(x: $0.x + rr * 0.8, y: $0.y) })
            wall.closeSubpath()
            p.c.addPath(wall); p.c.setFillColor(Pen.alpha(violet, 0.14 * appear)); p.c.fillPath()
            for sideX in [-0.8, 0.8] as [CGFloat] {
                let edge = CGMutablePath(); edge.addLines(between: all.map { CGPoint(x: $0.x + rr * sideX, y: $0.y) })
                p.stroke(edge, Pen.alpha(violet, 0.6 * appear), 0.7)
            }
            for (pt, mark) in zip(ringPts, marks) {
                let ring = CGRect(x: pt.x - rr * 0.8, y: pt.y - rr * 0.24, width: rr * 1.6, height: rr * 0.48)
                p.c.setFillColor(Pen.alpha(violet, 0.18 * appear)); p.c.fillEllipse(in: ring)
                glowing(p.c, Pen.alpha(violet, appear), blur: 5) {
                    p.c.setStrokeColor(Pen.alpha(Pen.mix(violet, Pen.white, 0.35), appear)); p.c.setLineWidth(1.0); p.c.strokeEllipse(in: ring)
                }
                if labels {
                    p.c.saveGState(); p.c.setShadow(offset: CGSize(width: 0, height: 0.6), blur: 4, color: Pen.col(0, 0, 0, 0.8))
                    p.text(String(format: "+%.2f s", mark), ring.minX - 4, pt.y - 4, 7, Pen.alpha(Pen.white, appear), weight: 0.65, align: 1, mono: true)
                    p.c.restoreGState()
                }
            }
        }
        // The projected path: glowing gold dots, brightest inside the contact window.
        let stepCount = Int((max(0, tLow) / (1.0 / 60)).rounded(.up))
        if stepCount >= 1 {
            for j in stride(from: 1, through: stepCount, by: 2) {
                let dt = Double(j) / 60
                let inWindow = dt >= tHigh && dt <= tLow
                glowing(p.c, Pen.alpha(Pen.gold, appear), blur: 4) { p.dot(at(dt), inWindow ? 2.2 : 1.8, Pen.alpha(Pen.gold, appear)) }
            }
        }
        // The landing spot: when the forecast is frozen at the touch, it bursts.
        let target = at(max(0, tMid))
        let landed = labels ? 0 : 1 - fade
        let pulse = 0.5 + 0.5 * sin(2 * Double.pi * (t - a) / 0.5)
        p.glow(target, rr * 1.2, Pen.lime, 0.55 * appear)
        glowing(p.c, Pen.alpha(Pen.lime, appear), blur: 6) { p.dot(target, 2.8, Pen.alpha(Pen.white, appear)) }
        p.ring(target, rr * (0.32 + 0.06 * CGFloat(pulse) + 0.9 * CGFloat(Motion.easeOut(landed))), Pen.alpha(Pen.lime, 0.9 * fade), 1.2)
        guard labels else { return }

        var adjust: Double?
        if let j = m.body.joints(near: until, needing: ["leftAnkle", "rightAnkle"]) {
            let tx = x0 + vx * tMid
            let foot = [j["leftAnkle"]!, j["rightAnkle"]!].min { abs($0[0] - tx) < abs($1[0] - tx) }!
            adjust = abs(tx - foot[0]) * 22 / (2 * r)
        }
        let recentX = (max(0, k - 9)...k).compactMap { m.ball.ball(at: m.touches[$0]).map { Double($0.p.x) } }.sorted()
        var margin: Double?
        if recentX.count >= 3, let x15 = TimingSpread.quantile(recentX, 0.15), let x85 = TimingSpread.quantile(recentX, 0.85) {
            let tx = x0 + vx * tMid, pad = r * 0.4
            margin = min(tx - x15 + pad, x85 + pad - tx) * 22 / (2 * r)
        }
        let age = t - a
        let side = outward(m, target.x, until, u)
        if let ballNow = m.ball.ball(at: until) {
            let bp = CGPoint(x: ballNow.p.x / u, y: ballNow.p.y / u)
            callout(p, "PROJECTED", "", box: CGPoint(x: bp.x + side * 50, y: bp.y - 30), anchor: CGPoint(x: bp.x + side * rr * 0.7, y: bp.y - rr * 0.7),
                    color: Pen.white, opacity: appear)
        }
        callout(p, "NEXT TOUCH", String(format: "%.2f s", max(0, tMid)), box: CGPoint(x: target.x - side * 66, y: target.y - 34), anchor: target,
                color: Pen.gold, opacity: appear)
        if let margin {
            callout(p, "REACH MARGIN", String(format: "%+.0f cm", margin), box: CGPoint(x: target.x - side * 66, y: target.y + 20), anchor: nil,
                    color: margin >= 0 ? Pen.lime : Pen.coral, opacity: appear, roll: rollIn(age - 0.15))
        }
        if let adjust {
            callout(p, "FOOT TO BALL", String(format: "%.0f cm", adjust), box: CGPoint(x: target.x + side * 66, y: target.y + 20), anchor: nil,
                    color: Pen.white, opacity: appear, roll: rollIn(age - 0.15))
        }
    }

    static func quadratic(_ t: [Double], _ y: [Double]) -> (a: Double, b: Double, c: Double)? {
        let n = Double(t.count)
        var s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0, sy = 0.0, sty = 0.0, st2y = 0.0
        for (x, v) in zip(t, y) { s1 += x; s2 += x * x; s3 += x * x * x; s4 += x * x * x * x; sy += v; sty += x * v; st2y += x * x * v }
        let m = [[s4, s3, s2], [s3, s2, s1], [s2, s1, n]], r = [st2y, sty, sy]
        func det(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }
        let d = det(m)
        guard abs(d) > 1e-12 else { return nil }
        var out = [Double]()
        for k in 0..<3 { var mk = m; for row in 0..<3 { mk[row][k] = r[row] }; out.append(det(mk) / d) }
        return (out[0], out[1], out[2])
    }
    static func slope(_ t: [Double], _ x: [Double]) -> Double {
        let n = Double(t.count), mt = t.reduce(0, +) / n, mx = x.reduce(0, +) / n
        let num = zip(t, x).reduce(0) { $0 + ($1.0 - mt) * ($1.1 - mx) }, den = t.reduce(0) { $0 + ($1 - mt) * ($1 - mt) }
        return den > 0 ? num / den : 0
    }

    // MARK: Touch Signature

    static func touchSignature(_ p: Pen, _ m: Technique.Model, _ t: Double, _ u: CGFloat, _ P: (Double, Double) -> CGPoint) {
        guard let k = m.touchIndex(at: t), let origin = m.ball.ball(at: m.touches[k]) else { return }
        let age = t - m.touches[k]
        let done = m.flights.keys.filter { $0 < k }.sorted().suffix(12).compactMap { m.flights[$0] }
        guard done.count >= 3 else { return }
        // Anchor at this touch; glide over from the last one.
        var anchor = P(Double(origin.p.x), Double(origin.p.y))
        if k > 0, let before = m.ball.ball(at: m.touches[k - 1]) {
            let f = CGFloat(Motion.easeInOut(age / 0.25)), b = P(Double(before.p.x), Double(before.p.y))
            anchor = CGPoint(x: b.x + (anchor.x - b.x) * f, y: b.y + (anchor.y - b.y) * f)
        }
        let perCm = CGFloat(2 * Double(origin.r) / 22) / u
        func Q(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: anchor.x + CGFloat(x) * perCm, y: anchor.y - CGFloat(y) * perCm) }
        let appear = Motion.easeOut(age / 0.25)

        legendPair(p, ("LAST \(done.count) TOUCHES", cyan), ("LATEST", Pen.gold))
        let apexes = done.map(\.apex).sorted()
        let usual = TimingSpread.quantile(apexes, 0.5) ?? 50
        /// Where a rising path crosses height `h` (cm), sideways.
        func crossing(_ f: Technique.Flight, _ h: Double) -> Double? {
            for (a, b) in zip(f.path, f.path.dropFirst()) where a.y <= h && b.y >= h {
                return a.x + (b.x - a.x) * (h - a.y) / max(0.001, b.y - a.y)
            }
            return nil
        }
        // The envelope of the last bounces: the space they all fit in, from the foot up.
        let levels = (0...16).map { usual * Double($0) / 16 * 0.98 }
        var left = [CGPoint](), right = [CGPoint]()
        for h in levels {
            let xs = done.compactMap { crossing($0, h) }
            guard xs.count >= 3 else { continue }
            left.append(Q(xs.min()! - 2.5, h)); right.append(Q(xs.max()! + 2.5, h))
        }
        if left.count >= 3 {
            let shape = CGMutablePath(); shape.addPath(Pen.smooth(left))
            for pt in Pen.smoothPoints(right.reversed()) { shape.addLine(to: pt) }
            shape.closeSubpath()
            p.gradient(shape, top: left.last!.y, bottom: left[0].y, cyan, 0.34 * appear)
            glowing(p.c, Pen.alpha(cyan, appear), blur: 6) {
                p.stroke(Pen.smooth(left), Pen.alpha(cyan, 0.85 * appear), 1.0)
                p.stroke(Pen.smooth(right), Pen.alpha(cyan, 0.85 * appear), 1.0)
            }
        }
        // Each earlier bounce as a fine glowing line, with its top as a dot.
        for (n, f) in done.enumerated() {
            let pts = f.path.map { Q($0.x, $0.y) }
            guard pts.count > 1 else { continue }
            let a = 0.3 + 0.4 * Double(n + 1) / Double(done.count)
            glowing(p.c, Pen.alpha(cyan, a * appear), blur: 3) { p.stroke(Pen.smooth(pts), Pen.alpha(Pen.mix(cyan, Pen.white, 0.3), a * appear), 0.6) }
            p.dot(pts.last!, 1.1, Pen.alpha(Pen.white, 0.9 * appear))
        }
        // Rings at four heights, sized by how far apart the bounces pass there.
        var spreads = [Double](), topRing: (CGPoint, CGFloat)?
        for level in [0.25, 0.5, 0.75, 0.97] {
            let h = usual * level
            let xsAt = done.compactMap { crossing($0, h) }
            guard xsAt.count >= 3 else { continue }
            let mean = xsAt.reduce(0, +) / Double(xsAt.count)
            let sd = (xsAt.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xsAt.count)).squareRoot()
            spreads.append(sd)
            let center = Q(mean, h), half = max(4, CGFloat(xsAt.max()! - xsAt.min()!) / 2 * perCm + 3)
            let ring = CGRect(x: center.x - half, y: center.y - half * 0.3, width: 2 * half, height: half * 0.6)
            p.c.setFillColor(Pen.alpha(cyan, 0.12 * appear)); p.c.fillEllipse(in: ring)
            glowing(p.c, Pen.alpha(cyan, appear), blur: 4) {
                p.c.setStrokeColor(Pen.alpha(Pen.mix(cyan, Pen.white, 0.4), 0.95 * appear)); p.c.setLineWidth(0.9); p.c.strokeEllipse(in: ring)
            }
            if level > 0.9 { topRing = (center, half) }
        }
        // This bounce, live, until it peaks.
        let live = m.ball.path(from: m.touches[k], to: t).map { CGPoint(x: $0.x / u, y: $0.y / u) }
        if live.count > 1 {
            let top = live.indices.min { live[$0].y < live[$1].y }!
            let rising = Array(live[...top])
            if rising.count > 1 {
                glowing(p.c, Pen.gold, blur: 8) { p.stroke(Pen.smooth(rising), Pen.gold, 2.2) }
            }
        }
        glowing(p.c, Pen.gold, blur: 6) { p.dot(anchor, 2.6, Pen.alpha(Pen.gold, appear)) }
        let heightVar: Double? = apexes.count >= 3 && usual > 1 ? {
            let deviations = apexes.map { abs($0 - usual) }.sorted()
            return (TimingSpread.quantile(deviations, 0.5) ?? 0) / usual * 100
        }() : nil
        let top = Q(0, usual)
        let side = outward(m, anchor.x, t, u)
        // Path spread with a dimension bar across the top ring.
        if let spread = spreads.last, let (center, half) = topRing {
            let y = center.y
            p.line(center.x - half, y, center.x + half, y, Pen.alpha(Pen.white, 0.9 * appear), 0.8)
            for x in [center.x - half, center.x + half] { p.line(x, y - 3, x, y + 3, Pen.alpha(Pen.white, 0.9 * appear), 0.8) }
            callout(p, "PATH SPREAD", String(format: "%.0f cm", spread), box: CGPoint(x: center.x - side * (half + 60), y: y + 4),
                    anchor: CGPoint(x: center.x - side * half, y: y), color: Pen.gold, opacity: appear, roll: rollIn(age))
        }
        if let heightVar {
            callout(p, "HEIGHT VAR", String(format: "±%.0f%%", heightVar), box: CGPoint(x: top.x + side * 62, y: top.y - 26),
                    anchor: CGPoint(x: top.x, y: top.y - 3), color: Pen.gold, opacity: appear, roll: rollIn(age))
        }
    }

    /// Two-line key in the top corner: a coloured bar and a name per line.
    static func legendPair(_ p: Pen, _ a: (String, CGColor), _ b: (String, CGColor)) {
        let c = p.c
        c.saveGState(); c.setShadow(offset: CGSize(width: 0, height: 0.6), blur: 4, color: Pen.col(0, 0, 0, 0.7))
        for (n, item) in [a, b].enumerated() {
            let y = CGFloat(18 + n * 10)
            glowing(c, item.1, blur: 3) { p.line(300, y + 3, 316, y + 3, item.1, 1.6) }
            p.text(item.0, 356, y, 6.2, Pen.alpha(Pen.white, 0.95), weight: 0.6, align: 1, kern: 0.6)
        }
        c.restoreGState()
    }

    // MARK: Leg Swing

    /// Swing Volume (concepts 13 + 07 + 01): the surface the leg sweeps through during the
    /// kick (thigh faint, shin strong), as a mesh coloured slow → fast, with its glowing outer
    /// edge (the foot's path). The last swing stays until the next one starts. Then how high
    /// the foot lifted, how long the swing took and how fast it was back down.
    static func legSwing(_ p: Pen, _ m: Technique.Model, _ t: Double, _ u: CGFloat, _ P: (Double, Double) -> CGPoint) {
        legend(p, "SLOW", "FAST", [cyan, violet, Pen.gold])
        guard let i = Motion.lastIndex(m.kickStarts, atOrBefore: t) else { return }
        // The volume: the foot paths of the last eight swings, so the view is never empty and
        // shows how repeatable the swing is.
        for (n, k) in (max(0, i - 8)..<i).enumerated() {
            let kick = m.kicks[k]
            var pts = [CGPoint]()
            for (j, time) in m.legTimes.enumerated() where time >= kick.start && time <= kick.end {
                if let leg = m.legs[j] { pts.append(CGPoint(x: leg.ankle.x / u, y: leg.ankle.y / u)) }
            }
            guard pts.count >= 3 else { continue }
            pts = pts.indices.map { j in
                let r = max(0, j - 2)...min(pts.count - 1, j + 2)
                let s = pts[r].reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
                return CGPoint(x: s.x / CGFloat(r.count), y: s.y / CGFloat(r.count))
            }
            let age = Double(i - k)
            let a = (0.16 + 0.3 * (1 - age / 8)) * (k == i - 8 ? 1 - Motion.smoothstep(0, 0.2, t - m.kicks[i].start) : 1)
            glowing(p.c, Pen.alpha(violet, a), blur: 5) { p.stroke(Pen.smooth(pts), Pen.alpha(Pen.mix(cyan, violet, Double(n) / 8), a), 1.3) }
        }
        // The previous swing gives way while the new one grows.
        if i > 0, t - m.kicks[i].start < 0.15 { swing(p, m, m.kicks[i - 1], t, u, fade: 1 - Motion.smoothstep(0, 0.15, t - m.kicks[i].start), labels: false) }
        let next = i + 1 < m.kicks.count ? m.kicks[i + 1].start : .infinity
        let fade = min(1 - Motion.smoothstep(m.kicks[i].end + 1.2, m.kicks[i].end + 1.6, t), 1 - Motion.smoothstep(next, next + 0.15, t))
        swing(p, m, m.kicks[i], t, u, fade: fade, labels: true)
    }

    private static func swing(_ p: Pen, _ m: Technique.Model, _ kick: Technique.Kick, _ t: Double, _ u: CGFloat, fade: Double, labels: Bool) {
        let c = p.c
        guard fade > 0.01 else { return }
        var legs = [(hip: CGPoint, knee: CGPoint, ankle: CGPoint, lift: Double)]()
        for (i, time) in m.legTimes.enumerated() where time >= kick.start && time <= min(t, kick.end) {
            guard let leg = m.legs[i] else { continue }
            legs.append((CGPoint(x: leg.hip.x / u, y: leg.hip.y / u), CGPoint(x: leg.knee.x / u, y: leg.knee.y / u),
                         CGPoint(x: leg.ankle.x / u, y: leg.ankle.y / u), leg.lift))
        }
        guard legs.count >= 3 else { return }
        // Smoothed over neighbouring frames: tracking wobbles a few pixels on a moving leg.
        func avg(_ pts: ArraySlice<CGPoint>) -> CGPoint {
            let n = CGFloat(pts.count), s = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return CGPoint(x: s.x / n, y: s.y / n)
        }
        let raw = legs
        legs = raw.indices.map { i in
            let r = max(0, i - 2)...min(raw.count - 1, i + 2)
            return (avg(raw[r].map(\.hip)[...]), avg(raw[r].map(\.knee)[...]), avg(raw[r].map(\.ankle)[...]), raw[i].lift)
        }
        var speeds = [CGFloat](repeating: 0, count: legs.count)
        for i in 1..<legs.count { speeds[i] = hypot(legs[i].ankle.x - legs[i - 1].ankle.x, legs[i].ankle.y - legs[i - 1].ankle.y) }
        speeds[0] = speeds[1]
        let fastest = max(0.001, speeds.max() ?? 1)
        func col(_ i: Int) -> CGColor {
            let f = Double(speeds[i] / fastest)
            return f < 0.5 ? Pen.mix(cyan, violet, f * 2) : Pen.mix(violet, Pen.gold, (f - 0.5) * 2)
        }
        /// Along the leg: 0 at the hip, 0.5 at the knee, 1 at the ankle.
        func point(_ i: Int, _ f: CGFloat) -> CGPoint {
            let l = legs[i]
            if f <= 0.5 { let g = f * 2; return CGPoint(x: l.hip.x + (l.knee.x - l.hip.x) * g, y: l.hip.y + (l.knee.y - l.hip.y) * g) }
            let g = (f - 0.5) * 2
            return CGPoint(x: l.knee.x + (l.ankle.x - l.knee.x) * g, y: l.knee.y + (l.ankle.y - l.knee.y) * g)
        }
        let steps: [CGFloat] = [0.25, 0.5, 0.625, 0.75, 0.875, 1]
        c.saveGState(); c.setAlpha(CGFloat(fade))
        // The swept surface, cell by cell: faint at the thigh, strong toward the foot.
        for i in 1..<legs.count {
            for (a, b) in zip(steps, steps.dropFirst()) {
                let cell = CGMutablePath()
                cell.addLines(between: [point(i - 1, a), point(i - 1, b), point(i, b), point(i, a)]); cell.closeSubpath()
                let strength = 0.1 + 0.6 * Double((b - 0.25) / 0.75) * Double((b - 0.25) / 0.75)
                c.addPath(cell); c.setFillColor(Pen.alpha(col(i), strength)); c.fillPath()
            }
        }
        // Mesh: ribs every other frame, and lines along the leg.
        c.setBlendMode(.screen)
        for i in stride(from: 0, to: legs.count, by: 2) {
            let rib = CGMutablePath(); rib.addLines(between: steps.map { point(i, $0) })
            p.stroke(rib, Pen.alpha(Pen.white, 0.45), 0.55)
        }
        for f in steps.dropFirst() {
            let path = CGMutablePath(); path.addLines(between: legs.indices.map { point($0, f) })
            p.stroke(path, Pen.alpha(Pen.white, f == 1 ? 0 : 0.35), 0.5)
        }
        c.setBlendMode(.normal)
        // The outer edge, the foot's path: glowing, in the speed colours.
        for i in 1..<legs.count {
            glowing(c, Pen.alpha(col(i), 1), blur: 9) {
                p.line(legs[i - 1].ankle.x, legs[i - 1].ankle.y, legs[i].ankle.x, legs[i].ankle.y, Pen.mix(col(i), Pen.white, 0.25), 2.4)
            }
        }
        for i in stride(from: 0, to: legs.count, by: 2) { p.dot(legs[i].ankle, 1.7, Pen.white) }
        if t <= kick.end, let last = legs.last { glowing(c, Pen.white, blur: 10) { p.dot(last.ankle, 3, Pen.white) } }
        c.restoreGState()
        guard labels else { return }

        let peak = legs.indices.max { legs[$0].lift < legs[$1].lift }!
        let out = outward(m, legs[peak].ankle.x, t, u)
        let (o, sc) = enter(t - kick.start - 0.08)
        callout(p, "FOOT LIFT", String(format: "%.0f cm", legs[peak].lift), box: CGPoint(x: legs[peak].ankle.x + out * 56, y: legs[peak].ankle.y - 34),
                anchor: legs[peak].ankle, color: Pen.gold, opacity: o * fade, scale: sc, roll: rollIn(t - kick.start - 0.08))
        if let touch = kick.touch, t >= touch {
            let (o2, sc2) = enter(t - touch)
            let mid = legs.count / 2
            callout(p, "SWING", String(format: "%.2f s", touch - kick.start), box: CGPoint(x: point(mid, 0.8).x + out * 60, y: point(mid, 0.8).y + 30),
                    anchor: point(mid, 0.8), color: Pen.gold, opacity: o2 * fade, scale: sc2, roll: rollIn(t - touch))
        }
        if let reset = kick.reset, t >= kick.end, let last = legs.last {
            let (o3, sc3) = enter(t - kick.end)
            callout(p, "BACK DOWN", String(format: "%.2f s", reset), box: CGPoint(x: last.ankle.x + out * 56, y: last.ankle.y + 28),
                    anchor: last.ankle, color: Pen.gold, opacity: o3 * fade, scale: sc3, roll: rollIn(t - kick.end))
        }
    }

    /// A small gradient key in the top corner, as on the concept sheets.
    static func legend(_ p: Pen, _ from: String, _ to: String, _ colors: [CGColor]) {
        let c = p.c, r = CGRect(x: 300, y: 24, width: 56, height: 2.4)
        c.saveGState(); c.setShadow(offset: CGSize(width: 0, height: 0.6), blur: 4, color: Pen.col(0, 0, 0, 0.7))
        let label = "\(from) → \(to)"
        p.text(label, r.maxX, r.minY - 10, 6.2, Pen.alpha(Pen.white, 0.95), weight: 0.6, align: 1, kern: 0.6)
        c.addPath(CGPath(roundedRect: r, cornerWidth: 1.2, cornerHeight: 1.2, transform: nil)); c.clip()
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
        c.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.midY), end: CGPoint(x: r.maxX, y: r.midY), options: [])
        c.restoreGState()
    }
}
