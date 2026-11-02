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
        /// Neon's and Galaxy's per-frame strands (EffectPaths.h), which fxEmission reads.
        let effectPath: MTLComputePipelineState
        let resolve: MTLComputePipelineState
        let composite: MTLComputePipelineState
        let shotCamera: MTLComputePipelineState?
        let particles: MTLRenderPipelineState
        let noise: MTLTexture
        /// Effects Lab renderers. Absent from libraries built without their shaders.
        let liquidSplat: MTLRenderPipelineState?
        let liquidShade: MTLRenderPipelineState?
        let library: MTLLibrary

        init(libraryURL: URL? = nil, source: String? = nil) throws {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
                throw Failure.unavailable("Metal is unavailable on this device.")
            }
            self.device = device; self.queue = queue
            let library: MTLLibrary
            if let source { library = try device.makeLibrary(source: source, options: nil) }
            else if let libraryURL { library = try device.makeLibrary(URL: libraryURL) }
            else if let bundled = device.makeDefaultLibrary() { library = bundled }
            else { throw Failure.unavailable("The effects shader library is missing.") }
            self.library = library
            func kernel(_ name: String) throws -> MTLComputePipelineState {
                guard let f = library.makeFunction(name: name) else { throw Failure.unavailable("Missing effect shader: \(name)") }
                return try device.makeComputePipelineState(function: f)
            }
            emission = try kernel("fxEmission"); resolve = try kernel("fxResolve"); composite = try kernel("fxComposite")
            shotCamera = library.makeFunction(name: "fxShotCamera").map { try? device.makeComputePipelineState(function: $0) } ?? nil
            effectPath = try kernel("fxEffectPath")
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "fxParticleVertex")
            desc.fragmentFunction = library.makeFunction(name: "fxParticleFragment")
            let color = desc.colorAttachments[0]!
            color.pixelFormat = .rgba16Float
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = .one; color.destinationRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .one; color.destinationAlphaBlendFactor = .one
            particles = try device.makeRenderPipelineState(descriptor: desc)
            func pass(_ vertex: String, _ fragment: String, _ format: MTLPixelFormat, additive: Bool) -> MTLRenderPipelineState? {
                guard let v = library.makeFunction(name: vertex), let f = library.makeFunction(name: fragment) else { return nil }
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = v; d.fragmentFunction = f
                let color = d.colorAttachments[0]!
                color.pixelFormat = format
                if additive {
                    color.isBlendingEnabled = true
                    color.sourceRGBBlendFactor = .one; color.destinationRGBBlendFactor = .one
                    color.sourceAlphaBlendFactor = .one; color.destinationAlphaBlendFactor = .one
                }
                return try? device.makeRenderPipelineState(descriptor: d)
            }
            liquidSplat = pass("liquidSplatVertex", "liquidSplatFragment", .rgba16Float, additive: true)
            liquidShade = pass("liquidVertex", "liquidFragment", .bgra8Unorm, additive: false)
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
    /// fxEffectPath's output: 311 float4 for Neon, 224 for Galaxy (EffectPaths.h).
    private var paths: MTLBuffer?
    private var near: MTLTexture?
    private var far: MTLTexture?
    private var cache: CVMetalTextureCache?
    private var scratch: MTLTexture?
    private var cameraScratch: MTLTexture?
    private var cameraBlur: MTLTexture?
    private var focusBlur: MPSImageGaussianBlur?
    private var focusSigma: Float = 0
    private var blurNear: MPSImageGaussianBlur?
    private var blurFar: MPSImageGaussianBlur?
    private var blurRadius: Float = -1
    private var blurFarRadius: Float = -1
    private var labBackground: MTLTexture?
    private var labField: MTLTexture?
    private var water: WaterLabRenderer?
    private var crystal: CrystalLabRenderer?
    /// Set by the editor's live preview: Crystal draws lighter there, saved videos in full.
    var livePreview = false

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
        // Shot trails span the whole flight, so they need more texels than a ball-sized effect.
        let limit = frame.counter ? 768.0 : frame.style == 1 ? 832.0 : frame.style >= 20 && frame.style < 30 ? 1024.0 : 640.0
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
                camera: ShotCameraFrame? = nil, atlas: ShotSpriteAtlas? = nil, arc: ShotArcLayers? = nil,
                command: MTLCommandBuffer) throws {
        if let camera, camera.isActive, let source {
            if cameraScratch?.width != target.width || cameraScratch?.height != target.height {
                cameraScratch = try texture(width: target.width, height: target.height)
            }
            guard let cameraScratch, let pipeline = resources.shotCamera else {
                throw Failure.unavailable("The camera effects renderer is unavailable.")
            }
            try encode(frame, into: cameraScratch, source: source, material: material, command: command)
            // Rack Focus reads a blurred copy of the picture.
            var blurred: MTLTexture = cameraScratch
            if camera.needsBlur {
                if cameraBlur?.width != target.width || cameraBlur?.height != target.height {
                    cameraBlur = try texture(width: target.width, height: target.height)
                }
                let sigma = max(2, Float(target.width) / 720 * 7.5)
                if focusBlur == nil || focusSigma != sigma {
                    focusBlur = MPSImageGaussianBlur(device: device, sigma: sigma); focusSigma = sigma
                    focusBlur?.edgeMode = .clamp
                }
                if let cameraBlur, let focusBlur {
                    focusBlur.encode(commandBuffer: command, sourceTexture: cameraScratch, destinationTexture: cameraBlur)
                    blurred = cameraBlur
                }
            }
            guard let encoder = command.makeComputeCommandEncoder() else {
                throw Failure.unavailable("Couldn’t draw the camera effect.")
            }
            let sprites = camera.usesArcLayers ? arc?.texture(device: device) : atlas?.texture(device: device)
            let uniforms = camera.uniforms(hasAtlas: sprites != nil)
            let path = camera.path.isEmpty ? [SIMD4<Float>.zero] : camera.path
            let stamps = camera.stamps.isEmpty ? [SIMD4<Float>.zero] : camera.stamps
            encoder.label = "Power Shot camera and replay"
            uniforms.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
            path.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 1) }
            stamps.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 2) }
            encoder.setTexture(cameraScratch, index: 0)
            encoder.setTexture(target, index: 1)
            encoder.setTexture(source, index: 2)
            encoder.setTexture(sprites ?? cameraScratch, index: 3)
            encoder.setTexture(blurred, index: 4)
            dispatch(encoder, pipeline, target)
            return
        }
        guard frame.size.width > 0, frame.size.height > 0, !frame.region.isNull,
              frame.region.width > 0, frame.region.height > 0 else { throw Failure.unavailable("Invalid effect geometry.") }
        if let liquid = frame.liquid, !frame.counter, frame.intensity > 0.005, frame.visibility > 0.005,
           let splat = resources.liquidSplat, let shade = resources.liquidShade {
            // Liquid refracts the picture behind it, so a transparent overlay without one shows
            // nothing; picker icons ask for a plain backdrop instead.
            let icon = liquid.uniforms.options.y < 0
            if source != nil || icon {
                try encodeLiquid(liquid, frame: frame, into: target, source: source, material: material,
                                 backdrop: icon ? Double(liquid.uniforms.options.w) : nil,
                                 splat: splat, shade: shade, command: command)
                return
            }
        }
        if let ice = frame.crystal, !frame.counter, frame.intensity > 0.005, frame.visibility > 0.005,
           source != nil || frame.labBackdrop != nil {
            if crystal == nil { crystal = try? CrystalLabRenderer(device: device, library: resources.library) }
            if let crystal {
                // Crystal refracts the picture behind it: the video with any replacement ball.
                let background = try labBackground(frame, target: target, source: source, material: material,
                                                   backdrop: frame.labBackdrop, command: command)
                try crystal.encode(frame: ice, source: background, target: target, command: command,
                                   previewLevel: livePreview ? CrystalLabRenderer.previewLevel(device: device) : 0)
                return
            }
        }
        if let splash = frame.water, !frame.counter, frame.intensity > 0.005, frame.visibility > 0.005,
           source != nil || frame.labBackdrop != nil {
            if water == nil { water = try? WaterLabRenderer(device: device, library: resources.library) }
            if let water {
                // Water refracts the picture it splashes over: the video with any replacement ball.
                let background = try labBackground(frame, target: target, source: source, material: material,
                                                   backdrop: frame.labBackdrop, command: command)
                try water.encode(frame: splash, source: background, target: target, command: command)
                return
            }
        }
        // A lab effect without its touches and track (style 30 and up) has nothing to draw.
        let labWithoutScene = frame.style >= 30 && frame.liquid == nil && frame.water == nil && frame.crystal == nil
        if !frame.counter && (frame.style < 0.5 || frame.intensity <= 0.005 || frame.visibility <= 0.005 || labWithoutScene) {
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
        var u = frame.uniforms
        u.environment.y = material == nil ? 0 : 1
        var history = Array(frame.trail.suffix(64))
        let emitters = frame.emissionHistory
        if history.isEmpty { history = [.zero] }
        if paths == nil { paths = device.makeBuffer(length: 320 * MemoryLayout<SIMD4<Float>>.stride, options: .storageModePrivate) }
        guard let paths else { throw Failure.unavailable("Cannot allocate effect paths.") }
        // Neon and Galaxy strands depend on the frame, not the pixel: build them once, then shade.
        if frame.style == 3 || frame.style == 4 {
            guard let build = command.makeComputeCommandEncoder() else { throw Failure.unavailable("Cannot encode effect paths.") }
            let pipeline = resources.effectPath
            build.label = "Effect paths"
            build.setComputePipelineState(pipeline)
            build.setBytes(&u, length: MemoryLayout<EffectUniforms>.stride, index: 0)
            emitters.withUnsafeBytes { build.setBytes($0.baseAddress!, length: $0.count, index: 2) }
            build.setBuffer(paths, offset: 0, index: 3)
            build.dispatchThreads(MTLSize(width: 320, height: 1, depth: 1),
                                  threadsPerThreadgroup: MTLSize(width: min(320, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
            build.endEncoding()
        }
        guard let emission, let near, let far, let first = command.makeComputeCommandEncoder() else {
            throw Failure.unavailable("Cannot encode the effects volume.")
        }
        first.label = "Effect material"
        first.setBytes(&u, length: MemoryLayout<EffectUniforms>.stride, index: 0)
        history.withUnsafeBytes { first.setBytes($0.baseAddress!, length: $0.count, index: 1) }
        emitters.withUnsafeBytes { first.setBytes($0.baseAddress!, length: $0.count, index: 2) }
        first.setBuffer(paths, offset: 0, index: 3)
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
        // Shot trails draw their sparks in the field; an empty instanced draw is not valid.
        if frame.particleCount > 0 {
            particles.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: frame.particleCount)
        }
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

    /// The picture a lab effect refracts: the video, aspect-filled as the compositor does, with any
    /// replacement ball, in output pixels. Without a video it stays clear.
    private func labBackground(_ frame: EffectFrame, target: MTLTexture, source: MTLTexture?, material: MTLTexture?,
                               backdrop: Double? = nil, command: MTLCommandBuffer) throws -> MTLTexture {
        if labBackground?.width != target.width || labBackground?.height != target.height {
            labBackground = try texture(width: target.width, height: target.height)
        }
        guard let background = labBackground else { throw Failure.unavailable("Cannot allocate the effect background.") }
        if let source {
            guard let encoder = command.makeComputeCommandEncoder() else { throw Failure.unavailable("Cannot draw the video frame.") }
            var u = frame.uniforms; u.viewport.w = 0; u.motion.w = 0
            u.environment.y = material == nil ? 0 : 1
            encoder.setBytes(&u, length: MemoryLayout<EffectUniforms>.stride, index: 0)
            for i in 0...3 { encoder.setTexture(source, index: i) }
            encoder.setTexture(background, index: 4); encoder.setTexture(material ?? source, index: 5)
            dispatch(encoder, resources.composite, background)
        } else {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = background
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            let level = backdrop ?? 0
            pass.colorAttachments[0].clearColor = MTLClearColorMake(level, level, level, backdrop == nil ? 0 : 1)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.unavailable("Cannot clear the effect background.") }
            encoder.endEncoding()
        }
        return background
    }

    /// Liquid Spectrum, drawn by the Effects Lab's two passes: particles splat into a density
    /// field, then the field is shaded over the picture it refracts.
    private func encodeLiquid(_ liquid: LiquidFrame, frame: EffectFrame, into target: MTLTexture, source: MTLTexture?,
                              material: MTLTexture?, backdrop: Double?, splat: MTLRenderPipelineState,
                              shade: MTLRenderPipelineState, command: MTLCommandBuffer) throws {
        let background = try labBackground(frame, target: target, source: source, material: material,
                                           backdrop: backdrop, command: command)
        if labField?.width != target.width || labField?.height != target.height {
            labField = try texture(width: target.width, height: target.height, format: .rgba16Float)
        }
        guard let field = labField else { throw Failure.unavailable("Cannot allocate the liquid field.") }
        var uniforms = liquid.uniforms
        let density = MTLRenderPassDescriptor()
        density.colorAttachments[0].texture = field
        density.colorAttachments[0].loadAction = .clear; density.colorAttachments[0].storeAction = .store
        density.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let splats = command.makeRenderCommandEncoder(descriptor: density) else { throw Failure.unavailable("Cannot draw the liquid.") }
        splats.label = "Liquid density"
        splats.setRenderPipelineState(splat)
        splats.setVertexBytes(&uniforms, length: MemoryLayout<LiquidUniforms>.stride, index: 0)
        if !liquid.parts.isEmpty,
           let parts = liquid.parts.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) {
            splats.setVertexBuffer(parts, offset: 0, index: 1)
            splats.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: liquid.parts.count)
        }
        splats.endEncoding()
        let surface = MTLRenderPassDescriptor()
        surface.colorAttachments[0].texture = target
        surface.colorAttachments[0].loadAction = .dontCare; surface.colorAttachments[0].storeAction = .store
        guard let shading = command.makeRenderCommandEncoder(descriptor: surface) else { throw Failure.unavailable("Cannot shade the liquid.") }
        shading.label = "Liquid surface"
        shading.setRenderPipelineState(shade)
        shading.setFragmentBytes(&uniforms, length: MemoryLayout<LiquidUniforms>.stride, index: 0)
        shading.setFragmentTexture(background, index: 0); shading.setFragmentTexture(field, index: 1)
        shading.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        shading.endEncoding()
    }

    func render(_ frame: EffectFrame, into target: MTLTexture, source: MTLTexture? = nil, camera: ShotCameraFrame? = nil,
                atlas: ShotSpriteAtlas? = nil, arc: ShotArcLayers? = nil) throws {
        guard let command = resources.queue.makeCommandBuffer() else { throw Failure.unavailable("Cannot start effect rendering.") }
        try encode(frame, into: target, source: source, camera: camera, atlas: atlas, arc: arc, command: command)
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
    }

    /// The decoded video is copied before compositing to avoid read/write hazards.
    func composite(_ frame: EffectFrame, pixelBuffer: CVPixelBuffer, camera: ShotCameraFrame? = nil, atlas: ShotSpriteAtlas? = nil,
                   arc: ShotArcLayers? = nil) throws {
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
        try encode(frame, into: output, source: scratch, camera: camera, atlas: atlas, arc: arc, command: command)
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        withExtendedLifetime(ref) {}
    }

    func releaseCameraTargets() { cameraScratch = nil; cameraBlur = nil }
}
