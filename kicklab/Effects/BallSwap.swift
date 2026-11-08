//
//  BallSwap.swift
//  kicklab
//
//  A different ball on any touch, and the moment the ball changes. The swap is
//  drawn into the same material canvas as the ball, so replay and export agree.
//

import CoreGraphics
import Foundation

/// What happens on screen when the ball changes at a touch. Drawn for half a second
/// after the contact, on the material canvas, in output pixels around the ball.
nonisolated enum BallSwapEffect: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case none, pop, flash, burst, ripple, sparkle, shatter, halo, pixel, smoke, lightning
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "None", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        case .pop: "Pop"
        case .flash: "Flash"
        case .burst: "Burst"
        case .ripple: "Ripple"
        case .sparkle: "Sparkle"
        case .shatter: "Shatter"
        case .halo: "Halo"
        case .pixel: "Pixel"
        case .smoke: "Smoke"
        case .lightning: "Lightning"
        }
    }

    var caption: String {
        switch self {
        case .none: "The ball just changes."
        case .pop: "A quick swell and a ring."
        case .flash: "A bright flash on contact."
        case .burst: "Rays shoot out of the touch."
        case .ripple: "Rings spread from the ball."
        case .sparkle: "Stars fly off the kick."
        case .shatter: "The old ball breaks away."
        case .halo: "A glow blooms and closes in."
        case .pixel: "Blocks scatter and dissolve."
        case .smoke: "A soft puff drifts up."
        case .lightning: "Bolts crack off the ball."
        }
    }

    var symbol: String {
        switch self {
        case .none: "circle.slash"
        case .pop: "circle.circle"
        case .flash: "sun.max.fill"
        case .burst: "rays"
        case .ripple: "circle.dotted.circle"
        case .sparkle: "sparkles"
        case .shatter: "burst.fill"
        case .halo: "circle.dashed"
        case .pixel: "square.grid.3x3.fill"
        case .smoke: "cloud.fill"
        case .lightning: "bolt.fill"
        }
    }

    /// Seconds the moment stays on screen after the touch.
    static let duration = 0.7

    /// The sound each moment makes unless the person picks another. Every effect has its own.
    var defaultSound: BallSwapSound {
        switch self {
        case .none: .none
        case .pop: .flip
        case .flash: .shimmer
        case .burst: .drop
        case .ripple: .warp
        case .sparkle: .sparkle
        case .shatter: .zap
        case .halo: .chime
        case .pixel: .glitch
        case .smoke: .whoosh
        case .lightning: .thunder
        }
    }

    /// How much larger the incoming ball is drawn through the moment; 1 at rest.
    func ballScale(age: Double) -> Double {
        let a = min(1, max(0, age))
        switch self {
        case .pop: return 1 + 0.34 * sin(a * .pi) * (1 - a * 0.5)
        case .halo: return 1 + 0.15 * sin(a * .pi)
        case .flash: return 1 + 0.12 * max(0, 1 - a * 3)
        case .shatter: return 1 - 0.16 * max(0, 1 - a * 4)
        default: return 1
        }
    }
}

/// The accent each print leaves on a swap: the colour of its rays, shards and glow.
extension BallSkin {
    nonisolated var accent: SIMD3<Double> {
        switch self {
        case .original: SIMD3(1, 1, 1)
        case .classic: SIMD3(0.95, 0.95, 0.98)
        case .stealth: SIMD3(0.55, 0.58, 0.62)
        case .matrix: SIMD3(0.2, 1, 0.5)
        case .gold: SIMD3(1, 0.82, 0.3)
        case .arctic: SIMD3(0.6, 0.9, 1)
        case .crimson: SIMD3(1, 0.25, 0.3)
        case .galaxy: SIMD3(0.7, 0.45, 1)
        case .chrome: SIMD3(0.85, 0.9, 1)
        case .graffiti: SIMD3(1, 0.5, 0.85)
        case .aurora: SIMD3(0.45, 1, 0.85)
        case .metal: SIMD3(0.78, 0.8, 0.85)
        case .lava: SIMD3(1, 0.45, 0.12)
        case .pearl: SIMD3(1, 0.95, 0.9)
        case .volt: SIMD3(0.85, 1, 0.25)
        case .goldPolish: SIMD3(1, 0.8, 0.32)
        case .prism: SIMD3(0.88, 0.92, 1)
        case .wave: SIMD3(0.35, 0.8, 1)
        case .nightPulse: SIMD3(0.3, 1, 0.9)
        }
    }
}

/// One look change: at this touch the ball on screen becomes `to`, and the effect `toEffect`.
nonisolated struct BallSwapEvent: Hashable, Sendable {
    /// Position in the sorted touch list.
    let index: Int
    let time: Double
    let from: BallSkin
    let to: BallSkin
    var fromEffect: BallStyle = .none
    var toEffect: BallStyle = .none
}

/// The ball changes of one edit laid against the clip's touches. Built once per edit,
/// queried per frame.
nonisolated struct BallSwapTimeline: Hashable, Sendable {
    let events: [BallSwapEvent]
    let effect: BallSwapEffect

    init(events: [BallSwapEvent] = [], effect: BallSwapEffect = .none) {
        self.events = events.sorted { $0.time < $1.time }
        self.effect = effect
    }

    init(edit: SessionEditState, touchTimes: [Double]) {
        self.init(events: edit.lookSwaps(touchTimes: touchTimes), effect: edit.swapEffect)
    }

    var isEmpty: Bool { events.isEmpty || effect == .none }

    /// The moment in progress at `time`, with its age in 0..<1, or nil once it has passed.
    func active(at time: Double) -> (event: BallSwapEvent, age: Double)? {
        guard !isEmpty, time.isFinite else { return nil }
        var lo = 0, hi = events.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if events[mid].time <= time { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return nil }
        let event = events[lo - 1]
        let age = (time - event.time) / BallSwapEffect.duration
        guard age >= 0, age < 1 else { return nil }
        return (event, age)
    }
}

/// A ball and the effect around it: what one run of touches looks like.
nonisolated struct TouchLook: Hashable, Sendable {
    var ball: BallSkin
    var effect: BallStyle
}

extension SessionEditState {
    /// The first run's look: the clip's own ball and effect, as the Ball and Effects pages set them.
    nonisolated var baseLook: TouchLook { TouchLook(ball: ballSkin, effect: style) }

    nonisolated var hasLookChanges: Bool { !lookChanges.isEmpty }

    /// Any frame may need the material canvas: the base ball or any run's ball is a print.
    nonisolated var usesBallMaterial: Bool {
        ballSkin != .original || lookChanges.values.contains { $0.ball != .original }
    }

    /// Any run draws an effect.
    nonisolated var usesEffects: Bool {
        intensity > 0 && (style != .none || lookChanges.values.contains { $0.effect != .none })
    }

    /// Any run's ball is a lab skin, which Metal draws: its export needs the GPU even in the background.
    nonisolated var usesLabSkin: Bool {
        ballSkin.isLabSkin || lookChanges.values.contains { $0.ball.isLabSkin }
    }

    /// Balls drawn as prints only where the source spin is ready; effects stay.
    nonisolated func withoutBallPrints() -> Self {
        var value = self
        value.ballSkin = .original
        value.lookChanges = lookChanges.mapValues { TouchLook(ball: .original, effect: $0.effect) }
        return value
    }

    /// Sounds that would actually play on this clip.
    nonisolated var hasSounds: Bool { touchSound != .none || (swapSound != .none && hasLookChanges) }

    /// Touches where a run of looks begins, sorted; the first run always starts at 0.
    nonisolated var runStarts: [Int] { [0] + lookChanges.keys.filter { $0 > 0 }.sorted() }

    /// The touches sharing the look of touch `index`.
    nonisolated func run(containing index: Int, touchCount: Int) -> Range<Int> {
        let starts = runStarts
        let start = starts.last { $0 <= index } ?? 0
        let end = starts.first { $0 > index } ?? touchCount
        return start..<max(start + 1, end)
    }

    /// The look from touch `index` until the next run; the base look before any change.
    nonisolated func look(forTouch index: Int) -> TouchLook {
        var best: (index: Int, look: TouchLook)?
        for (at, look) in lookChanges where at > 0 && at <= index {
            if best == nil || at > best!.index { best = (at, look) }
        }
        return best?.look ?? baseLook
    }

    /// Sets a whole run at once. The first run is the clip's own ball and effect.
    nonisolated mutating func setLook(_ look: TouchLook, forRunStartingAt start: Int) {
        if start <= 0 { ballSkin = look.ball; style = look.effect } else { lookChanges[start] = look }
    }

    nonisolated func ballSkin(forTouch index: Int) -> BallSkin { look(forTouch: index).ball }

    /// Position of the latest touch at or before `time` in a sorted list.
    nonisolated static func touchIndex(at time: Double, touchTimes: [Double]) -> Int? {
        guard time.isFinite else { return nil }
        var lo = 0, hi = touchTimes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if touchTimes[mid] <= time { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? lo - 1 : nil
    }

    /// The look on screen at `time`. `touchTimes` must be sorted ascending.
    nonisolated func look(at time: Double, touchTimes: [Double]) -> TouchLook {
        guard !lookChanges.isEmpty, let index = Self.touchIndex(at: time, touchTimes: touchTimes) else { return baseLook }
        return look(forTouch: index)
    }

    nonisolated func ballSkin(at time: Double, touchTimes: [Double]) -> BallSkin { look(at: time, touchTimes: touchTimes).ball }
    nonisolated func effect(at time: Double, touchTimes: [Double]) -> BallStyle { look(at: time, touchTimes: touchTimes).effect }

    /// Every run start where the look differs from the run before it.
    nonisolated func lookSwaps(touchTimes: [Double]) -> [BallSwapEvent] {
        guard !lookChanges.isEmpty else { return [] }
        var previous = baseLook, events: [BallSwapEvent] = []
        for start in runStarts where start > 0 && start < touchTimes.count && touchTimes[start].isFinite {
            let next = look(forTouch: start)
            if next != previous {
                events.append(BallSwapEvent(index: start, time: touchTimes[start], from: previous.ball, to: next.ball,
                                            fromEffect: previous.effect, toEffect: next.effect))
            }
            previous = next
        }
        return events
    }

    /// How strongly the effect draws at `time` and how many seconds of trail it may show. The old
    /// effect fades out just before a change and the new one fades in after it, drawing only the
    /// path since the change, so an old fire trail never repaints itself as ice.
    nonisolated func effectBlend(at time: Double, touchTimes: [Double]) -> (gain: Double, trail: Double) {
        var gain = 1.0, trail = 0.84
        guard !lookChanges.isEmpty, time.isFinite else { return (gain, trail) }
        for event in lookSwaps(touchTimes: touchTimes) where event.fromEffect != event.toEffect {
            let since = time - event.time
            if since >= 0 && since < 0.84 { trail = min(trail, max(0.02, since)) }
            if since >= 0 && since < 0.2 { gain = min(gain, since / 0.2) }
            if since < 0 && since > -0.1 { gain = min(gain, -since / 0.1) }
        }
        return (gain, trail)
    }
}

/// Draws the swap moment on the material canvas: top-left output pixels, premultiplied.
/// Everything is a deterministic function of the event and its age, so a seek, a loop and
/// the export all draw the same frame.
nonisolated enum BallSwapRenderer {
    /// `center` and `radius` are output pixels, as BallMaterialRenderer resolves them.
    static func draw(in ctx: CGContext, center: CGPoint, radius: CGFloat, effect: BallSwapEffect,
                     age: Double, event: BallSwapEvent) {
        guard effect != .none, radius > 1, age >= 0, age < 1 else { return }
        let r = max(6, radius)
        let to = event.to.accent, from = event.from.accent
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch effect {
        case .none: break
        case .pop: pop(ctx, center, r, age, to)
        case .flash: flash(ctx, center, r, age, to)
        case .burst: burst(ctx, center, r, age, to, seed: event.index)
        case .ripple: ripple(ctx, center, r, age, to)
        case .sparkle: sparkle(ctx, center, r, age, to, seed: event.index)
        case .shatter: shatter(ctx, center, r, age, from, seed: event.index)
        case .halo: halo(ctx, center, r, age, to)
        case .pixel: pixel(ctx, center, r, age, from, to, seed: event.index)
        case .smoke: smoke(ctx, center, r, age, seed: event.index)
        case .lightning: lightning(ctx, center, r, age, to, seed: event.index)
        }
    }

    // MARK: - Palette helpers

    private static func color(_ rgb: SIMD3<Double>, _ alpha: Double) -> CGColor {
        CGColor(srgbRed: min(1, max(0, rgb.x)), green: min(1, max(0, rgb.y)), blue: min(1, max(0, rgb.z)),
                alpha: min(1, max(0, alpha)))
    }
    private static let white = SIMD3<Double>(1, 1, 1)
    private static func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> { a + (b - a) * t }

    /// A stable pseudo-random in 0..<1 from the event and a lane.
    private static func noise(_ seed: Int, _ lane: Int) -> Double {
        let value = sin(Double(seed) * 12.9898 + Double(lane) * 78.233) * 43758.5453
        return value - floor(value)
    }
    private static func ease(_ t: Double) -> Double { 1 - (1 - t) * (1 - t) }
    /// Holds near full strength through the first part of the moment, then falls away, so the
    /// change still reads at playback speed instead of fading as it starts.
    private static func fade(_ t: Double) -> Double { let t = min(1, max(0, t)); return 1 - t * t }

    /// A soft disc that falls to nothing at `radius`: a Gaussian-like glow without a blur pass.
    /// `profile` is the strength at each stop out from the centre.
    private static func puff(_ ctx: CGContext, _ center: CGPoint, _ radius: CGFloat, _ rgb: SIMD3<Double>, _ alpha: Double,
                             profile: [(location: CGFloat, strength: Double)], blend: CGBlendMode) {
        guard alpha > 0.002, radius > 0,
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: profile.map { color(rgb, alpha * $0.strength) } as CFArray,
                                        locations: profile.map(\.location)) else { return }
        ctx.setBlendMode(blend)
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        ctx.setBlendMode(.normal)
    }

    /// Light added around the ball; brightest over the inner third, as stacked discs were, without their rings.
    private static func glow(_ ctx: CGContext, _ center: CGPoint, _ radius: CGFloat, _ rgb: SIMD3<Double>, _ alpha: Double) {
        puff(ctx, center, radius, rgb, alpha, profile: [(0, 0.84), (0.35, 0.8), (0.6, 0.4), (0.85, 0.12), (1, 0)],
             blend: .plusLighter)
    }

    /// A bright ring over a faint dark one, so a white ring still reads against a white wall or sky.
    private static func ring(_ ctx: CGContext, _ center: CGPoint, _ radius: CGFloat, width: CGFloat, _ rgb: SIMD3<Double>,
                             _ alpha: Double, backed: Bool = true) {
        guard alpha > 0.002, radius > 0 else { return }
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        if backed {
            ctx.setBlendMode(.normal)
            ctx.setStrokeColor(color(rgb * 0.25, alpha * 0.3))
            ctx.setLineWidth(max(1.5, width * 2))
            ctx.strokeEllipse(in: rect)
        }
        ctx.setBlendMode(.plusLighter)
        ctx.setStrokeColor(color(rgb, alpha))
        ctx.setLineWidth(max(0.5, width))
        ctx.strokeEllipse(in: rect)
        ctx.setBlendMode(.normal)
    }

    /// Strokes every segment as one path, so crossings don't double up.
    private static func stroke(_ ctx: CGContext, _ segments: [(CGPoint, CGPoint)], width: CGFloat, _ color: CGColor,
                               blend: CGBlendMode) {
        ctx.setBlendMode(blend)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(max(0.5, width))
        for (start, end) in segments { ctx.move(to: start); ctx.addLine(to: end) }
        ctx.strokePath()
        ctx.setBlendMode(.normal)
    }

    // MARK: - Effects

    private static func pop(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ age: Double, _ tint: SIMD3<Double>) {
        let u = ease(age), f = fade(age)
        glow(ctx, c, r * (1.5 + 1.1 * u), mix(tint, white, 0.5), 0.8 * f)
        ring(ctx, c, r * (1.05 + 1.4 * u), width: r * 0.12 * (1 - u) + 0.8, mix(tint, white, 0.35), 0.7 * f)
        ring(ctx, c, r * (1.05 + 2.3 * u), width: r * 0.2 * (1 - u) + 1, white, f)
    }

    private static func flash(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ age: Double, _ tint: SIMD3<Double>) {
        let a = max(0, 1 - age * 1.3), f = fade(age)
        ctx.setBlendMode(.plusLighter)
        ctx.setFillColor(color(white, a * a))
        let fr = r * (1.25 + 1.5 * age)
        ctx.fillEllipse(in: CGRect(x: c.x - fr, y: c.y - fr, width: fr * 2, height: fr * 2))
        ctx.setBlendMode(.normal)
        glow(ctx, c, r * (2.4 + 2 * age), mix(tint, white, 0.3), 0.85 * f)
        ring(ctx, c, r * (1 + 3.4 * ease(age)), width: r * 0.1 * (1 - age) + 1.5, mix(tint, white, 0.6), 0.9 * f)
    }

    private static func burst(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ age: Double, _ tint: SIMD3<Double>, seed: Int) {
        let u = ease(age), f = fade(age), rays = 16
        let segments = (0..<rays).map { i -> (CGPoint, CGPoint) in
            let jitter = noise(seed, i) * 0.4 - 0.2
            let angle = Double(i) / Double(rays) * 2 * .pi + jitter
            let length = r * (1.2 + 3.6 * u) * (0.75 + 0.5 * noise(seed, i + 40))
            let inner = r * (1.05 + 2.2 * u)
            let dx = cos(angle), dy = sin(angle)
            return (CGPoint(x: c.x + inner * dx, y: c.y + inner * dy),
                    CGPoint(x: c.x + (inner + length * 0.6) * dx, y: c.y + (inner + length * 0.6) * dy))
        }
        let width = r * 0.24 * (1 - u) + 0.9
        ctx.setLineCap(.round)
        // A dark line under each ray, so the rays also read on a bright background.
        stroke(ctx, segments, width: width * 1.8, color(tint * 0.25, 0.3 * f), blend: .normal)
        stroke(ctx, segments, width: width, color(tint, 0.95 * f), blend: .plusLighter)
        stroke(ctx, segments, width: width * 0.35, color(white, f), blend: .plusLighter)
        glow(ctx, c, r * 1.9, tint, 0.6 * f)
    }

    private static func ripple(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ age: Double, _ tint: SIMD3<Double>) {
        for k in 0..<3 {
            let delay = Double(k) * 0.12
            let u = min(1, max(0, (age - delay) / (1 - delay)))
            guard u > 0, u < 1 else { continue }
            let e = ease(u)
            ring(ctx, c, r * (1 + 4 * e), width: r * 0.22 * (1 - e) + 1,
                 k == 0 ? white : mix(tint, white, 0.35), fade(u) * (k == 0 ? 1 : 0.75))
        }
        glow(ctx, c, r * 1.7, tint, 0.45 * fade(age))
    }

    private static func sparkle(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ age: Double, _ tint: SIMD3<Double>, seed: Int) {
        let u = ease(age), f = fade(age)
        ctx.setBlendMode(.plusLighter)
        for i in 0..<24 {
            let angle = noise(seed, i) * 2 * .pi
            let speed = 2 + 2.6 * noise(seed, i + 100)
            let distance = r * (0.9 + speed * u)
            let fall = r * 2 * u * u
            let p = CGPoint(x: c.x + cos(angle) * distance, y: c.y + sin(angle) * distance + fall)
            let size = r * (0.2 + 0.2 * noise(seed, i + 200)) * (1 - u * 0.6)
            let alpha = f * (0.75 + 0.25 * sin(age * 50 + Double(i)))
            star(ctx, p, size, i % 3 == 0 ? white : mix(tint, white, 0.4), alpha)
        }
        ctx.setBlendMode(.normal)
        glow(ctx, c, r * 1.9, tint, 0.55 * f)
    }

    private static func star(_ ctx: CGContext, _ p: CGPoint, _ size: CGFloat, _ rgb: SIMD3<Double>, _ alpha: Double) {
        guard alpha > 0.01, size > 0.3 else { return }
        ctx.setFillColor(color(rgb, alpha))
        ctx.move(to: CGPoint(x: p.x, y: p.y - size))
        ctx.addLine(to: CGPoint(x: p.x + size * 0.28, y: p.y - size * 0.28))
        ctx.addLine(to: CGPoint(x: p.x + size, y: p.y))
        ctx.addLine(to: CGPoint(x: p.x + size * 0.28, y: p.y + size * 0.28))
        ctx.addLine(to: CGPoint(x: p.x, y: p.y + size))
        ctx.addLine(to: CGPoint(x: p.x - size * 0.28, y: p.y + size * 0.28))
        ctx.addLine(to: CGPoint(x: p.x - size, y: p.y))
        ctx.addLine(to: CGPoint(x: p.x - size * 0.28, y: p.y - size * 0.28))
        ctx.closePath(); ctx.fillPath()
    }

    private static func shatter(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ age: Double, _ tint: SIMD3<Double>, seed: Int) {
        let u = ease(age), f = fade(age), shards = 12
        for i in 0..<shards {
            let angle = Double(i) / Double(shards) * 2 * .pi + noise(seed, i) * 0.5
            let distance = r * (0.6 + 3 * u * (0.8 + 0.4 * noise(seed, i + 50)))
            let fall = r * 1.6 * u * u
            let p = CGPoint(x: c.x + cos(angle) * distance, y: c.y + sin(angle) * distance + fall)
            let spin = angle + u * (noise(seed, i + 90) - 0.5) * 9
            let size = r * (0.38 + 0.3 * noise(seed, i + 130)) * (1 - 0.3 * u)
            ctx.saveGState()
            ctx.translateBy(x: p.x, y: p.y); ctx.rotate(by: spin)
            ctx.setFillColor(color(mix(tint, white, 0.25), 0.95 * f))
            ctx.move(to: CGPoint(x: 0, y: -size))
            ctx.addLine(to: CGPoint(x: size * 0.8, y: size * 0.6))
            ctx.addLine(to: CGPoint(x: -size * 0.7, y: size * 0.5))
            ctx.closePath(); ctx.fillPath()
            ctx.setStrokeColor(color(white, 0.8 * f)); ctx.setLineWidth(max(0.8, r * 0.04))
            ctx.move(to: CGPoint(x: 0, y: -size)); ctx.addLine(to: CGPoint(x: size * 0.8, y: size * 0.6)); ctx.strokePath()
            ctx.restoreGState()
        }
        glow(ctx, c, r * 1.7, white, 0.6 * max(0, 1 - age * 2.5))
    }

    private static func halo(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ age: Double, _ tint: SIMD3<Double>) {
        // Blooms out over the first half, then closes back onto the ball.
        let bloom = age < 0.5 ? ease(age * 2) : 1 - ease((age - 0.5) * 2) * 0.85
        let radius = r * (1.1 + 1.5 * bloom)
        let alpha = sin(age * .pi)
        for step in 0..<6 {
            let t = Double(step) / 5
            // One dark backing under the band; one per ring would dim the rings inside it.
            ring(ctx, c, radius * (1 + 0.18 * t), width: r * 0.3 * (1 - t) + 1.2,
                 mix(tint, white, 0.3), alpha * 0.75 * (1 - t * 0.85), backed: step == 0)
        }
        glow(ctx, c, r * 2.3, tint, 0.5 * alpha)
    }

    private static func pixel(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ age: Double, _ from: SIMD3<Double>, _ to: SIMD3<Double>, seed: Int) {
        let u = ease(age), f = fade(age), cells = 6
        let block = r * 2.2 / CGFloat(cells)
        for row in 0..<cells { for col in 0..<cells {
            let lane = row * cells + col
            let ox = (CGFloat(col) + 0.5 - CGFloat(cells) / 2) * block
            let oy = (CGFloat(row) + 0.5 - CGFloat(cells) / 2) * block
            let distance = hypot(ox, oy)
            guard distance < r * 1.15 else { continue }
            let drift = 1 + u * (2 + 1.6 * noise(seed, lane))
            let p = CGPoint(x: c.x + ox * drift, y: c.y + oy * drift)
            let shade = noise(seed, lane + 300)
            let rgb = mix(mix(from, to, u), white, shade * 0.5)
            let alpha = f * (0.7 + 0.3 * noise(seed, lane + 600))
            let size = block * (1 - u * 0.5)
            ctx.setFillColor(color(rgb, alpha))
            ctx.fill(CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
        } }
    }

    private static func smoke(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ age: Double, seed: Int) {
        let u = ease(age), f = fade(age)
        for i in 0..<9 {
            let angle = noise(seed, i) * 2 * .pi
            let spread = r * (0.6 + 1.3 * u) * (0.5 + noise(seed, i + 30))
            let rise = r * (0.5 + 2.6 * u) * (0.7 + 0.6 * noise(seed, i + 60))
            let p = CGPoint(x: c.x + cos(angle) * spread + sin(u * 6 + Double(i)) * r * 0.15,
                            y: c.y - rise + sin(angle) * spread * 0.4)
            let radius = r * (0.5 + 0.6 * noise(seed, i + 90)) * (1 + 1.7 * u)
            puff(ctx, p, radius, SIMD3(0.92, 0.94, 0.97), 0.55 * f, profile: [(0, 1), (0.4, 0.75), (1, 0)], blend: .normal)
        }
    }

    private static func lightning(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ age: Double, _ tint: SIMD3<Double>, seed: Int) {
        let visible = max(0, 1 - age * 1.15)
        guard visible > 0 else { return }
        let flicker = 0.6 + 0.4 * abs(sin(age * 46 + Double(seed)))
        let bolts = (0..<6).map { bolt -> [CGPoint] in
            let base = noise(seed, bolt) * 2 * .pi
            let length = r * (2.2 + 1.6 * noise(seed, bolt + 20))
            var points: [CGPoint] = [CGPoint(x: c.x + cos(base) * r * 0.95, y: c.y + sin(base) * r * 0.95)]
            for segment in 1...6 {
                let t = Double(segment) / 6
                let wobble = (noise(seed, bolt * 10 + segment) - 0.5) * r
                let angle = base + (noise(seed, bolt + 40) - 0.5) * 0.6
                points.append(CGPoint(x: c.x + cos(angle) * (r + length * t) - sin(angle) * wobble,
                                      y: c.y + sin(angle) * (r + length * t) + cos(angle) * wobble))
            }
            return points
        }
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        // A dark line under the bolts first, so they also read on a bright background.
        let passes: [(width: CGFloat, rgb: SIMD3<Double>, alpha: Double, blend: CGBlendMode)] = [
            (r * 0.42, tint * 0.2, 0.3, .normal), (r * 0.28, tint, 0.5, .plusLighter),
            (r * 0.11, mix(tint, white, 0.6), 0.85, .plusLighter), (r * 0.045, white, 1, .plusLighter)]
        for pass in passes {
            ctx.setBlendMode(pass.blend)
            ctx.setStrokeColor(color(pass.rgb, pass.alpha * visible * flicker))
            ctx.setLineWidth(max(0.5, pass.width))
            for points in bolts { ctx.addLines(between: points) }
            ctx.strokePath()
        }
        ctx.setBlendMode(.normal)
        glow(ctx, c, r * 2.1, tint, 0.65 * visible * flicker)
    }
}
