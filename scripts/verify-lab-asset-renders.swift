// Compile with the app's LabAssetData, LabSkinRenderer, IceTextures, IceGeometry,
// CrystalScene and CrystalLabRenderer sources into a macOS .app. Run twice with the
// archived raw assets and the packed assets. Compare the output pixel hashes.
import AppKit
import CryptoKit
import Foundation
import ImageIO
import Metal
import simd

// The four skin selectors used by the unmodified production renderer.
nonisolated enum BallSkin: String { case goldPolish, prism, wave, nightPulse; var isLabSkin: Bool { true } }

@main struct VerifyLabAssetRenders {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var results = [[String: Any]]()
        func save(_ image: CGImage, name: String) throws {
            let bytes = image.dataProvider!.data! as Data
            let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name + ".png") as CFURL,
                "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            precondition(CGImageDestinationFinalize(destination))
            results.append(["name": name, "width": image.width, "height": image.height,
                "pixel_sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()])
        }
        guard let skins = LabSkinRenderer.shared, let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary(), let queue = device.makeCommandQueue() else {
            fatalError("Production render resources missing")
        }
        for size in [96, 384] {
            for skin: BallSkin in [.goldPolish, .prism, .wave, .nightPulse] {
                for (index, angle): (Int, Float) in [0, 0.7, 2.1].enumerated() {
                    guard let image = skins.image(skin: skin,
                        orientation: simd_quatf(angle: angle, axis: simd_normalize(SIMD3(1, 2, 3))), size: size) else {
                        fatalError("Skin render failed")
                    }
                    try save(image, name: "\(skin.rawValue)-\(size)-\(index)")
                }
            }
        }
        let crystal = try CrystalLabRenderer(device: device, library: library)
        for size in [192, 512] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: size, height: size, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
            let source = device.makeTexture(descriptor: descriptor)!, target = device.makeTexture(descriptor: descriptor)!
            var pixels = [UInt8](repeating: 255, count: size * size * 4)
            for y in 0..<size { for x in 0..<size {
                let i = (y * size + x) * 4
                pixels[i] = UInt8((x / 16 + y / 16) % 2 == 0 ? 130 : 70)
                pixels[i + 1] = UInt8(40 + y * 130 / size)
                pixels[i + 2] = UInt8(50 + x * 140 / size)
            } }
            pixels.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                                                    withBytes: $0.baseAddress!, bytesPerRow: size * 4) }
            for (index, time) in [1.81, 2.0, 2.35].enumerated() {
                let frame = CrystalFrame.make(time: time, size: CGSize(width: size, height: size), strength: 1,
                    track: CrystalTrack(sample: { _ in SIMD4(Float(size) * 0.5, Float(size) * 0.6, Float(size) * 0.13, 1) }, touchTimes: [1.8]))
                for quality: Float in [0, 2] {
                    let command = queue.makeCommandBuffer()!
                    try crystal.encode(frame: frame, source: source, target: target, command: command, previewLevel: quality)
                    command.commit(); command.waitUntilCompleted()
                    if let error = command.error { throw error }
                    var rendered = pixels
                    rendered.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: size * 4,
                        from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0) }
                    let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue:
                            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                        provider: CGDataProvider(data: Data(rendered) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
                    try save(image, name: "crystal-\(size)-\(index)-\(Int(quality))")
                }
            }
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("renders.json"))
        print("Rendered \(results.count) production frames on \(device.name)")
    }
}
