import CoreGraphics
import Foundation
import Metal
import simd

/// Gold Polish, Prism, Wave and Night Pulse: the Effects Lab's skin shaders (accepted 1 November
/// 2026) draw the lit, rotated ball into the same raster the artwork skins fill, so the replacement
/// pipeline's outline, occlusion, motion blur and scene light apply to them as to every other skin.
nonisolated final class LabSkinRenderer: @unchecked Sendable {
    static let shared: LabSkinRenderer? = try? LabSkinRenderer()

    /// Mirrored in GoldSkin.metal and SurfaceSkins.metal.
    private struct Uniforms { var viewport, ball, orientation, options: SIMD4<Float> }

    private let lock = NSLock()
    private let device: MTLDevice, queue: MTLCommandQueue
    private let gold: MTLRenderPipelineState, surface: MTLRenderPipelineState
    private let panels: MTLBuffer, environment: MTLTexture, black: MTLTexture
    private var targets: [Int: MTLTexture] = [:]

    private init() throws {
        func failure(_ text: String) -> NSError { NSError(domain: "LabSkin", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { throw failure("Metal unavailable") }
        self.device = device; self.queue = queue
        func pipeline(_ vertex: String, _ fragment: String) throws -> MTLRenderPipelineState {
            guard let v = library.makeFunction(name: vertex), let f = library.makeFunction(name: fragment) else { throw failure("Missing \(fragment)") }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = v; d.fragmentFunction = f
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: d)
        }
        gold = try pipeline("goldVertex", "goldFragment")
        surface = try pipeline("surfaceSkinVertex", "surfaceSkinFragment")
        let sites = Self.panelSites()
        guard let panels = sites.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
            throw failure("Panel buffer")
        }
        self.panels = panels
        // The licensed gold lighting environment, as the lab loads it: 1024 × 512 rgba16Float with mipmaps.
        guard let url = Bundle.main.url(forResource: "gold-environment", withExtension: "bin") else { throw failure("Missing lighting environment") }
        let data = try Data(contentsOf: url)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1024, height: 512, mipmapped: true)
        descriptor.usage = .shaderRead
        let expected = (0..<descriptor.mipmapLevelCount).reduce(0) { $0 + max(1, 1024 >> $1) * max(1, 512 >> $1) * 8 }
        guard data.count == expected, let environment = device.makeTexture(descriptor: descriptor) else { throw failure("Invalid lighting environment") }
        data.withUnsafeBytes { bytes in
            var offset = 0
            for level in 0..<descriptor.mipmapLevelCount {
                let w = max(1, 1024 >> level), h = max(1, 512 >> level)
                environment.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: level, withBytes: bytes.baseAddress! + offset, bytesPerRow: w * 8)
                offset += w * h * 8
            }
        }
        self.environment = environment
        let one = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        one.storageMode = .shared; one.usage = .shaderRead
        guard let black = device.makeTexture(descriptor: one) else { throw failure("Backdrop") }
        var zero: UInt32 = 0
        black.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)
        self.black = black
    }

    /// The lab's 12 pentagonal and 20 hexagonal spherical cells, from icosahedron vertices and face centres.
    private static func panelSites() -> [SIMD4<Float>] {
        let phi = Float((1 + sqrt(5.0)) / 2)
        var vertices = [SIMD3<Float>]()
        for a: Float in [-1, 1] { for b: Float in [-phi, phi] {
            vertices += [SIMD3(0, a, b), SIMD3(a, b, 0), SIMD3(b, 0, a)]
        } }
        var sites = vertices.map(simd_normalize)
        for i in vertices.indices { for j in (i + 1)..<vertices.count { for k in (j + 1)..<vertices.count {
            if abs(simd_distance(vertices[i], vertices[j]) - 2) < 0.001 && abs(simd_distance(vertices[i], vertices[k]) - 2) < 0.001
                && abs(simd_distance(vertices[j], vertices[k]) - 2) < 0.001 {
                sites.append(simd_normalize(vertices[i] + vertices[j] + vertices[k]))
            }
        } } }
        return sites.map { SIMD4($0.x, $0.y, $0.z, 0) }
    }

    /// The skin's ball filling a `size` pixel square, premultiplied RGBA like the artwork rasters.
    /// Outdoor lighting matches the lab's footage renders.
    func image(skin: BallSkin, orientation: simd_quatf, size: Int) -> CGImage? {
        guard skin.isLabSkin, size > 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        let target: MTLTexture
        if let existing = targets[size] { target = existing } else {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
            d.storageMode = .shared; d.usage = [.renderTarget, .shaderRead]
            guard let made = device.makeTexture(descriptor: d) else { return nil }
            targets[size] = made; target = made
        }
        let half = Float(size) / 2
        let surfaceIndex: Float = skin == .prism ? 0 : skin == .wave ? 1 : 2
        var uniforms = Uniforms(viewport: SIMD4(Float(size), Float(size), 0, 1), ball: SIMD4(half, half, half, 1),
                                orientation: simd_normalize(orientation).vector,
                                options: skin == .goldPolish ? SIMD4(0.19, 1, 1, 0) : SIMD4(0.28, 1, 1, surfaceIndex))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(skin == .goldPolish ? gold : surface)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBuffer(panels, offset: 0, index: 1)
        encoder.setFragmentTexture(black, index: 0); encoder.setFragmentTexture(environment, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.commit(); command.waitUntilCompleted()
        guard command.error == nil else { return nil }
        var bgra = [UInt8](repeating: 0, count: size * size * 4)
        bgra.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0) }
        // Over black the shaders' colour is already premultiplied by their edge coverage; give the
        // raster that same coverage as alpha.
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size { for x in 0..<size {
            let nx = (Float(x) + 0.5) / half - 1, ny = 1 - (Float(y) + 0.5) / half
            let edge = 1 - (nx * nx + ny * ny).squareRoot()
            guard edge > 0 else { continue }
            let t = min(1, edge * half), coverage = t * t * (3 - 2 * t)
            let i = (y * size + x) * 4, alpha = UInt8((coverage * 255).rounded())
            rgba[i] = min(alpha, bgra[i + 2]); rgba[i + 1] = min(alpha, bgra[i + 1]); rgba[i + 2] = min(alpha, bgra[i])
            rgba[i + 3] = alpha
        } }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
