import Foundation
import simd

/// Mirrored in LiquidEffect.h: three float4s each.
nonisolated struct LiquidUniforms: Equatable, Sendable { var viewport, ball, options: SIMD4<Float> }
nonisolated struct LiquidPart: Equatable, Sendable { var centerSize, shape, material: SIMD4<Float> }
nonisolated struct LiquidFrame: Equatable, Sendable { var uniforms: LiquidUniforms; var parts: [LiquidPart] }

/// Liquid Spectrum poured the way Water splashes: Water's motion stage (the crown off the ball, its
/// jets, the larger spray drops and the wake between touches), drawn by the liquid renderer as glossy
/// spectrum paint. The rainbow runs once around the crown's rim, each jet takes one colour and spray
/// drops cycle through the spectrum. The Effects Lab's own Liquid flow poured to one side in loose
/// bits; the owner chose Water's motion for it on 2 November 2026.
nonisolated enum LiquidScene {
    /// `sample` gives the ball (x, y, radius, visibility) in output pixels at any earlier time.
    static func frame(time: Float, size: SIMD2<Float>, intensity: Float, touches: [Float],
                      sample: (Float) -> SIMD4<Float>) -> LiquidFrame {
        let water = WaterScene.frame(time: time, size: size, stage: .motion, intensity: intensity,
                                     light: true, source: true, touches: touches, sample: sample)
        var parts = [LiquidPart]()
        parts.reserveCapacity(water.parts.count)
        for part in water.parts {
            // WaterScene numbers a crown atom event * 10000 + atom, and a spray drop event * 10000 + 8000 + drop.
            let atom = Int(part.material.y) % 10000
            if part.material.w > 1.5 {
                let hue = atom < WaterCrown.rimCount ? Float(atom / 8) / 71 : Float((atom - WaterCrown.rimCount) / 60) / 17
                // Paint is thicker than water, and the liquid renderer does not smooth its field into
                // sheets as Water's does: fuller atoms keep the crown a sheet rather than threads.
                var body = part.centerSize
                body.w *= 1.4
                parts.append(LiquidPart(centerSize: body, shape: part.shape,
                                        material: SIMD4(hue, part.material.y, part.material.z, 2)))
            } else if part.material.w > 0.5, atom - 8000 < 27 {
                // Only the larger spray drops: the finest read as confetti in paint.
                parts.append(LiquidPart(centerSize: part.centerSize, shape: part.shape,
                                        material: SIMD4(Float((atom - 8000) % 9) / 8, part.material.y, part.material.z, 1)))
            }
        }
        return LiquidFrame(uniforms: LiquidUniforms(viewport: water.uniforms.viewport, ball: water.uniforms.ball,
            options: SIMD4(2, 1, 1, Float(parts.count))), parts: parts)
    }
}
