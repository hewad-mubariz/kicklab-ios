// Copied from the Effects Lab (EffectLab/FX/FXSprites.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import Metal
import simd

/// An oriented card in 3D (petal, blossom, feather, twig…). The fragment shader draws its shape
/// procedurally from the card's uv, so depth-of-field blur is just a softer shape edge.
nonisolated struct FXSprite {
    var center: SIMD4<Float>   // x, y (px), z (px, + toward the viewer), size (half extent in px along u)
    var u: SIMD4<Float>        // unit axis u (3D), w = blur radius in px
    var v: SIMD4<Float>        // axis v (3D, length = aspect), w = kind
    var color: SIMD4<Float>    // tint rgb, opacity
    var extra: SIMD4<Float>    // seed, effect-specific
}

nonisolated extension FXSprite {
    /// A card facing the viewer, turned by `roll`, then tilted about its own axes.
    static func card(_ p: SIMD3<Float>, size: Float, aspect: Float = 1, rotation: simd_quatf, kind: Float,
                     color: SIMD4<Float>, blur: Float = 0, extra: SIMD4<Float> = .zero) -> FXSprite {
        let u = rotation.act(SIMD3<Float>(1, 0, 0)), v = rotation.act(SIMD3<Float>(0, 1, 0)) * aspect
        return FXSprite(center: SIMD4(p.x, p.y, p.z, size), u: SIMD4(u.x, u.y, u.z, blur), v: SIMD4(v.x, v.y, v.z, kind),
                        color: color, extra: extra)
    }
}

/// Simple lens: cards near the focus plane are sharp; nearer or farther cards blur.
@inline(__always) nonisolated func fxBlur(z: Float, focus: Float = 0, ballRadius r: Float, strength: Float = 0.05) -> Float {
    min(r * 0.9, abs(z - focus) * strength)
}
/// Perspective scale for a card at depth z (camera ~ 14 ball radii away).
@inline(__always) nonisolated func fxPerspective(z: Float, ballRadius r: Float) -> Float { 14 * r / max(4 * r, 14 * r - z) }

nonisolated final class FXSpriteRenderer {
    let kit: FXKit
    let fragment: String
    init(kit: FXKit, fragment: String) throws {
        self.kit = kit; self.fragment = fragment
        _ = try kit.pipeline("spriteVertex", fragment, format: .rgba16Float, blend: .premultiplied, samples: 4)
        _ = try kit.pipeline("fxCompositeVertex", "spriteComposite", blend: .none)
    }

    /// Draws the cards back to front into a layer, then over the source (the ball stays on top).
    func encode(_ ctx: FXContext, sprites: [FXSprite], source: MTLTexture, target: MTLTexture, command: MTLCommandBuffer,
                params: SIMD4<Float> = .zero) throws {
        let sorted = sprites.sorted { $0.center.z < $1.center.z }
        guard ctx.intensity > 0, ctx.ball.w > 0, let buffer = kit.buffer(sorted) else {
            kit.passthrough(command, source: source, target: target); return
        }
        let w = source.width, h = source.height
        let msaa = kit.texture("sprite.msaa", w, h, .rgba16Float, samples: 4)
        let layer = kit.texture("sprite.layer", w, h, .rgba16Float)
        var u = kit.uniforms(ctx, params)
        try kit.pass(command, msaa, resolve: layer) { e in
            e.setRenderPipelineState(try kit.pipeline("spriteVertex", fragment, format: .rgba16Float, blend: .premultiplied, samples: 4))
            e.setCullMode(.none)
            e.setVertexBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
            e.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
            e.setVertexBuffer(buffer, offset: 0, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: sorted.count)
        }
        try kit.pass(command, target) { e in
            e.setRenderPipelineState(try kit.pipeline("fxCompositeVertex", "spriteComposite", blend: .none))
            e.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
            e.setFragmentTexture(source, index: 0)
            e.setFragmentTexture(layer, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }
}
