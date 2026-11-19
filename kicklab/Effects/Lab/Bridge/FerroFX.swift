// Copied from the Effects Lab (EffectLab/FX/FerroFX.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import Metal
import simd

/// Ferro Storm, rebuilt 2026-11-19 after the owner called the first lab version flat and basic.
/// Target: effects-sheet-v1 panel 03 — liquid chrome erupting out of the ball on a touch: a crown of
/// curling jets with drop tips, short ferrofluid spikes at the ball, and loose chrome drops in the air.
/// Between touches a thin chrome tail follows the ball. Everything is rebuilt from the playhead.
nonisolated final class FerroFX: FXEffect {
    let liquid: FXLiquidRenderer
    init(kit: FXKit) throws { liquid = try FXLiquidRenderer(kit: kit, material: .chrome) }

    func encode(_ ctx: FXContext, source: MTLTexture, target: MTLTexture, command: MTLCommandBuffer) throws {
        try liquid.encode(ctx, beads: Self.scene(ctx).items, source: source, target: target, command: command, reflect: 0.4)
    }

    /// Effective gravity for the liquid, in ball radii per second² (about 0.45 g, so drops hang in the air).
    static let gravity: Float = 40

    static func scene(_ ctx: FXContext) -> FXBeads {
        var beads = FXBeads()
        let now = ctx.ball
        guard now.w > 0 else { return beads }
        tail(ctx, &beads)
        for touch in ctx.recentTouches(within: 1.5) { splash(ctx, touch.index, touch.time, touch.age, &beads) }
        return beads
    }

    /// A thin chrome tail behind the ball, made of parcels released along its path.
    static func tail(_ ctx: FXContext, _ beads: inout FXBeads) {
        let rate: Float = 90, life: Float = 0.24
        let last = Int(floor(ctx.time * rate)), first = max(0, Int(floor((ctx.time - life) * rate)))
        guard last > first else { return }
        var points = [SIMD2<Float>](), radii = [Float]()
        for i in first...last {
            let birth = Float(i) / rate, age = ctx.time - birth
            guard age >= 0, age < life else { continue }
            let b = ctx.sample(birth), r = b.z
            let v = ctx.velocity(birth), speed = simd_length(v)
            let back = speed > 1 ? -v / speed : SIMD2<Float>(0, 1)
            // Released on the trailing side of the ball, keeping a little of its momentum.
            var p = SIMD2(b.x, b.y) + back * r * 0.82 + v * 0.18 * age
            p.y += 0.5 * gravity * r * age * age
            p += SIMD2(sin(birth * 23), cos(birth * 17)) * r * 0.05 * age / life
            let swell = fxSmooth(0, 0.06, age) * pow(1 - age / life, 0.8)
            let strength = fxSmooth(r * 2.5, r * 7, speed)
            points.append(p); radii.append(r * 0.15 * swell * strength)
        }
        beads.tube(points, radii)
    }

    static func splash(_ ctx: FXContext, _ index: Int, _ t0: Float, _ age: Float, _ beads: inout FXBeads) {
        let seed = 9100 + index * 131
        let birth = ctx.sample(t0 + 0.015), r = birth.z
        let ballNow = ctx.sample(t0 + age)
        let v = ctx.velocity(t0 + 0.06)
        let g = SIMD2<Float>(0, gravity * r)
        // Which way the splash leans: away from the ball's sideways travel, and up.
        let lean: Float = v.x >= 0 ? -1 : 1
        _ = lean
        let axis: Float = index % 2 == 0 ? -0.55 : Float.pi + 0.55

        // 1. Crescent of liquid hugging the ball's lower half right at the touch.
        if age < 0.3 {
            let k = fxSmooth(0, 0.03, age) * pow(1 - age / 0.3, 1.6)
            var pts = [SIMD2<Float>](), rad = [Float]()
            for j in 0...24 {
                let a = axis - 0.9 + 1.8 * Float(j) / 24
                let d = SIMD2(cos(a), sin(a))
                pts.append(SIMD2(ballNow.x, ballNow.y) + d * r * 1.0)
                rad.append(r * (0.16 + 0.16 * sin(Float(j) / 24 * .pi)) * k)
            }
            beads.tube(pts, rad)
        }

        // 2. Ferrofluid spikes standing out of the ball surface for the first quarter second.
        if age < 0.34 {
            let rise = fxSmooth(0, 0.07, age) * (1 - fxSmooth(0.16, 0.34, age))
            for j in 0..<8 {
                let a = axis + (j < 5 ? 0 : Float.pi) + (Float(j % 5) - 2) * 0.32 + (fxRandom(seed, 300 + j) - 0.5) * 0.2
                let d = SIMD2(cos(a), sin(a))
                let base = SIMD2(ballNow.x, ballNow.y) + d * r * 1.0
                let length = r * (0.25 + 0.35 * fxRandom(seed, 320 + j)) * rise
                guard length > 1 else { continue }
                beads.tube([base, base + d * length * 0.6, base + d * length], [r * 0.1 * rise, r * 0.05 * rise, r * 0.012])
            }
        }

        // 3. Jets: a diagonal fan of thin streaks, as if the ball punched through a sheet of liquid metal.
        // The long lobe goes up and away on one side, a shorter lobe down the other side.
        let jets = 20
        for j in 0..<jets {
            func rnd(_ c: Int) -> Float { fxRandom(seed + j * 17, c) }
            let upper = j < 13
            let spread = (rnd(1) - 0.5) * (upper ? 0.85 : 0.7)
            let angle: Float = upper ? axis + spread : axis + .pi + 0.35 * (index % 2 == 0 ? -1 : 1) + spread
            let dir = SIMD2(cos(angle), sin(angle))
            let speed = r * (upper ? (11 + 13 * rnd(2)) : (7 + 8 * rnd(2)))
            let delay = 0.012 * rnd(3)
            let a = age - delay
            guard a > 0 else { continue }
            let breakup: Float = 0.2 + 0.16 * rnd(4)
            let curl = (rnd(5) - 0.5) * 1.2
            let thickness = r * (0.1 + 0.14 * pow(rnd(6), 1.5)) * (upper ? 1 : 0.85)
            let root0 = SIMD2(birth.x, birth.y) + dir * r * 0.98
            let drag: Float = 3.2
            func tip(_ t: Float) -> SIMD2<Float> {
                let travel = (1 - exp(-drag * t)) / drag
                return root0 + (dir * speed + v * 0.85) * travel + g * 0.5 * t * t
            }
            // Root rides on the ball until the jet breaks, then snaps back into it.
            let rootNow = SIMD2(ballNow.x, ballNow.y) + dir * r * 0.98
            let attached = a < breakup
            if attached {
                let tp = tip(a)
                let len = simd_distance(rootNow, tp)
                let perp = SIMD2(-dir.y, dir.x)
                let thin = 1 / sqrt(1 + a * 9)
                var pts = [SIMD2<Float>](), rad = [Float]()
                let n = 14
                for k in 0...n {
                    let s = Float(k) / Float(n)
                    // Quadratic curve bent sideways so the jet hooks like a flicked tendril.
                    let straight = rootNow + (tp - rootNow) * s
                    let p = straight + perp * curl * len * 0.22 * s * (1 - s) * 4 * min(1, a / 0.1)
                    let neck = thickness * (1.1 - 0.8 * pow(s, 0.6) + 1.4 * exp(-s * 9)) * thin
                    let bulb = thickness * 0.95 * thin * fxSmooth(0.78, 1.0, s)
                    pts.append(p); rad.append(max(neck, bulb) * fxSmooth(0, 0.035, a))
                }
                beads.tube(pts, rad)
            } else {
                // Snapped: a short stub sinks back into the ball…
                let back = 1 - fxSmooth(breakup, breakup + 0.12, a)
                if back > 0.02 {
                    beads.tube([rootNow, rootNow + dir * r * 0.35 * back], [thickness * 0.8 * back, thickness * 0.3 * back])
                }
                // …and the outer part flies on as drops, each with the speed it had on the jet.
                let pieces = 3 + Int(rnd(7) * 4)
                for k in 0..<pieces {
                    let s = 0.35 + 0.65 * Float(k) / Float(pieces - 1)
                    let jitter = SIMD2(rnd(40 + k) - 0.5, rnd(50 + k) - 0.5) * r * 0.25
                    let startRoot = root0
                    let atBreak = startRoot + (tip(breakup) - startRoot) * s + jitter
                    let vel = (dir * speed * exp(-drag * breakup)) * s + v * 0.85 * exp(-drag * breakup) + SIMD2(rnd(60 + k) - 0.5, rnd(70 + k) - 0.5) * r * 1.5
                    let dt = a - breakup
                    let p = atBreak + vel * dt * (1 - 0.35 * min(1, dt)) + g * 0.5 * (breakup + dt) * (breakup + dt) - g * 0.5 * breakup * breakup
                    let life: Float = 0.75 + 0.5 * rnd(80 + k)
                    let fade = 1 - fxSmooth(life * 0.6, life, a)
                    let size = thickness * (0.45 + 0.5 * rnd(90 + k)) * (s > 0.95 ? 1.2 : 1) / sqrt(1 + breakup * 9)
                    beads.drop(p, size * (0.4 + 0.6 * fade), fade: min(1, fade * 1.6))
                    // A short neck behind fresh drops so they read as torn liquid, not balls.
                    if dt < 0.08 {
                        let neck = 1 - dt / 0.08
                        beads.tube([p, p - simd_normalize(vel) * size * 2.6 * neck], [size * 0.55, size * 0.12])
                    }
                }
            }
        }

        // 4. Loose chrome drops thrown wide (mixed sizes, like the floating spheres in the concept).
        for j in 0..<14 {
            func rnd(_ c: Int) -> Float { fxRandom(seed + 5000 + j * 11, c) }
            let delay = 0.03 + 0.08 * rnd(1)
            let a = age - delay
            guard a > 0 else { continue }
            let angle = axis + (rnd(2) < 0.7 ? 0 : Float.pi) + (rnd(2) - 0.5) * 1.6
            let dir = SIMD2(cos(angle), sin(angle))
            let speed = r * (3 + 7 * rnd(3))
            let start = SIMD2(birth.x, birth.y) + dir * r * 1.05
            let drag: Float = 1.4
            let p = start + (dir * speed + v * 0.7) * (1 - exp(-drag * a)) / drag + g * 0.5 * a * a * 0.8
            let life: Float = 0.9 + 0.6 * rnd(4)
            let fade = 1 - fxSmooth(life * 0.65, life, a)
            let size = r * (rnd(5) < 0.25 ? 0.16 + 0.12 * rnd(6) : 0.05 + 0.07 * rnd(6))
            beads.drop(p, size * fxSmooth(0, 0.04, a) * (0.5 + 0.5 * fade), fade: min(1, fade * 1.5))
        }
    }
}
