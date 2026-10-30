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
        case .none: "None"
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
    static let duration = 0.5

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
        case .pop: return 1 + 0.24 * sin(a * .pi) * (1 - a * 0.5)
        case .halo: return 1 + 0.1 * sin(a * .pi)
        case .flash: return 1 + 0.08 * max(0, 1 - a * 3)
        case .shatter: return 1 - 0.12 * max(0, 1 - a * 4)
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

    /// Concentric filled discs stand in for a Gaussian glow without a blur pass.
    private static func glow(_ ctx: CGContext, _ center: CGPoint, _ radius: CGFloat, _ rgb: SIMD3<Double>, _ alpha: Double) {
        guard alpha > 0.002 else { return }
        ctx.setBlendMode(.plusLighter)
        for step in 0..<5 {
            let t = Double(step) / 4
            let r = radius * (0.35 + 0.65 * t)
            ctx.setFillColor(color(rgb, alpha * 0.28 * (1 - t * 0.8)))
            ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        }
        ctx.setBlendMode(.normal)
    }

    private static func ring(_ ctx: CGContext, _ center: CGPoint, _ radius: CGFloat, width: CGFloat, _ rgb: SIMD3<Double>, _ alpha: Double) {
        guard alpha > 0.002, radius > 0 else { return }
        ctx.setBlendMode(.plusLighter)
        ctx.setStrokeColor(color(rgb, alpha))
        ctx.setLineWidth(max(0.5, width))
        ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        ctx.setBlendMode(.normal)
    }

    // MARK: - Effects

    private static func pop(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ age: Double, _ tint: SIMD3<Double>) {
        let u = ease(age)
        glow(ctx, c, r * (1.3 + 0.6 * u), mix(tint, white, 0.5), 0.5 * (1 - u))
        ring(ctx, c, r * (1.05 + 1.3 * u), width: r * 0.12 * (1 - u) + 0.8, white, 0.9 * (1 - u))
    }

    private static func flash(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ age: Double, _ tint: SIMD3<Double>) {
        let a = max(0, 1 - age * 1.6)
        ctx.setBlendMode(.plusLighter)
        ctx.setFillColor(color(white, 0.95 * a * a))
        let fr = r * (1.15 + 1.1 * age)
        ctx.fillEllipse(in: CGRect(x: c.x - fr, y: c.y - fr, width: fr * 2, height: fr * 2))
        ctx.setBlendMode(.normal)
        glow(ctx, c, r * (2 + 1.4 * age), mix(tint, white, 0.3), 0.6 * (1 - age))
        ring(ctx, c, r * (1 + 2.4 * ease(age)), width: 1.5, mix(tint, white, 0.6), 0.7 * (1 - age))
    }

    private static func burst(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ age: Double, _ tint: SIMD3<Double>, seed: Int) {
        let u = ease(age), rays = 14
        ctx.setBlendMode(.plusLighter)
        ctx.setLineCap(.round)
        for i in 0..<rays {
            let jitter = noise(seed, i) * 0.4 - 0.2
            let angle = Double(i) / Double(rays) * 2 * .pi + jitter
            let length = r * (0.9 + 2.6 * u) * (0.75 + 0.5 * noise(seed, i + 40))
            let inner = r * (1.05 + 1.6 * u)
            let dx = cos(angle), dy = sin(angle)
            let start = CGPoint(x: c.x + inner * dx, y: c.y + inner * dy)
            let end = CGPoint(x: c.x + (inner + length * 0.6) * dx, y: c.y + (inner + length * 0.6) * dy)
            let fade = (1 - u) * (1 - u)
            ctx.setStrokeColor(color(tint, 0.8 * fade))
            ctx.setLineWidth(r * 0.16 * (1 - u) + 0.6)
            ctx.move(to: start); ctx.addLine(to: end); ctx.strokePath()
            ctx.setStrokeColor(color(white, 0.9 * fade))
            ctx.setLineWidth(r * 0.05 * (1 - u) + 0.4)
            ctx.move(to: start); ctx.addLine(to: end); ctx.strokePath()
        }
        ctx.setBlendMode(.normal)
        glow(ctx, c, r * 1.4, tint, 0.4 * (1 - u))
    }

    private static func ripple(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ age: Double, _ tint: SIMD3<Double>) {
        for k in 0..<3 {
            let delay = Double(k) * 0.14
            let u = min(1, max(0, (age - delay) / (1 - delay)))
            guard u > 0, u < 1 else { continue }
            let e = ease(u)
            ring(ctx, c, r * (1 + 2.8 * e), width: r * 0.14 * (1 - e) + 0.8,
                 k == 0 ? white : mix(tint, white, 0.35), (1 - e) * (k == 0 ? 0.9 : 0.6))
        }
    }

    private static func sparkle(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ age: Double, _ tint: SIMD3<Double>, seed: Int) {
        let u = ease(age)
        ctx.setBlendMode(.plusLighter)
        for i in 0..<18 {
            let angle = noise(seed, i) * 2 * .pi
            let speed = 1.6 + 2 * noise(seed, i + 100)
            let distance = r * (0.9 + speed * u)
            let fall = r * 1.5 * u * u
            let p = CGPoint(x: c.x + cos(angle) * distance, y: c.y + sin(angle) * distance + fall)
            let size = r * (0.12 + 0.14 * noise(seed, i + 200)) * (1 - u * 0.7)
            let alpha = (1 - u) * (0.7 + 0.3 * sin(age * 50 + Double(i)))
            star(ctx, p, size, i % 3 == 0 ? white : mix(tint, white, 0.4), alpha)
        }
        ctx.setBlendMode(.normal)
        glow(ctx, c, r * 1.5, tint, 0.35 * (1 - u))
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
        let u = ease(age), shards = 10
        for i in 0..<shards {
            let angle = Double(i) / Double(shards) * 2 * .pi + noise(seed, i) * 0.5
            let distance = r * (0.6 + 2.2 * u * (0.8 + 0.4 * noise(seed, i + 50)))
            let fall = r * 1.2 * u * u
            let p = CGPoint(x: c.x + cos(angle) * distance, y: c.y + sin(angle) * distance + fall)
            let spin = angle + u * (noise(seed, i + 90) - 0.5) * 9
            let size = r * (0.3 + 0.25 * noise(seed, i + 130)) * (1 - 0.3 * u)
            let alpha = pow(1 - u, 1.3)
            ctx.saveGState()
            ctx.translateBy(x: p.x, y: p.y); ctx.rotate(by: spin)
            ctx.setFillColor(color(mix(tint, white, 0.25), 0.9 * alpha))
            ctx.move(to: CGPoint(x: 0, y: -size))
            ctx.addLine(to: CGPoint(x: size * 0.8, y: size * 0.6))
            ctx.addLine(to: CGPoint(x: -size * 0.7, y: size * 0.5))
            ctx.closePath(); ctx.fillPath()
            ctx.setStrokeColor(color(white, 0.7 * alpha)); ctx.setLineWidth(0.8)
            ctx.move(to: CGPoint(x: 0, y: -size)); ctx.addLine(to: CGPoint(x: size * 0.8, y: size * 0.6)); ctx.strokePath()
            ctx.restoreGState()
        }
        glow(ctx, c, r * 1.3, white, 0.45 * max(0, 1 - age * 3))
    }

    private static func halo(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ age: Double, _ tint: SIMD3<Double>) {
        // Blooms out over the first half, then closes back onto the ball.
        let bloom = age < 0.5 ? ease(age * 2) : 1 - ease((age - 0.5) * 2) * 0.85
        let radius = r * (1.1 + 1.0 * bloom)
        let alpha = sin(age * .pi)
        ctx.setBlendMode(.plusLighter)
        for step in 0..<6 {
            let t = Double(step) / 5
            ring(ctx, c, radius * (1 + 0.18 * t), width: r * 0.22 * (1 - t) + 1,
                 mix(tint, white, 0.3), alpha * 0.55 * (1 - t * 0.85))
        }
        ctx.setBlendMode(.normal)
        glow(ctx, c, r * 1.8, tint, 0.35 * alpha)
    }

    private static func pixel(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ age: Double, _ from: SIMD3<Double>, _ to: SIMD3<Double>, seed: Int) {
        let u = ease(age), cells = 6
        let block = r * 2.2 / CGFloat(cells)
        for row in 0..<cells { for col in 0..<cells {
            let lane = row * cells + col
            let ox = (CGFloat(col) + 0.5 - CGFloat(cells) / 2) * block
            let oy = (CGFloat(row) + 0.5 - CGFloat(cells) / 2) * block
            let distance = hypot(ox, oy)
            guard distance < r * 1.15 else { continue }
            let drift = 1 + u * (1.4 + 1.2 * noise(seed, lane))
            let p = CGPoint(x: c.x + ox * drift, y: c.y + oy * drift)
            let shade = noise(seed, lane + 300)
            let rgb = mix(mix(from, to, u), white, shade * 0.5)
            let alpha = (1 - u) * (0.55 + 0.45 * noise(seed, lane + 600))
            let size = block * (1 - u * 0.6)
            ctx.setFillColor(color(rgb, alpha))
            ctx.fill(CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
        } }
    }

    private static func smoke(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ age: Double, seed: Int) {
        let u = ease(age)
        for i in 0..<7 {
            let angle = noise(seed, i) * 2 * .pi
            let spread = r * (0.5 + 0.9 * u) * (0.5 + noise(seed, i + 30))
            let rise = r * (0.4 + 1.9 * u) * (0.7 + 0.6 * noise(seed, i + 60))
            let p = CGPoint(x: c.x + cos(angle) * spread + sin(u * 6 + Double(i)) * r * 0.15,
                            y: c.y - rise + sin(angle) * spread * 0.4)
            let radius = r * (0.4 + 0.5 * noise(seed, i + 90)) * (1 + 1.4 * u)
            let alpha = 0.5 * (1 - u) * (1 - u)
            for step in 0..<4 {
                let t = Double(step) / 3, rr = radius * (0.45 + 0.55 * t)
                ctx.setFillColor(color(SIMD3(0.92, 0.94, 0.97), alpha * 0.35 * (1 - t * 0.7)))
                ctx.fillEllipse(in: CGRect(x: p.x - rr, y: p.y - rr, width: rr * 2, height: rr * 2))
            }
        }
    }

    private static func lightning(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ age: Double, _ tint: SIMD3<Double>, seed: Int) {
        let visible = max(0, 1 - age * 1.4)
        guard visible > 0 else { return }
        let flicker = 0.55 + 0.45 * abs(sin(age * 46 + Double(seed)))
        ctx.setBlendMode(.plusLighter)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        for bolt in 0..<5 {
            let base = noise(seed, bolt) * 2 * .pi
            let length = r * (1.6 + 1.2 * noise(seed, bolt + 20))
            var points: [CGPoint] = [CGPoint(x: c.x + cos(base) * r * 0.95, y: c.y + sin(base) * r * 0.95)]
            for segment in 1...6 {
                let t = Double(segment) / 6
                let wobble = (noise(seed, bolt * 10 + segment) - 0.5) * r * 0.9
                let angle = base + (noise(seed, bolt + 40) - 0.5) * 0.6
                points.append(CGPoint(x: c.x + cos(angle) * (r + length * t) - sin(angle) * wobble,
                                      y: c.y + sin(angle) * (r + length * t) + cos(angle) * wobble))
            }
            for (width, rgb, alpha) in [(r * 0.2, tint, 0.45), (r * 0.08, mix(tint, white, 0.6), 0.8), (r * 0.03, white, 1.0)] {
                ctx.setStrokeColor(color(rgb, alpha * visible * flicker))
                ctx.setLineWidth(max(0.5, width))
                ctx.addLines(between: points); ctx.strokePath()
            }
        }
        ctx.setBlendMode(.normal)
        glow(ctx, c, r * 1.6, tint, 0.5 * visible * flicker)
    }
}
