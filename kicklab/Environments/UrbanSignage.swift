import CoreGraphics
import CoreText
import Foundation
import MetalKit

/// Four transparent rows of painted court lettering, set at native resolution.
nonisolated enum UrbanSignage {
    static func make(device: MTLDevice) throws -> MTLTexture {
        let width = 2048, height = 2048
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ForegroundMaskProcessor.Failure.allocation
        }
        let white = CGColor(red: 0.84, green: 0.85, blue: 0.83, alpha: 1)
        let teal = CGColor(red: 0.07, green: 0.65, blue: 0.51, alpha: 1)
        func line(_ string: String, size: CGFloat, color: CGColor) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("HelveticaNeue-CondensedBlack" as CFString, size, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]))
        }
        func draw(_ string: String, row: Int, y: CGFloat, size: CGFloat, color: CGColor) {
            let text = line(string, size: size, color: color)
            context.textPosition = CGPoint(x: (Double(width) - CTLineGetTypographicBounds(text, nil, nil, nil)) / 2,
                y: CGFloat(height - (row + 1) * 512) + y)
            CTLineDraw(text, context)
        }
        // Keep the longer name inside the original wall-sign footprint.
        let juggle = line("Juggle ", size: 225, color: white), dude = line("Dude", size: 225, color: teal)
        let a = CTLineGetTypographicBounds(juggle, nil, nil, nil), b = CTLineGetTypographicBounds(dude, nil, nil, nil)
        context.textPosition = CGPoint(x: (2048 - a - b) / 2, y: 1670); CTLineDraw(juggle, context)
        context.textPosition = CGPoint(x: (2048 - a - b) / 2 + a, y: 1670); CTLineDraw(dude, context)
        for (index, string) in ["PRACTICE.", "IMPROVE.", "REPEAT."].enumerated() {
            draw(string, row: 1, y: CGFloat(350 - index * 132), size: 144, color: white)
        }
        draw("FOOTBALL", row: 2, y: 280, size: 190, color: white)
        draw("LIVES HERE.", row: 2, y: 85, size: 190, color: white)
        draw("BETTER PLAYERS", row: 3, y: 290, size: 135, color: white)
        draw("BRIGHTER TOMORROW", row: 3, y: 115, size: 135, color: white)
        for row in [1, 2] {
            context.setStrokeColor(teal); context.setLineWidth(12)
            context.move(to: CGPoint(x: 620, y: height - (row + 1) * 512 + 45))
            context.addLine(to: CGPoint(x: 1440, y: height - (row + 1) * 512 + 64)); context.strokePath()
        }
        guard let image = context.makeImage() else { throw ForegroundMaskProcessor.Failure.allocation }
        return try MTKTextureLoader(device: device).newTexture(cgImage: image, options: [.SRGB: true, .generateMipmaps: true])
    }
}
