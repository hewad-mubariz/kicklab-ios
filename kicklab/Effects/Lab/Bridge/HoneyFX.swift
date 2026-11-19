// Copied from the Effects Lab (EffectLab/FX/HoneyFX.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import Metal
import simd

/// Honey Drift, rebuilt 2026-11-19 (the owner: "honey is not too good").
/// Target: effects-sheet-v1 panel 07 — a thick glossy honey ribbon sweeping along the ball's path,
/// sagging and dripping, stretched gooey splashes on each touch, and a few honeycomb chunks.
/// The liquid refracts the real frame through an amber body (FXLiquid, honey material).
nonisolated final class HoneyFX: FXEffect {
    let kit: FXKit
    let liquid: FXLiquidRenderer
    init(kit: FXKit) throws {
        self.kit = kit
        liquid = try FXLiquidRenderer(kit: kit, material: .honey)
        _ = try kit.pipeline("combVertex", "combFragment", blend: .premultiplied, samples: 1)
    }

    struct Comb { var center: SIMD4<Float>; var shape: SIMD4<Float> }   // x, y, size, angle | seed, tilt, fade, -

    func encode(_ ctx: FXContext, source: MTLTexture, target: MTLTexture, command: MTLCommandBuffer) throws {
        let liquidOut = kit.texture("honey.liquid", source.width, source.height, .bgra8Unorm)
        try liquid.encode(ctx, beads: Self.scene(ctx).items, source: source, target: liquidOut, command: command)
        kit.passthrough(command, source: liquidOut, target: target)
        let combs = Self.combs(ctx)
        guard ctx.intensity > 0, let buffer = kit.buffer(combs) else { return }
        var u = kit.uniforms(ctx)
        try kit.pass(command, target, clear: false) { e in
            e.setRenderPipelineState(try kit.pipeline("combVertex", "combFragment", blend: .premultiplied))
            e.setVertexBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
            e.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
            e.setVertexBuffer(buffer, offset: 0, index: 1)
            e.setFragmentTexture(liquidOut, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: combs.count)
        }
    }

    static let sag: Float = 7          // honey ribbon sag, ball radii / s²
    static let fall: Float = 26        // free drops, ball radii / s²

    static func scene(_ ctx: FXContext) -> FXBeads {
        var beads = FXBeads()
        guard ctx.ball.w > 0 else { return beads }
        ribbon(ctx, &beads)
        arms(ctx, &beads)
        for t in ctx.recentTouches(within: 1.6) { splash(ctx, t.index, t.time, t.age, &beads) }
        return beads
    }

    /// Where a ribbon parcel born at `birth` is `age` seconds later.
    static func parcel(_ ctx: FXContext, _ birth: Float, _ age: Float) -> (p: SIMD2<Float>, r: Float) {
        let b = ctx.sample(birth), r = b.z
        let v = ctx.velocity(birth), speed = simd_length(v)
        let back = speed > 1 ? -v / speed : SIMD2<Float>(0, 1)
        let side = SIMD2(-back.y, back.x)
        // Released just behind the ball, slightly to one side, keeping a little momentum, then sagging.
        var p = SIMD2(b.x, b.y) + back * r * 0.55 + side * r * 0.35 * sin(birth * 2.3) + v * 0.1 * age
        p.y += 0.5 * sag * r * age * age
        p += SIMD2(sin(birth * 7 + age * 3), cos(birth * 5)) * r * 0.12 * age
        return (p, r)
    }

    /// The main honey ribbon: two arms through the ball on a slowly turning diagonal. Each point follows the
    /// ball with a delay that grows along the arm, so the ribbon drags, swings and sags behind the motion.
    static func arms(_ ctx: FXContext, _ beads: inout FXBeads) {
        let r = ctx.ball.z
        let axis = -0.55 + 0.35 * sin(ctx.time * 0.7)
        for side in [Float(1), -1] {
            let dir = SIMD2(cos(axis), sin(axis)) * side
            let perp = SIMD2(-dir.y, dir.x)
            let length = r * (side > 0 ? 3.6 : 2.8)
            var pts = [SIMD2<Float>](), rad = [Float]()
            let n = 26
            for k in 0...n {
                let s = Float(k) / Float(n)
                let delay = 0.02 + 0.12 * s
                let b = ctx.sample(max(0, ctx.time - delay))
                let along = r * 0.7 + length * s
                // A slow travelling wave and a gravity sag that grows toward the free end.
                let wave = sin(s * 5.5 - ctx.time * 3.2 + side) * r * 0.32 * s
                let sagY = r * 0.9 * s * s
                let p = SIMD2(b.x, b.y) + dir * along + perp * wave + SIMD2(0, sagY)
                let width = r * (0.26 - 0.18 * s) * (1 + 0.22 * sin(s * 14 - ctx.time * 4 + side * 2))
                pts.append(p); rad.append(max(r * 0.05, width) * (k == n ? 0.9 : 1))
            }
            beads.tube(pts, rad, glow: 0.4)
            // A drop forms at the free end, stretches down and lets go now and then.
            let period: Float = 1.1, phase = (ctx.time + (side > 0 ? 0 : 0.5)).truncatingRemainder(dividingBy: period) / period
            let end = pts[n]
            let hang = r * 1.6 * phase * phase
            let bulb = r * 0.11 * (0.6 + 0.4 * phase)
            if phase < 0.85 {
                beads.tube([end, end + SIMD2(0, hang * 0.5), end + SIMD2(0, hang)], [r * 0.08, r * 0.04, bulb * 0.8])
                beads.drop(end + SIMD2(0, hang), bulb)
            } else {
                let dt = (phase - 0.85) * period
                beads.drop(end + SIMD2(0, r * 1.6 * 0.72 + fall * r * 0.5 * dt * dt + r * 2 * dt), bulb, fade: 1 - fxSmooth(0.05, 0.16, dt))
            }
        }
    }

    static func ribbon(_ ctx: FXContext, _ beads: inout FXBeads) {
        let rate: Float = 75, life: Float = 0.75
        let last = Int(floor(ctx.time * rate)), first = max(0, Int(floor((ctx.time - life) * rate)))
        guard last > first else { return }
        var points = [SIMD2<Float>](), radii = [Float]()
        for i in first...last {
            let birth = Float(i) / rate, age = ctx.time - birth
            guard age >= 0, age < life else { continue }
            let (p, r) = parcel(ctx, birth, age)
            let speed = simd_length(ctx.velocity(birth)) / r
            // Thick where the ball moved fast; thins into strings as it ages.
            let body = 0.06 + 0.12 * fxSmooth(1.5, 7, speed)
            let wobble = 1 + 0.25 * sin(birth * 31) * sin(birth * 13)
            let k = fxSmooth(0, 0.05, age) * pow(1 - age / life, 0.75)
            points.append(p); radii.append(r * body * wobble * k)
        }
        beads.tube(points, radii, glow: 0.3)

        // Drips hang from the ribbon, stretch, and let go of a drop.
        let dripRate: Float = 9
        let dLast = Int(floor(ctx.time * dripRate)), dFirst = max(0, Int(floor((ctx.time - 1.3) * dripRate)))
        guard dLast >= dFirst else { return }
        for i in dFirst...dLast {
            let birth = Float(i) / dripRate + 0.05 * fxRandom(i, 1)
            let age = ctx.time - birth
            guard age > 0, age < 1.3, fxRandom(i, 2) < 0.7 else { continue }
            let (anchorNow, r) = parcel(ctx, birth, min(age, life * 0.8))
            let speed = simd_length(ctx.velocity(birth)) / r
            guard speed > 2 else { continue }
            let g = fall * r * (0.45 + 0.3 * fxRandom(i, 3))
            let hang = 0.5 * g * age * age * 0.35 + r * 0.25
            let breakAt = r * (1.0 + 0.9 * fxRandom(i, 4))
            let bulbR = r * (0.09 + 0.06 * fxRandom(i, 5))
            if hang < breakAt {
                let anchor = anchorNow
                let end = anchor + SIMD2(0, hang)
                beads.tube([anchor, anchor + SIMD2(0, hang * 0.5), end], [r * 0.07, r * 0.035, bulbR * 0.8])
                beads.drop(end, bulbR)
            } else {
                // Let go: the bulb falls on, the string snaps back up.
                let tBreak = sqrt((breakAt - r * 0.25) * 2 / (g * 0.35))
                let dt = age - tBreak
                let drop = anchorNow + SIMD2(0, breakAt) + SIMD2(0, g * (tBreak * 0.35 * dt + 0.5 * dt * dt))
                let fade = 1 - fxSmooth(0.35, 0.6, dt)
                beads.drop(drop, bulbR * (0.6 + 0.4 * fade), fade: fade)
                let back = 1 - fxSmooth(0, 0.18, dt)
                if back > 0.02 { beads.tube([anchorNow, anchorNow + SIMD2(0, breakAt * 0.5 * back)], [r * 0.06 * back, r * 0.03 * back]) }
            }
        }
    }

    static func splash(_ ctx: FXContext, _ index: Int, _ t0: Float, _ age: Float, _ beads: inout FXBeads) {
        let seed = 7300 + index * 97
        let birth = ctx.sample(t0 + 0.015), r = birth.z
        let ballNow = ctx.sample(t0 + age)
        let v = ctx.velocity(t0 + 0.06)
        let g = SIMD2<Float>(0, fall * r)
        let axis: Float = index % 2 == 0 ? -0.35 : Float.pi + 0.35
        // Gooey strings: stay attached much longer than water, stretch, sag, then break.
        for j in 0..<9 {
            func rnd(_ c: Int) -> Float { fxRandom(seed + j * 13, c) }
            let upper = j < 6
            let angle = (upper ? axis : axis + .pi + 0.3) + (rnd(1) - 0.5) * 1.1
            let dir = SIMD2(cos(angle), sin(angle))
            let speed = r * (upper ? 7 + 7 * rnd(2) : 5 + 4 * rnd(2))
            let a = age - 0.01 * rnd(3)
            guard a > 0 else { continue }
            let drag: Float = 3.5
            let root0 = SIMD2(birth.x, birth.y) + dir * r * 0.95
            func tip(_ t: Float) -> SIMD2<Float> { root0 + (dir * speed + v * 0.8) * (1 - exp(-drag * t)) / drag + g * 0.5 * t * t * 0.5 }
            let breakup: Float = 0.32 + 0.2 * rnd(4)
            let thick = r * (0.13 + 0.1 * rnd(5))
            let rootNow = SIMD2(ballNow.x, ballNow.y) + dir * r * 0.95
            if a < breakup {
                let tp = tip(a)
                var pts = [SIMD2<Float>](), rad = [Float]()
                for k in 0...12 {
                    let s = Float(k) / 12
                    // Sags in the middle like a pulled string of honey.
                    let p = rootNow + (tp - rootNow) * s + SIMD2(0, r * 0.5 * s * (1 - s) * 4 * fxSmooth(0.05, 0.3, a))
                    let neck = thick * (1.2 - 0.85 * sqrt(s) + 0.9 * exp(-s * 8)) / sqrt(1 + a * 6)
                    let bulb = thick * 1.05 * fxSmooth(0.8, 1, s) / sqrt(1 + a * 3)
                    pts.append(p); rad.append(max(neck, bulb) * fxSmooth(0, 0.04, a))
                }
                beads.tube(pts, rad, glow: 0.2)
            } else {
                let dt = a - breakup
                let tp = tip(breakup)
                let vel = (dir * speed + v * 0.8) * exp(-drag * breakup) * 0.6
                let p = tp + vel * dt + g * (breakup * 0.5 * dt + 0.5 * dt * dt)
                let fade = 1 - fxSmooth(0.5, 0.9, dt)
                beads.drop(p, thick * 1.0 * (0.6 + 0.4 * fade), fade: fade, glow: 0.2)
                if dt < 0.12 { beads.tube([p, p - simd_normalize(vel + SIMD2(0, 0.01)) * thick * 3 * (1 - dt / 0.12)], [thick * 0.6, thick * 0.15]) }
                let back = 1 - fxSmooth(0, 0.2, dt)
                if back > 0.02 { beads.tube([rootNow, rootNow + dir * r * 0.4 * back], [thick * 0.9 * back, thick * 0.4 * back]) }
            }
        }
        // Small golden droplets.
        for j in 0..<16 {
            func rnd(_ c: Int) -> Float { fxRandom(seed + 4000 + j * 7, c) }
            let a = age - 0.02 - 0.06 * rnd(1)
            guard a > 0 else { continue }
            let angle = axis + (rnd(2) < 0.65 ? 0 : .pi) + (rnd(3) - 0.5) * 1.7
            let dir = SIMD2(cos(angle), sin(angle))
            let start = SIMD2(birth.x, birth.y) + dir * r
            let p = start + (dir * r * (4 + 7 * rnd(4)) + v * 0.6) * (1 - exp(-2 * a)) / 2 + g * 0.5 * a * a * 0.7
            let life: Float = 0.8 + 0.5 * rnd(5)
            let fade = 1 - fxSmooth(life * 0.6, life, a)
            beads.drop(p, r * (0.04 + 0.08 * rnd(6)) * fxSmooth(0, 0.04, a), fade: fade, glow: 0.3)
        }
    }

    /// One honeycomb chunk thrown off every other touch: tumbles slowly and falls.
    static func combs(_ ctx: FXContext) -> [Comb] {
        var out = [Comb]()
        for t in ctx.recentTouches(within: 2.0) where t.index % 2 == 0 || t.index % 5 == 3 {
            let seed = 8800 + t.index * 31
            let b = ctx.sample(t.time + 0.02), r = b.z
            let v = ctx.velocity(t.time + 0.06)
            let side: Float = fxRandom(seed, 1) < 0.5 ? -1 : 1
            let dir = simd_normalize(SIMD2(side * (0.8 + 0.5 * fxRandom(seed, 2)), -0.6 - 0.6 * fxRandom(seed, 3)))
            let a = t.age
            let p = SIMD2(b.x, b.y) + dir * r * 1.1 + (dir * r * 5.5 + v * 0.3) * (1 - exp(-1.6 * a)) / 1.6 + SIMD2(0, 0.5 * 9 * r * a * a)
            let fade = fxSmooth(0, 0.12, a) * (1 - fxSmooth(1.4, 2.0, a))
            let size = r * (0.42 + 0.2 * fxRandom(seed, 4))
            let angle = fxRandom(seed, 5) * 6.28 + a * (fxRandom(seed, 6) - 0.5) * 2.4
            let tilt = 0.55 + 0.4 * abs(sin(a * 1.7 + fxRandom(seed, 7) * 3))
            out.append(Comb(center: SIMD4(p.x, p.y, size * (0.4 + 0.6 * fxSmooth(0, 0.15, a)), angle), shape: SIMD4(Float(seed % 97), tilt, fade * ctx.intensity, 0)))
        }
        return out
    }
}
