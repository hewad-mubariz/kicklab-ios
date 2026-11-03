import Foundation
import Metal
import simd

/// Crystal's footage renderer from the Effects Lab (accepted 1 November 2026), adapted to the
/// effect engine's device, shader library and command buffer. One pass, clipped to the crystals,
/// traces the closed ice meshes and refracts the picture behind them.
nonisolated final class CrystalLabRenderer: @unchecked Sendable {
    let device: MTLDevice, pipeline: MTLRenderPipelineState
    let textures: IceTextures, geometry: IceGeometry

    init(device: MTLDevice, library: MTLLibrary) throws {
        guard let vertex = library.makeFunction(name: "labVertex"), let fragment = library.makeFunction(name: "labFragment") else {
            throw NSError(domain: "Crystal", code: 1, userInfo: [NSLocalizedDescriptionKey: "Crystal shaders are missing"])
        }
        self.device = device
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertex; desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: desc)
        textures = try IceTextures(device: device)
        geometry = try IceGeometry(device: device, prefix: "ice-fracture")
    }

    /// Exercise the first submission on a tiny off-screen target before publishing the renderer.
    /// Pipelines, textures and geometry are immutable; each encode owns its per-frame buffers,
    /// so the prepared renderer can be shared by the replay, picker and export engines.
    func warmUp(queue: MTLCommandQueue) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 48, height: 48, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        guard let source = device.makeTexture(descriptor: descriptor),
              let target = device.makeTexture(descriptor: descriptor), let command = queue.makeCommandBuffer() else {
            throw NSError(domain: "Crystal", code: 5)
        }
        let clear = MTLRenderPassDescriptor()
        clear.colorAttachments[0].texture = source
        clear.colorAttachments[0].loadAction = .clear
        clear.colorAttachments[0].storeAction = .store
        clear.colorAttachments[0].clearColor = MTLClearColorMake(0.4, 0.4, 0.4, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: clear) else {
            throw NSError(domain: "Crystal", code: 6)
        }
        encoder.endEncoding()
        let frame = CrystalFrame.make(time: 2, size: CGSize(width: 48, height: 48), strength: 1,
            track: CrystalTrack(sample: { _ in SIMD4(24, 24, 6, 1) }, touchTimes: [1.8]))
        try encode(frame: frame, source: source, target: target, command: command,
                   previewLevel: Self.previewLevel(device: device))
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
    }

    /// The lab's clip: every crystal, puff and mote with its reach, around the ball.
    private func bounds(_ frame: CrystalFrame, width: Int, height: Int) -> MTLScissorRect {
        let ball = frame.ball, unit = ball.z
        var low = SIMD2<Float>(repeating: Float.greatestFiniteMagnitude), high = -low
        for object in frame.objects {
            let extent = object.centerScale.w * 1.45
            let center = SIMD2(object.centerScale.x, object.centerScale.y)
            low = simd_min(low, center - SIMD2(repeating: extent)); high = simd_max(high, center + SIMD2(repeating: extent))
        }
        for puff in frame.mist + frame.dust {
            let extent = puff.centerSize.w * max(1, puff.appearance.z) * 1.5
            let center = SIMD2(puff.centerSize.x, puff.centerSize.y)
            low = simd_min(low, center - SIMD2(repeating: extent)); high = simd_max(high, center + SIMD2(repeating: extent))
        }
        low = simd_min(low, SIMD2(repeating: -1.2)); high = simd_max(high, SIMD2(repeating: 1.2))
        let x0 = max(0, min(width - 1, Int(floor(ball.x + low.x * unit)) - 1)), y0 = max(0, min(height - 1, Int(floor(ball.y + low.y * unit)) - 1))
        let x1 = max(x0 + 1, min(width, Int(ceil(ball.x + high.x * unit)) + 1)), y1 = max(y0 + 1, min(height, Int(ceil(ball.y + high.y * unit)) + 1))
        return MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// How lightly the live preview draws: 0 for saved videos (four rays, five bounces), 1 for one ray,
    /// 2 for one ray and two bounces on older GPUs. Measured at preview size: 32 -> 9 ms on an iPhone 17
    /// Pro Max, 147 -> 33 ms on an iPhone 11.
    static func previewLevel(device: MTLDevice) -> Float { device.supportsFamily(.apple8) ? 1 : 2 }

    func encode(frame: CrystalFrame, source: MTLTexture, target: MTLTexture, command: MTLCommandBuffer, previewLevel: Float = 0) throws {
        guard let blit = command.makeBlitCommandEncoder() else { throw NSError(domain: "Crystal", code: 2) }
        blit.copy(from: source, to: target); blit.endEncoding()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load; pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw NSError(domain: "Crystal", code: 3) }
        encoder.label = "Crystal"
        encoder.setRenderPipelineState(pipeline)
        encoder.setScissorRect(bounds(frame, width: target.width, height: target.height))
        textures.bind(encoder); geometry.bind(encoder)
        encoder.setFragmentTexture(source, index: 4)
        var uniforms = frame.uniforms
        uniforms.atmosphere.w = previewLevel
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FootageUniforms>.stride, index: 0)
        // These particle arrays exceed setFragmentBytes' 4 KiB limit.
        func upload<T>(_ values: [T], zero: T, index: Int) throws {
            let list = values.isEmpty ? [zero] : values
            guard let buffer = list.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
                throw NSError(domain: "Crystal", code: 4)
            }
            encoder.setFragmentBuffer(buffer, offset: 0, index: index)
        }
        try upload(frame.objects, zero: IceInstance(centerScale: .zero, rotationSeed: .zero, appearance: .zero), index: 1)
        let none = FrostElement(centerSize: .zero, appearance: .zero)
        try upload(frame.mist, zero: none, index: 5)
        try upload(frame.dust, zero: none, index: 6)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
