// Copied from the Effects Lab (EffectLab/Graphs/BodyZones.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import CoreGraphics

/// Body-aware analytics, measured against the player's own body instead of the screen.
///   Peak Zone  – how high each bounce goes: knee, hip, chest or head.
///   Touch Zone – where on the body the ball is met (ankle, shin, high) and with what
///                (foot, thigh, chest, head).
/// Heights are fractions of the player's height in the same frame: 0 at the standing foot,
/// 1 at the nose. Moving toward or away from the camera therefore changes nothing.
/// Body pose comes from Apple Vision on every frame; left/right joint names are never used
/// (they swap when the legs cross). Lab prototype, 2026-11-18.
nonisolated enum BodyZones {
    struct PoseFile: Decodable {
        struct Frame: Decodable { let time: Double; let joints: [String: [Double]] }
        let frames: [Frame]
    }

    static let zoneNames = ["KNEE", "HIP", "CHEST", "HEAD"]
    static let contactNames = ["ANKLE", "SHIN", "HIGH"]
    static let partNames = ["FOOT", "THIGH", "CHEST", "HEAD"]

    /// A standing figure in body units (u sideways from the body centre, v up from the
    /// ground), symmetric, from the session's own standing frames.
    struct Figure {
        var points: [String: (u: Double, v: Double)] = [:]
    }

    /// The body's scale over time, smoothed (τ 0.1 s), plus the session's landmark heights.
    struct Body {
        let times: [Double], ground: [Double], head: [Double], rootX: [Double]
        let frames: [PoseFile.Frame]
        let frameTimes: [Double]
        /// Session medians, as fractions from ground (0) to nose (1).
        let knee: Double, hip: Double, shoulder: Double
        let figure: Figure

        init(_ file: PoseFile) {
            let sorted = file.frames.sorted { $0.time < $1.time }
            var t = [Double](), g = [Double](), h = [Double](), rx = [Double]()
            var kn = [Double](), hp = [Double](), sh = [Double]()
            var parts: [String: ([Double], [Double])] = [:]
            var last: (Double, Double, Double, Double)?
            for f in sorted {
                let j = f.joints
                guard let la = j["leftAnkle"], let ra = j["rightAnkle"], let nose = j["nose"], let root = j["root"] else { continue }
                let ground = max(la[1], ra[1]), L = ground - nose[1]
                guard L > 50 else { continue }
                if let (t0, g0, h0, x0) = last {
                    let k = 1 - exp(-(f.time - t0) / 0.1)
                    last = (f.time, g0 + k * (ground - g0), h0 + k * (nose[1] - h0), x0 + k * (root[0] - x0))
                } else { last = (f.time, ground, nose[1], root[0]) }
                t.append(f.time); g.append(last!.1); h.append(last!.2); rx.append(last!.3)
                if let lk = j["leftKnee"], let rk = j["rightKnee"] { kn.append((ground - max(lk[1], rk[1])) / L) }
                hp.append((ground - root[1]) / L)
                if let ls = j["leftShoulder"], let rs = j["rightShoulder"] { sh.append((ground - (ls[1] + rs[1]) / 2) / L) }
                // The figure comes from frames with both feet down.
                guard abs(la[1] - ra[1]) < 0.03 * L else { continue }
                for (name, keys) in [("shoulder", ["leftShoulder", "rightShoulder"]), ("wrist", ["leftWrist", "rightWrist"]),
                                     ("hip", ["leftHip", "rightHip"]), ("knee", ["leftKnee", "rightKnee"]),
                                     ("ankle", ["leftAnkle", "rightAnkle"]), ("neck", ["neck"]), ("root", ["root"]), ("nose", ["nose"])] {
                    for key in keys {
                        guard let p = j[key], p[2] >= 0.3 else { continue }
                        parts[name, default: ([], [])].0.append(abs(p[0] - root[0]) / L)
                        parts[name, default: ([], [])].1.append((ground - p[1]) / L)
                    }
                }
            }
            times = t; ground = g; head = h; rootX = rx
            frames = sorted; frameTimes = sorted.map(\.time)
            knee = Motion.median(kn) ?? 0.26; hip = Motion.median(hp) ?? 0.51; shoulder = Motion.median(sh) ?? 0.86
            var figure = Figure()
            for (name, values) in parts {
                let paired = !["neck", "root", "nose"].contains(name)
                figure.points[name] = (paired ? Motion.median(values.0) ?? 0 : 0, Motion.median(values.1) ?? 0)
            }
            self.figure = figure
        }

        /// Ground, head and body centre at `t`, in pixels.
        func scale(at t: Double) -> (ground: Double, head: Double, rootX: Double)? {
            guard let i = Motion.lastIndex(times, atOrBefore: t) else { return nil }
            // Short tracking drop-outs (up to 0.3 s) are bridged, so nothing built on the body blinks.
            if i + 1 < times.count, times[i + 1] - times[i] <= 0.3 {
                let f = (t - times[i]) / (times[i + 1] - times[i])
                return (Motion.lerp(ground[i], ground[i + 1], f), Motion.lerp(head[i], head[i + 1], f), Motion.lerp(rootX[i], rootX[i + 1], f))
            }
            return t - times[i] <= 0.3 ? (ground[i], head[i], rootX[i]) : nil
        }
        /// Height of an image row at `t`, ground 0, nose 1.
        func height(ofY y: Double, at t: Double) -> Double? {
            guard let s = scale(at: t), s.ground - s.head > 1 else { return nil }
            return (s.ground - y) / (s.ground - s.head)
        }
        /// Raw joints of the nearest frame that has the ones needed, looking back first.
        func joints(near t: Double, needing keys: [String]) -> [String: [Double]]? {
            guard let i = Motion.lastIndex(frameTimes, atOrBefore: t) ?? (frames.isEmpty ? nil : 0) else { return nil }
            for k in 0..<8 {
                for s in [i - k, i + 1 + k] where s >= 0 && s < frames.count {
                    if keys.allSatisfy({ frames[s].joints[$0] != nil }) { return frames[s].joints }
                }
            }
            return nil
        }
    }

    // MARK: - Peak Zone

    struct Peak {
        let start: Double, end: Double
        let apexTime: Double
        /// Ball centre height at the top, ground 0 … nose 1.
        let height: Double
        /// When the top is confirmed (the ball has started down), as the card shows it.
        let shownAt: Double
        let zone: Int
    }

    final class PeakModel {
        let body: Body
        let ball: GraphScene.BallTrack
        let levels: [Double]
        let bounds: [Double]
        let peaks: [Peak]
        let shownTimes: [Double]
        /// Most common zone so far: its share, and the band it covers.
        let commonShare: Motion.Tween
        let bandLow: Motion.Tween
        let bandHigh: Motion.Tween
        let common: [Int]
        let highest: [Int]

        init(body: Body, ball: GraphScene.BallTrack, touches: [Double]) {
            self.body = body; self.ball = ball
            let levels = [body.knee, body.hip, body.shoulder, 1]
            let bounds = zip(levels, levels.dropFirst()).map { ($0 + $1) / 2 }
            self.levels = levels; self.bounds = bounds
            func zoneOf(_ h: Double) -> Int { bounds.firstIndex { h < $0 } ?? bounds.count }
            var peaks = [Peak]()
            for (a, b) in zip(touches, touches.dropFirst()) where b - a > 0.15 && b - a <= 1.5 {
                var top: (Double, Double)?, previous = a, ok = true, samples = [(Double, Double)]()
                var i = (Motion.lastIndex(ball.times, atOrBefore: a) ?? -1) + 1
                while i < ball.times.count && ball.times[i] <= b {
                    let t = ball.times[i]
                    if t - previous > 0.05 { ok = false; break }
                    if let h = body.height(ofY: ball.y[i], at: t) {
                        samples.append((t, h))
                        if top == nil || h > top!.1 { top = (t, h) }
                    }
                    previous = t; i += 1
                }
                guard ok, let top, samples.count >= 5 else { continue }
                let shown = samples.first { $0.0 >= top.0 + 0.05 && $0.1 <= top.1 - 0.01 }?.0 ?? b
                peaks.append(Peak(start: a, end: b, apexTime: top.0, height: top.1, shownAt: shown, zone: zoneOf(top.1)))
            }
            self.peaks = peaks
            shownTimes = peaks.map(\.shownAt)
            var counts = [Int](repeating: 0, count: levels.count), share = [(Double, Double)](), low = [(Double, Double)](), high = [(Double, Double)]()
            var common = [Int](), highest = [Int](), best = 0
            for p in peaks {
                counts[p.zone] += 1
                let top = counts.indices.max { counts[$0] < counts[$1] || (counts[$0] == counts[$1] && $0 > $1) }!
                common.append(top)
                best = max(best, p.zone); highest.append(best)
                share.append((p.shownAt, Double(counts[top]) / Double(counts.reduce(0, +)) * 100))
                low.append((p.shownAt, top == 0 ? 0 : bounds[top - 1]))
                high.append((p.shownAt, top < bounds.count ? bounds[top] : 1.1))
            }
            self.common = common; self.highest = highest
            commonShare = Motion.Tween(share, duration: 0.45)
            bandLow = Motion.Tween(low, duration: 0.5)
            bandHigh = Motion.Tween(high, duration: 0.5)
        }

        func zone(_ h: Double) -> Int { bounds.firstIndex { h < $0 } ?? bounds.count }
        /// The latest peak already shown at `t`.
        func shownIndex(at t: Double) -> Int? { Motion.lastIndex(shownTimes, atOrBefore: t) }
        /// Ball centre height now, if tracked.
        func ballHeight(at t: Double) -> Double? {
            guard let b = ball.ball(at: t) else { return nil }
            return body.height(ofY: Double(b.p.y), at: t)
        }
        /// The highest point so far in the bounce that started at `start`, up to `t`.
        func topSoFar(from start: Double, to t: Double) -> (time: Double, height: Double)? {
            var top: (Double, Double)?
            var i = (Motion.lastIndex(ball.times, atOrBefore: start) ?? -1) + 1
            while i < ball.times.count && ball.times[i] <= t {
                if let h = body.height(ofY: ball.y[i], at: ball.times[i]), top == nil || h > top!.1 { top = (ball.times[i], h) }
                i += 1
            }
            if let h = ballHeight(at: t), top == nil || h > top!.1 { top = (t, h) }
            return top
        }
    }

    // MARK: - Touch Zone

    struct Contact {
        let time: Double
        let side: FootChallenge.Side?
        /// Where the ball was met: sideways from the body centre and up from the ground, in body heights.
        let u: Double, v: Double
        let zone: Int
        let part: Int
    }

    final class TouchModel {
        let body: Body
        let contacts: [Contact]
        let times: [Double]
        let shares: [Motion.Tween]
        let zoneCounts: [[Int]]
        let partCounts: [[Int]]

        init(body: Body, ball: GraphScene.BallTrack, feet: FootChallenge.Session) {
            self.body = body
            var out = [Contact]()
            let keys = ["leftAnkle", "rightAnkle", "leftKnee", "rightKnee", "leftHip", "rightHip", "leftShoulder", "rightShoulder", "nose", "root"]
            for touch in feet.touches {
                guard let b = ball.ball(at: touch.time), let s = body.scale(at: touch.time),
                      let j = body.joints(near: touch.time - 0.017, needing: keys) else { continue }
                let L = s.ground - s.head, r = Double(b.r)
                let cx = Double(b.p.x), cy = Double(b.p.y) + 0.8 * r
                let v = (s.ground - cy) / L, u = (cx - s.rootX) / L
                let zone = v < body.knee / 2 ? 0 : v < body.knee ? 1 : 2
                // What met the ball: the nearest body landmark to the contact point.
                func d(_ k: String) -> Double { hypot(j[k]![0] - cx, j[k]![1] - cy) }
                let shoulders = hypot((j["leftShoulder"]![0] + j["rightShoulder"]![0]) / 2 - cx, (j["leftShoulder"]![1] + j["rightShoulder"]![1]) / 2 - cy)
                let candidates = [min(d("leftAnkle"), d("rightAnkle")), min(d("leftKnee"), d("rightKnee"), d("leftHip"), d("rightHip")), shoulders, d("nose")]
                let part = candidates.indices.min { candidates[$0] < candidates[$1] }!
                out.append(Contact(time: touch.time, side: touch.side, u: u, v: v, zone: zone, part: part))
            }
            contacts = out
            times = out.map(\.time)
            var zc = [Int](repeating: 0, count: 3), pc = [Int](repeating: 0, count: 4)
            var zoneCounts = [[Int]](), partCounts = [[Int]](), shareChanges = [[(Double, Double)]](repeating: [], count: 3)
            for c in out {
                zc[c.zone] += 1; pc[c.part] += 1
                zoneCounts.append(zc); partCounts.append(pc)
                let total = Double(zc.reduce(0, +))
                for z in 0..<3 { shareChanges[z].append((c.time, Double(zc[z]) / total)) }
            }
            self.zoneCounts = zoneCounts; self.partCounts = partCounts
            shares = shareChanges.map { Motion.Tween($0, duration: 0.45) }
        }

        func index(at t: Double) -> Int? { Motion.lastIndex(times, atOrBefore: t) }
    }
}

// MARK: - Drawing

nonisolated enum BodyZonesDrawing {
    typealias Pen = AnalyticsMotionDrawing.Pen
    static let size = CGSize(width: 342, height: 124)
    static let zoneColors = [Pen.mint, Pen.lime, Pen.gold, Pen.coral]

    static func begin(_ c: CGContext, _ rect: CGRect) -> Pen {
        c.translateBy(x: rect.minX, y: rect.minY)
        c.scaleBy(x: rect.width / size.width, y: rect.height / size.height)
        c.setAllowsAntialiasing(true); c.setShouldAntialias(true)
        let p = Pen(c); p.card(); return p
    }

    /// Zone colour that blends across each boundary instead of jumping.
    static func color(_ h: Double, _ bounds: [Double]) -> CGColor {
        var col = zoneColors[0]
        for (i, b) in bounds.enumerated() { col = Pen.mix(col, zoneColors[i + 1], Motion.smoothstep(b - 0.03, b + 0.03, h)) }
        return col
    }

    // MARK: Peak Zone

    static func peakZone(in c: CGContext, rect: CGRect, model m: BodyZones.PeakModel, time: Double) {
        c.saveGState(); defer { c.restoreGState() }
        let p = begin(c, rect), t = max(0, time)
        p.header("PEAK ZONE", "Each bounce vs your body")
        let x0: CGFloat = 54, x1: CGFloat = 326, xNow: CGFloat = 298, gy: CGFloat = 89, span: CGFloat = 64
        func Y(_ h: Double) -> CGFloat { gy - CGFloat(min(1.1, max(0, h))) * span }
        let pxps = (xNow - x0) / 4.0
        func X(_ time: Double) -> CGFloat { xNow + CGFloat(time - t) * pxps }
        let shown = m.shownIndex(at: t)
        let latest = shown.map { m.peaks[$0] }
        let latestAge = latest.map { t - $0.shownAt } ?? 9

        // The player's usual zone, as a band that slides when it changes.
        if let lo = m.bandLow.value(at: t), let hi = m.bandHigh.value(at: t), let k = shown {
            let appear = Motion.easeOut((t - m.peaks[0].shownAt) / 0.4)
            p.fill(CGRect(x: x0, y: Y(hi), width: x1 - x0, height: Y(lo) - Y(hi)), Pen.alpha(zoneColors[m.common[k]], 0.10 * appear), radius: 3)
        }
        // Landmarks of the player's own body.
        // Head height sits just above the shoulders on this scale; it only appears once a bounce gets there.
        let reachedHead = shown.map { m.highest[$0] >= 3 } ?? false
        for (i, name) in BodyZones.zoneNames.enumerated() where i < 3 || reachedHead {
            let y = Y(m.levels[i]), hit = latest?.zone == i ? Motion.flash(latestAge, decay: 0.35) : 0
            p.dashed(x0, y, x1, y, Pen.alpha(Pen.white, 0.12 + 0.2 * hit))
            p.text(name, 16, y - 3.4, 6.2, Pen.mix(Pen.muted, zoneColors[i], 0.35 + 0.65 * hit), weight: 0.45, kern: 0.5,
                   scale: CGFloat(1 + 0.12 * hit))
        }
        p.line(x0, gy, x1, gy, Pen.alpha(Pen.white, 0.22), 0.7)
        p.text("FEET", 16, gy - 3.4, 6.2, Pen.alpha(Pen.muted, 0.6), weight: 0.45, kern: 0.5)

        let plot = CGRect(x: x0, y: 24, width: x1 - x0, height: 70)
        p.faded(plot, left: 26, right: 8) {
            for (i, peak) in m.peaks.enumerated() where peak.start <= t {
                let done = shown.map { i <= $0 } ?? false
                guard let top = done ? (peak.apexTime, peak.height) : m.topSoFar(from: peak.start, to: min(t, peak.end)) else { continue }
                let x = X(min(t, top.0))
                guard x > x0 - 20 else { continue }
                let col = color(top.1, m.bounds)
                let barTop = Y(top.1)
                let bar = CGRect(x: x - 4.5, y: barTop, width: 9, height: gy - barTop)
                let area = CGPath(roundedRect: bar, cornerWidth: 3, cornerHeight: 3, transform: nil)
                p.gradient(area, top: barTop, bottom: gy, col, done ? 0.75 : 0.9)
                p.line(x - 4.5, barTop, x + 4.5, barTop, Pen.alpha(col, 1), 1.6)
                if done, t - peak.shownAt < 1.6 {
                    let a = t - peak.shownAt
                    let next = i + 1 < m.peaks.count ? m.peaks[i + 1].shownAt : .infinity
                    let fade = min(1 - Motion.smoothstep(1.1, 1.6, a), 1 - Motion.smoothstep(next, next + 0.1, t))
                    p.pill(BodyZones.zoneNames[peak.zone], at: CGPoint(x: x, y: barTop - 8), color: zoneColors[peak.zone],
                           scale: Motion.backOut(a / 0.28), opacity: fade, maxX: x1)
                }
            }
        }
        // The ball, riding the now line at its height on your body.
        if let h = m.ballHeight(at: t) {
            let point = CGPoint(x: xNow, y: Y(h))
            p.line(xNow, gy, xNow, point.y, Pen.alpha(Pen.white, 0.18), 0.6)
            p.glow(point, 9, Pen.white, 0.45)
            p.dot(point, 3.0, Pen.white)
        }

        let share = m.commonShare.value(at: t)
        let common = shown.map { m.common[$0] }, highest = shown.map { m.highest[$0] }
        let highestChanged = shown.flatMap { k in (0...k).last { $0 == 0 || m.highest[$0] != m.highest[$0 - 1] } }.map { t - m.peaks[$0].shownAt }
        p.stats(Pen.Stat(label: "MOST BOUNCES", value: common.map { BodyZones.zoneNames[$0] } ?? "—",
                         unit: share.map { String(format: "%.0f%%", $0) } ?? "", color: common.map { zoneColors[$0] } ?? Pen.white,
                         pulse: m.commonShare.age(at: t)),
                Pen.Stat(label: "HIGHEST", value: highest.map { BodyZones.zoneNames[$0] } ?? "—", unit: "",
                         color: highest.map { zoneColors[$0] } ?? Pen.white, pulse: highestChanged))
    }

    // MARK: Touch Zone

    static func touchZone(in c: CGContext, rect: CGRect, model m: BodyZones.TouchModel, time: Double) {
        c.saveGState(); defer { c.restoreGState() }
        let p = begin(c, rect), t = max(0, time)
        p.header("TOUCH ZONE", "Where you meet the ball")
        // Zoomed on the legs, where the ball is met: ground to just above the hips.
        let cx: CGFloat = 76, gy: CGFloat = 89, S: CGFloat = 100, top = 0.62
        func P(_ u: Double, _ v: Double) -> CGPoint {
            CGPoint(x: cx + CGFloat(Motion.clamp(u, -0.6, 0.6)) * S, y: gy - CGFloat(Motion.clamp(v, 0, top)) * S)
        }
        let k = m.index(at: t)
        let latest = k.map { m.contacts[$0] }
        let age = latest.map { t - $0.time } ?? 9

        // Contact heights as bands behind the figure; the latest one lights up.
        let knee = m.body.knee
        let bands = [(0.0, knee / 2), (knee / 2, knee), (knee, top)]
        for (z, band) in bands.enumerated() {
            let hit = latest?.zone == z ? Motion.flash(age, decay: 0.4) : 0
            let r = CGRect(x: cx - 60, y: gy - CGFloat(band.1) * S, width: 120, height: CGFloat(band.1 - band.0) * S)
            p.fill(r, Pen.alpha(zoneColor(z), 0.04 + 0.16 * hit), radius: 2)
        }
        p.line(cx - 64, gy, cx + 64, gy, Pen.alpha(Pen.white, 0.22), 0.7)
        p.dashed(cx - 60, gy - CGFloat(knee) * S, cx + 60, gy - CGFloat(knee) * S, Pen.alpha(Pen.white, 0.14))

        // The player's own legs, from their standing frames; the body fades out above the hips.
        let f = m.body.figure.points
        func pt(_ name: String, _ side: Double = 0) -> CGPoint? { f[name].map { CGPoint(x: cx + CGFloat($0.u * side) * S, y: gy - CGFloat($0.v) * S) } }
        func bone(_ a: CGPoint, _ b: CGPoint) {
            let highest = Double((gy - min(a.y, b.y)) / S)
            p.line(a.x, a.y, b.x, b.y, Pen.alpha(Pen.white, 0.4 * (1 - Motion.smoothstep(0.5, top + 0.02, highest))), 1.6)
        }
        if let root = pt("root") {
            bone(root, CGPoint(x: root.x, y: root.y - 0.1 * S))
            for side in [-1.0, 1.0] {
                if let hip = pt("hip", side), let knee = pt("knee", side), let ankle = pt("ankle", side) {
                    bone(root, hip); bone(hip, knee); bone(knee, ankle)
                    p.line(ankle.x, ankle.y, ankle.x + CGFloat(side) * 3.5, ankle.y + 0.5, Pen.alpha(Pen.white, 0.4), 1.6)
                }
            }
        }
        p.text("KNEE", cx - 60, gy - CGFloat(knee) * S - 8.2, 5.4, Pen.alpha(Pen.muted, 0.8), weight: 0.45, kern: 0.4)

        // Contacts: the last sixteen, newest brightest, joined like a constellation.
        if let k {
            let first = max(0, k - 15)
            let points = (first...k).map { P(m.contacts[$0].u, m.contacts[$0].v) }
            for i in 1..<max(1, points.count) {
                let a = Double(i) / Double(points.count)
                p.line(points[i - 1].x, points[i - 1].y, points[i].x, points[i].y, Pen.alpha(Pen.white, 0.16 * a), 0.6)
            }
            for (n, i) in (first...k).enumerated() {
                let contact = m.contacts[i], a = t - contact.time, at = points[n]
                // Coloured by height zone, like the bars on the right; which foot is Foot Rally's job.
                let col = zoneColor(contact.zone)
                let older = Double(k - i)
                if a < 0.5 {
                    let g = a / 0.5
                    p.ring(at, 3 + 9 * CGFloat(Motion.easeOut(g)), Pen.alpha(col, 0.8 * (1 - g)), 1.1)
                }
                p.glow(at, 9, col, 0.5 * Motion.flash(a, decay: 0.25))
                p.dot(at, 2.6 * CGFloat(Motion.backOut(a / 0.24)), Pen.alpha(col, max(0.25, 1 - older * 0.05)))
            }
        }

        // Share of touches in each height zone.
        let rows = [(2, "HIGH", "knee and up"), (1, "SHIN", "below the knee"), (0, "ANKLE", "low")]
        let counts = k.map { m.zoneCounts[$0] } ?? [0, 0, 0]
        for (row, (z, name, hint)) in rows.enumerated() {
            let y = 36 + CGFloat(row) * 18
            let hit = latest?.zone == z ? Motion.flash(age, decay: 0.3) : 0
            let col = zoneColor(z)
            p.text(name, 148, y - 4.2, 7.2, Pen.mix(Pen.white, col, 0.4 + 0.6 * hit), weight: 0.62, kern: 0.5,
                   scale: CGFloat(1 + 0.1 * hit))
            p.text(hint, 148, y + 4.6, 5.6, Pen.muted)
            let bar = CGRect(x: 200, y: y - 2.5, width: 98, height: 5)
            p.fill(bar, Pen.alpha(Pen.white, 0.08), radius: 2.5)
            let share = m.shares[z].value(at: t) ?? 0
            if share > 0.001 {
                p.fill(CGRect(x: bar.minX, y: bar.minY, width: max(5, bar.width * CGFloat(share)), height: bar.height),
                       Pen.mix(Pen.alpha(col, 0.9), Pen.white, 0.5 * hit), radius: 2.5)
            }
            p.text("\(counts[z])", 326, y - 4.8, 8.6, Pen.mix(Pen.white, col, 0.5), weight: 0.62, align: 1, mono: true,
                   scale: CGFloat(1 + 0.16 * hit))
        }

        let mostZone = counts.indices.max { counts[$0] < counts[$1] || (counts[$0] == counts[$1] && $0 < $1) }
        let total = counts.reduce(0, +)
        let parts = k.map { m.partCounts[$0] } ?? [0, 0, 0, 0]
        p.stats(Pen.Stat(label: "MOST TOUCHES", value: total > 0 ? BodyZones.contactNames[mostZone!] : "—",
                         unit: total > 0 ? String(format: "%.0f%%", Double(counts[mostZone!]) / Double(total) * 100) : "",
                         color: total > 0 ? zoneColor(mostZone!) : Pen.white, pulse: latest?.zone == mostZone ? age : nil),
                Pen.Stat(label: "FOOT · THIGH · HEAD", value: "\(parts[0]) · \(parts[1]) · \(parts[3])", unit: parts[2] > 0 ? "· chest \(parts[2])" : "",
                         color: Pen.white, pulse: age))
    }

    static func zoneColor(_ z: Int) -> CGColor { [Pen.mint, Pen.lime, Pen.gold][z] }
}
