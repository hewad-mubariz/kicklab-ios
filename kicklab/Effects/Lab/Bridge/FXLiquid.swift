// Copied from the Effects Lab (EffectLab/FX/FXLiquid.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import Metal
import simd

/// One splat of the liquid field. `radius` is the tube/drop radius in pixels.
nonisolated struct FXBead {
    var p: SIMD4<Float>   // x, y, radius, weight
    var m: SIMD4<Float>   // tint, glow, -, -
}

/// Builds bead lists. Line beads use weight 0.75 × spacing / radius so a dense line reads as one smooth
/// tube of that radius; a lone drop uses weight 1.185 so its edge sits exactly at its radius.
nonisolated struct FXBeads {
    var items = [FXBead]()

    mutating func drop(_ p: SIMD2<Float>, _ r: Float, fade: Float = 1, tint: Float = 0, glow: Float = 0) {
        guard r > 0.4, fade > 0.01 else { return }
        items.append(FXBead(p: SIMD4(p.x, p.y, r, 1.185 * fade), m: SIMD4(tint, glow, 0, 0)))
    }

    /// A tube through `points` with a radius per point; beads every third of the radius.
    mutating func tube(_ points: [SIMD2<Float>], _ radii: [Float], fade: Float = 1, tint: Float = 0, glow: Float = 0) {
        guard points.count >= 2, fade > 0.01 else { return }
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1], ra = radii[i], rb = radii[i + 1]
            let length = simd_distance(a, b)
            let step = max(0.6, min(ra, rb) * 0.33)
            let n = max(1, Int(ceil(length / step)))
            for k in 0..<n {
                let t = Float(k) / Float(n)
                let r = ra + (rb - ra) * t
                guard r > 0.4 else { continue }
                let spacing = length / Float(n)
                let p = a + (b - a) * t
                items.append(FXBead(p: SIMD4(p.x, p.y, r, 0.75 * spacing / r * fade), m: SIMD4(tint, glow, 0, 0)))
            }
        }
        // Round cap at the end.
        if let last = points.last, let r = radii.last, r > 0.4 {
            items.append(FXBead(p: SIMD4(last.x, last.y, r, 0.6 * fade), m: SIMD4(tint, glow, 0, 0)))
        }
    }
}

nonisolated enum FXLiquidMaterial: Float { case chrome = 0, honey = 1 }

nonisolated final class FXLiquidRenderer {
    let kit: FXKit
    let material: FXLiquidMaterial

    init(kit: FXKit, material: FXLiquidMaterial) throws {
        self.kit = kit; self.material = material
        _ = try kit.pipeline("liquidBeadVertex", "liquidBeadFragment", format: .rgba16Float, blend: .additive)
        _ = try kit.pipeline("liquidCompositeVertex", "liquidComposite", blend: .none)
    }

    /// Draws the liquid over the source into the target. `reflect` is how much of the real frame the
    /// surface mirrors (chrome) — 0…1.
    func encode(_ ctx: FXContext, beads: [FXBead], source: MTLTexture, target: MTLTexture, command: MTLCommandBuffer,
                reflect: Float = 0.35) throws {
        guard ctx.intensity > 0, ctx.ball.w > 0, let buffer = kit.buffer(beads) else {
            kit.passthrough(command, source: source, target: target); return
        }
        let w = source.width, h = source.height
        let field = kit.texture("liquid.field", w, h, .rgba16Float)
        var u = kit.uniforms(ctx, SIMD4(material.rawValue, reflect, 1, 0))
        try kit.pass(command, field) { e in
            e.setRenderPipelineState(try kit.pipeline("liquidBeadVertex", "liquidBeadFragment", format: .rgba16Float, blend: .additive))
            e.setVertexBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
            e.setVertexBuffer(buffer, offset: 0, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: beads.count)
        }
        let soft = kit.texture("liquid.soft", w / 2, h / 2, .bgra8Unorm)
        let half = kit.texture("liquid.half", w / 2, h / 2, .bgra8Unorm)
        // Downsample then blur: the mirrored world is soft, like a curved metal surface would show it.
        kit.scale(command, source, half)
        kit.blur(command, half, soft, sigma: 5)
        try kit.pass(command, target) { e in
            e.setRenderPipelineState(try kit.pipeline("liquidCompositeVertex", "liquidComposite", blend: .none))
            e.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
            e.setFragmentTexture(field, index: 0)
            e.setFragmentTexture(source, index: 1)
            e.setFragmentTexture(soft, index: 2)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }
}
