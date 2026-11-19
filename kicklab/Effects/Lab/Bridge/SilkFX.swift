// Copied from the Effects Lab (EffectLab/FX/SilkFX.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import Metal
import simd

/// Silk Dancer, 2026-11-19 pass (the owner: "needs some work").
/// Target: effects-sheet-v1 panel 04 — sheer scarlet and ivory silk you can see through, with fine
/// loose threads running along the bands and trailing off their ends. The lab's cloth simulation and
/// fold shading are kept (SilkScene / SilkGPU, now sheerer and a brighter scarlet in Silk.metal);
/// this adds the threads.
nonisolated final class SilkFX: FXEffect {
    let kit: FXKit
    let gpu: SilkGPU
    let scene = SilkSimulation()
    let lines: FXLineRenderer
    let queue: MTLCommandQueue
    init(kit: FXKit) throws {
        self.kit = kit
        gpu = try SilkGPU(libraryURL: try fxLabLibrary("silk"))
        lines = try FXLineRenderer(kit: kit)
        queue = kit.device.makeCommandQueue()!
    }

    func encode(_ ctx: FXContext, source: MTLTexture, target: MTLTexture, command: MTLCommandBuffer) throws {
        let frame = scene.frame(time: ctx.time, size: ctx.size, intensity: ctx.intensity, touches: ctx.touches, sample: ctx.sample)
        let cloth = kit.texture("silk.cloth", source.width, source.height, .bgra8Unorm)
        try gpu.render(frame: frame, source: source, target: cloth)
        let finish = queue.makeCommandBuffer()!
        kit.passthrough(finish, source: cloth, target: target)
        try lines.encode(ctx, strokes: Self.threads(ctx, frame), target: target, command: finish)
        finish.commit(); finish.waitUntilCompleted()
    }

    static func threads(_ ctx: FXContext, _ frame: SilkFrame) -> FXStrokes {
        var strokes = FXStrokes()
        guard ctx.ball.w > 0 else { return strokes }
        let count = SilkSimulation.count
        for ribbon in frame.ribbons where ribbon.material.z > 0.5 {
            let offset = Int(ribbon.material.x), red = ribbon.material.y < 0.5
            let spine = (0..<count).map { frame.nodes[offset + $0].positionWidth }
            let tint: SIMD3<Float> = red ? SIMD3(0.95, 0.16, 0.12) : SIMD3(1.0, 0.94, 0.82)
            for j in 0..<9 {
                func rnd(_ c: Int) -> Float { fxRandom(j * 31 + (red ? 0 : 999), c) }
                let across = (rnd(1) * 2 - 1) * 1.05          // where across the band the thread runs
                let start = Int(rnd(2) * 30), length = 30 + Int(rnd(3) * 50)
                let fringe = rnd(4) < 0.5                      // some threads trail past the band's end
                var pts = [SIMD2<Float>](), widths = [Float](), colors = [SIMD4<Float>]()
                for i in start..<min(count, start + length) {
                    let p = spine[i]
                    let a = spine[max(0, i - 1)], b = spine[min(count - 1, i + 1)]
                    var d = SIMD2(b.x - a.x, b.y - a.y); let l = simd_length(d); d = l > 1e-3 ? d / l : SIMD2(1, 0)
                    let n = SIMD2(-d.y, d.x)
                    let wave = sin(Float(i) * 0.35 + ctx.time * 3 + rnd(5) * 6) * p.w * 0.08
                    pts.append(SIMD2(p.x, p.y) + n * (across * p.w + wave))
                    let u = Float(i - start) / Float(max(1, length - 1))
                    widths.append(0.55 + 0.35 * rnd(6))
                    colors.append(SIMD4(tint.x, tint.y, tint.z, 0.4 * sin(.pi * u) * ctx.intensity))
                }
                if fringe, let last = pts.last, pts.count > 3 {
                    // Loose end: keeps going in the band's direction and curls.
                    var d = last - pts[pts.count - 3]; d = simd_length(d) > 1e-3 ? simd_normalize(d) : SIMD2(1, 0)
                    var p = last
                    for k in 1...10 {
                        d = fxRotate(d, (rnd(7) - 0.5) * 0.25 + sin(ctx.time * 2 + Float(k)) * 0.04)
                        p += d * ctx.ball.z * 0.09
                        pts.append(p); widths.append(0.5)
                        colors.append(SIMD4(tint.x, tint.y, tint.z, 0.45 * (1 - Float(k) / 10) * ctx.intensity))
                    }
                }
                strokes.stroke(pts, widths: widths, colors: colors)
            }
        }
        return strokes
    }
}
