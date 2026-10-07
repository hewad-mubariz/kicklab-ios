import CoreGraphics
import CoreText
import Foundation
import MetalKit

/// Two canvas banners: the training motto and the forest scene's signature line.
nonisolated enum ForestSignage {
    static func make(device: MTLDevice) throws -> MTLTexture {
        let width = 2048, height = 1024
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ForegroundMaskProcessor.Failure.allocation
        }
        let white = CGColor(red: 0.91, green: 0.90, blue: 0.81, alpha: 1)
        let teal = CGColor(red: 0.14, green: 0.66, blue: 0.46, alpha: 1)
        func line(_ string: String, size: CGFloat, color: CGColor) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("HelveticaNeue-BoldItalic" as CFString, size, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]))
        }
        func draw(_ string: String, size: CGFloat, y: CGFloat) {
            let text = line(string, size: size, color: white)
            context.textPosition = CGPoint(x: (Double(width) - CTLineGetTypographicBounds(text, nil, nil, nil)) / 2, y: y)
            CTLineDraw(text, context)
        }
        let kick = line("KICK", size: 202, color: white), lab = line("LAB", size: 202, color: teal)
        let a = CTLineGetTypographicBounds(kick, nil, nil, nil), b = CTLineGetTypographicBounds(lab, nil, nil, nil)
        context.textPosition = CGPoint(x: (2048-a-b)/2, y: 818); CTLineDraw(kick, context)
        context.textPosition = CGPoint(x: (2048-a-b)/2+a, y: 818); CTLineDraw(lab, context)
        for (i, text) in ["PRACTICE.", "IMPROVE.", "REPEAT."].enumerated() { draw(text, size: 78, y: CGFloat(720-i*81)) }
        draw("SAME GAME.", size: 114, y: 270)
        draw("DIFFERENT VIBES.", size: 114, y: 132)
        context.setStrokeColor(teal); context.setLineWidth(9)
        context.move(to: CGPoint(x: 490, y: 87)); context.addLine(to: CGPoint(x: 1560, y: 108)); context.strokePath()
        guard let image = context.makeImage() else { throw ForegroundMaskProcessor.Failure.allocation }
        return try MTKTextureLoader(device: device).newTexture(cgImage: image, options: [.SRGB: true, .generateMipmaps: true])
    }
}
