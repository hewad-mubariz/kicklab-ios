// Copied from the Effects Lab (EffectLab/FX/RiftFX.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import Metal
import simd

/// Rift Break, rebuilt 2026-11-19 (the owner: "kinda too much bad").
/// Target: effects-sheet-v1 panel 10 — glossy black obsidian shards burst out of the ball on a touch,
/// faceted like broken volcanic glass, with teal light leaking from their edges, a flash of light at
/// the contact and a spray of small chips and sparks. Edges and sparks bloom.
nonisolated final class RiftFX: FXEffect {
    let kit: FXKit
    init(kit: FXKit) throws {
        self.kit = kit
        _ = try kit.pipeline("riftVertex", "riftFragment", format: .rgba16Float, blend: .none, samples: 4, depth: true)
        _ = try kit.pipeline("riftVertex", "riftGlowFragment", format: .rgba16Float, blend: .none, samples: 1, depth: true)
        _ = try kit.pipeline("riftSparkVertex", "riftSparkFragment", format: .rgba16Float, blend: .additive)
        _ = try kit.pipeline("fxCompositeVertex", "riftComposite", blend: .none)
    }

    struct Vertex { var position: SIMD4<Float>; var normal: SIMD4<Float>; var extra: SIMD4<Float> }  // extra: edge, glow, fade, side
    struct Spark { var p: SIMD4<Float>; var c: SIMD4<Float> }   // x, y, size, stretch angle | brightness, length, -, -

    func encode(_ ctx: FXContext, source: MTLTexture, target: MTLTexture, command: MTLCommandBuffer) throws {
        let (mesh, sparks) = Self.scene(ctx)
        guard ctx.intensity > 0, ctx.ball.w > 0, let vertices = kit.buffer(mesh) else {
            kit.passthrough(command, source: source, target: target); return
        }
        let w = source.width, h = source.height
        let msaa = kit.texture("rift.msaa", w, h, .rgba16Float, samples: 4)
        let layer = kit.texture("rift.layer", w, h, .rgba16Float)
        let depthMS = kit.texture("rift.depth4", w, h, .depth32Float, samples: 4)
        let depth = kit.texture("rift.depth", w, h, .depth32Float)
        let glow = kit.texture("rift.glow", w / 2, h / 2, .rgba16Float)
        let glowFull = kit.texture("rift.glowFull", w, h, .rgba16Float)
        let blurA = kit.texture("rift.blurA", w / 2, h / 2, .rgba16Float)
        let blurB = kit.texture("rift.blurB", w / 4, h / 4, .rgba16Float)
        let blurC = kit.texture("rift.blurC", w / 4, h / 4, .rgba16Float)
        var u = kit.uniforms(ctx)
        let depthState = kit.device.makeDepthStencilState(descriptor: {
            let d = MTLDepthStencilDescriptor(); d.depthCompareFunction = .less; d.isDepthWriteEnabled = true; return d
        }())!
        // 1. Shards with depth, 4× multisampled.
        try kit.pass(command, msaa, resolve: layer, depth: depthMS) { e in
            e.setRenderPipelineState(try kit.pipeline("riftVertex", "riftFragment", format: .rgba16Float, blend: .none, samples: 4, depth: true))
            e.setDepthStencilState(depthState); e.setCullMode(.none)
            e.setVertexBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
            e.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
            e.setVertexBuffer(vertices, offset: 0, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.count)
        }
        // 2. What glows: shard edges (depth tested, so hidden edges don't glow) plus sparks and the flash.
        try kit.pass(command, glowFull, depth: depth) { e in
            e.setRenderPipelineState(try kit.pipeline("riftVertex", "riftGlowFragment", format: .rgba16Float, blend: .none, samples: 1, depth: true))
            e.setDepthStencilState(depthState); e.setCullMode(.none)
            e.setVertexBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
            e.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
            e.setVertexBuffer(vertices, offset: 0, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.count)
        }
        if let sparkBuffer = kit.buffer(sparks) {
            try kit.pass(command, glowFull, clear: false) { e in
                e.setRenderPipelineState(try kit.pipeline("riftSparkVertex", "riftSparkFragment", format: .rgba16Float, blend: .additive))
                e.setVertexBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
                e.setVertexBuffer(sparkBuffer, offset: 0, index: 1)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: sparks.count)
            }
        }
        // 3. Bloom: a tight and a wide blur of the glow.
        kit.scale(command, glowFull, glow)
        kit.blur(command, glow, blurA, sigma: 3)
        kit.scale(command, glow, blurB)
        kit.blur(command, blurB, blurC, sigma: 9)
        try kit.pass(command, target) { e in
            e.setRenderPipelineState(try kit.pipeline("fxCompositeVertex", "riftComposite", blend: .none))
            e.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
            e.setFragmentTexture(source, index: 0)
            e.setFragmentTexture(layer, index: 1)
            e.setFragmentTexture(glowFull, index: 2)
            e.setFragmentTexture(blurA, index: 3)
            e.setFragmentTexture(blurC, index: 4)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    // MARK: Scene

    static func scene(_ ctx: FXContext) -> ([Vertex], [Spark]) {
        var mesh = [Vertex](), sparks = [Spark]()
        guard ctx.ball.w > 0 else { return (mesh, sparks) }
        for t in ctx.recentTouches(within: 1.6) { burst(ctx, t.index, t.time, t.age, &mesh, &sparks) }
        return (mesh, sparks)
    }

    static func burst(_ ctx: FXContext, _ index: Int, _ t0: Float, _ age: Float, _ mesh: inout [Vertex], _ sparks: inout [Spark]) {
        let seed = 4400 + index * 211
        let b = ctx.sample(t0 + 0.015), r = b.z
        let v = ctx.velocity(t0 + 0.06)
        let axis: Float = index % 2 == 0 ? -0.5 : Float.pi + 0.5
        let center = SIMD2(b.x, b.y)

        // Flash of light where the ball broke through.
        if age < 0.35 {
            let k = (1 - fxSmooth(0.02, 0.35, age)) * fxSmooth(0, 0.02, age)
            let ballNow = ctx.sample(t0 + age)
            sparks.append(Spark(p: SIMD4(ballNow.x, ballNow.y + r * 0.4, r * (1.6 + 1.4 * age / 0.35), 0), c: SIMD4(2.2 * k, 0, 1, 0)))
        }

        // Big shards and small chips.
        let count = 46
        for j in 0..<count {
            func rnd(_ c: Int) -> Float { fxRandom(seed + j * 29, c) }
            let big = j < 7
            let a = age - 0.012 * rnd(1)
            guard a > 0 else { continue }
            let lobe: Float = rnd(2) < (big ? 0.62 : 0.55) ? 0 : .pi
            let angle = axis + lobe + (rnd(3) - 0.5) * (big ? 1.3 : 2.2)
            let dir = SIMD2(cos(angle), sin(angle))
            let speed = r * (big ? 3.2 + 4.0 * rnd(4) : 5 + 9 * rnd(4))
            let drag: Float = big ? 2.6 : 2.0
            let travel = (1 - exp(-drag * a)) / drag
            let gravity = SIMD2<Float>(0, r * (big ? 3 : 9))
            let pos = center + dir * r * (big ? 0.9 : 1.0) + (dir * speed + v * 0.45) * travel + gravity * 0.5 * a * a
            let size = big ? r * (0.8 + 0.55 * rnd(5)) : r * (0.1 + 0.22 * pow(rnd(5), 1.6))
            let life: Float = big ? 1.15 + 0.35 * rnd(6) : 0.7 + 0.5 * rnd(6)
            let fade = 1 - fxSmooth(life * 0.6, life, a)
            guard fade > 0.01 else { continue }
            let grow = 0.35 + 0.65 * fxSmooth(0, 0.08, a)
            // Tumbling: random axis, spin slows with drag.
            let spinAxis = simd_normalize(SIMD3(rnd(7) - 0.5, rnd(8) - 0.5, rnd(9) - 0.5) + SIMD3(0, 0, 0.001))
            let spin = (big ? 2.5 + 3 * rnd(10) : 6 + 10 * rnd(10)) * travel
            let start = simd_quatf(angle: rnd(11) * 6.28, axis: simd_normalize(SIMD3(rnd(12) - 0.5, rnd(13) - 0.5, rnd(14) - 0.5) + SIMD3(0.001, 0, 0)))
            let rot = simd_quatf(angle: spin, axis: spinAxis) * start
            let z = (rnd(15) - 0.5) * r * 3
            let glow = (big ? 1.0 : 0.35) * (0.55 + 0.45 * (1 - fxSmooth(0.1, 0.9, a)))
            shard(&mesh, seed: seed + j * 29, center: SIMD3(pos.x, pos.y, z), size: size * grow, rotation: rot,
                  elongation: big ? 1.4 + 0.7 * rnd(16) : 1.1 + 0.5 * rnd(16), facets: big ? 5 : 4, glow: glow, fade: fade * ctx.intensity)
        }

        // Teal sparks and dust streaking out.
        for j in 0..<40 {
            func rnd(_ c: Int) -> Float { fxRandom(seed + 9000 + j * 7, c) }
            let a = age - 0.02 * rnd(1)
            guard a > 0 else { continue }
            let angle = axis + (rnd(2) < 0.6 ? 0 : .pi) + (rnd(3) - 0.5) * 2.4
            let dir = SIMD2(cos(angle), sin(angle))
            let speed = r * (6 + 14 * rnd(4))
            let p = center + dir * r + (dir * speed + v * 0.4) * (1 - exp(-2.6 * a)) / 2.6
            let vel = dir * speed * exp(-2.6 * a) + v * 0.4
            let life: Float = 0.35 + 0.5 * rnd(5)
            let k = (1 - fxSmooth(life * 0.4, life, a))
            guard k > 0.01 else { continue }
            let len = min(r * 0.9, simd_length(vel) * 0.03)
            sparks.append(Spark(p: SIMD4(p.x, p.y, r * (0.025 + 0.03 * rnd(6)), atan2(vel.y, vel.x)), c: SIMD4(k * (0.8 + 1.2 * rnd(7)), len, 0, 0)))
        }
    }

    /// One faceted shard: an irregular polygon, extruded, with an off-centre ridge on both faces so each
    /// face breaks into flat facets (that is what makes it read as broken glass).
    static func shard(_ mesh: inout [Vertex], seed: Int, center: SIMD3<Float>, size: Float, rotation: simd_quatf,
                      elongation: Float, facets: Int, glow: Float, fade: Float) {
        var rim = [SIMD2<Float>]()
        for k in 0..<facets {
            let a = (Float(k) + 0.6 * (fxRandom(seed, 100 + k) - 0.5)) / Float(facets) * 2 * .pi
            var rr = 0.55 + 0.35 * fxRandom(seed, 120 + k)
            if k == 0 { rr = 1.0 }          // a long sharp tip
            rim.append(SIMD2(cos(a) * rr * elongation, sin(a) * rr) * 0.6)
        }
        let thickness: Float = 0.16 + 0.12 * fxRandom(seed, 140)
        let apex = SIMD2(fxRandom(seed, 141) - 0.5, fxRandom(seed, 142) - 0.5) * 0.4
        let top = SIMD3(apex.x, apex.y, thickness * 0.5 + 0.12 + 0.1 * fxRandom(seed, 143))
        let bottom = SIMD3(-apex.x * 0.6, -apex.y * 0.6, -thickness * 0.5 - 0.06)
        func world(_ p: SIMD3<Float>) -> SIMD3<Float> { center + rotation.act(p) * size }
        func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ ea: Float, _ eb: Float, _ ec: Float, side: Float) {
            let wa = world(a), wb = world(b), wc = world(c)
            var n = simd_normalize(simd_cross(wb - wa, wc - wa))
            let mid = (wa + wb + wc) / 3
            if simd_dot(n, mid - center) < 0 { n = -n }
            for (p, e) in [(wa, ea), (wb, eb), (wc, ec)] {
                mesh.append(Vertex(position: SIMD4(p.x, p.y, p.z, size), normal: SIMD4(n.x, n.y, n.z, side), extra: SIMD4(e, glow, fade, Float(seed % 1000) / 1000)))
            }
        }
        let n = rim.count
        for k in 0..<n {
            let a2 = rim[k], b2 = rim[(k + 1) % n]
            let at = SIMD3(a2.x, a2.y, thickness * 0.5), bt = SIMD3(b2.x, b2.y, thickness * 0.5)
            let ab = SIMD3(a2.x, a2.y, -thickness * 0.5), bb = SIMD3(b2.x, b2.y, -thickness * 0.5)
            tri(top, at, bt, 1, 0, 0, side: 0)
            tri(bottom, bb, ab, 1, 0, 0, side: 0)
            tri(at, ab, bb, 0, 1, 1, side: 1)
            tri(at, bb, bt, 0, 1, 0, side: 1)
        }
    }
}
