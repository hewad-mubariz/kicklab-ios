// Copied from the Effects Lab (EffectLab/FX/InkFX.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import Metal
import simd

/// Ink Bloom, rebuilt 2026-11-19 (the owner: "too basic, less context and details on texture").
/// Target: effects-sheet-v1 panel 01 — ink smoke billowing out of the ball: a dark violet body with
/// glowing cyan wisps and fine curling filaments, plus glossy black ink drops splattered on each touch.
/// Every smoke particle is advected through a swirling flow field from its birth to the playhead on the
/// GPU, so the picture is still a pure function of time (scrub-safe) while it moves like real smoke.
nonisolated final class InkFX: FXEffect {
    let kit: FXKit
    init(kit: FXKit) throws {
        self.kit = kit
        _ = try kit.compute("inkAdvect")
        _ = try kit.pipeline("inkSplatVertex", "inkSplatFragment", format: .rgba16Float, blend: .additive)
        _ = try kit.pipeline("fxCompositeVertex", "inkComposite", blend: .none)
        _ = try kit.pipeline("inkDropVertex", "inkDropFragment", blend: .premultiplied)
    }

    struct Particle { var start: SIMD4<Float>; var velocity: SIMD4<Float> }  // x, y, birth, life | vx, vy, seed, hue
    struct Drop { var p: SIMD4<Float> }                                   // x, y, radius, alpha

    func encode(_ ctx: FXContext, source: MTLTexture, target: MTLTexture, command: MTLCommandBuffer) throws {
        let (particles, drops) = Self.scene(ctx)
        guard ctx.intensity > 0, ctx.ball.w > 0, let input = kit.buffer(particles) else {
            kit.passthrough(command, source: source, target: target); return
        }
        let w = source.width, h = source.height
        let positions = kit.device.makeBuffer(length: particles.count * 16, options: .storageModePrivate)!
        let motion = kit.device.makeBuffer(length: particles.count * 16, options: .storageModePrivate)!
        var u = kit.uniforms(ctx, SIMD4(Float(particles.count), 0, 0, 0))
        let c = command.makeComputeCommandEncoder()!
        let advect = try kit.compute("inkAdvect")
        c.setComputePipelineState(advect)
        c.setBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
        c.setBuffer(input, offset: 0, index: 1)
        c.setBuffer(positions, offset: 0, index: 2)
        c.setBuffer(motion, offset: 0, index: 3)
        c.dispatchThreads(MTLSize(width: particles.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        c.endEncoding()
        // Density at half resolution (smoke is soft) and a softer copy for lighting.
        let density = kit.texture("ink.density", w, h, .rgba16Float)
        let soft = kit.texture("ink.soft", w / 2, h / 2, .rgba16Float)
        let half = kit.texture("ink.half", w / 2, h / 2, .rgba16Float)
        try kit.pass(command, density) { e in
            e.setRenderPipelineState(try kit.pipeline("inkSplatVertex", "inkSplatFragment", format: .rgba16Float, blend: .additive))
            e.setVertexBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
            e.setVertexBuffer(positions, offset: 0, index: 1)
            e.setVertexBuffer(input, offset: 0, index: 2)
            e.setVertexBuffer(motion, offset: 0, index: 3)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: particles.count)
        }
        kit.scale(command, density, half)
        kit.blur(command, half, soft, sigma: 3)
        try kit.pass(command, target) { e in
            e.setRenderPipelineState(try kit.pipeline("fxCompositeVertex", "inkComposite", blend: .none))
            e.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
            e.setFragmentTexture(source, index: 0)
            e.setFragmentTexture(density, index: 1)
            e.setFragmentTexture(soft, index: 2)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        if let dropBuffer = kit.buffer(drops) {
            try kit.pass(command, target, clear: false) { e in
                e.setRenderPipelineState(try kit.pipeline("inkDropVertex", "inkDropFragment", blend: .premultiplied))
                e.setVertexBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
                e.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
                e.setVertexBuffer(dropBuffer, offset: 0, index: 1)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: drops.count)
            }
        }
    }

    static func scene(_ ctx: FXContext) -> ([Particle], [Drop]) {
        var particles = [Particle](), drops = [Drop]()
        guard ctx.ball.w > 0 else { return (particles, drops) }
        particles.reserveCapacity(40000)
        // A steady plume peeling off the ball's trailing side.
        let rate: Float = 9000, life: Float = 1.25
        let last = Int(floor(ctx.time * rate)), first = max(0, Int(floor((ctx.time - life) * rate)))
        if last > first {
            for i in first...last {
                let birth = Float(i) / rate
                let b = ctx.sample(birth), r = b.z
                let v = ctx.velocity(birth), speed = simd_length(v)
                let back = speed > 1 ? -v / speed : SIMD2<Float>(0, 1)
                let a = fxRandom(i, 1) * 6.28
                let around = SIMD2(cos(a), sin(a))
                // Most ink leaves from the trailing half of the ball.
                let dir = simd_normalize(around + back * 0.9)
                let p = SIMD2(b.x, b.y) + dir * r * (0.95 + 0.1 * fxRandom(i, 2))
                let vel = dir * r * (0.4 + 0.6 * fxRandom(i, 3)) + v * 0.15
                let hue = fxSmooth(0.35, 0.65, fxNoiseCPU(birth * 2.2))
                let strength = 0.35 + 0.65 * fxSmooth(r * 1.5, r * 6, speed)
                particles.append(Particle(start: SIMD4(p.x, p.y, birth, life * (0.7 + 0.3 * fxRandom(i, 4))),
                                          velocity: SIMD4(vel.x, vel.y, Float(i % 100_000) + strength * 0.5, hue)))
            }
        }
        // Touch: a big bloom thrown out along a diagonal, and black ink drops.
        for t in ctx.recentTouches(within: 1.6) {
            let b = ctx.sample(t.time + 0.015), r = b.z
            let v = ctx.velocity(t.time + 0.06)
            let axis: Float = t.index % 2 == 0 ? -0.5 : Float.pi + 0.5
            let n = 22000
            for j in 0..<n {
                let seed = 500_000 + t.index * 20_000 + j
                let birth = t.time + 0.12 * fxRandom(seed, 1) * fxRandom(seed, 9)
                guard birth <= ctx.time else { continue }
                let lobe: Float = fxRandom(seed, 2) < 0.6 ? 0 : .pi
                let ang = axis + lobe + (fxRandom(seed, 3) - 0.5) * 1.5
                let dir = SIMD2(cos(ang), sin(ang))
                let p = SIMD2(b.x, b.y) + dir * r * 0.95 + SIMD2(fxRandom(seed, 4) - 0.5, fxRandom(seed, 5) - 0.5) * r * 0.3
                let vel = dir * r * (2.5 + 7 * pow(fxRandom(seed, 6), 1.5)) + v * 0.35
                let hue: Float = fxRandom(seed, 7) < (lobe == 0 ? 0.55 : 0.35) ? 1 : 0
                particles.append(Particle(start: SIMD4(p.x, p.y, birth, 1.15 + 0.4 * fxRandom(seed, 8)),
                                          velocity: SIMD4(vel.x, vel.y, Float(seed % 100_000) + 0.5, hue)))
            }
            for j in 0..<26 {
                func rnd(_ c: Int) -> Float { fxRandom(900_000 + t.index * 131 + j * 7, c) }
                let a = t.age - 0.03 * rnd(1)
                guard a > 0 else { continue }
                let ang = axis + (rnd(2) < 0.65 ? 0 : .pi) + (rnd(3) - 0.5) * 2.2
                let dir = SIMD2(cos(ang), sin(ang))
                let speed = r * (5 + 11 * rnd(4))
                let p = SIMD2(b.x, b.y) + dir * r + (dir * speed + v * 0.4) * (1 - exp(-1.6 * a)) / 1.6 + SIMD2(0, 0.5 * r * 22 * a * a)
                let fade = 1 - fxSmooth(0.7, 1.2, a)
                let size = r * (rnd(5) < 0.2 ? 0.1 + 0.08 * rnd(6) : 0.025 + 0.05 * rnd(6))
                drops.append(Drop(p: SIMD4(p.x, p.y, size, fade * ctx.intensity)))
            }
        }
        return (particles, drops)
    }
}

/// Smooth 1D value noise on the CPU (for slowly changing choices like the ink colour of a stream).
nonisolated func fxNoiseCPU(_ x: Float) -> Float {
    let i = floor(x), f = x - i, u = f * f * (3 - 2 * f)
    return fxRandom(Int(i) &+ 1_000_003, 0) * (1 - u) + fxRandom(Int(i) &+ 1_000_004, 0) * u
}
