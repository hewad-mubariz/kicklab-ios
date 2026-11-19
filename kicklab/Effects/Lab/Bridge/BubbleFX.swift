// Copied from the Effects Lab (EffectLab/FX/BubbleFX.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import Metal
import simd

/// Bubble Burst, 2026-11-19: the owner asked to combine the current Water and Bubble effects.
/// The accepted Water motion splash (the one already shipped in the app) now fires on every touch,
/// and the existing iridescent bubbles drift around it and pop into water drops. More large bubbles
/// sit close to the camera, like the concept (effects-sheet-v1 panel 06).
/// Rendering reuses the lab's BubbleGPU (bubbles over the accepted water material) unchanged.
nonisolated final class BubbleFX: FXEffect {
    let gpu: BubbleGPU
    init(kit: FXKit) throws {
        gpu = try BubbleGPU(libraryURL: try fxLabLibrary("bubble"))
    }

    func encode(_ ctx: FXContext, source: MTLTexture, target: MTLTexture, command: MTLCommandBuffer) throws {
        // BubbleGPU commits its own work; the caller's buffer stays empty.
        try gpu.render(frame: Self.frame(ctx), source: source, target: target)
    }

    static func frame(_ ctx: FXContext) -> BubbleFrame {
        var frame = BubbleScene.frame(time: ctx.time, size: ctx.size, intensity: ctx.intensity, touches: ctx.touches, sample: ctx.sample)
        let water = WaterScene.frame(time: ctx.time, size: ctx.size, stage: .motion, intensity: ctx.intensity, light: true, source: true,
                                     touches: ctx.touches, sample: ctx.sample)
        frame.water = WaterFrame(uniforms: water.uniforms, parts: water.parts + frame.water.parts, surface: water.surface)
        frame.water.uniforms.options.w = Float(frame.water.parts.count)
        // Extra large bubbles near the lens on touches: they drift up past the ball and pop late.
        for t in ctx.recentTouches(within: 3.2) where t.index % 2 == 1 {
            let seed = 41_000 + t.index * 17
            let b = ctx.sample(t.time + 0.03), r = b.z
            let side: Float = fxRandom(seed, 1) < 0.5 ? -1 : 1
            let a = t.age
            let center = SIMD3(b.x + side * r * (1.6 + 0.8 * fxRandom(seed, 2)) + side * r * 0.4 * a,
                               b.y + r * (0.8 - 1.1 * a) + sin(a * 2.1) * r * 0.2, r * 2.6)
            let state = BubbleState(id: seed, birth: t.time, life: 2.6, age: a, center: center, velocity: SIMD3(side * r * 0.4, -r * 1.1, 0),
                                    radius: r * (1.25 + 0.4 * fxRandom(seed, 3)), phase: fxRandom(seed, 4) * 6.28)
            if a < 2.6 + BubbleScene.ruptureDuration { frame.bubbles.append(BubbleScene.sphere(state, intensity: ctx.intensity * b.w)) }
        }
        frame.bubbles.sort { $0.centerSize.z < $1.centerSize.z }
        return frame
    }
}
