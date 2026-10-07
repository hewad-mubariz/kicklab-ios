import Foundation
import Metal
import MetalPerformanceShaders
import CoreVideo
import CoreGraphics

/// One renderer contract for transparent preview, the counter, and video burn-in.
/// Instances own their render targets. Immutable pipelines/noise are shared.
nonisolated final class MetalEffectEngine {
    enum Failure: LocalizedError {
        case unavailable(String)
        var errorDescription: String? { if case let .unavailable(reason) = self { return reason }; return nil }
    }

    final class Resources {
        static let shared: Result<Resources, Error> = Result { try Resources() }
        let device: MTLDevice
        let queue: MTLCommandQueue
        let emission: MTLComputePipelineState
        let resolve: MTLComputePipelineState
        let composite: MTLComputePipelineState
        let particles: MTLRenderPipelineState
        let noise: MTLTexture

        init(libraryURL: URL? = nil) throws {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
                throw Failure.unavailable("Metal is unavailable on this device.")
            }
            self.device = device; self.queue = queue
            let library: MTLLibrary
            if let libraryURL { library = try device.makeLibrary(URL: libraryURL) }
            else if let bundled = device.makeDefaultLibrary() { library = bundled }
            else { throw Failure.unavailable("The effects shader library is missing.") }
            func kernel(_ name: String) throws -> MTLComputePipelineState {
                guard let f = library.makeFunction(name: name) else { throw Failure.unavailable("Missing effect shader: \(name)") }
                return try device.makeComputePipelineState(function: f)
            }
            emission = try kernel("fxEmission"); resolve = try kernel("fxResolve"); composite = try kernel("fxComposite")
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "fxParticleVertex")
            desc.fragmentFunction = library.makeFunction(name: "fxParticleFragment")
            let color = desc.colorAttachments[0]!
            color.pixelFormat = .rgba16Float
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = .one; color.destinationRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .one; color.destinationAlphaBlendFactor = .one
            particles = try device.makeRenderPipelineState(descriptor: desc)
            let noiseDesc = MTLTextureDescriptor()
            noiseDesc.textureType = .type3D; noiseDesc.pixelFormat = .rgba8Unorm
            noiseDesc.width = 32; noiseDesc.height = 32; noiseDesc.depth = 32
            noiseDesc.storageMode = .shared; noiseDesc.usage = .shaderRead
            guard let noise = device.makeTexture(descriptor: noiseDesc) else { throw Failure.unavailable("Cannot allocate the turbulence field.") }
            self.noise = noise
            // A seeded periodic volume: stable under pause, seeking and export.
            var state: UInt32 = 0xC0FFEE
            var bytes = [UInt8](repeating: 0, count: 32 * 32 * 32 * 4)
            for i in bytes.indices {
                state ^= state << 13; state ^= state >> 17; state ^= state << 5
                bytes[i] = UInt8(truncatingIfNeeded: state)
            }
            bytes.withUnsafeBytes { data in
                noise.replace(region: MTLRegionMake3D(0, 0, 0, 32, 32, 32), mipmapLevel: 0, slice: 0,
                              withBytes: data.baseAddress!, bytesPerRow: 128, bytesPerImage: 4096)
            }
        }
    }

    let resources: Resources
    var device: MTLDevice { resources.device }
    private var emission: MTLTexture?
    private var near: MTLTexture?
    private var far: MTLTexture?
    private var cache: CVMetalTextureCache?
    private var scratch: MTLTexture?
    private var blurNear: MPSImageGaussianBlur?
    private var blurFar: MPSImageGaussianBlur?
    private var blurRadius: Float = -1
    private var blurFarRadius: Float = -1

    init(resources: Resources? = nil) throws {
        self.resources = try resources ?? Resources.shared.get()
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, self.resources.device, nil, &cache) == kCVReturnSuccess else {
            throw Failure.unavailable("Cannot create the video texture cache.")
        }
    }

    func texture(width: Int, height: Int, format: MTLPixelFormat = .bgra8Unorm,
                 storage: MTLStorageMode = .private) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]; d.storageMode = storage
        guard let texture = device.makeTexture(descriptor: d) else { throw Failure.unavailable("Cannot allocate an effect render target.") }
        return texture
    }

    private func prepare(_ frame: EffectFrame) throws {
        let region = frame.region
        let limit = frame.counter ? 768.0 : frame.style == 1 ? 832.0 : 640.0
        let scale = min(1, limit / max(1, max(region.width, region.height)))
        // Quantization avoids allocation churn as the tracked ball moves.
        let w = max(16, Int(ceil(region.width * scale / 16)) * 16)
        let h = max(16, Int(ceil(region.height * scale / 16)) * 16)
        if emission?.width != w || emission?.height != h {
            emission = try texture(width: w, height: h, format: .rgba16Float)
            near = try texture(width: w, height: h, format: .rgba16Float)
            far = try texture(width: w, height: h, format: .rgba16Float)
        }
        let fire = !frame.counter && frame.style == 1
        let radius = fire ? max(0.6, (frame.radius * Float(scale) * 0.10 * 2).rounded() / 2)
            : max(1, (frame.radius * Float(scale) * 0.065).rounded())
        let farRadius = fire ? max(1, (frame.radius * Float(scale) * 0.85 * 2).rounded() / 2) : radius * 3.5
        if radius != blurRadius || farRadius != blurFarRadius {
            blurRadius = radius
            blurFarRadius = farRadius
            blurNear = MPSImageGaussianBlur(device: device, sigma: radius)
            blurFar = MPSImageGaussianBlur(device: device, sigma: farRadius)
            blurNear?.edgeMode = .zero; blurFar?.edgeMode = .zero
        }
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, _ target: MTLTexture) {
        encoder.setComputePipelineState(pipeline)
        let w = pipeline.threadExecutionWidth
        let h = max(1, min(8, pipeline.maxTotalThreadsPerThreadgroup / w))
        encoder.dispatchThreads(MTLSize(width: target.width, height: target.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        encoder.endEncoding()
    }

    /// Caller controls presentation / completion. A single queue orders reuse of targets.
    func encode(_ frame: EffectFrame, into target: MTLTexture, source: MTLTexture? = nil, material: MTLTexture? = nil,
                command: MTLCommandBuffer) throws {
        guard frame.size.width > 0, frame.size.height > 0, !frame.region.isNull,
              frame.region.width > 0, frame.region.height > 0 else { throw Failure.unavailable("Invalid effect geometry.") }
        if !frame.counter && (frame.style < 0.5 || frame.intensity <= 0.005 || frame.visibility <= 0.005) {
            // An explicit off frame never consumes cached flame/bloom textures.
            // Still composite an independently selected ball material or grade.
            if let source {
                guard let encoder=command.makeComputeCommandEncoder() else { throw Failure.unavailable("Cannot draw the original video frame.") }
                var u=frame.uniforms;u.viewport.w=0;u.motion.w=0
                u.environment.y=material == nil ? 0:1
                encoder.setBytes(&u,length:MemoryLayout<EffectUniforms>.stride,index:0)
                for i in 0...3 { encoder.setTexture(source,index:i) }
                encoder.setTexture(target,index:4);encoder.setTexture(material ?? source,index:5)
                dispatch(encoder,resources.composite,target)
            } else {
                let pass=MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture=target
                pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
                guard let encoder=command.makeRenderCommandEncoder(descriptor:pass) else { throw Failure.unavailable("Cannot clear the effect.") }
                encoder.endEncoding()
            }
            return
        }
        try prepare(frame)
        guard let emission, let near, let far, let first = command.makeComputeCommandEncoder() else {
            throw Failure.unavailable("Cannot encode the effects volume.")
        }
        var u = frame.uniforms
        u.environment.y = material == nil ? 0 : 1
        var history = Array(frame.trail.suffix(64))
        let emitters = frame.emissionHistory
        if history.isEmpty { history = [.zero] }
        first.label = "Effect material"
        first.setBytes(&u, length: MemoryLayout<EffectUniforms>.stride, index: 0)
        history.withUnsafeBytes { first.setBytes($0.baseAddress!, length: $0.count, index: 1) }
        emitters.withUnsafeBytes { first.setBytes($0.baseAddress!, length: $0.count, index: 2) }
        first.setTexture(emission, index: 0); first.setTexture(resources.noise, index: 1)
        dispatch(first, resources.emission, emission)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = emission
        pass.colorAttachments[0].loadAction = .load; pass.colorAttachments[0].storeAction = .store
        guard let particles = command.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.unavailable("Cannot encode particles.") }
        particles.label = "Effect particles / touch burst"
        particles.setRenderPipelineState(resources.particles)
        particles.setVertexBytes(&u, length: MemoryLayout<EffectUniforms>.stride, index: 0)
        history.withUnsafeBytes { particles.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
        emitters.withUnsafeBytes { particles.setVertexBytes($0.baseAddress!, length: $0.count, index: 2) }
        particles.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: frame.particleCount)
        particles.endEncoding()
        blurNear?.encode(commandBuffer: command, sourceTexture: emission, destinationTexture: near)
        blurFar?.encode(commandBuffer: command, sourceTexture: emission, destinationTexture: far)
        guard let last = command.makeComputeCommandEncoder() else { throw Failure.unavailable("Cannot composite effects.") }
        last.label = "HDR bloom / premultiplied resolve"
        last.setBytes(&u, length: MemoryLayout<EffectUniforms>.stride, index: 0)
        last.setTexture(emission, index: 0); last.setTexture(near, index: 1); last.setTexture(far, index: 2)
        if let source {
            last.setTexture(source, index: 3); last.setTexture(target, index: 4)
            last.setTexture(material ?? source, index: 5)
            dispatch(last, resources.composite, target)
        } else {
            last.setTexture(target, index: 3)
            dispatch(last, resources.resolve, target)
        }
    }

    func render(_ frame: EffectFrame, into target: MTLTexture, source: MTLTexture? = nil) throws {
        guard let command = resources.queue.makeCommandBuffer() else { throw Failure.unavailable("Cannot start effect rendering.") }
        try encode(frame, into: target, source: source, command: command)
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
    }

    /// The decoded video is copied before compositing to avoid read/write hazards.
    func composite(_ frame: EffectFrame, pixelBuffer: CVPixelBuffer) throws {
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        var ref: CVMetalTexture?
        guard let cache, CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, w, h, 0, &ref) == kCVReturnSuccess,
              let ref, let output = CVMetalTextureGetTexture(ref) else { throw Failure.unavailable("The video frame is not Metal-compatible.") }
        if scratch?.width != w || scratch?.height != h { scratch = try texture(width: w, height: h) }
        guard let scratch, let command = resources.queue.makeCommandBuffer(), let copy = command.makeBlitCommandEncoder() else {
            throw Failure.unavailable("Cannot prepare the video texture.")
        }
        copy.copy(from: output, to: scratch); copy.endEncoding()
        try encode(frame, into: output, source: scratch, command: command)
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        withExtendedLifetime(ref) {}
    }
}
