// Copied from the Effects Lab (EffectLab/FX/FXCore.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import Metal
import MetalPerformanceShaders
import simd

/// Shared kit for the 2026-11-19 effect rebuilds (Ferro, Honey, Rift, Sakura, Feather, Ink, Bubble, Koi, Silk).
/// Every effect is a pure function of the playhead: the scene is rebuilt from the ball track and the touch
/// times on each frame, so scrubbing, preview and export all draw the same picture.
/// Effects encode into a caller's command buffer with a caller's device and library, the same shape the
/// app's ported lab renderers use (see WaterLabRenderer in the app).
nonisolated struct FXContext {
    var time: Float
    var size: SIMD2<Float>
    var intensity: Float
    var touches: [Float]
    /// Ball at a time: x, y, radius in pixels, visibility 0…1.
    var sample: (Float) -> SIMD4<Float>

    var ball: SIMD4<Float> { sample(time) }
    /// Ball velocity in pixels per second, from a ±1/60 s difference.
    func velocity(_ t: Float) -> SIMD2<Float> {
        let a = sample(max(0, t - 1.0 / 60)), b = sample(t + 1.0 / 60)
        return SIMD2(b.x - a.x, b.y - a.y) * 30
    }
    /// Touches that already happened and are younger than `within` seconds, oldest first.
    func recentTouches(within: Float) -> [(index: Int, time: Float, age: Float)] {
        touches.enumerated().compactMap { i, t in
            let age = time - t
            return age >= 0 && age < within ? (i, t, age) : nil
        }
    }
    /// Seconds since the last touch (large when none yet).
    var sinceTouch: Float { touches.last(where: { $0 <= time }).map { time - $0 } ?? 99 }
}

nonisolated protocol FXEffect: AnyObject {
    init(kit: FXKit) throws
    func encode(_ ctx: FXContext, source: MTLTexture, target: MTLTexture, command: MTLCommandBuffer) throws
}

nonisolated enum FXBlend { case none, premultiplied, additive, maximum }

/// Deterministic hash in 0..<1 from a seed and a channel (same scheme as the earlier lab scenes).
@inline(__always) nonisolated func fxRandom(_ seed: Int, _ channel: Int) -> Float {
    var x = UInt32(truncatingIfNeeded: seed) &* 747796405 &+ UInt32(truncatingIfNeeded: channel) &* 2891336453 &+ 277803737
    x = ((x >> ((x >> 28) &+ 4)) ^ x) &* 277803737
    x = (x >> 22) ^ x
    return Float(x & 0x00ffffff) / Float(0x01000000)
}
@inline(__always) nonisolated func fxSmooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t)
}
@inline(__always) nonisolated func fxMix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) nonisolated func fxRotate(_ v: SIMD2<Float>, _ a: Float) -> SIMD2<Float> {
    SIMD2(v.x * cos(a) - v.y * sin(a), v.x * sin(a) + v.y * cos(a))
}

/// A lab renderer's own shader library: the lab harness's build folder (FX_LAB_BUILD), or the app bundle
/// (fxlab-<name>.metallib, built by scripts/fx/app-shaders.py).
nonisolated func fxLabLibrary(_ name: String) throws -> URL {
    if let dir = ProcessInfo.processInfo.environment["FX_LAB_BUILD"] {
        return URL(fileURLWithPath: dir).appendingPathComponent(name + ".metallib")
    }
    guard let url = Bundle.main.url(forResource: "fxlab-" + name, withExtension: "metallib") else {
        throw FXKit.failure("Missing shader library \(name)")
    }
    return url
}

/// Per-frame values every shader gets at buffer 0.
nonisolated struct FXUniforms {
    var viewport: SIMD4<Float>   // width, height, time, intensity
    var ball: SIMD4<Float>       // x, y, radius, visibility
    var params: SIMD4<Float>     // effect specific
    var params2: SIMD4<Float>    // effect specific
}

nonisolated final class FXKit {
    let device: MTLDevice
    let library: MTLLibrary
    private var renderStates = [String: MTLRenderPipelineState]()
    private var computeStates = [String: MTLComputePipelineState]()
    private var textures = [String: MTLTexture]()
    private var blurs = [Float: MPSImageGaussianBlur]()

    init(device: MTLDevice, library: MTLLibrary) {
        self.device = device; self.library = library
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "FX", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat = .bgra8Unorm, blend: FXBlend = .premultiplied,
                  samples: Int = 1, depth: Bool = false) throws -> MTLRenderPipelineState {
        let key = "\(vertex)|\(fragment)|\(format.rawValue)|\(blend)|\(samples)|\(depth)"
        if let s = renderStates[key] { return s }
        guard let v = library.makeFunction(name: vertex), let f = library.makeFunction(name: fragment) else {
            throw Self.failure("Missing shader \(vertex) / \(fragment)")
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = v; d.fragmentFunction = f; d.rasterSampleCount = samples
        if depth { d.depthAttachmentPixelFormat = .depth32Float }
        let c = d.colorAttachments[0]!
        c.pixelFormat = format
        switch blend {
        case .none: c.isBlendingEnabled = false
        case .premultiplied:
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case .additive:
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .one
        case .maximum:
            c.isBlendingEnabled = true
            c.rgbBlendOperation = .max; c.alphaBlendOperation = .max
            c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .one
        }
        let s = try device.makeRenderPipelineState(descriptor: d)
        renderStates[key] = s
        return s
    }

    func compute(_ name: String) throws -> MTLComputePipelineState {
        if let s = computeStates[name] { return s }
        guard let f = library.makeFunction(name: name) else { throw Self.failure("Missing kernel \(name)") }
        let s = try device.makeComputePipelineState(function: f)
        computeStates[name] = s
        return s
    }

    /// A cached private render target; the same key returns the same texture while the size matches.
    func texture(_ key: String, _ width: Int, _ height: Int, _ format: MTLPixelFormat, samples: Int = 1) -> MTLTexture {
        if let t = textures[key], t.width == width, t.height == height, t.pixelFormat == format, t.sampleCount == samples { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.storageMode = .private
        if samples > 1 {
            d.textureType = .type2DMultisample; d.sampleCount = samples; d.usage = .renderTarget
        } else if format == .depth32Float {
            d.usage = [.renderTarget, .shaderRead]
        } else {
            d.usage = [.renderTarget, .shaderRead, .shaderWrite]
        }
        let t = device.makeTexture(descriptor: d)!
        textures[key] = t
        return t
    }

    func blur(_ command: MTLCommandBuffer, _ source: MTLTexture, _ destination: MTLTexture, sigma: Float) {
        let key = (sigma * 4).rounded() / 4
        let b = blurs[key] ?? {
            let k = MPSImageGaussianBlur(device: device, sigma: key)
            k.edgeMode = .clamp
            blurs[key] = k
            return k
        }()
        b.encode(commandBuffer: command, sourceTexture: source, destinationTexture: destination)
    }

    private var scaler: MPSImageBilinearScale?
    /// Resizes `source` into `destination` (any sizes).
    func scale(_ command: MTLCommandBuffer, _ source: MTLTexture, _ destination: MTLTexture) {
        let s = scaler ?? MPSImageBilinearScale(device: device)
        scaler = s
        s.encode(commandBuffer: command, sourceTexture: source, destinationTexture: destination)
    }

    func buffer<T>(_ items: [T]) -> MTLBuffer? {
        guard !items.isEmpty else { return nil }
        return items.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
    }

    /// A pass that clears `texture` and lets `body` draw into it.
    func pass(_ command: MTLCommandBuffer, _ texture: MTLTexture, resolve: MTLTexture? = nil, clear: Bool = true,
              depth: MTLTexture? = nil, _ body: (MTLRenderCommandEncoder) throws -> Void) rethrows {
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = texture
        p.colorAttachments[0].loadAction = clear ? .clear : .load
        p.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        if let resolve {
            p.colorAttachments[0].resolveTexture = resolve
            p.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            p.colorAttachments[0].storeAction = .store
        }
        if let depth {
            p.depthAttachment.texture = depth
            p.depthAttachment.loadAction = .clear
            p.depthAttachment.clearDepth = 1
            p.depthAttachment.storeAction = .dontCare
        }
        let e = command.makeRenderCommandEncoder(descriptor: p)!
        try body(e)
        e.endEncoding()
    }

    /// Copies the source into the target untouched (used when the effect has nothing to draw).
    func passthrough(_ command: MTLCommandBuffer, source: MTLTexture, target: MTLTexture) {
        let b = command.makeBlitCommandEncoder()!
        b.copy(from: source, to: target)
        b.endEncoding()
    }

    func uniforms(_ ctx: FXContext, _ params: SIMD4<Float> = .zero, _ params2: SIMD4<Float> = .zero) -> FXUniforms {
        FXUniforms(viewport: SIMD4(ctx.size.x, ctx.size.y, ctx.time, ctx.intensity), ball: ctx.ball, params: params, params2: params2)
    }
}
