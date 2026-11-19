// Copied from the Effects Lab (EffectLab/FX/FXLines.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import Metal
import simd

/// Thin anti-aliased strokes (fin wisps, silk threads). Each stroke is a polyline with a width and
/// an opacity per point; they are drawn as triangle strips with a soft one-pixel edge.
nonisolated struct FXLineVertex {
    var p: SIMD4<Float>   // x, y, signed distance across (px), half width (px)
    var c: SIMD4<Float>   // rgb, alpha
}

nonisolated struct FXStrokes {
    var vertices = [FXLineVertex]()

    mutating func stroke(_ points: [SIMD2<Float>], widths: [Float], colors: [SIMD4<Float>]) {
        guard points.count >= 2 else { return }
        func normal(_ i: Int) -> SIMD2<Float> {
            let a = points[max(0, i - 1)], b = points[min(points.count - 1, i + 1)]
            let d = b - a, l = simd_length(d)
            return l > 1e-4 ? SIMD2(-d.y, d.x) / l : SIMD2(0, 1)
        }
        var left = [FXLineVertex](), right = [FXLineVertex]()
        for i in 0..<points.count {
            let w = max(0.35, widths[i]), n = normal(i), e = w + 1.2
            left.append(FXLineVertex(p: SIMD4(points[i].x + n.x * e, points[i].y + n.y * e, e, w), c: colors[i]))
            right.append(FXLineVertex(p: SIMD4(points[i].x - n.x * e, points[i].y - n.y * e, -e, w), c: colors[i]))
        }
        for i in 0..<(points.count - 1) {
            vertices += [left[i], right[i], left[i + 1], left[i + 1], right[i], right[i + 1]]
        }
    }
}

nonisolated final class FXLineRenderer {
    let kit: FXKit
    init(kit: FXKit) throws {
        self.kit = kit
        _ = try kit.pipeline("fxLineVertex", "fxLineFragment", blend: .premultiplied, samples: 1)
    }
    /// Draws strokes straight into `target` (which already holds the picture underneath).
    func encode(_ ctx: FXContext, strokes: FXStrokes, target: MTLTexture, command: MTLCommandBuffer) throws {
        guard ctx.intensity > 0, let buffer = kit.buffer(strokes.vertices) else { return }
        var u = kit.uniforms(ctx)
        try kit.pass(command, target, clear: false) { e in
            e.setRenderPipelineState(try kit.pipeline("fxLineVertex", "fxLineFragment", blend: .premultiplied))
            e.setVertexBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
            e.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
            e.setVertexBuffer(buffer, offset: 0, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: strokes.vertices.count)
        }
    }
}
