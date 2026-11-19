// Copied from the Effects Lab (EffectLab/FX/SakuraFX.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import Metal
import simd

/// Sakura Rush, rebuilt 2026-11-19 (the owner: "too basic, less context and details on texture").
/// Target: effects-sheet-v1 panel 02 — on every touch a flowering cherry sprig shoots out of the ball
/// along a diagonal, its blossoms pop open along the branch, gold glitter hangs in the air and loose
/// petals stream and tumble away. Near blossoms are big and out of focus, like a real lens.
nonisolated final class SakuraFX: FXEffect {
    let renderer: FXSpriteRenderer
    init(kit: FXKit) throws { renderer = try FXSpriteRenderer(kit: kit, fragment: "sakuraCard") }

    func encode(_ ctx: FXContext, source: MTLTexture, target: MTLTexture, command: MTLCommandBuffer) throws {
        try renderer.encode(ctx, sprites: Self.scene(ctx), source: source, target: target, command: command)
    }

    enum Kind: Float { case petal = 0, blossom = 1, bud = 2, glitter = 3, twig = 4 }

    static func scene(_ ctx: FXContext) -> [FXSprite] {
        var out = [FXSprite]()
        guard ctx.ball.w > 0 else { return out }
        for t in ctx.recentTouches(within: 2.0) {
            sprig(ctx, t.index, t.time, t.age, main: true, &out)
            sprig(ctx, t.index, t.time, t.age, main: false, &out)
            burst(ctx, t.index, t.time, t.age, &out)
        }
        stream(ctx, &out)
        return out
    }

    static func blossomColor(_ seed: Int) -> SIMD4<Float> {
        let k = fxRandom(seed, 77)
        // Mostly cherry pink, some paler, a few deeper.
        let c: SIMD3<Float> = k < 0.2 ? SIMD3(1.0, 0.9, 0.93) : k > 0.88 ? SIMD3(0.95, 0.5, 0.68) : SIMD3(1.0, 0.74, 0.84)
        return SIMD4(c.x, c.y, c.z, 1)
    }

    /// A flowering sprig that grows out of the ball on a touch, blooms, then drifts and fades.
    static func sprig(_ ctx: FXContext, _ index: Int, _ t0: Float, _ age: Float, main: Bool, _ out: inout [FXSprite]) {
        let seed = 6100 + index * 173 + (main ? 0 : 61)
        func rnd(_ c: Int) -> Float { fxRandom(seed, c) }
        let b = ctx.sample(t0 + 0.02), r = b.z
        let v = ctx.velocity(t0 + 0.06)
        let axis: Float = (index % 2 == 0 ? -0.62 : Float.pi + 0.62) + (main ? 0 : Float.pi + 0.35 * (index % 2 == 0 ? 1 : -1))
        let dir = SIMD2(cos(axis), sin(axis)), perp = SIMD2(-dir.y, dir.x)
        let lengthMax = r * (main ? 3.4 + 0.6 * rnd(1) : 2.0 + 0.5 * rnd(1))
        let grow = 1 - pow(1 - min(1, age / 0.32), 3)
        let life: Float = 1.35
        let fade = 1 - fxSmooth(life * 0.55, life, age)
        guard fade > 0.01 else { return }
        // The whole sprig keeps a little of the ball's push, then sinks slowly.
        let drift = v * 0.18 * (1 - exp(-2 * age)) / 2 + SIMD2(0, r * 0.35 * age * age)
        let base = SIMD2(b.x, b.y) + dir * r * 0.92 + drift
        let bend = (rnd(2) - 0.5) * 1.4
        func point(_ s: Float) -> SIMD2<Float> {
            base + dir * lengthMax * s + perp * r * (bend * sin(s * 2.6) * s + 0.25 * sin(s * 7 + rnd(3) * 6) * s)
        }
        let z0 = (rnd(4) - 0.5) * r * 0.8
        // Main branch.
        let segments = 10
        let shown = grow
        for k in 0..<segments {
            let s0 = Float(k) / Float(segments) * shown, s1 = Float(k + 1) / Float(segments) * shown
            guard s1 > s0 + 0.001 else { continue }
            let w0 = r * (main ? 0.085 : 0.065) * (1 - 0.7 * s0 / max(shown, 0.01) * shown), w1 = r * (main ? 0.085 : 0.065) * (1 - 0.7 * s1)
            twig(point(s0), point(s1), w0, max(w1, r * 0.02), z: z0, fade: fade, seed: seed + k, &out)
        }
        // Side twigs, each ending in a blossom, plus blossoms and buds on the branch itself.
        let twigs = main ? 4 : 2
        for k in 0..<twigs {
            let s = 0.25 + 0.65 * (Float(k) + rnd(10 + k) * 0.5) / Float(twigs)
            guard shown > s else { continue }
            let local = min(1, (shown - s) / 0.25)
            let at = point(s)
            let side: Float = k % 2 == 0 ? 1 : -1
            let tdir = fxRotate(dir, side * (0.55 + 0.4 * rnd(20 + k)))
            let tl = r * (0.45 + 0.45 * rnd(30 + k)) * local
            let tip = at + tdir * tl
            twig(at, tip, r * 0.04, r * 0.018, z: z0, fade: fade, seed: seed + 50 + k, &out)
            blossom(tip, z: z0 + (rnd(40 + k) - 0.5) * r * 0.6, size: r * (0.46 + 0.16 * rnd(50 + k)), open: (age - 0.05 - s * 0.15) / 0.18,
                    fade: fade, seed: seed + 100 + k, ctx: ctx, &out)
        }
        let onBranch = main ? 9 : 5
        for k in 0..<onBranch {
            let s = 0.18 + 0.82 * (Float(k) + 0.3 + 0.4 * rnd(60 + k)) / Float(onBranch)
            guard shown > s else { continue }
            let at = point(s) + perp * r * 0.35 * (rnd(70 + k) - 0.5)
            let isBud = rnd(80 + k) < 0.3
            if isBud {
                let rot = simd_quatf(angle: atan2(dir.y, dir.x) + (rnd(90 + k) - 0.5) * 1.5 + .pi / 2, axis: SIMD3(0, 0, 1))
                let open = FXMotion.backOut((age - 0.1 - s * 0.25) / 0.2)
                out.append(.card(SIMD3(at.x, at.y, z0 + 2), size: r * 0.1 * open, aspect: 1.5, rotation: rot, kind: Kind.bud.rawValue,
                                 color: SIMD4(0.92, 0.42, 0.6, fade), extra: SIMD4(Float(seed + k), 0, 0, 0)))
            } else {
                blossom(at, z: z0 + (rnd(100 + k) - 0.5) * r, size: r * (0.36 + 0.2 * rnd(110 + k)), open: (age - 0.03 - s * 0.15) / 0.18,
                        fade: fade, seed: seed + 200 + k, ctx: ctx, &out)
            }
        }
        // Gold glitter strung along the branch, twinkling.
        for k in 0..<(main ? 40 : 20) {
            let s = rnd(300 + k)
            guard shown > s else { continue }
            let at = point(s) + perp * r * (rnd(320 + k) - 0.5) * 0.9 + dir * r * (rnd(340 + k) - 0.5) * 0.3
                + SIMD2(0, r * 0.25 * age * rnd(360 + k))
            let twinkle = 0.5 + 0.5 * sin(ctx.time * (9 + 7 * rnd(380 + k)) + rnd(400 + k) * 6)
            let k2 = fade * fxSmooth(s * 0.3, s * 0.3 + 0.08, age) * (0.35 + 0.65 * twinkle)
            out.append(.card(SIMD3(at.x, at.y, z0 + r), size: r * (0.05 + 0.07 * rnd(420 + k)), rotation: simd_quatf(angle: rnd(440 + k), axis: SIMD3(0, 0, 1)),
                             kind: Kind.glitter.rawValue, color: SIMD4(1, 0.84, 0.45, k2), extra: SIMD4(Float(seed + k), 0, 0, 0)))
        }
    }

    static func twig(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ wa: Float, _ wb: Float, z: Float, fade: Float, seed: Int, _ out: inout [FXSprite]) {
        let d = b - a, len = simd_length(d)
        guard len > 0.5 else { return }
        let mid = (a + b) / 2, half = len / 2 + max(wa, wb)
        let angle = atan2(d.y, d.x)
        let width = max(wa, wb) * 1.4
        out.append(.card(SIMD3(mid.x, mid.y, z - 1), size: half, aspect: width / half, rotation: simd_quatf(angle: angle, axis: SIMD3(0, 0, 1)),
                         kind: Kind.twig.rawValue, color: SIMD4(0.2, 0.11, 0.07, fade),
                         extra: SIMD4(Float(seed), wa / width, wb / width, (len / 2) / half)))
    }

    static func blossom(_ p: SIMD2<Float>, z: Float, size: Float, open: Float, fade: Float, seed: Int, ctx: FXContext, _ out: inout [FXSprite]) {
        guard open > 0 else { return }
        let o = FXMotion.backOut(min(1, open))
        func rnd(_ c: Int) -> Float { fxRandom(seed, c) }
        let rot = simd_quatf(angle: rnd(1) * 6.28 + ctx.time * (rnd(2) - 0.5) * 0.6, axis: SIMD3(0, 0, 1))
            * simd_quatf(angle: (rnd(3) - 0.5) * 1.1, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: (rnd(4) - 0.5) * 1.1, axis: SIMD3(0, 1, 0))
        var c = blossomColor(seed); c.w = fade
        out.append(.card(SIMD3(p.x, p.y, z), size: size * o, rotation: rot, kind: Kind.blossom.rawValue, color: c,
                         blur: fxBlur(z: z, ballRadius: ctx.ball.z, strength: 0.03), extra: SIMD4(Float(seed % 997), o, 0, 0)))
    }

    /// Touch burst: a fan of petals and whole blossoms, sparkles, and now and then a huge blurred blossom
    /// sweeping past close to the camera.
    static func burst(_ ctx: FXContext, _ index: Int, _ t0: Float, _ age: Float, _ out: inout [FXSprite]) {
        let seed = 8300 + index * 151
        let b = ctx.sample(t0 + 0.02), r = b.z
        let v = ctx.velocity(t0 + 0.06)
        let axis: Float = index % 2 == 0 ? -0.62 : Float.pi + 0.62
        for j in 0..<34 {
            func rnd(_ c: Int) -> Float { fxRandom(seed + j * 13, c) }
            let a = age - 0.03 * rnd(1)
            guard a > 0 else { continue }
            let angle = axis + (rnd(2) < 0.65 ? 0 : .pi) + (rnd(3) - 0.5) * 1.8
            let dir = SIMD2(cos(angle), sin(angle))
            let speed = r * (3 + 7 * rnd(4))
            let isBlossom = j < 5
            let z = (rnd(5) - 0.5) * r * 5
            let persp = fxPerspective(z: z, ballRadius: r)
            var p = SIMD2(b.x, b.y) + dir * r + (dir * speed + v * 0.3) * (1 - exp(-1.8 * a)) / 1.8
            p.y += r * 0.9 * a * a
            p.x += sin(a * 4 + rnd(6) * 6) * r * 0.3 * a
            let life: Float = 1.5 + 0.5 * rnd(7)
            let fade = fxSmooth(0, 0.05, a) * (1 - fxSmooth(life * 0.6, life, a))
            guard fade > 0.01 else { continue }
            let rot = simd_quatf(angle: rnd(8) * 6.28 + a * (rnd(9) - 0.5) * 4, axis: SIMD3(0, 0, 1))
                * simd_quatf(angle: a * (2 + 5 * rnd(10)) + rnd(11) * 6, axis: simd_normalize(SIMD3(1, rnd(12) - 0.5, 0)))
            var c = blossomColor(seed + j); c.w = fade
            let blur = fxBlur(z: z, ballRadius: r, strength: 0.035)
            if isBlossom {
                out.append(.card(SIMD3(p.x, p.y, z), size: r * (0.3 + 0.15 * rnd(13)) * persp, rotation: rot, kind: Kind.blossom.rawValue,
                                 color: c, blur: blur, extra: SIMD4(Float((seed + j) % 997), 1, 0, 0)))
            } else {
                out.append(.card(SIMD3(p.x, p.y, z), size: r * (0.08 + 0.08 * rnd(13)) * persp, aspect: 1.15, rotation: rot, kind: Kind.petal.rawValue,
                                 color: c, blur: blur, extra: SIMD4(Float((seed + j) % 997), 0, 0, 0)))
            }
        }
        for j in 0..<16 {
            func rnd(_ c: Int) -> Float { fxRandom(seed + 3000 + j * 7, c) }
            let a = age - 0.02 * rnd(1)
            guard a > 0, a < 0.9 else { continue }
            let angle = axis + (rnd(2) < 0.6 ? 0 : .pi) + (rnd(3) - 0.5) * 2
            let dir = SIMD2(cos(angle), sin(angle))
            let p = SIMD2(b.x, b.y) + dir * r + dir * r * (3 + 6 * rnd(4)) * (1 - exp(-3 * a)) / 3 + SIMD2(0, r * 0.4 * a * a)
            let k = (1 - fxSmooth(0.3, 0.9, a)) * (0.5 + 0.5 * sin(a * 30 + rnd(5) * 6))
            out.append(.card(SIMD3(p.x, p.y, r), size: r * (0.04 + 0.05 * rnd(6)), rotation: simd_quatf(angle: rnd(7), axis: SIMD3(0, 0, 1)),
                             kind: Kind.glitter.rawValue, color: SIMD4(1, 0.86, 0.5, k), extra: SIMD4(Float(seed + j), 0, 0, 0)))
        }
        // Close to the lens: one big soft blossom drifting through a lower corner.
        if fxRandom(seed, 9) < 0.55 {
            let side: Float = fxRandom(seed, 10) < 0.5 ? -1 : 1
            let z = r * 7.5
            let start = SIMD2(ctx.size.x * (side < 0 ? 0.1 : 0.9), b.y + r * (2.2 + 1.2 * fxRandom(seed, 11)))
            let p = start + SIMD2(-side * r * 1.2 * age, r * 0.6 * age)
            let fade = fxSmooth(0, 0.25, age) * (1 - fxSmooth(1.2, 1.9, age))
            if fade > 0.01 {
                var c = blossomColor(seed + 1); c.w = fade * 0.92
                out.append(.card(SIMD3(p.x, p.y, z), size: r * 0.42 * fxPerspective(z: z, ballRadius: r), rotation: simd_quatf(angle: age * 0.5 + fxRandom(seed, 12) * 6, axis: SIMD3(0, 0, 1)),
                                 kind: Kind.blossom.rawValue, color: c, blur: r * 0.42, extra: SIMD4(Float(seed % 997), 1, 0, 0)))
            }
        }
    }

    /// A steady light stream of petals peeling off the ball between touches.
    static func stream(_ ctx: FXContext, _ out: inout [FXSprite]) {
        let rate: Float = 30, life: Float = 1.8
        let last = Int(floor(ctx.time * rate)), first = max(0, Int(floor((ctx.time - life) * rate)))
        guard last > first else { return }
        for i in first...last {
            func rnd(_ c: Int) -> Float { fxRandom(77000 + i, c) }
            let birth = Float(i) / rate, a = ctx.time - birth
            guard a > 0, a < life else { continue }
            let b = ctx.sample(birth), r = b.z
            let v = ctx.velocity(birth)
            let angle = rnd(1) * 6.28
            let dir = SIMD2(cos(angle), sin(angle))
            let z = (rnd(2) - 0.5) * r * 4
            var p = SIMD2(b.x, b.y) + dir * r * 1.05 + (dir * r * (0.6 + 1.2 * rnd(3)) + v * 0.25) * (1 - exp(-1.5 * a)) / 1.5
            p += SIMD2(r * 0.5 * a + sin(a * 3 + rnd(4) * 6) * r * 0.25, r * 0.55 * a * a)
            let fade = fxSmooth(0, 0.1, a) * (1 - fxSmooth(life * 0.55, life, a)) * 0.95
            let rot = simd_quatf(angle: rnd(5) * 6.28 + a * (rnd(6) - 0.5) * 3, axis: SIMD3(0, 0, 1))
                * simd_quatf(angle: a * (2 + 4 * rnd(7)) + rnd(8) * 6, axis: simd_normalize(SIMD3(1, rnd(9) - 0.5, 0.2)))
            var c = blossomColor(77000 + i); c.w = fade
            out.append(.card(SIMD3(p.x, p.y, z), size: r * (0.07 + 0.07 * rnd(10)) * fxPerspective(z: z, ballRadius: r), aspect: 1.15, rotation: rot,
                             kind: Kind.petal.rawValue, color: c, blur: fxBlur(z: z, ballRadius: r, strength: 0.035), extra: SIMD4(Float(i % 997), 0, 0, 0)))
        }
    }
}

/// Small easing helpers shared by the rebuilt effects.
nonisolated enum FXMotion {
    static func backOut(_ x: Float) -> Float {
        let t = max(0, min(1, x)) - 1
        return 1 + t * t * (2.7 * t + 1.7)
    }
    static func easeOut(_ x: Float) -> Float { let t = max(0, min(1, x)); return 1 - (1 - t) * (1 - t) * (1 - t) }
}
