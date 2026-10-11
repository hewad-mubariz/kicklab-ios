// Compile with BallSkin.swift, BallCollectionMaterial.swift and BallSkinSphereRenderer.swift.
// Runs the production renderer at picker/export sizes without loading a video or app account.
import AppKit
import Foundation
import simd

@main struct ReviewBallCollection {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let start = Date()
        let originalCatalog = CommandLine.arguments.contains("--original-catalog")
        let skins: [BallSkin] = originalCatalog
            ? [.classic, .stealth, .matrix, .gold, .arctic, .crimson, .galaxy, .chrome, .graffiti, .aurora]
            : [.metal, .lava, .pearl, .volt]
        let columns = originalCatalog ? 5 : 4
        let rows = (skins.count + columns - 1) / columns
        let canvasWidth = columns * 300, canvasHeight = rows * 450
        let canvas = CGContext(data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.setFillColor(NSColor(white: 0.055, alpha: 1).cgColor)
        canvas.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        for (i, skin) in skins.enumerated() {
            let image = BallSkinSphereRenderer.image(skin: skin, time: 1.4)!
            let x = CGFloat(i % columns * 300)
            let y = CGFloat((rows - 1 - i / columns) * 450)
            canvas.saveGState()
            canvas.translateBy(x: 0, y: y)
            canvas.interpolationQuality = .high
            canvas.draw(image, in: CGRect(x: x + 22, y: 138, width: 256, height: 256))
            canvas.draw(image, in: CGRect(x: x + 124, y: 42, width: 52, height: 52))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
            let style = NSMutableParagraphStyle(); style.alignment = .center
            (skin.title as NSString).draw(in: CGRect(x: x, y: 98, width: 300, height: 26), withAttributes: [
                .font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.white,
                .paragraphStyle: style])
            NSGraphicsContext.restoreGraphicsState()
            canvas.restoreGState()
            for pose in 0..<4 {
                let rotation = simd_quatf(angle: Float(pose) * .pi / 2, axis: SIMD3<Float>(0,1,0))
                let rendered = BallSkinSphereRenderer.image(skin: skin, time: 0, orientation: rotation)!
                try NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:])!
                    .write(to: directory.appendingPathComponent("\(skin.rawValue)-\(pose).png"))
            }
        }
        try NSBitmapImageRep(cgImage: canvas.makeImage()!).representation(using: .png, properties: [:])!
            .write(to: directory.appendingPathComponent("production-materials.png"))
        print("Prepared \(BallSkinSphereRenderer.decodedArtworkBytes) bytes in \(Date().timeIntervalSince(start)) seconds")
    }
}
