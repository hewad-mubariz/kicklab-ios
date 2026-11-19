// Copied from the Effects Lab (EffectLab/FX/KoiFX.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import Metal
import simd

/// Koi Spirit, 2026-11-19 pass (the owner: "kind of too basic").
/// Target: effects-sheet-v1 panel 08 — two koi with long, flowing, see-through veil fins that trail
/// behind them like spirit wisps. The lab's koi bodies are kept (KoiGPU, larger now) and every fish gets
/// veil streamers: fine strands that follow where its tail has been, fan out and ripple, plus a soft
/// wide veil underneath them. Touches make the fish surge (already in the koi pose) and the veils flare.
nonisolated final class KoiFX: FXEffect {
    let kit: FXKit
    let gpu: KoiGPU
    let lines: FXLineRenderer
    let queue: MTLCommandQueue
    init(kit: FXKit) throws {
        self.kit = kit
        queue = kit.device.makeCommandQueue()!
        gpu = try KoiGPU(libraryURL: try fxLabLibrary("koi"))
        lines = try FXLineRenderer(kit: kit)
    }

    func encode(_ ctx: FXContext, source: MTLTexture, target: MTLTexture, command: MTLCommandBuffer) throws {
        let fishLayer = kit.texture("koi.fish", source.width, source.height, .bgra8Unorm)
        let frame = KoiScene.frame(time: ctx.time, size: ctx.size, intensity: ctx.intensity, touches: ctx.touches, sample: ctx.sample)
        // Veils go under the fish: draw them on the source first, then the fish over them.
        // KoiGPU commits its own work, so this effect runs its passes on its own queue in order.
        let under = kit.texture("koi.under", source.width, source.height, .bgra8Unorm)
        let first = queue.makeCommandBuffer()!
        kit.passthrough(first, source: source, target: under)
        try lines.encode(ctx, strokes: Self.veils(ctx, wide: true), target: under, command: first)
        first.commit(); first.waitUntilCompleted()
        try gpu.render(frame: frame, source: under, target: fishLayer)
        let finish = queue.makeCommandBuffer()!
        kit.passthrough(finish, source: fishLayer, target: target)
        try lines.encode(ctx, strokes: Self.veils(ctx, wide: false), target: target, command: finish)
        finish.commit(); finish.waitUntilCompleted()
    }

    /// Fine strands (wide = false) or the soft veil body under them (wide = true).
    static func veils(_ ctx: FXContext, wide: Bool) -> FXStrokes {
        var strokes = FXStrokes()
        guard ctx.ball.w > 0 else { return strokes }
        let r = ctx.ball.z
        let flare = ctx.recentTouches(within: 0.8).map { exp(-$0.age * 4) * fxSmooth(0, 0.05, $0.age) }.reduce(0, +)
        for id in 0..<2 {
            let tint: SIMD3<Float> = id == 0 ? SIMD3(1.0, 0.93, 0.88) : SIMD3(0.78, 1.0, 0.93)
            let steps = 22, dt: Float = 0.03
            // Where the tail root has been over the last ~0.65 s.
            var trail = [SIMD2<Float>](), dirs = [SIMD2<Float>](), sides = [SIMD2<Float>]()
            for k in 0..<steps {
                let t = max(0, ctx.time - Float(k) * dt)
                let f = KoiScene.pose(id: id, time: t, touches: ctx.touches, sample: ctx.sample)
                let a = KoiScene.tailAnchor(f)
                trail.append(SIMD2(a.root.x, a.root.y))
                dirs.append(simd_normalize(SIMD2(a.direction.x, a.direction.y) + SIMD2(0.0001, 0)))
                sides.append(simd_normalize(SIMD2(a.side.x, a.side.y) + SIMD2(0, 0.0001)))
            }
            let fishSize = KoiScene.pose(id: id, time: ctx.time, touches: ctx.touches, sample: ctx.sample).size
            let strands = wide ? 5 : 16
            for s in 0..<strands {
                let lane = Float(s) / Float(strands - 1) * 2 - 1          // -1…1 across the tail
                let phase = Float(s) * 1.7 + Float(id) * 3
                let reach = wide ? 1 : 0.45 + 0.55 * fxRandom(s * 7 + id * 131, 1)     // strands end at different lengths
                let curl = (fxRandom(s * 7 + id * 131, 2) - 0.5) * 2
                var pts = [SIMD2<Float>](), widths = [Float](), colors = [SIMD4<Float>]()
                for k in 0..<steps {
                    let u = Float(k) / Float(steps - 1)
                    // Strands start on the tail fork and fan out the further back they are.
                    let spread = fishSize * (0.12 + 0.55 * u + 0.25 * flare * u) * lane
                    let ripple = sin(u * 7 - ctx.time * 5.5 + phase) * fishSize * 0.09 * u + curl * fishSize * 0.35 * u * u * u
                    let back = dirs[k] * fishSize * 0.25 * u
                    let p = trail[k] + sides[k] * (spread + ripple) + back
                    pts.append(p)
                    let fade = max(0, 1 - u / reach) * fxSmooth(0, 0.08, u + 0.04)
                    if wide {
                        widths.append(r * (0.1 + 0.18 * u))
                        colors.append(SIMD4(tint.x, tint.y, tint.z, 0.1 * fade * ctx.intensity))
                    } else {
                        widths.append(max(0.5, (1.4 - 0.9 * u) * (abs(lane) > 0.8 ? 1.3 : 0.9)))
                        colors.append(SIMD4(tint.x, tint.y, tint.z, (0.5 + 0.25 * flare) * fade * ctx.intensity))
                    }
                }
                strokes.stroke(pts, widths: widths, colors: colors)
            }
            if wide { continue }
            // Long pectoral wisps from the body, curling back.
            let now = KoiScene.pose(id: id, time: ctx.time, touches: ctx.touches, sample: ctx.sample)
            let forward = SIMD2(cos(now.heading), sin(now.heading))
            for side in [Float(1), -1] {
                for j in 0..<3 {
                    var pts = [SIMD2<Float>](), widths = [Float](), colors = [SIMD4<Float>]()
                    for k in 0..<14 {
                        let u = Float(k) / 13
                        let t = max(0, ctx.time - u * 0.3)
                        let f = KoiScene.pose(id: id, time: t, touches: ctx.touches, sample: ctx.sample)
                        let fw = SIMD2(cos(f.heading), sin(f.heading)), sd = SIMD2(-fw.y, fw.x)
                        let root = SIMD2(f.center.x, f.center.y) + fw * f.size * 0.18
                        let p = root + sd * side * f.size * (0.12 + 0.5 * u + 0.06 * Float(j)) - fw * f.size * 0.45 * u
                            + sd * side * sin(u * 6 - ctx.time * 6 + Float(j)) * f.size * 0.05 * u
                        pts.append(p); widths.append(max(0.5, 1.1 - 0.7 * u))
                        colors.append(SIMD4(tint.x, tint.y, tint.z, 0.45 * (1 - u) * ctx.intensity))
                    }
                    _ = forward
                    strokes.stroke(pts, widths: widths, colors: colors)
                }
            }
        }
        return strokes
    }
}
