// Generate the four added picker cards using the shipping Metal materials.
// Compile with EffectFrame.swift and MetalEffectEngine.swift on macOS.
import Foundation
import AppKit
import Metal

@main struct RenderEffectCards {
    static func main() throws {
        let args = CommandLine.arguments
        let resources = try MetalEffectEngine.Resources(libraryURL: URL(fileURLWithPath: args[1]))
        let engine = try MetalEffectEngine(resources: resources)
        let image = NSImage(contentsOfFile: args[2])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let w = 432, h = 576, radius: Float = 81
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let source = try engine.texture(width: w, height: h, storage: .shared)
        let target = try engine.texture(width: w, height: h, storage: .shared)
        var bytes = [UInt8](repeating: 0, count: w*h*4)
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress!, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
            ctx.setFillColor(CGColor(red: 0.012, green: 0.035, blue: 0.043, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: 135, y: 207, width: 162, height: 162)); ctx.clip()
            ctx.translateBy(x: 216, y: 288); ctx.scaleBy(x: 81/335, y: 81/335)
            ctx.draw(image, in: CGRect(x: -430, y: -584, width: 864, height: 1152))
            ctx.restoreGState()
            source.replace(region: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0,
                withBytes: buffer.baseAddress!, bytesPerRow: w*4)
        }
        for (name, style) in [("shadow", Float(7)), ("rainbow", 8), ("pixel", 9), ("nature", 10)] {
            let frame = EffectFrame(size: CGSize(width: w, height: h), center: SIMD2(216, 288), radius: radius,
                time: 2.35, intensity: 1, style: style)
            try engine.render(frame, into: target, source: source)
            bytes.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: w*4,
                from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0) }
            let provider = CGDataProvider(data: Data(bytes) as CFData)!
            let out = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w*4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
            let folder = URL(fileURLWithPath: args[3]).appendingPathComponent("effect-card-\(name).imageset")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])!
                .write(to: folder.appendingPathComponent("effect-card-\(name).png"))
            let manifest: [String: Any] = ["images": [["filename": "effect-card-\(name).png", "idiom": "universal"]],
                "info": ["author": "xcode", "version": 1]]
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("Contents.json"))
        }
    }
}
