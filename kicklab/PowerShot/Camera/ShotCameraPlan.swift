import CoreGraphics
import Foundation
import simd

/// Text the camera pass puts on screen (a replay badge, a flight time). Positions are output
/// pixels; the preview draws it with SwiftUI and the export with Core Text, from this one value.
nonisolated struct ShotCaption: Equatable, Sendable {
    enum Align: Int, Sendable { case leading, center, trailing }
    var text: String
    var position: CGPoint
    var size: CGFloat
    var alpha: Double
    var color: SIMD3<Float>
    var align: Align = .leading
    var bold = true
}

/// What the camera pass needs for one output moment. Layout is shared with ShotCameraPixel.h.
nonisolated struct ShotCameraFrame: Sendable {
    static let uniformCount = 24, pathCount = 64, stampCount = 24
    var uniforms: [SIMD4<Float>]
    var path: [SIMD4<Float>] = []
    var stamps: [SIMD4<Float>] = []
    var captions: [ShotCaption] = []
    /// Rack Focus needs a blurred copy of the picture.
    var needsBlur: Bool { uniforms[10].w > 0.001 }
    var isActive: Bool { uniforms[0].z > 0 }

    /// Frozen Arc reads its layers where the other moves read the sprite sheet.
    var usesArcLayers: Bool { uniforms[0].z == 8 }

    /// Stamps and Frozen Arc need their picture (the sprite sheet or the arc's layers). Until it is
    /// ready they are left out, rather than drawn from whatever texture stands in for it.
    func uniforms(hasAtlas: Bool) -> [SIMD4<Float>] {
        guard !hasAtlas else { return uniforms }
        var u = uniforms
        u[17].x = 0
        if u[0].z == 8 { u[0].z = 1; u[1] = SIMD4(0.5, 0.5, 1, 0) }
        return u
    }

    init(size: CGSize) {
        uniforms = Array(repeating: .zero, count: Self.uniformCount)
        uniforms[0] = SIMD4(Float(size.width), Float(size.height), 0, 0)
        uniforms[1] = SIMD4(0.5, 0.5, 1, 0)
    }
}

/// The camera track, worked out once per edit: the smoothed ball and kicker, each block's
/// camera path, and the replay clock. `frame(output:size:)` is then cheap for every frame.
nonisolated final class ShotCameraPlan: @unchecked Sendable {
    struct Stamp: Equatable, Sendable { var time: Double; var x: Double; var y: Double; var radius: Double }
    private struct Ball { var x, y, r, seen: Double }
    private typealias Crop = SIMD4<Double> // centre x, y, zoom, angle

    let track: ShotCameraTrack
    let timeline: ShotEditTimeline
    let strike: Double
    /// The strike found from the ball's flight, whatever the track's own strike says.
    let foundStrike: Double
    let flightEnd: Double
    let duration: Double
    /// Upright picture width / height.
    let aspect: Double
    /// Ball pictures for Ball Strobe and Freeze + Path ghosts, in atlas order.
    let stamps: [Stamp]
    /// Where things stand in the frozen moment, for Frozen Arc.
    let arcScene: ShotArcScene
    /// The source moment Frozen Arc freezes (its layers are cut there); nil without one.
    var arcMoment: Double? { track.clips.first { $0.move == .arc }?.start }

    private static let grid = 240.0
    private let ballGrid: [Ball]
    private let personGrid: [SIMD4<Double>]?
    private let hasBall: Bool
    private let strikeRadius: Double
    private var crops: [UUID: [Crop]] = [:]
    private var panels: [UUID: [Crop]] = [:]
    private var stampIndex: [UUID: [Int]] = [:]
    /// Each Frozen Arc's swing, worked out once: as wide as asked, as wide as stays on the picture.
    private var arcSwing: [UUID: Double] = [:]

    init(track: ShotCameraTrack, ball: BallEffectTrack, flight: ShotFlight?, duration: Double, aspect: Double,
         frameDuration: Double = 1.0 / 60) {
        self.track = track
        self.duration = max(0.01, duration)
        self.aspect = max(0.1, aspect)
        timeline = ShotEditTimeline(track: track, duration: duration, frameDuration: frameDuration)
        foundStrike = max(0, flight?.launch ?? ball.samples.first?.time ?? 0)
        let strike = max(0, track.strike ?? foundStrike)
        self.strike = strike
        let lastSeen = min(duration, max(strike + 0.3, flight?.end ?? strike + 1.2))
        hasBall = ball.samples.count >= 3

        // The ball, smoothed with zero lag and never across the strike (the camera must not move
        // before the ball does). Radius is a share of the picture's width.
        let samples = ball.samples.filter { $0.confidence >= 0.05 }
        let aspect = self.aspect
        func radius(_ s: BallStyleSample) -> Double {
            guard let box = s.boxSize else { return Double(s.radius) }
            return min(Double(box.width), Double(box.height) / aspect) / 2
        }
        let count = Int(self.duration * Self.grid) + 2
        var grid: [Ball] = []
        grid.reserveCapacity(count)
        let sigma = 0.028
        for i in 0..<count {
            let t = Double(i) / Self.grid
            let pre = t <= strike + 0.0001
            var wsum = 0.0, x = 0.0, y = 0.0, r = 0.0, nearest = 9.0
            var before: BallStyleSample?, after: BallStyleSample?
            for s in samples {
                guard pre ? s.time <= strike + 0.0001 : s.time >= strike - 0.0001 else { continue }
                let d = s.time - t
                nearest = min(nearest, abs(d))
                if d <= 0 { before = s } else if after == nil { after = s }
                guard abs(d) < sigma * 3.5 else { continue }
                let w = exp(-0.5 * pow(d / sigma, 2)) * max(0.3, min(1, s.confidence * 2))
                wsum += w; x += Double(s.center.x) * w; y += Double(s.center.y) * w; r += radius(s) * w
            }
            let seen = exp(-pow(nearest / 0.12, 2))
            if wsum > 0.2 { grid.append(Ball(x: x / wsum, y: y / wsum, r: r / wsum, seen: seen)); continue }
            if let a = before, let b = after, b.time - a.time < 0.6 {
                let f = (t - a.time) / (b.time - a.time)
                let ax = Double(a.center.x), ay = Double(a.center.y), bx = Double(b.center.x), by = Double(b.center.y)
                let ra = radius(a), rb = radius(b)
                grid.append(Ball(x: ax + (bx - ax) * f, y: ay + (by - ay) * f, r: ra + (rb - ra) * f, seen: seen))
            } else if let a = before ?? after {
                grid.append(Ball(x: Double(a.center.x), y: Double(a.center.y), r: radius(a), seen: seen))
            } else {
                grid.append(Ball(x: 0.5, y: 0.5, r: 0.05, seen: 0))
            }
        }
        ballGrid = grid
        flightEnd = hasBall ? Self.forwardEnd(grid, strike: strike, limit: lastSeen, aspect: aspect) : lastSeen
        strikeRadius = max(0.004, grid[min(grid.count - 1, Int(strike * Self.grid))].r)

        // The kicker's box, smoothed, for cameras that frame him.
        if !ball.people.isEmpty {
            let raw = (0..<count).map { i -> SIMD4<Double> in
                let p = ball.person(at: Double(i) / Self.grid)!
                return SIMD4(p.x, p.y, p.width, p.height)
            }
            personGrid = Self.smooth(raw, sigma: 0.08)
        } else { personGrid = nil }

        // Ball pictures to stamp: a confident sighting near every few frames of the flight. A guess
        // between sightings can sit beside the ball, and its picture would be a disc of background.
        let sightings = samples.filter { $0.confidence >= 0.5 }
        var stamps: [Stamp] = []
        for clip in track.clips where clip.move == .strobe || clip.move == .freeze {
            let step = clip.move == .strobe ? 5.0 / 60 : 6.0 / 60
            let from = (clip.move == .strobe ? max(strike, clip.start) : clip.start) + step
            let to = clip.move == .strobe ? min(clip.end, flightEnd) : flightEnd
            var ids: [Int] = []
            var t = from
            while t <= to + 0.0001, stamps.count < ShotCameraFrame.stampCount {
                let near = sightings.filter { abs($0.time - t) <= step / 2 && $0.time <= to + 0.0001 }
                if let s = near.min(by: { abs($0.time - t) < abs($1.time - t) }), s.time > (stamps.last?.time ?? -1) || ids.isEmpty {
                    ids.append(stamps.count)
                    stamps.append(Stamp(time: s.time, x: Double(s.center.x), y: Double(s.center.y), radius: radius(s) * 1.08))
                }
                t += step
            }
            stampIndex[clip.id] = ids
        }
        self.stamps = stamps
        arcScene = ShotArcScene.solve(ball: ball, strike: strike, flightEnd: flightEnd, aspect: self.aspect)
        for clip in track.clips { prepare(clip) }
    }

    /// A sample of the real flight (normalised picture points), for move previews.
    func flightSketch(count: Int = 24) -> [CGPoint] {
        let from = max(0, strike - 0.25), to = flightEnd
        return (0..<count).map { i in
            let b = ball(from + (to - from) * Double(i) / Double(max(1, count - 1)))
            return CGPoint(x: b.x, y: b.y)
        }
    }
    /// The ball's size at the strike, as a share of the picture width.
    var strikeBallRadius: Double { strikeRadius }
    var hasKicker: Bool { personGrid != nil }

    /// True when another edit would need the same plan.
    func matches(track: ShotCameraTrack, duration: Double) -> Bool { self.track == track && abs(self.duration - duration) < 0.0001 }

    // MARK: Curves

    private func ball(_ t: Double) -> Ball {
        let f = min(Double(ballGrid.count - 1), max(0, t * Self.grid)), i = min(ballGrid.count - 2, Int(f)), k = f - Double(i)
        let a = ballGrid[max(0, i)], b = ballGrid[min(ballGrid.count - 1, i + 1)]
        return Ball(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k, r: a.r + (b.r - a.r) * k, seen: a.seen + (b.seen - a.seen) * k)
    }
    private func person(_ t: Double) -> SIMD4<Double>? {
        guard let grid = personGrid else { return nil }
        let f = min(Double(grid.count - 1), max(0, t * Self.grid)), i = min(grid.count - 2, Int(f))
        return grid[max(0, i)] + (grid[min(grid.count - 1, i + 1)] - grid[max(0, i)]) * (f - Double(i))
    }
    /// How far away the ball looks compared with the strike: 1 at the foot, 4 when a quarter the size.
    private func distanceRatio(_ b: Ball) -> Double { strikeRadius / max(0.003, b.r) }

    /// Where the ball stops flying away: the first time it turns back on itself, sideways (off the
    /// net or a post, or rolling back) or upward after coming down (a bounce). A lob's fall is not
    /// a turn. Distances are in picture heights.
    private static func forwardEnd(_ grid: [Ball], strike: Double, limit: Double, aspect: Double) -> Double {
        let first = min(grid.count - 1, Int(strike * Self.grid)), last = min(grid.count - 1, Int(limit * Self.grid))
        let earliest = strike + 0.3
        guard last > first + 2 else { return limit }
        let x0 = grid[first].x * aspect
        var side = 0.0, sideAt = first
        var top = grid[first].y, low = grid[first].y, lowAt = first
        for i in first...last {
            let b = grid[i], e = b.x * aspect - x0
            if abs(e) > abs(side) { side = e; sideAt = i }
            let back = abs(side) - e * (side < 0 ? -1 : 1)
            if abs(side) > 0.03, back > max(0.025, 0.3 * abs(side)) {
                return min(limit, max(earliest, Double(sideAt) / Self.grid))
            }
            if b.y < top { top = b.y; low = b.y; lowAt = i }
            if b.y > low { low = b.y; lowAt = i }
            if low - top > 0.03, low - b.y > max(0.025, 0.3 * (low - top)) {
                return min(limit, max(earliest, Double(lowAt) / Self.grid))
            }
        }
        return limit
    }

    private static func smooth(_ v: [SIMD4<Double>], sigma: Double) -> [SIMD4<Double>] {
        let k = max(1, Int(sigma * grid * 3))
        let weights = (-k...k).map { exp(-0.5 * pow(Double($0) / (sigma * grid), 2)) }
        let total = weights.reduce(0, +)
        return v.indices.map { i in
            var s = SIMD4<Double>.zero
            for (j, w) in zip(-k...k, weights) { s += v[min(v.count - 1, max(0, i + j))] * w }
            return s / total
        }
    }
    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t)
    }
    private static func smootherstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a))); return t * t * t * (t * (t * 6 - 15) + 10)
    }
    private static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    /// Keeps a crop (possibly rotated, possibly for a smaller panel) inside the recorded picture.
    private func clamp(_ c: Crop, panel: CGSize = CGSize(width: 1, height: 1)) -> Crop {
        let w = aspect, h = 1.0
        let pw = Double(panel.width) * w, ph = Double(panel.height) * h
        let fit = max(pw / w, ph / h)
        let cs = abs(cos(c.w)), sn = abs(sin(c.w))
        let zoom = max(c.z, max((pw * cs + ph * sn) / (w * fit), (ph * cs + pw * sn) / (h * fit)))
        let rx = min(0.5, (pw * cs + ph * sn) / (2 * fit * zoom * w)), ry = min(0.5, (ph * cs + pw * sn) / (2 * fit * zoom * h))
        return Crop(min(1 - rx, max(rx, c.x)), min(1 - ry, max(ry, c.y)), zoom, c.w)
    }

    /// A camera path over a block's range: target per grid step, smoothed with zero lag.
    private func path(_ clip: ShotCameraClip, sigma: (Double, Double), margin: Double = 0.4,
                      _ target: (Double) -> (Double, Double, Double)) -> [Crop] {
        let lo = max(0, clip.start - margin), hi = min(duration, clip.end + margin)
        let n = max(2, Int((hi - lo) * Self.grid) + 1)
        let raw = (0..<n).map { i -> SIMD4<Double> in
            let t = lo + Double(i) / Self.grid
            let v = target(t); return SIMD4(v.0, v.1, v.2, 0)
        }
        let centre = Self.smooth(raw, sigma: sigma.0), zoom = Self.smooth(raw, sigma: sigma.1)
        return (0..<n).map { Crop(centre[$0].x, centre[$0].y, zoom[$0].z, 0) }
    }
    private func lookup(_ list: [Crop], _ clip: ShotCameraClip, _ t: Double, margin: Double = 0.4) -> Crop {
        let lo = max(0, clip.start - margin)
        let f = min(Double(list.count - 1), max(0, (t - lo) * Self.grid)), i = min(list.count - 2, Int(f))
        return list[max(0, i)] + (list[min(list.count - 1, i + 1)] - list[max(0, i)]) * (f - Double(i))
    }

    private func prepare(_ clip: ShotCameraClip) {
        let s = clip.settings, S = strike
        let fixed = s.target
        switch clip.move {
        case .follow:
            crops[clip.id] = path(clip, sigma: (s.alternate ? 0.045 : 0.075, 0.16)) { t in
                if let fixed { return (fixed.x, fixed.y, s.zoom) }
                let b = self.ball(t + 0.04)
                let z = t < S - 0.1 ? min(s.zoom, 1.6) : min(s.zoom, 1.75 * max(1, pow(self.distanceRatio(b), 0.38)))
                return (b.x, t < S - 0.15 ? b.y - 0.03 : b.y, z)
            }
        case .chase:
            crops[clip.id] = path(clip, sigma: (0.06, 0.12)) { t in
                let b = self.ball(t + 0.03)
                let lockStart = max(clip.start, S - 0.35)
                let lock = Self.smoothstep(lockStart, lockStart + 0.3, t)
                let z = min(s.zoom, max(1, 1.3 * self.distanceRatio(b)))
                return (Self.mix(0.5, b.x, lock), Self.mix(0.5, b.y, lock), Self.mix(1, z, lock))
            }
        case .handoff:
            crops[clip.id] = path(clip, sigma: (0.06, 0.09)) { t in
                let b = self.ball(t + 0.03)
                let bz = min(s.zoom, max(1.6, 1.75 * pow(self.distanceRatio(b), 0.4)))
                guard let p = self.person(t) else { return (b.x, b.y, bz) }
                let w = Self.smoothstep(S + 0.02, S + 0.22, t)
                let kz = min(2.4, max(1, 0.8 / max(0.2, p.w)))
                return (Self.mix(p.x, b.x, w), Self.mix(p.y - 0.03, b.y, w), Self.mix(kz, bz, w))
            }
        case .broadcast:
            // A causal spring: the operator reacts, so lag and overshoot are real.
            let lo = max(0, clip.start - 0.4), hi = min(duration, clip.end + 0.4)
            let n = max(2, Int((hi - lo) * Self.grid) + 1)
            var state = SIMD3(0.5, 0.52, 1.25), velocity = SIMD3<Double>.zero
            let omega = SIMD3(7.5, 7.5, 3.2) * (1.5 - 0.5 * min(1.5, max(0.5, s.strength))), zeta = 0.68
            var list: [Crop] = []
            for i in 0..<n {
                let t = lo + Double(i) / Self.grid
                let b = ball(t + 0.05), p = person(t) ?? SIMD4(b.x, b.y, 0.2, 0.4)
                let w = Self.smoothstep(S - 0.2, S + 0.15, t)
                let zoom = t < S ? 1.3 : min(s.zoom, 1.3 + (s.zoom - 1.3) * Self.smoothstep(S + 0.1, flightEnd, t))
                let target = SIMD3(Self.mix(Self.mix(p.x, b.x, 0.55), b.x, w), Self.mix(Self.mix(p.y, b.y, 0.4), b.y - 0.03, w), zoom)
                let accel = (target - state) * omega * omega - velocity * omega * 2 * zeta
                velocity += accel / Self.grid; state += velocity / Self.grid
                let wobble = SIMD2(sin(t * 3.1) * 0.6 + sin(t * 7.7 + 1) * 0.35, sin(t * 2.3 + 2) * 0.5 + sin(t * 6.1) * 0.3) * 0.0016
                list.append(Crop(state.x + wobble.x, state.y + wobble.y, state.z, 0))
            }
            crops[clip.id] = list
        case .split:
            crops[clip.id] = path(clip, sigma: (0.07, 0.15)) { t in
                let b = self.ball(t + 0.04)
                return (b.x, b.y, t < S - 0.1 ? min(s.zoom, 1.7) : min(s.zoom, 1.9 * max(1, pow(self.distanceRatio(b), 0.4))))
            }
        case .duo:
            panels[clip.id] = path(clip, sigma: (0.08, 0.12)) { t in
                guard let p = self.person(max(t, S - 0.1)) else { let b = self.ball(t); return (b.x, b.y, 1.4) }
                return (p.x, p.y - 0.02, min(2.6, max(1.1, 0.42 / max(0.15, p.w))))
            }
            crops[clip.id] = path(clip, sigma: (0.06, 0.12)) { t in
                let b = self.ball(t + 0.03)
                return (b.x, b.y, min(s.zoom, max(1.7, 1.8 * pow(self.distanceRatio(b), 0.45))))
            }
        case .warp:
            crops[clip.id] = path(clip, sigma: (0.08, 0.08)) { t in
                let k = Self.smoothstep(S - 0.02, S + 0.5, t), b = self.ball(t)
                return (Self.mix(0.5, b.x, 0.5 * k), Self.mix(0.5, b.y, 0.5 * k), 1 + 0.16 * k)
            }
        case .replay:
            crops[clip.id] = path(clip, sigma: (0.06, 0.12)) { t in
                let b = self.ball(t + 0.03), lock = Self.smoothstep(S - 0.3, S, t)
                let z = min(s.zoom, max(1.15, 1.25 * self.distanceRatio(b)))
                return (Self.mix(0.5, b.x, lock), Self.mix(0.55, b.y, lock), Self.mix(1.15, z, lock))
            }
        case .spotlight, .focus, .lock:
            let (pull, zoom): (Double, Double) = clip.move == .spotlight ? (0.35, 1.12) : clip.move == .focus ? (0.4, 1.1) : (0.6, 1.25)
            crops[clip.id] = path(clip, sigma: (0.13, 0.2)) { t in
                let b = self.ball(t)
                return (Self.mix(0.5, b.x, pull), Self.mix(0.5, b.y, pull), clip.move == .lock && t < S ? 1.1 : zoom)
            }
            // Spotlight, focus and brackets ride the ball closely.
            panels[clip.id] = path(clip, sigma: (clip.move == .focus ? 0.09 : 0.03, 0.06)) { t in
                let b = self.ball(clip.move == .lock ? min(t, self.flightEnd + 0.02) : t)
                return (b.x, b.y, b.r)
            }
        case .lens:
            panels[clip.id] = path(clip, sigma: (0.05, 0.1)) { t in
                let b = self.ball(t)
                let z = t < S ? min(s.zoom, 2.1) : min(s.zoom, 2.1 * pow(self.distanceRatio(b), 0.7))
                return (t < S ? b.x - 0.012 : b.x, t < S ? b.y - 0.01 : b.y, z)
            }
        case .strobe:
            crops[clip.id] = path(clip, sigma: (0.2, 0.2)) { t in
                let k = Self.smoothstep(S, self.flightEnd, t)
                let mid = self.ball((S + self.flightEnd) / 2)
                return (Self.mix(0.5, mid.x, 0.5 * k), Self.mix(0.5, mid.y, 0.5 * k), 1 + 0.15 * k)
            }
        case .arc:
            // The camera never travels more than about 70 cm: around a far kicker the swing gets gentler,
            // so a misjudged distance can only soften the move, never tear the grass apart. Nor does it
            // swing wider than the recorded picture can show without inventing its edges.
            let reach = asin(min(1, 0.7 / max(0.7, arcScene.kickerDepth)))
            let limit = min(reach, min(20, max(0, s.angle)) * .pi / 180)
            arcSwing[clip.id] = arcScene.coveredSwing(upTo: limit, width: 1000, height: 1000 / aspect)
        case .impact, .tilt, .recoil, .ripple, .ramp, .slowmo, .freeze:
            break // shaped analytically per frame
        }
    }

    // MARK: Frame

    /// Everything the camera pass needs at an output moment, for a picture of `size` pixels.
    func frame(output: Double, size: CGSize) -> ShotCameraFrame { frame(location: timeline.locate(output), size: size) }

    /// For a player whose item was built from an older timeline: the moment it is showing.
    func frame(location: ShotEditTimeline.Location, size: CGSize) -> ShotCameraFrame {
        var frame = ShotCameraFrame(size: size)
        let t = location.source
        guard let clip = location.segment.clip.flatMap(track.clip) ?? track.clip(at: t) else { return frame }
        // Blocks ease in and out at their edges; a neighbour that touches hands over instead.
        let index = track.index(of: clip.id) ?? 0
        let previous = index > 0 && abs(track.clips[index - 1].end - clip.start) < 0.0005 ? track.clips[index - 1] : nil
        let next = index + 1 < track.clips.count && abs(track.clips[index + 1].start - clip.end) < 0.0005 ? track.clips[index + 1] : nil
        let edge = min(0.15, clip.length / 3)
        // Hits, ramps and freezes carry their own envelope; the rest ease in and out at their edges.
        let shaped = clip.move.isMoment || clip.move.retimes
        let held = shaped || location.segment.kind != .play(rate: 1) || location.segment.isReplay
        let into = held ? 1 : (previous == nil ? Self.smoothstep(clip.start, clip.start + edge, t) : 1)
        // Unless a touching block takes over, every move winds down over its last moments and lands
        // on the original picture, or cuts there when asked. Tilt Punch already settles back to level.
        let releases = next == nil && clip.settings.ending == .ease && clip.move != .tilt && clip.move != .replay
        let release = ShotMoveSettings.release(length: clip.length)
        var out = releases ? 1 - Self.smootherstep(clip.end - release, clip.end, t) : 1
        // A replay eases out of its slow pass into the action, which carries on from the same moment.
        if clip.move == .replay, clip.settings.ending == .ease, location.segment.isReplay {
            let tail = release * max(0.1, clip.settings.rate)
            out = 1 - Self.smootherstep(clip.end - tail, clip.end, t)
        }
        let weight = min(into, out)
        apply(clip, t: t, location: location, weight: weight, size: size, to: &frame)
        // Hand the framing over smoothly from a touching previous block.
        let handover = 0.3
        if let previous, t < clip.start + handover, previous.move != .replay, clip.move != .duo, clip.move != .split,
           location.segment.kind == .play(rate: 1), !location.segment.isReplay {
            var before = ShotCameraFrame(size: size)
            apply(previous, t: previous.end, location: location, weight: 1, size: size, to: &before)
            let k = Float(Self.smootherstep(clip.start, clip.start + handover, t))
            if before.uniforms[0].z > 0, frame.uniforms[0].z > 0 { frame.uniforms[1] = before.uniforms[1] + (frame.uniforms[1] - before.uniforms[1]) * k }
        }
        return frame
    }

    private func apply(_ clip: ShotCameraClip, t: Double, location: ShotEditTimeline.Location, weight: Double,
                       size: CGSize, to f: inout ShotCameraFrame) {
        let s = clip.settings, S = strike, W = Double(size.width), H = Double(size.height)
        let strength = min(1.5, max(0.5, s.strength))
        var u = f.uniforms
        let lime = SIMD3<Float>(0.80, 1, 0.43), white = SIMD3<Float>(1, 1, 1)
        func set(crop c: Crop, panel: CGSize = CGSize(width: 1, height: 1)) {
            let k = Self.smoothstep(0, 1, weight)
            let eased = Crop(Self.mix(0.5, c.x, k), Self.mix(0.5, c.y, k), Self.mix(1, c.z, k), c.w * k)
            let v = clamp(eased, panel: panel)
            u[1] = SIMD4(Float(v.x), Float(v.y), Float(v.z), Float(v.w))
        }
        /// A source point in output pixels for the current full-frame crop.
        func toOutput(_ x: Double, _ y: Double) -> SIMD2<Float> {
            let c = u[1], z = Double(c.z), a = Double(c.w)
            let dx = (x - Double(c.x)) * W, dy = (y - Double(c.y)) * H
            let cs = cos(a), sn = sin(a)
            return SIMD2(Float((cs * dx - sn * dy) * z + W / 2), Float((sn * dx + cs * dy) * z + H / 2))
        }
        u[0].z = 1
        u[15].y = 1 // bicubic sampling for every enlarged crop
        let b = ball(t)
        let tau = t - S
        var captions: [ShotCaption] = []

        switch clip.move {
        case .follow, .chase, .handoff, .broadcast, .warp, .strobe, .spotlight, .focus, .lock, .replay:
            if let list = crops[clip.id] { set(crop: lookup(list, clip, t)) }
        default: break
        }

        switch clip.move {
        case .follow, .broadcast: break
        case .chase, .handoff:
            if let list = crops[clip.id] {
                let now = lookup(list, clip, t), prev = lookup(list, clip, t - 1.0 / 60)
                let vx = (now.x - prev.x) * W * now.z, vy = (now.y - prev.y) * H * now.z
                u[3] = SIMD4(0, 0, Float(min(40, hypot(vx, vy) * 0.6 * strength) * weight), Float(atan2(vy, vx)))
                u[2] = SIMD4(Float(b.x), Float(b.y), Float(b.r * W), t > S ? 1 : 0)
            }
        case .split:
            let stacked = s.alternate
            // The wide shot grows to fill the frame as the block ends, so the last frame is the original.
            let open = Self.smoothstep(0, 1, weight)
            let balance = 1 - 0.5 * open
            let panel = stacked ? CGSize(width: 1, height: max(0.05, 1 - balance)) : CGSize(width: max(0.05, 1 - balance), height: 1)
            if let list = crops[clip.id] { set(crop: lookup(list, clip, t), panel: panel) }
            u[0].z = 6
            let wideY = Float(Self.mix(0.5, 0.42, open))
            let a = Self.smoothstep(0, 0.6, weight)
            u[13] = SIMD4(Float(a), Float(balance), stacked ? 1 : 0, wideY)
            let d = u[1], fit = Double(max(panel.width / 1, panel.height / 1)) * Double(d.z)
            let hx = Float(Double(panel.width) / (2 * fit)), hy = Float(Double(panel.height) / (2 * fit))
            u[12] = SIMD4(d.x - hx, d.y - hy, d.x + hx, d.y + hy)
            captions = stacked
                ? [ShotCaption(text: "WIDE", position: CGPoint(x: 0.03 * W, y: 0.025 * H), size: 0.03 * W, alpha: a, color: white),
                   ShotCaption(text: "BALL CAM", position: CGPoint(x: 0.03 * W, y: 0.525 * H), size: 0.03 * W, alpha: a, color: lime)]
                : []
        case .duo:
            let open = Self.smootherstep(clip.start, clip.start + 0.26, t) * Self.smoothstep(0, 1, weight)
            let balance = 1 - 0.5 * open
            u[0].z = open > 0.001 ? 7 : 1
            u[13] = SIMD4(1, Float(balance), 0, 0)
            if let top = panels[clip.id] {
                let kicker = lookup(top, clip, t)
                let c = clamp(Crop(Self.mix(0.5, kicker.x, open), Self.mix(0.5, kicker.y, open), Self.mix(1, kicker.z, open), 0),
                              panel: CGSize(width: 1, height: balance))
                u[16] = SIMD4(Float(c.x), Float(c.y), Float(c.z), 0)
            }
            // Both panels open out of the original picture and close back into it.
            if let list = crops[clip.id] {
                let ball = lookup(list, clip, t)
                let c = clamp(Crop(Self.mix(0.5, ball.x, open), Self.mix(0.5, ball.y, open), Self.mix(1, ball.z, open), 0),
                              panel: CGSize(width: 1, height: 1 - balance + 0.001))
                u[1] = SIMD4(Float(c.x), Float(c.y), Float(c.z), 0)
            }
            let a = Self.smoothstep(clip.start + 0.15, clip.start + 0.35, t) * weight
            captions = [ShotCaption(text: "KICKER", position: CGPoint(x: 0.04 * W, y: 0.03 * H), size: 0.032 * W, alpha: a, color: white),
                        ShotCaption(text: "BALL", position: CGPoint(x: 0.04 * W, y: balance * H + 0.025 * H), size: 0.032 * W, alpha: a, color: lime)]
        case .impact:
            let contact = ball(S), fixed = s.target
            let zPeak = max(1, s.zoom)
            var z = 1.0
            if tau >= -0.1 && tau < 0 { let k = (tau + 0.1) / 0.1; z = 1 + (zPeak - 1) * k * k * k }
            else if tau >= 0 { z = 1 + (zPeak - 1) * pow(max(0, 1 - tau / 0.75), 2.4) }
            let follow = Self.smoothstep(0, 0.3, tau)
            let cx = fixed?.x ?? Self.mix(contact.x, b.x, follow), cy = fixed?.y ?? Self.mix(contact.y - 0.015, b.y, follow)
            set(crop: Crop(cx, cy, z, 0))
            if tau >= 0 {
                let shake = 4 * exp(-tau / 0.07) * strength
                u[3] = SIMD4(Float(shake * Self.noise(tau, 1)), Float(shake * Self.noise(tau, 4)), 0, 0)
                u[4] = SIMD4(Float(0.3 * exp(-tau / 0.045) * strength), 0, 0, Float(1.5 * exp(-tau / 0.08) * strength))
                let p = toOutput(b.x, b.y)
                u[8] = SIMD4(p.x, p.y, Float(0.035 * exp(-tau / 0.09) * strength), Float(b.r * W * Double(u[1].z) * 2.2))
            }
        case .tilt:
            // Today's Tilt Punch, unchanged: a soft symmetric tilt around the strike.
            let half = max(0.05, clip.length / 2), mid = (clip.start + clip.end) / 2
            let pulse = abs(t - mid) < half ? (1 + cos(.pi * abs(t - mid) / half)) / 2 : 0
            let angle = (s.alternate ? 1 : -1) * min(12, max(0, s.angle)) * pulse * .pi / 180
            set(crop: Crop(0.5, 0.5, 1 + 0.1 * pulse, angle))
        case .recoil:
            let a = s.angle * .pi / 180
            var angle = 0.0
            if tau >= -0.05 && tau < 0 { angle = -a * Self.smoothstep(-0.05, 0, tau) }
            if tau >= 0 { angle = -a * exp(-tau / 0.17) * cos(2 * .pi * tau / 0.38) }
            let env = tau >= -0.05 ? exp(-max(0, tau) / 0.3) : 0
            let contact = ball(S)
            set(crop: Crop(Self.mix(0.5, contact.x, 0.3 * env), Self.mix(0.5, contact.y, 0.3 * env), 1 + 0.1 * env, angle))
            if tau >= 0 {
                let shake = 8 * exp(-tau / 0.09) * strength
                u[3] = SIMD4(Float(shake * Self.noise(tau, 2)), Float(shake * Self.noise(tau, 7)), Float(8 * exp(-tau / 0.06) * strength), 0.35)
                u[4] = SIMD4(Float(0.15 * exp(-tau / 0.04)), 0, 0, Float(2.2 * exp(-tau / 0.1) * strength))
            }
        case .ripple:
            let contact = ball(S)
            if tau >= 0 {
                set(crop: Crop(contact.x, contact.y, 1 + 0.07 * exp(-tau / 0.14), 0))
                let p = toOutput(contact.x, contact.y)
                u[7] = SIMD4(p.x, p.y, Float(tau), tau < 0.7 ? Float(weight) : 0)
                u[18].y = Float(strength)
                u[4] = SIMD4(Float(0.45 * exp(-tau / 0.05) * strength), 0, 0, 0)
            }
        case .warp:
            if tau > -0.02 && tau < 1 {
                let p = toOutput(b.x, b.y)
                let k = 0.075 * exp(-max(0, tau) / 0.2) * Self.smoothstep(-0.02, 0.01, tau) * strength * weight
                u[8] = SIMD4(p.x, p.y, Float(k), Float(max(10, b.r * W * Double(u[1].z) * 2.2)))
                u[4] = SIMD4(Float(0.25 * exp(-max(0, tau) / 0.05) * weight), 0, 0, Float(3 * exp(-max(0, tau) / 0.2) * weight))
            }
        case .ramp:
            let contact = ball(S)
            let push = Self.smoothstep(clip.start - 0.02, S - 0.02, t)
            let follow = Self.smoothstep(S, S + 0.3, t)
            set(crop: Crop(Self.mix(0.5, Self.mix(contact.x - 0.03, b.x, follow), push),
                           Self.mix(0.5, Self.mix(contact.y - 0.03, b.y, follow), push), 1 + 0.38 * push, 0))
        case .freeze:
            let isHold = location.segment.kind == .hold && location.segment.clip == clip.id
            let progress = isHold ? Self.smoothstep(0.07, 0.75, location.progress) : t > clip.start + 0.001 ? 1 : 0
            let into = isHold ? location.elapsed : 0
            let dim = isHold ? Self.smoothstep(0, 0.15, into) : 0
            u[4] = SIMD4(isHold ? Float(0.3 * exp(-into / 0.06)) : 0, Float(0.35 * dim), Float(0.32 * dim), 0)
            let pathEnd = flightEnd
            let pathAlpha = isHold ? 1 : (s.smooth && t > clip.start ? max(0, 1 - max(0, t - pathEnd) / 0.4) * 0.85 : 0)
            f.path = (0..<ShotCameraFrame.pathCount).map { i in
                let p = ball(clip.start + (pathEnd - clip.start) * Double(i) / Double(ShotCameraFrame.pathCount - 1))
                return SIMD4(Float(p.x), Float(p.y), i == 0 ? 0 : 1, 0)
            }
            u[0].w = Float(ShotCameraFrame.pathCount)
            u[14] = SIMD4(Float(progress), Float(pathAlpha * weight), progress >= 0.999 ? 1 : 0, 0)
            if let ids = stampIndex[clip.id], isHold {
                let span = max(0.001, pathEnd - clip.start)
                f.stamps = ids.map { i in
                    let st = stamps[i], along = Float(min(0.999, max(0, (st.time - clip.start) / span)))
                    return SIMD4(Float(st.x), Float(st.y), Float(st.radius), Float(i) + along)
                }
                u[15].z = 1; u[15].w = 1
                u[17] = SIMD4(Float(f.stamps.count), Float(clip.start), Float(pathEnd), 1.6)
            }
            if progress >= 0.999 && pathAlpha > 0.01 {
                let end = toOutput(ball(pathEnd).x, ball(pathEnd).y)
                captions = [ShotCaption(text: String(format: "%.2f s", pathEnd - clip.start), position: CGPoint(x: Double(end.x) + 0.03 * W, y: Double(end.y) - 0.05 * H),
                                        size: 0.042 * W, alpha: pathAlpha * weight, color: lime)]
            }
        case .slowmo:
            // Time only: the picture is the recording's own.
            u[0].z = 0
        case .arc:
            // Only while frozen, and only on the moment its layers were cut at; the rest plays as recorded.
            guard location.segment.kind == .hold, location.segment.clip == clip.id, clip.start == arcMoment else {
                u[0].z = 0
                break
            }
            let scene = arcScene
            let p = Self.smootherstep(0.04, 0.96, location.progress)
            // Out one way, through the real view to the other side, and back: it starts and ends on the real frame.
            let swing = (s.alternate ? -1 : 1) * (arcSwing[clip.id] ?? 0) * sin(2 * .pi * p)
            // The phone at (0, height, 0) looks down +z; the camera swings about the kicker, pushes in a
            // little, and pans and zooms just enough to stay on what the phone filmed.
            let view = scene.view(swing: swing, push: 1 + 0.1 * sin(.pi * p), width: W, height: H)
            u[0].z = 8
            u[19] = SIMD4(Float(view.eye.x), Float(view.eye.y), Float(view.eye.z), Float(view.focal))
            u[20] = SIMD4(Float(view.cos), Float(view.sin), Float(0.5 * W), Float(scene.horizon * W))
            u[21] = SIMD4(Float(scene.focal * W), Float(scene.cameraHeight), Float(scene.kickerDepth), Float(scene.backdropDepth))
            // What other frames fill in behind the kicker is softened; the frozen background stays sharp.
            let soften = 8 * W / 720 * min(1.5, max(0.5, s.strength))
            u[22] = SIMD4(Float(Self.smoothstep(0.002, 0.03, abs(swing))), Float(max(3, 0.008 * W)),
                          Float(view.centerX - 0.5 * W), Float(view.centerY - scene.horizon * W))
            u[23] = SIMD4(Float(soften), Float(soften * 2.5), 0, 0)
        case .replay:
            let segment = location.segment
            if segment.kind == .rewind {
                u[1] = SIMD4(0.5, 0.5, 1, 0)
                u[15].x = 1
                u[18].z = Float(location.elapsed * 60)
                u[4] = SIMD4(location.elapsed < 0.034 ? 0.5 : 0, 0.55, 0.1, 3)
                captions = [ShotCaption(text: "◀◀  REWIND", position: CGPoint(x: 0.05 * W, y: 0.05 * H), size: 0.046 * W, alpha: 1, color: white)]
            } else if segment.isReplay {
                u[4].x = location.elapsed < 0.05 ? Float(0.6 * (1 - location.elapsed / 0.05)) : 0
                let blink = location.elapsed.truncatingRemainder(dividingBy: 1) < 0.6 ? 1.0 : 0.35
                captions = [ShotCaption(text: "● REPLAY", position: CGPoint(x: 0.05 * W, y: 0.05 * H), size: 0.046 * W, alpha: weight, color: lime),
                            ShotCaption(text: String(format: "×%.2g", s.rate), position: CGPoint(x: 0.95 * W, y: 0.055 * H), size: 0.036 * W,
                                        alpha: 0.85 * blink * weight, color: white, align: .trailing)]
            } else {
                u = ShotCameraFrame(size: size).uniforms
            }
        case .lens:
            let open = Self.smoothstep(clip.start, clip.start + 0.2, t) * Self.smoothstep(0, 1, weight)
            if let list = panels[clip.id], open > 0 {
                let l = lookup(list, clip, t)
                let pop = Float(open < 1 ? open * (1 + 0.25 * sin(open * .pi)) : 1)
                u[5] = SIMD4(Float(l.x), Float(l.y), Float(l.z), 1)
                u[6] = SIMD4(s.alternate ? 0.73 : 0.27, 0.17, 0.21 * pop, Float(Self.smoothstep(S + 0.05, S + 0.2, t) * open))
                let p = toOutput(b.x, b.y)
                u[2] = SIMD4(p.x, p.y, max(12, Float(b.r * W) * 1.7), Float(b.seen))
            }
        case .spotlight:
            if let list = panels[clip.id] {
                let spot = lookup(list, clip, t)
                let p = toOutput(spot.x, spot.y)
                let on = Self.smoothstep(clip.start, clip.start + 0.35, t) * weight
                u[9] = SIMD4(p.x, p.y, max(64 * Float(W / 720), Float(spot.z * W * Double(u[1].z) * 3.2)), Float(on))
                u[4] = SIMD4(tau >= 0 ? Float(0.4 * exp(-tau / 0.07)) : 0, Float(0.75 * on * strength), Float(0.6 * on * strength), 0)
            }
        case .focus:
            if let list = panels[clip.id] {
                let focus = lookup(list, clip, t)
                let p = toOutput(focus.x, focus.y)
                let amount = Self.smoothstep(clip.start, clip.start + 0.4, t) * weight * min(1, strength)
                u[10] = SIMD4(p.x, p.y, Float(max(focus.z * W * 3, 34 * W / 720) * Double(u[1].z) * (t < S ? 1.25 : 1)), Float(amount))
            }
        case .lock:
            if let list = panels[clip.id] {
                let h = lookup(list, clip, t)
                let p = toOutput(h.x, h.y)
                let fitSize = max(22 * Float(W / 720), Float(h.z * W) * u[1].z * 2.1)
                let lock = tau < 0 ? 0 : 1 - pow(max(0, 1 - tau / 0.2), 3)
                let size = tau < 0 ? fitSize * 1.35 : fitSize * Float(1 + 2.2 * (1 - lock))
                let landed = t >= flightEnd
                let blink: Float = landed ? ((t - flightEnd).truncatingRemainder(dividingBy: 0.24) < 0.14 || t - flightEnd > 0.5 ? 1 : 0.25) : 1
                u[11] = SIMD4(p.x, p.y, size, Float(lock))
                u[12] = SIMD4((tau < 0 ? 0.55 : blink) * Float(weight), 0, tau < 0 ? 1 : 0, landed ? 1 : 0)
                if !s.alternate && tau >= 0 {
                    let air = min(max(0, tau), flightEnd - S)
                    captions = [ShotCaption(text: String(format: "%.2f s", air), position: CGPoint(x: Double(p.x + size) + 0.022 * W, y: Double(p.y) - 0.012 * H),
                                            size: (landed ? 0.047 : 0.036) * W, alpha: Double(blink) * weight, color: lime)]
                    if landed {
                        captions.append(ShotCaption(text: "FLIGHT TIME", position: CGPoint(x: Double(p.x + size) + 0.022 * W, y: Double(p.y) - 0.064 * H),
                                                    size: 0.025 * W, alpha: 0.9 * weight, color: white))
                    }
                }
            }
        case .strobe:
            if let ids = stampIndex[clip.id] {
                let shown = ids.filter { stamps[$0].time < t - 0.001 }
                f.stamps = shown.map { i in let st = stamps[i]; return SIMD4(Float(st.x), Float(st.y), Float(st.radius), Float(i)) }
                u[15].w = Float(weight); u[15].z = 0
                u[17] = SIMD4(Float(f.stamps.count), Float(S), Float(flightEnd), 1.6)
            }
        }
        f.uniforms = u
        f.captions = captions
    }

    /// Smooth deterministic noise for shake, identical in preview and export.
    private static func noise(_ t: Double, _ seed: Double) -> Double { sin(t * 37.1 + seed) * 0.6 + sin(t * 61.7 + seed * 2.3) * 0.4 }
}
