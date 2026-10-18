import AVFoundation
import CoreGraphics
import Metal

/// Real ball pictures for Ball Strobe and the Freeze + Path ghosts: a 6 x 4 sheet of 96 px
/// squares, each cut around the ball at one stamp moment (with `scale` radii of margin).
nonisolated final class ShotSpriteAtlas: @unchecked Sendable {
    static let columns = 6, rows = 4, cell = 96
    static let scale = 1.6
    static var width: Int { columns * cell }
    static var height: Int { rows * cell }

    /// BGRA, premultiplied, top row first.
    let bytes: [UInt8]
    let stamps: [ShotCameraPlan.Stamp]
    private var texture: MTLTexture?
    private let lock = NSLock()

    init(bytes: [UInt8], stamps: [ShotCameraPlan.Stamp]) { self.bytes = bytes; self.stamps = stamps }

    func texture(device: MTLDevice) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        if let texture, texture.device === device { return texture }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Self.width, height: Self.height, mipmapped: false)
        desc.usage = .shaderRead
        guard let made = device.makeTexture(descriptor: desc) else { return nil }
        bytes.withUnsafeBytes { made.replace(region: MTLRegionMake2D(0, 0, Self.width, Self.height), mipmapLevel: 0,
                                             withBytes: $0.baseAddress!, bytesPerRow: Self.width * 4) }
        texture = made
        return made
    }

    /// Cuts the sprites from the upright source video. Empty stamps give no atlas.
    @concurrent static func build(source: URL, stamps: [ShotCameraPlan.Stamp]) async throws -> ShotSpriteAtlas? {
        guard !stamps.isEmpty else { return nil }
        let asset = AVURLAsset(url: source)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.interpolationQuality = .high
        for (index, stamp) in stamps.prefix(columns * rows).enumerated() {
            try Task.checkCancellation()
            guard let image = try? await generator.image(at: CMTime(seconds: stamp.time + 0.000001, preferredTimescale: 1_800_000_000)).image
            else { continue }
            let w = Double(image.width), h = Double(image.height)
            let half = stamp.radius * w * scale
            let crop = CGRect(x: stamp.x * w - half, y: stamp.y * h - half, width: half * 2, height: half * 2)
            guard let piece = image.cropping(to: crop.integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))) else { continue }
            // Cells are filled top to bottom; Core Graphics draws from the bottom-left.
            let column = index % columns, row = index / columns
            let target = CGRect(x: column * cell, y: height - (row + 1) * cell, width: cell, height: cell)
            // Keep the ball centred even when the cut was clipped at a picture edge.
            let visible = crop.integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
            let sx = target.width / crop.width, sy = target.height / crop.height
            let placed = CGRect(x: target.minX + (visible.minX - crop.minX) * sx, y: target.minY + (crop.maxY - visible.maxY) * sy,
                                width: visible.width * sx, height: visible.height * sy)
            context.draw(piece, in: placed)
        }
        return ShotSpriteAtlas(bytes: bytes, stamps: stamps)
    }
}
