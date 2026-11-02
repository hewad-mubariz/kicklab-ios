import Foundation
import simd

/// Mirrored in LiquidEffect.h: three float4s each.
nonisolated struct LiquidUniforms: Equatable, Sendable { var viewport, ball, options: SIMD4<Float> }
nonisolated struct LiquidPart: Equatable, Sendable { var centerSize, shape, material: SIMD4<Float> }
nonisolated struct LiquidFrame: Equatable, Sendable { var uniforms: LiquidUniforms; var parts: [LiquidPart] }

/// Liquid Spectrum's releases, the Effects Lab's motion stage as rendered on footage (accepted
/// 1 November 2026). Each touch releases a full flow and two smaller ones, each keeping the ball
/// position and velocity of its own birth, so later kicks never reset older fluid.
nonisolated enum LiquidScene {
    private struct Release {
        var birth: Float
        var id, seed: Int
        var scale, lifetime: Float
        var side: Float
        var offset: SIMD2<Float>
    }
    static func hash(_ x: Float) -> Float { let v = sin(x * 127.1 + 311.7) * 43758.5453; return v - floor(v) }
    static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t) }
    static func velocity(at t: Float, sample: (Float) -> SIMD4<Float>) -> SIMD2<Float> {
        let p = sample(t), q = sample(max(0, t - 0.025))
        return simd_clamp((SIMD2(p.x, p.y) - SIMD2(q.x, q.y)) / 0.025, SIMD2(repeating: -p.z * 24), SIMD2(repeating: p.z * 24))
    }

    /// `sample` gives the ball (x, y, radius, visibility) in output pixels at any earlier time.
    static func frame(time: Float, size: SIMD2<Float>, intensity: Float, touches: [Float],
                      sample: (Float) -> SIMD4<Float>) -> LiquidFrame {
        let ball = sample(time)
        var parts = [LiquidPart]()
        var events = [Release]()
        for (i, t) in touches.enumerated() {
            // A full touch release, followed by two smaller fresh flows at
            // the ball. Every release retains its own birth transform.
            let candidates = [
                Release(birth: t + 0.025, id: i * 3, seed: i, scale: 1, lifetime: LiquidFluid.lifetime, side: 1, offset: .zero),
                Release(birth: t + 0.145, id: i * 3 + 1, seed: i + 5, scale: 0.43, lifetime: 0.66, side: 1, offset: SIMD2(-0.58, 0.12)),
                Release(birth: t + 0.305, id: i * 3 + 2, seed: i + 9, scale: 0.30, lifetime: 0.53, side: -1, offset: SIMD2(0.74, -0.08))
            ]
            events += candidates.filter { $0.birth <= time && time - $0.birth < $0.lifetime }
        }
        for event in events {
            let birth = event.birth, id = event.id
            let age = time - birth, b = sample(birth)
            guard b.w > 0, let atoms = LiquidFluid.readySample(age: age, seed: event.seed) else { continue }
            let radius = b.z * event.scale
            let base = SIMD2(b.x, b.y) + event.offset * b.z
            let inherit: Float = event.scale < 1 ? 0.76 : 0.58
            let inherited = velocity(at: birth, sample: sample) * inherit * ((1 - exp(-age * 0.6)) / 0.6)
            let fade = smooth(0, 0.045, age) * (1 - smooth(event.lifetime * 0.63, event.lifetime, age))
            for (j, atom) in atoms.enumerated() {
                let p = base + SIMD2(atom.p.x * event.side, atom.p.y) * radius + inherited
                // Neighborhood covariance aligns the surface kernel with the fluid's
                // local strand, rather than drawing a chain of round beads.
                let xx = atom.covariance.x, xy = atom.covariance.y * event.side, yy = atom.covariance.z
                let trace = xx + yy, disc = sqrt((xx - yy) * (xx - yy) + 4 * xy * xy)
                let ratio = (trace + disc) / max(0.0001, trace - disc)
                let stretch: Float = min(2.8, max(1, pow(ratio, 0.30)))
                let angle = 0.5 * atan2(2 * xy, xx - yy)
                let r = radius * 0.082 * sqrt(atom.volume) * sqrt(max(0, fade))
                guard r > 0.25 else { continue }
                parts.append(LiquidPart(centerSize: SIMD4(p.x, p.y, atom.p.z * radius, r),
                    shape: SIMD4(stretch, 1 / stretch, angle, 1),
                    material: SIMD4(atom.dye, Float(id * 1000 + j), age, 0)))
            }
        }
        // The lab's motion stage on footage: stage 2, light background, source video.
        return LiquidFrame(uniforms: LiquidUniforms(viewport: SIMD4(size.x, size.y, time, intensity), ball: ball,
            options: SIMD4(2, 1, 1, Float(parts.count))), parts: parts)
    }
}
