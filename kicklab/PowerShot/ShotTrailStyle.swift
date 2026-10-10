import CoreGraphics
import SwiftUI
import simd

/// Power Shot effects: one trail per shot, drawn along the whole flight behind the ball.
/// Shader IDs 20–29 live in ShotTrails.h; juggling effects keep 1–16.
nonisolated enum ShotTrailStyle: String, CaseIterable, Identifiable, Sendable {
    case none, juggleFlame, blueJet, voltStrike, emberRush, limeRibbon, iceTrail, shockwave, fireTrail, glowTrail, pulseTrail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .juggleFlame: "Juggle Flame"
        case .blueJet: "Blue Jet"
        case .voltStrike: "Volt Strike"
        case .emberRush: "Ember Rush"
        case .limeRibbon: "Lime Ribbon"
        case .iceTrail: "Ice Trail"
        case .shockwave: "Shockwave"
        case .fireTrail: "Fire Trail"
        case .glowTrail: "Glow Trail"
        case .pulseTrail: "Pulse Trail"
        }
    }

    var shaderID: Float {
        switch self {
        case .none: 0
        case .juggleFlame: 20
        case .blueJet: 21
        case .voltStrike: 22
        case .emberRush: 23
        case .limeRibbon: 24
        case .iceTrail: 25
        case .shockwave: 26
        case .fireTrail: 27
        case .glowTrail: 28
        case .pulseTrail: 29
        }
    }

    /// The trail's colours from the ball outward, so graphs can wear the chosen effect.
    @MainActor var palette: [Color] {
        switch self {
        case .none, .limeRibbon:
            [Color(red: 0.95, green: 1, blue: 0.82), TrainingHomeStyle.lime, Color(red: 0.42, green: 0.62, blue: 0.1)]
        case .juggleFlame, .fireTrail:
            [Color(red: 1, green: 0.95, blue: 0.7), Color(red: 1, green: 0.6, blue: 0.16), Color(red: 0.88, green: 0.2, blue: 0.06)]
        case .emberRush:
            [Color(red: 1, green: 0.92, blue: 0.6), Color(red: 1, green: 0.7, blue: 0.24), Color(red: 0.86, green: 0.34, blue: 0.08)]
        case .blueJet:
            [Color(red: 0.86, green: 0.94, blue: 1), Color(red: 0.3, green: 0.6, blue: 1), Color(red: 0.12, green: 0.24, blue: 0.92)]
        case .voltStrike:
            [.white, Color(red: 0.64, green: 0.76, blue: 1), Color(red: 0.36, green: 0.44, blue: 1)]
        case .iceTrail:
            [.white, Color(red: 0.62, green: 0.9, blue: 1), Color(red: 0.3, green: 0.64, blue: 1)]
        case .shockwave:
            [.white, Color(red: 0.66, green: 0.83, blue: 1), Color(red: 0.4, green: 0.58, blue: 1)]
        case .glowTrail:
            [.white, Color(red: 0.38, green: 0.95, blue: 1), Color(red: 0.1, green: 0.55, blue: 1)]
        case .pulseTrail:
            [Color(red: 0.96, green: 0.88, blue: 1), Color(red: 0.72, green: 0.46, blue: 1), Color(red: 0.46, green: 0.2, blue: 0.95)]
        }
    }

    @MainActor var tint: Color {
        switch self {
        case .none: .white.opacity(0.45)
        case .juggleFlame, .fireTrail: Color(red: 1, green: 0.5, blue: 0.14)
        case .blueJet: Color(red: 0.2, green: 0.5, blue: 1)
        case .voltStrike: Color(red: 0.45, green: 0.62, blue: 1)
        case .emberRush: Color(red: 1, green: 0.66, blue: 0.24)
        case .limeRibbon: TrainingHomeStyle.lime
        case .iceTrail: Color(red: 0.45, green: 0.85, blue: 1)
        case .shockwave: Color(red: 0.55, green: 0.78, blue: 1)
        case .glowTrail: Color(red: 0.3, green: 0.9, blue: 1)
        case .pulseTrail: Color(red: 0.62, green: 0.4, blue: 1)
        }
    }
}

extension EffectFrame {
    /// How long a shot trail reaches back, in seconds. Matches the longest look in ShotTrails.h.
    nonisolated static let shotTrailSeconds = 0.95
    /// After the ball is lost (in the net, out of frame) the trail keeps fading for this long.
    nonisolated static let shotLingerSeconds = 0.45
    /// Right after the strike a blurred ball is often missed for a few frames. A shot trail
    /// bridges misses this long, so it still runs from the foot. (Juggling keeps 0.12 s.)
    nonisolated static let shotBridgeSeconds = 0.3

    /// A Power Shot frame. The trail covers the flight so far, keeps fading after the ball
    /// is lost, and only shows while the ball is really travelling, never while it rests.
    nonisolated static func shot(size: CGSize, sourceSize: CGSize, style: ShotTrailStyle, intensity: Double,
                                 track: BallEffectTrack, time: Double) -> EffectFrame {
        let crop = EffectVideoGeometry.aspectFillRect(source: sourceSize, destination: size)
        func position(_ s: BallStyleSample) -> SIMD2<Float> {
            SIMD2(Float(crop.minX + s.center.x * crop.width), Float(crop.minY + s.center.y * crop.height))
        }
        let off = EffectFrame(size: size, center: SIMD2(Float(size.width / 2), Float(size.height / 2)), radius: 1,
                              time: time, intensity: 0, visibility: 0, style: style.shaderID)
        let samples = track.samples
        guard style != .none, let lastIndex = samples.lastIndex(where: { $0.time <= time + 0.0005 }) else { return off }
        // Between two sightings the ball is interpolated. Past the end of its tracking (net,
        // out of frame) the trail stays where the ball was last really seen, and fades.
        let last = samples[lastIndex]
        let head: BallStyleSample
        if lastIndex + 1 < samples.count, bridges(last, samples[lastIndex + 1]) {
            head = interpolate(last, samples[lastIndex + 1], at: time)
        } else if time - last.time <= shotLingerSeconds {
            head = last
        } else { return off }
        let headTime = head.time
        let lag = time - headTime

        // This flight's sightings, walking back from the ball across short misses.
        var sightings = [head]
        var index = headTime > last.time + 0.0005 ? lastIndex : lastIndex - 1
        while index >= 0 {
            let sample = samples[index]
            guard headTime - sample.time <= shotTrailSeconds, bridges(sample, sightings[sightings.count - 1]) else { break }
            sightings.append(sample)
            index -= 1
        }
        let points = resample(Array(sightings.reversed()), until: headTime)
        let flight = points[launchIndex(points, crop: crop)...]
        let history = flight.suffix(64).map { point in
            let p = position(point)
            return SIMD4(p.x, p.y, Float(point.pixelRadius(in: crop.size)), Float(time - point.time))
        }
        let radius = Float(max(1, head.pixelRadius(in: crop.size)))
        var velocity = SIMD2<Float>.zero
        if let past = points.last(where: { headTime - $0.time >= 0.04 && headTime - $0.time < 0.12 }) {
            velocity = (position(head) - position(past)) / (radius * Float(headTime - past.time))
            velocity = simd_clamp(velocity, SIMD2(repeating: -60), SIMD2(repeating: 60))
        }
        let fadeAfterLoss = Float(1 - lag / shotLingerSeconds)
        var frame = EffectFrame(size: size, center: position(head), radius: radius, time: time,
            intensity: Float(min(1, max(0, intensity))) * shotMotion(points: points, at: headTime, crop: crop, radius: radius),
            visibility: Float(head.visibility) * fadeAfterLoss, velocity: velocity, style: style.shaderID, trail: history)
        frame.seed = Float(headTime.truncatingRemainder(dividingBy: 97))
        return frame
    }

    /// Two sightings belong to one flight when the gap is short and the jump plausible.
    nonisolated static func bridges(_ a: BallStyleSample, _ b: BallStyleSample) -> Bool {
        let gap = abs(b.time - a.time)
        return gap <= shotBridgeSeconds && hypot(b.center.x - a.center.x, b.center.y - a.center.y) < 0.5
    }

    nonisolated static func interpolate(_ a: BallStyleSample, _ b: BallStyleSample, at time: Double) -> BallStyleSample {
        let f = b.time > a.time ? min(1, max(0, (time - a.time) / (b.time - a.time))) : 0
        var result = a
        result.center = CGPoint(x: a.center.x + (b.center.x - a.center.x) * f, y: a.center.y + (b.center.y - a.center.y) * f)
        result.radius = a.radius + (b.radius - a.radius) * f
        if let sa = a.boxSize, let sb = b.boxSize {
            result.boxSize = CGSize(width: sa.width + (sb.width - sa.width) * f, height: sa.height + (sb.height - sa.height) * f)
        }
        result.confidence = min(a.confidence, b.confidence)
        result.time = time
        return result
    }

    /// Evenly spaced points (60 a second) along the sightings, so recordings at any frame
    /// rate, and misses inside the flight, give the shader the same smooth path.
    nonisolated static func resample(_ sightings: [BallStyleSample], until end: Double) -> [BallStyleSample] {
        guard let first = sightings.first else { return [] }
        var points: [BallStyleSample] = []
        var upper = 0
        var t = first.time
        while t < end - 0.0005 {
            while upper < sightings.count - 1 && sightings[upper].time < t { upper += 1 }
            let b = sightings[upper], a = sightings[max(0, upper - 1)]
            points.append(upper == 0 ? { var s = b; s.time = t; return s }() : interpolate(a, b, at: t))
            t += 1.0 / 60
        }
        points.append(sightings[sightings.count - 1])
        return points
    }

    /// Where the ball took off: walking back from the ball, the first place it was barely
    /// moving. The trail starts there, so the wobble of the strike never hooks its tail.
    nonisolated static func launchIndex(_ points: [BallStyleSample], crop: CGRect) -> Int {
        guard points.count > 2 else { return 0 }
        var slow = 0
        for index in stride(from: points.count - 1, to: 0, by: -1) {
            let a = points[index - 1], b = points[index]
            let dx = (b.center.x - a.center.x) * crop.width, dy = (b.center.y - a.center.y) * crop.height
            let radius = max(1, a.pixelRadius(in: crop.size))
            let pace = hypot(dx, dy) / radius / max(0.001, b.time - a.time)
            slow = pace < 6 ? slow + 1 : 0
            if slow == 2 { return index + 1 }
        }
        return 0
    }

    /// 0 while the ball sits still or is dribbled slowly, 1 once it has been struck.
    /// Pace is measured over a fifth of a second, in ball radii per second; once the ball
    /// stops, the trail eases out over half a second instead of vanishing.
    nonisolated static func shotMotion(points: [BallStyleSample], at time: Double, crop: CGRect, radius: Float) -> Float {
        func pace(endingAt end: Double) -> Float {
            // Over up to a fifth of a second, so a flight picked up late still counts.
            guard let newest = points.last(where: { $0.time <= end + 0.001 }),
                  let older = points.first(where: { end - $0.time <= 0.18 }),
                  newest.time - older.time >= 0.04 else { return 0 }
            let dx = (newest.center.x - older.center.x) * crop.width
            let dy = (newest.center.y - older.center.y) * crop.height
            return Float(hypot(dx, dy)) / max(1, radius) / Float(newest.time - older.time)
        }
        return (0...5).map { step -> Float in
            let moving = min(1, max(0, (pace(endingAt: time - Double(step) * 0.1) - 3) / 5))
            return moving * (1 - Float(step) * 0.18)
        }.max() ?? 0
    }
}
