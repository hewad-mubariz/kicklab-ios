// Copied from the Effects Lab (EffectLab/Graphs/TechniqueFun.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import CoreGraphics

/// Three playful views on real data (lab prototype, 2026-11-18):
///   Ghost Ball     – your best bounce so far replays as a ghost beside the real ball, from the
///                    same touch; you race yourself. "Best" = the straightest bounce at about your
///                    usual height (top within ±15%), chosen only from bounces already finished.
///   Light Painting – the ball draws a long-exposure light trail that builds into a picture of
///                    the session, ending on a session signature card.
///   Zone Game      – keep every bounce inside a neon lane; five clean bounces fill the meter and
///                    the lane shrinks a level; a bounce that leaves it drops a level.
/// Also the follow camera used by the renderer. Everything is a function of the playhead.
nonisolated enum TechniqueFun {
    // MARK: Follow camera

    /// A slow push-in to 1.4× in the first 1.2 s, then a calm follow of the player's body,
    /// smoothed over ±0.8 s. Kept inside the frame.
    struct Camera {
        let times: [Double], cx: [Double], cy: [Double]
        let width: Double, height: Double
        static let zoom = 1.4

        init(body: BodyZones.Body, width: Double, height: Double, duration: Double) {
            self.width = width; self.height = height
            var t = [Double](), x = [Double](), y = [Double]()
            var lastX = width / 2, lastY = height / 2
            var s = 0.0
            while s <= duration + 3 {
                if let b = body.scale(at: s) {
                    let L = b.ground - b.head
                    lastX = b.rootX; lastY = (b.ground + b.head) / 2 - 0.04 * L
                }
                t.append(s); x.append(lastX); y.append(lastY); s += 1.0 / 30
            }
            func smooth(_ v: [Double], _ r: Int) -> [Double] {
                v.indices.map { i in let lo = max(0, i - r), hi = min(v.count - 1, i + r); return v[lo...hi].reduce(0, +) / Double(hi - lo + 1) }
            }
            times = t; cx = smooth(smooth(x, 24), 12); cy = smooth(smooth(y, 24), 12)
        }

        func zoom(at t: Double) -> Double { 1 + (Camera.zoom - 1) * Motion.easeInOut(t / 1.2) }

        /// The source rectangle on screen at `t`, in pixels.
        func visible(at t: Double) -> CGRect {
            let z = zoom(at: t)
            let i = min(times.count - 1, max(0, Int((t * 30).rounded())))
            let w = width / z, h = height / z
            let x = min(max(cx[i], w / 2), width - w / 2), y = min(max(cy[i], h / 2), height - h / 2)
            return CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
        }
    }

    // MARK: Ghost Ball data

    struct Bounce {
        let start: Double, end: Double
        /// Relative to the contact point, cm: (seconds after the touch, sideways +right, up).
        let path: [(t: Double, x: Double, y: Double)]
        let apex: Double, apexX: Double
    }

    final class Ghost {
        let bounces: [Int: Bounce]
        /// Per touch k: the best bounce finished before it, and the usual top then.
        let best: [Int: Int]
        let usual: [Int: Double]

        init(_ m: Technique.Model) {
            var bounces = [Int: Bounce]()
            for k in 0..<max(0, m.touches.count - 1) {
                let a = m.touches[k], b = m.touches[k + 1]
                guard b - a > 0.2, b - a <= 1.5, let origin = m.ball.ball(at: a) else { continue }
                let cm = m.cmPerPx(at: a)
                var path = [(t: Double, x: Double, y: Double)](), previous = a, ok = true
                var i = (Motion.lastIndex(m.ball.times, atOrBefore: a) ?? -1) + 1
                while i < m.ball.times.count && m.ball.times[i] <= b {
                    if m.ball.times[i] - previous > 0.05 { ok = false; break }
                    path.append((m.ball.times[i] - a, (m.ball.x[i] - Double(origin.p.x)) * cm, (Double(origin.p.y) - m.ball.y[i]) * cm))
                    previous = m.ball.times[i]; i += 1
                }
                guard ok, path.count >= 8, let top = path.indices.max(by: { path[$0].y < path[$1].y }) else { continue }
                bounces[k] = Bounce(start: a, end: b, path: path, apex: path[top].y, apexX: path[top].x)
            }
            self.bounces = bounces
            var best = [Int: Int](), usual = [Int: Double]()
            for k in m.touches.indices {
                let done = bounces.filter { $0.key + 1 <= k }
                guard done.count >= 3 else { continue }
                let tops = done.values.map(\.apex).sorted()
                let u = tops[tops.count / 2]
                usual[k] = u
                let fair = done.filter { abs($0.value.apex - u) <= 0.15 * u }
                if let pick = fair.min(by: { abs($0.value.apexX) < abs($1.value.apexX) || (abs($0.value.apexX) == abs($1.value.apexX) && $0.key > $1.key) }) {
                    best[k] = pick.key
                }
            }
            self.best = best; self.usual = usual
        }

        static func position(_ b: Bounce, at dt: Double) -> (x: Double, y: Double)? {
            guard dt >= 0, let last = b.path.last, dt <= last.t else { return nil }
            let i = b.path.lastIndex { $0.t <= dt } ?? 0
            guard i + 1 < b.path.count else { return (b.path[i].x, b.path[i].y) }
            let p = b.path[i], q = b.path[i + 1], f = (dt - p.t) / max(1e-6, q.t - p.t)
            return (Motion.lerp(p.x, q.x, f), Motion.lerp(p.y, q.y, f))
        }
    }

    // MARK: Zone Game data

    final class ZoneGame {
        static let halfWidths = [1.6, 1.35, 1.15, 0.98, 0.84, 0.72]
        static let perLevel = 5
        /// State after each touch k (the bounce that ended at touch k judged).
        let level: [Int], combo: [Int], score: [Int]
        let clean: [Bool?]
        let center: [Double]
        let diameter: Double
        let top: [Double]

        init(_ m: Technique.Model) {
            let radii = m.ball.r.sorted()
            diameter = 2 * (radii.isEmpty ? 62 : radii[radii.count / 2])
            var level = [Int](), combo = [Int](), score = [Int](), clean = [Bool?](), center = [Double](), top = [Double]()
            var lv = 0, cb = 0, sc = 0
            for k in m.touches.indices {
                // The lane for the bounce starting at touch k: centred on the last six contacts.
                let xs = (max(0, k - 5)...k).compactMap { m.ball.ball(at: m.touches[$0]).map { Double($0.p.x) } }.sorted()
                center.append(xs.isEmpty ? 540 : xs[xs.count / 2])
                let s = m.body.scale(at: m.touches[k])
                top.append(s.map { $0.ground - (min(0.9, (m.usualApex(at: m.touches[k]) ?? 0.55) + 0.18)) * ($0.ground - $0.head) } ?? 600)
                // Judge the bounce that just ended (from touch k-1).
                var verdict: Bool?
                if k >= 4, m.touches[k] - m.touches[k - 1] <= 1.5 {
                    let hw = ZoneGame.halfWidths[lv] * diameter, c = center[k - 1]
                    var inside = true
                    var i = (Motion.lastIndex(m.ball.times, atOrBefore: m.touches[k - 1] + 0.05) ?? -1) + 1
                    while i < m.ball.times.count && m.ball.times[i] < m.touches[k] - 0.05 {
                        if abs(m.ball.x[i] - c) > hw { inside = false; break }
                        i += 1
                    }
                    verdict = inside
                    if inside {
                        sc += 1; cb += 1
                        if cb == ZoneGame.perLevel { cb = 0; lv = min(ZoneGame.halfWidths.count - 1, lv + 1) }
                    } else { cb = 0; lv = max(0, lv - 1) }
                }
                clean.append(verdict); level.append(lv); combo.append(cb); score.append(sc)
            }
            self.level = level; self.combo = combo; self.score = score; self.clean = clean; self.center = center; self.top = top
        }
    }
}

// MARK: - Drawing

nonisolated extension TechniqueDrawing {
    nonisolated(unsafe) static var ghosts = [ObjectIdentifier: TechniqueFun.Ghost]()
    nonisolated(unsafe) static var games = [ObjectIdentifier: TechniqueFun.ZoneGame]()
    static let magenta = Pen.col(1, 0.35, 0.78)

    // MARK: Ghost Ball

    static func ghostBall(_ p: Pen, _ m: Technique.Model, _ t: Double, _ u: CGFloat) {
        let g = ghosts[ObjectIdentifier(m)] ?? TechniqueFun.Ghost(m)
        ghosts[ObjectIdentifier(m)] = g
        let c = p.c
        legendPair(p, ("GHOST · YOUR BEST", cyan), ("YOU", Pen.gold))
        guard let k = m.touchIndex(at: t), let origin = m.ball.ball(at: m.touches[k]) else { return }
        let dt = t - m.touches[k]
        let cm = m.cmPerPx(at: m.touches[k])
        func screen(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: (Double(origin.p.x) + x / cm) / Double(u), y: (Double(origin.p.y) - y / cm) / Double(u))
        }
        let r = origin.r / u

        // The real bounce: a gold trail.
        let live = m.ball.path(from: m.touches[k], to: t).map { CGPoint(x: $0.x / u, y: $0.y / u) }
        let ballNow = m.ball.ball(at: t).map { (CGPoint(x: $0.p.x / u, y: $0.p.y / u), $0.r / u) }
        if live.count > 2 {
            GraphScene.withBallCut(p, ballNow) {
                glowing(c, Pen.gold, blur: 8) { p.stroke(Pen.smooth(live), Pen.alpha(Pen.gold, 0.95), 2.0) }
            }
        }
        if let b = ballNow { glowing(c, Pen.gold, blur: 10) { p.ring(b.0, b.1 * 1.06, Pen.gold, 1.6) } }

        // The ghost: the best bounce, replayed from this touch.
        if let bi = g.best[k], let best = g.bounces[bi] {
            let appear = Motion.smoothstep(0, 0.1, dt)
            let gone = 1 - Motion.smoothstep(best.end - best.start, best.end - best.start + 0.15, dt)
            let a = appear * gone
            if a > 0.01, let pos = TechniqueFun.Ghost.position(best, at: min(dt, best.end - best.start)) {
                // Its whole path, faint and dashed, so you see where it's going.
                let full = best.path.map { screen($0.x, $0.y) }
                p.c.saveGState(); p.c.setLineDash(phase: CGFloat(-dt * 40), lengths: [3, 4])
                p.stroke(Pen.smooth(full), Pen.alpha(cyan, 0.45 * a), 0.9)
                p.c.restoreGState()
                // Where it has been: a glowing cyan trail.
                let done = best.path.filter { $0.t <= dt }.map { screen($0.x, $0.y) } + [screen(pos.x, pos.y)]
                if done.count > 2 { glowing(c, Pen.alpha(cyan, a), blur: 8) { p.stroke(Pen.smooth(done), Pen.alpha(cyan, 0.9 * a), 1.8) } }
                // The ghost ball itself.
                let at = screen(pos.x, pos.y)
                let shape = CGPath(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: 2 * r, height: 2 * r), transform: nil)
                c.saveGState(); c.addPath(shape); c.clip()
                let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                          colors: [Pen.alpha(Pen.white, 0.55 * a), Pen.alpha(cyan, 0.32 * a), Pen.alpha(cyan, 0.08 * a)] as CFArray,
                                          locations: [0, 0.45, 1])!
                c.drawRadialGradient(gradient, startCenter: CGPoint(x: at.x - r * 0.3, y: at.y - r * 0.35), startRadius: 0, endCenter: at, endRadius: r, options: [])
                c.restoreGState()
                glowing(c, Pen.alpha(cyan, a), blur: 10) { p.ring(at, r, Pen.alpha(Pen.mix(cyan, Pen.white, 0.4), a), 1.3) }
                callout(p, "GHOST", "", box: CGPoint(x: at.x + outward(m, at.x, t, u) * (r + 22), y: at.y - r - 4), anchor: nil,
                        color: cyan, opacity: a)

                // At the top: you against your best.
                if let top = live.indices.min(by: { live[$0].y < live[$1].y }), top < live.count - 3, let ballTop = live.last {
                    let liveTopCm = (Double(origin.p.y) / Double(u) - Double(live[top].y)) * Double(u) * cm
                    let diff = liveTopCm - best.apex
                    let topAge = dt - Double(top) / 60
                    let (o, sc) = enter(topAge)
                    let ok = abs(diff) <= 5
                    callout(p, ok ? "MATCHING YOUR BEST" : diff > 0 ? "HIGHER THAN BEST" : "LOWER THAN BEST", String(format: "%+.0f cm", diff),
                            box: CGPoint(x: live[top].x - outward(m, live[top].x, t, u) * 70, y: live[top].y - 10), anchor: live[top],
                            color: ok ? Pen.lime : Pen.gold, opacity: o, scale: sc, roll: rollIn(topAge))
                    _ = ballTop
                }
            }
        } else if dt < 0.6 {
            callout(p, "FINDING YOUR BEST", "\(min(3, g.bounces.keys.filter { $0 + 1 <= k }.count))/3", box: CGPoint(x: origin.p.x / u, y: origin.p.y / u - 60),
                    anchor: nil, color: cyan, opacity: 1 - Motion.smoothstep(0.4, 0.6, dt))
        }
        // A new best: the bounce that just ended beat the ghost.
        if k > 0, let prev = g.bounces[k - 1], g.best[k] == k - 1, g.best[k - 1] != nil, dt < 0.9 {
            let (o, sc) = enter(dt)
            let at = CGPoint(x: origin.p.x / u, y: origin.p.y / u)
            glowing(c, Pen.gold, blur: 12) { p.ring(at, r * (1.2 + 1.4 * CGFloat(Motion.easeOut(dt / 0.5))), Pen.alpha(Pen.gold, 1 - dt / 0.9), 1.6) }
            callout(p, "NEW BEST", String(format: "%.0f cm off line", abs(prev.apexX)), box: CGPoint(x: at.x - outward(m, at.x, t, u) * 64, y: at.y + 24),
                    anchor: nil, color: Pen.gold, opacity: o * leave(dt - 0.7), scale: sc, roll: rollIn(dt))
        }
    }

    // MARK: Light Painting

    static func lightPainting(_ p: Pen, _ m: Technique.Model, _ t: Double, _ u: CGFloat, size: CGSize) {
        let c = p.c
        if ghosts[ObjectIdentifier(m)] == nil { ghosts[ObjectIdentifier(m)] = TechniqueFun.Ghost(m) }
        let palette = [cyan, violet, magenta, Pen.gold, cyan]
        func color(_ time: Double) -> CGColor {
            let f = (time / 6).truncatingRemainder(dividingBy: 1) * Double(palette.count - 1)
            let i = Int(f)
            return Pen.mix(palette[i], palette[i + 1], f - Double(i))
        }
        let end = m.touches.last ?? 0
        let signature = Motion.smoothstep(end + 0.35, end + 0.9, t)
        // Darken the picture for the closing card.
        if signature > 0 {
            c.setFillColor(Pen.col(0.01, 0.02, 0.05, 0.62 * signature))
            c.fill(CGRect(x: -2000, y: -2000, width: 6000, height: 8000))
        }
        // The trail, in chunks of six frames: wide faint, medium and fine bright layers, added
        // with screen blending so overlaps glow brighter.
        c.saveGState(); c.setBlendMode(.screen)
        var i = 0, chunk = [CGPoint](), chunkTime = 0.0
        func flush() {
            guard chunk.count > 1 else { return }
            let age = t - chunkTime
            let a = signature > 0 ? 0.55 + 0.45 * signature : 0.38 + 0.62 * exp(-age / 3)
            let col = color(chunkTime), path = Pen.smooth(chunk)
            p.stroke(path, Pen.alpha(col, 0.10 * a), 8)
            p.stroke(path, Pen.alpha(col, 0.32 * a), 3.2)
            p.stroke(path, Pen.alpha(Pen.mix(col, Pen.white, 0.45), 0.95 * a), 1.1)
        }
        var previous: Double?
        while i < m.ball.times.count && m.ball.times[i] <= t {
            let time = m.ball.times[i], pt = CGPoint(x: m.ball.x[i] / u, y: m.ball.y[i] / u)
            if let prev = previous, time - prev > 0.05 { flush(); chunk = [] }
            if chunk.isEmpty { chunkTime = time }
            chunk.append(pt)
            if chunk.count >= 7 { flush(); chunk = [pt]; chunkTime = time }
            previous = time; i += 1
        }
        if let head = m.ball.ball(at: t) { chunk.append(CGPoint(x: head.p.x / u, y: head.p.y / u)) }
        flush()
        c.restoreGState()
        // A spark at every touch, staying as a small star.
        for k in m.touches.indices where m.touches[k] <= t {
            guard let b = m.ball.ball(at: m.touches[k]) else { continue }
            let at = CGPoint(x: b.p.x / u, y: (b.p.y + b.r * 0.8) / u), age = t - m.touches[k]
            let pop = Motion.backOut(age / 0.25), burst = Motion.flash(age, decay: 0.2)
            star(p, at, 3.2 * CGFloat(pop) + 8 * CGFloat(burst), Pen.alpha(Pen.mix(color(m.touches[k]), Pen.white, 0.6), 0.75 + 0.25 * burst))
        }
        // The ball's head.
        if signature < 1, let b = m.ball.ball(at: t) {
            glowing(c, Pen.white, blur: 10) { p.dot(CGPoint(x: b.p.x / u, y: b.p.y / u), 2.6, Pen.alpha(Pen.white, 1 - signature)) }
        }
        // The session signature.
        guard signature > 0.01, let first = m.touches.first else { return }
        let view = visible.map { CGRect(x: $0.minX / u, y: $0.minY / u, width: $0.width / u, height: $0.height / u) }
            ?? CGRect(x: 0, y: 0, width: 372, height: size.height / u)
        let age = t - end - 0.35
        let (o, _) = enter(age)
        c.saveGState(); c.setAlpha(CGFloat(o)); c.setShadow(offset: CGSize(width: 0, height: 1), blur: 6, color: Pen.col(0, 0, 0, 0.8))
        let titleY = view.minY + view.height * 0.1
        p.text("SESSION SIGNATURE", view.midX, titleY, 15 * view.width / 372, Pen.white, weight: 0.85, align: 0.5, kern: 2.5)
        p.text(String(format: "%d touches · %.1f seconds", m.touches.count, end - first), view.midX, titleY + 22 * view.width / 372,
               8.5 * view.width / 372, Pen.alpha(Pen.white, 0.85), weight: 0.55, align: 0.5, kern: 0.8)
        c.restoreGState()
        // Stats row at the bottom.
        let tops = (0..<max(0, m.touches.count - 1)).compactMap { k -> Double? in
            guard let g = ghosts[ObjectIdentifier(m)]?.bounces[k] else { return nil }
            return g.apex
        }.sorted()
        let leftCount = m.sides.filter { $0 == .left }.count, rightCount = m.sides.filter { $0 == .right }.count
        var stats: [(String, String, CGColor)] = [("TOUCHES", "\(m.touches.count)", Pen.white)]
        if !tops.isEmpty { stats.append(("USUAL RISE", String(format: "%.2f m", tops[tops.count / 2] / 100), cyan)) }
        stats.append(("LEFT · RIGHT", "\(leftCount) · \(rightCount)", Pen.gold))
        let rowY = view.maxY - view.height * 0.16
        for (n, s) in stats.enumerated() {
            let x = view.minX + view.width * (CGFloat(n) + 0.5) / CGFloat(stats.count)
            let (so, ssc) = enter(age - 0.15 - 0.1 * Double(n))
            callout(p, s.0, s.1, box: CGPoint(x: x, y: rowY), anchor: nil, color: s.2, opacity: so, scale: ssc, roll: rollIn(age - 0.15 - 0.1 * Double(n)))
        }
    }

    static func star(_ p: Pen, _ at: CGPoint, _ r: CGFloat, _ col: CGColor) {
        guard r > 0.2 else { return }
        let path = CGMutablePath()
        for k in 0..<8 {
            let ang = CGFloat(k) * .pi / 4, rr = k % 2 == 0 ? r : r * 0.32
            let pt = CGPoint(x: at.x + cos(ang) * rr, y: at.y + sin(ang) * rr)
            k == 0 ? path.move(to: pt) : path.addLine(to: pt)
        }
        path.closeSubpath()
        glowing(p.c, col, blur: 5) { p.c.addPath(path); p.c.setFillColor(col); p.c.fillPath() }
    }

    // MARK: Zone Game

    static func zoneGame(_ p: Pen, _ m: Technique.Model, _ t: Double, _ u: CGFloat) {
        let g = games[ObjectIdentifier(m)] ?? TechniqueFun.ZoneGame(m)
        games[ObjectIdentifier(m)] = g
        let c = p.c
        guard let k = m.touchIndex(at: t), k >= 3, let s = m.body.scale(at: t) else { return }
        let age = t - m.touches[k]
        // The lane glides to its new centre and springs to its new width after each touch.
        let previousLevel = k > 0 ? g.level[k - 1] : 0
        let hw0 = TechniqueFun.ZoneGame.halfWidths[previousLevel], hw1 = TechniqueFun.ZoneGame.halfWidths[g.level[k]]
        let hw = (hw0 + (hw1 - hw0) * Motion.backOut(age / 0.45, overshoot: 1.2)) * g.diameter
        let c0 = k > 0 ? g.center[k - 1] : g.center[k]
        var cx = c0 + (g.center[k] - c0) * Motion.easeInOut(age / 0.4)
        // A miss shakes the lane.
        let missed = g.clean[k] == false
        if missed { cx += 10 * sin(age * 60) * exp(-age / 0.12) }
        let top = (k > 0 ? g.top[k - 1] : g.top[k]) + (g.top[k] - (k > 0 ? g.top[k - 1] : g.top[k])) * Motion.easeInOut(age / 0.4)
        let rect = CGRect(x: (cx - hw) / Double(u), y: top / Double(u), width: 2 * hw / Double(u), height: (s.ground - top) / Double(u))
        let ball = m.ball.ball(at: t)
        let out = ball.map { abs(Double($0.p.x) - cx) > hw } ?? false
        let hit = Motion.flash(age, decay: 0.25)
        let edge = out || (missed && age < 0.5) ? Pen.coral : g.clean[k] == true ? Pen.mix(cyan, Pen.lime, hit) : cyan
        let appear = Motion.smoothstep(0, 0.3, t - m.touches[3])

        // Two light walls rising from the ground and fading out upward, with a soft curtain
        // between them that pulses on every clean bounce.
        let space = CGColorSpaceCreateDeviceRGB()
        let curtain = CGGradient(colorsSpace: space, colors: [Pen.alpha(violet, 0), Pen.alpha(violet, (0.1 + 0.22 * (g.clean[k] == true ? hit : 0)) * appear)] as CFArray, locations: [0, 1])!
        c.saveGState(); c.clip(to: rect)
        c.drawLinearGradient(curtain, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
        c.restoreGState()
        for x in [rect.minX, rect.maxX] {
            let wall = CGRect(x: x - 1.2, y: rect.minY, width: 2.4, height: rect.height)
            let beam = CGGradient(colorsSpace: space, colors: [Pen.alpha(edge, 0), Pen.alpha(Pen.mix(edge, Pen.white, 0.35), appear)] as CFArray, locations: [0, 1])!
            glowing(c, Pen.alpha(edge, appear), blur: 10) {
                c.saveGState(); c.clip(to: wall)
                c.drawLinearGradient(beam, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
                c.restoreGState()
            }
            // Energy running up the wall, a little faster as the level rises.
            for n in 0..<3 {
                let phase = (t * (0.7 + 0.15 * Double(g.level[k])) + Double(n) / 3).truncatingRemainder(dividingBy: 1)
                let y = rect.maxY - CGFloat(phase) * rect.height
                p.dot(CGPoint(x: x, y: y), 1.6, Pen.alpha(Pen.white, (1 - phase) * 0.9 * appear))
            }
        }
        // The floor of the lane: a glowing ellipse at the feet.
        let floor = CGRect(x: rect.minX, y: rect.maxY - 6, width: rect.width, height: 12)
        glowing(c, Pen.alpha(edge, appear), blur: 8) {
            c.setStrokeColor(Pen.alpha(Pen.mix(edge, Pen.white, 0.3), 0.9 * appear)); c.setLineWidth(1.2); c.strokeEllipse(in: floor)
        }
        c.setFillColor(Pen.alpha(edge, (0.12 + 0.25 * hit) * appear)); c.fillEllipse(in: floor)
        // Meter above the lane: five cells, the newest fills with a pop; on a level up all flash.
        let levelUp = k > 0 && g.level[k] > g.level[k - 1]
        let cellW: CGFloat = 9, gap: CGFloat = 3, n = TechniqueFun.ZoneGame.perLevel
        let mx = rect.midX - (CGFloat(n) * cellW + CGFloat(n - 1) * gap) / 2, my = rect.minY + 4
        for j in 0..<n {
            let r = CGRect(x: mx + CGFloat(j) * (cellW + gap), y: my, width: cellW, height: 4)
            let filled = j < g.combo[k] || (levelUp && age < 0.5)
            let isNew = j == g.combo[k] - 1 && g.clean[k] == true
            let col = levelUp && age < 0.5 ? Pen.white : Pen.lime
            p.fill(r, Pen.alpha(Pen.white, 0.18 * appear), radius: 2)
            if filled {
                let pop = isNew ? CGFloat(Motion.backOut(age / 0.25)) : 1
                let rr = CGRect(x: r.midX - r.width * pop / 2, y: r.midY - r.height * pop / 2, width: r.width * pop, height: r.height * pop)
                glowing(c, Pen.alpha(col, appear), blur: 5) { p.fill(rr, Pen.alpha(col, appear), radius: 2) }
            }
        }
        // Outside right now: a coral ring on the ball.
        if out, let b = ball {
            glowing(c, Pen.coral, blur: 8) { p.ring(CGPoint(x: b.p.x / u, y: b.p.y / u), b.r / u * 1.08, Pen.coral, 1.6) }
        }
        // Moments.
        if levelUp {
            let (o, sc) = enter(age)
            callout(p, "LEVEL UP", "LEVEL \(g.level[k] + 1)", box: CGPoint(x: rect.midX, y: rect.minY - 30), anchor: nil, color: Pen.lime,
                    opacity: o * leave(age - 1.0), scale: sc * (1 + 0.15 * Motion.flash(age, decay: 0.15)))
        } else if missed {
            let (o, sc) = enter(age)
            callout(p, "OUT OF THE ZONE", g.level[k] < previousLevel ? "LEVEL \(g.level[k] + 1)" : "COMBO LOST", box: CGPoint(x: rect.midX, y: rect.minY - 30),
                    anchor: nil, color: Pen.coral, opacity: o * leave(age - 0.8), scale: sc)
        }
        // Score and level, beside the lane.
        let side: CGFloat = rect.midX > CGFloat(s.rootX) / u ? 1 : -1
        let hx = side > 0 ? rect.maxX + 34 : rect.minX - 34
        callout(p, "LEVEL", "\(g.level[k] + 1)", box: CGPoint(x: hx, y: rect.minY + 20), anchor: nil, color: Pen.lime, opacity: appear)
        callout(p, "CLEAN BOUNCES", "\(g.score[k])", box: CGPoint(x: hx, y: rect.minY + 52), anchor: nil, color: Pen.white, opacity: appear,
                scale: 1 + 0.12 * (g.clean[k] == true ? Motion.flash(age, decay: 0.12) : 0))
    }
}
