// From the Effects Lab (Crystal, accepted 1 November 2026); texture bytes are unchanged.
import Foundation
import MetalKit

nonisolated final class IceTextures {
    let normal: MTLTexture
    let detail: MTLTexture
    let roughness: MTLTexture
    let environment: MTLTexture
    init(device: MTLDevice, directory: URL? = nil) throws {
        let loader = MTKTextureLoader(device: device)
        func load(_ name: String) throws -> MTLTexture {
            let url = directory?.appendingPathComponent(name + ".jpg") ?? Bundle.main.url(forResource: name, withExtension: "jpg")!
            return try loader.newTexture(URL: url, options: [.SRGB: false, .generateMipmaps: true, .origin: MTKTextureLoader.Origin.topLeft])
        }
        normal = try load("ice-normal")
        detail = try load("ice-detail")
        roughness = try load("ice-roughness")
        let data = try LabAssetData.load("studio-environment", directory: directory)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1024, height: 512, mipmapped: true)
        descriptor.usage = .shaderRead
        let byteCount = (0..<descriptor.mipmapLevelCount).reduce(0) { $0 + max(1, 1024 >> $1) * max(1, 512 >> $1) * 8 }
        guard data.count == byteCount, let texture = device.makeTexture(descriptor: descriptor) else {
            throw NSError(domain: "EffectLab", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid studio environment"])
        }
        data.withUnsafeBytes { bytes in
            var offset = 0
            for level in 0..<descriptor.mipmapLevelCount {
                let width = max(1, 1024 >> level), height = max(1, 512 >> level)
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: level, withBytes: bytes.baseAddress! + offset, bytesPerRow: width * 8)
                offset += width * height * 8
            }
        }
        environment = texture
    }
    func bind(_ encoder: MTLRenderCommandEncoder) {
        encoder.setFragmentTexture(normal, index: 0)
        encoder.setFragmentTexture(detail, index: 1)
        encoder.setFragmentTexture(roughness, index: 2)
        encoder.setFragmentTexture(environment, index: 3)
    }
}
