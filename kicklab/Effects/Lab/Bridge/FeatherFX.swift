// Copied from the Effects Lab (EffectLab/FX/FeatherFX.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import Metal
import simd

/// Feather Sweep, rebuilt 2026-11-19 (the owner: "too basic").
/// Target: effects-sheet-v1 panel 09 — real feathers: a shaft, hundreds of fine barbs, split vanes,
/// fluffy down at the base. Two big hero feathers sweep out of the ball on each touch, a burst of
/// smaller white, brown-barred and dark feathers tumbles away, and down floats off between touches.
nonisolated final class FeatherFX: FXEffect {
    let renderer: FXSpriteRenderer
    init(kit: FXKit) throws { renderer = try FXSpriteRenderer(kit: kit, fragment: "featherCard") }

    func encode(_ ctx: FXContext, source: MTLTexture, target: MTLTexture, command: MTLCommandBuffer) throws {
        try renderer.encode(ctx, sprites: Self.scene(ctx), source: source, target: target, command: command)
    }

    enum Kind: Float { case feather = 0, down = 1 }
    /// Plumage: 0 white, 1 white with brown bars, 2 dark grey.
    static func plumage(_ seed: Int) -> Float {
        let k = fxRandom(seed, 91)
        return k < 0.55 ? 0 : k < 0.83 ? 1 : 2
    }

    static func scene(_ ctx: FXContext) -> [FXSprite] {
        var out = [FXSprite]()
        guard ctx.ball.w > 0 else { return out }
        for t in ctx.recentTouches(within: 2.4) { burst(ctx, t.index, t.time, t.age, &out) }
        drift(ctx, &out)
        return out
    }

    /// A feather card: `length` is the half length in px, the shaft runs along the card's v axis.
    static func feather(_ p: SIMD3<Float>, length: Float, width: Float, rotation: simd_quatf, seed: Int, alpha: Float,
                        blur: Float, kind: Kind = .feather) -> FXSprite {
        let aspect = length / width
        return .card(p, size: width, aspect: aspect, rotation: rotation, kind: kind.rawValue, color: SIMD4(1, 1, 1, alpha), blur: blur,
                     extra: SIMD4(Float(seed % 991), aspect, plumage(seed), fxRandom(seed, 92)))
    }

    static func burst(_ ctx: FXContext, _ index: Int, _ t0: Float, _ age: Float, _ out: inout [FXSprite]) {
        let seed = 5200 + index * 199
        let b = ctx.sample(t0 + 0.02), r = b.z
        let v = ctx.velocity(t0 + 0.06)
        let axis: Float = index % 2 == 0 ? -0.6 : Float.pi + 0.6
        let center = SIMD2(b.x, b.y)
        let count = 22
        for j in 0..<count {
            func rnd(_ c: Int) -> Float { fxRandom(seed + j * 23, c) }
            let hero = j < 2
            let small = j >= 12
            let a = age - 0.02 * rnd(1)
            guard a > 0 else { continue }
            let lobe: Float = hero ? (j == 0 ? 0 : .pi) : (rnd(2) < 0.62 ? 0 : .pi)
            let angle = axis + lobe + (rnd(3) - 0.5) * (hero ? 0.4 : 1.6)
            let dir = SIMD2(cos(angle), sin(angle))
            let speed = r * (hero ? 3.2 + 1.2 * rnd(4) : small ? 5 + 8 * rnd(4) : 3.5 + 5 * rnd(4))
            // Feathers stop quickly in the air (high drag), then float down swaying.
            let drag: Float = hero ? 3.0 : 3.6
            let travel = (1 - exp(-drag * a)) / drag
            let fallSpeed = r * (hero ? 0.55 : 0.8 + 0.5 * rnd(5))
            let settle = max(0, a - 0.25)
            var p = center + dir * r * (hero ? 1.2 : 1.0) + (dir * speed + v * 0.3) * travel
            p.y += fallSpeed * settle
            let sway = sin(settle * (2.2 + 1.5 * rnd(6)) + rnd(7) * 6)
            p.x += sway * r * (hero ? 0.35 : 0.5) * min(1, settle * 2)
            let z = hero ? r * (0.3 + 0.5 * rnd(8)) * (j == 0 ? 1 : -1) : (rnd(8) - 0.5) * r * 3
            let persp = fxPerspective(z: z, ballRadius: r)
            let length = r * (hero ? 1.6 + 0.4 * rnd(9) : small ? 0.25 + 0.2 * rnd(9) : 0.45 + 0.35 * rnd(9)) * persp
            let width = length * (0.27 + 0.08 * rnd(10))
            // Heading: shaft points away from the ball at first, then rocks like a falling feather.
            let heading = angle + (rnd(11) - 0.5) * (hero ? 0.5 : 2.6) + sway * 0.35 + a * (rnd(12) - 0.5) * (hero ? 0.6 : 3)
            let roll = (rnd(13) - 0.5) * 0.6 + sin(a * (3 + 4 * rnd(14))) * (hero ? 0.2 : 0.4)
            let rot = simd_quatf(angle: heading - .pi / 2, axis: SIMD3(0, 0, 1)) * simd_quatf(angle: roll, axis: SIMD3(0, 1, 0))
                * simd_quatf(angle: (rnd(15) - 0.5) * 0.6, axis: SIMD3(1, 0, 0))
            let life: Float = hero ? 2.0 : 1.4 + 0.8 * rnd(16)
            let fade = fxSmooth(0, 0.06, a) * (1 - fxSmooth(life * 0.6, life, a)) * ctx.intensity
            guard fade > 0.01 else { continue }
            let grow = 0.55 + 0.45 * FXMotion.easeOut(a / 0.18)
            let blur = fxBlur(z: z, ballRadius: r, strength: 0.03)
            out.append(feather(SIMD3(p.x, p.y, z), length: length * grow, width: width * grow, rotation: rot, seed: seed + j * 23, alpha: fade, blur: blur))
        }
        // Down: fluffy plumes puffed out with the burst.
        for j in 0..<10 {
            func rnd(_ c: Int) -> Float { fxRandom(seed + 7000 + j * 11, c) }
            let a = age - 0.03 * rnd(1)
            guard a > 0 else { continue }
            let angle = axis + (rnd(2) < 0.6 ? 0 : .pi) + (rnd(3) - 0.5) * 2.2
            let dir = SIMD2(cos(angle), sin(angle))
            var p = center + dir * r + (dir * r * (3 + 4 * rnd(4)) + v * 0.25) * (1 - exp(-4 * a)) / 4
            p += SIMD2(sin(a * 2 + rnd(5) * 6) * r * 0.3, r * 0.35 * a)
            let z = (rnd(6) - 0.5) * r * 5
            let fade = fxSmooth(0, 0.08, a) * (1 - fxSmooth(1.2, 2.0, a)) * ctx.intensity
            guard fade > 0.01 else { continue }
            let size = r * (0.16 + 0.14 * rnd(7)) * fxPerspective(z: z, ballRadius: r)
            out.append(feather(SIMD3(p.x, p.y, z), length: size, width: size, rotation: simd_quatf(angle: rnd(8) * 6 + a * (rnd(9) - 0.5) * 2, axis: SIMD3(0, 0, 1)),
                               seed: seed + 7000 + j, alpha: fade * 0.9, blur: fxBlur(z: z, ballRadius: r, strength: 0.03), kind: .down))
        }
    }

    /// Between touches: a slow trickle of small feathers and down drifting off the ball.
    static func drift(_ ctx: FXContext, _ out: inout [FXSprite]) {
        let rate: Float = 7, life: Float = 2.4
        let last = Int(floor(ctx.time * rate)), first = max(0, Int(floor((ctx.time - life) * rate)))
        guard last > first else { return }
        for i in first...last {
            func rnd(_ c: Int) -> Float { fxRandom(64000 + i, c) }
            let birth = Float(i) / rate + rnd(1) / rate, a = ctx.time - birth
            guard a > 0, a < life else { continue }
            let b = ctx.sample(birth), r = b.z
            let angle = rnd(2) * 6.28
            let dir = SIMD2(cos(angle), sin(angle))
            var p = SIMD2(b.x, b.y) + dir * r * 1.1 + dir * r * 0.8 * (1 - exp(-2 * a)) / 2
            p += SIMD2(sin(a * 2.4 + rnd(3) * 6) * r * 0.35, r * 0.45 * a)
            let z = (rnd(4) - 0.5) * r * 4
            let fade = fxSmooth(0, 0.2, a) * (1 - fxSmooth(life * 0.6, life, a)) * ctx.intensity
            let isDown = rnd(5) < 0.45
            let persp = fxPerspective(z: z, ballRadius: r)
            let length = r * (isDown ? 0.14 : 0.3 + 0.2 * rnd(6)) * persp
            let rot = simd_quatf(angle: rnd(7) * 6.28 + sin(a * 2.4) * 0.5, axis: SIMD3(0, 0, 1)) * simd_quatf(angle: sin(a * 3 + rnd(8) * 6) * 0.35, axis: SIMD3(0, 1, 0))
            out.append(feather(SIMD3(p.x, p.y, z), length: length, width: isDown ? length : length * 0.3, rotation: rot, seed: 64000 + i, alpha: fade * 0.9,
                               blur: fxBlur(z: z, ballRadius: r, strength: 0.03), kind: isDown ? .down : .feather))
        }
    }
}
