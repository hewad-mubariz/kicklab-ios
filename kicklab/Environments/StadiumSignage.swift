import CoreGraphics
import CoreText
import Foundation
import MetalKit

/// Native lettering for the stadium's advertising ribbons and scoreboards.
/// Matches the other scene signs without baking the app name into a PNG.
nonisolated enum StadiumSignage {
    static func make(device: MTLDevice) throws -> MTLTexture {
        try MTKTextureLoader(device: device).newTexture(cgImage: makeImage(),
            options: [.SRGB: true, .generateMipmaps: true])
    }

    static func makeImage() throws -> CGImage {
        let width = 2048, height = 512
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ForegroundMaskProcessor.Failure.allocation
        }
        let white = CGColor(red: 0.94, green: 0.97, blue: 1, alpha: 1)
        let mint = CGColor(red: 0.04, green: 0.91, blue: 0.70, alpha: 1)
        context.setFillColor(CGColor(red: 0.005, green: 0.025, blue: 0.021, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        func line(_ string: String, size: CGFloat, color: CGColor,
                  italic: Bool = false, kern: CGFloat = 0) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String):
                    CTFontCreateWithName((italic ? "HelveticaNeue-BoldItalic" : "HelveticaNeue-Bold") as CFString, size, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                NSAttributedString.Key(kCTKernAttributeName as String): kern]))
        }
        let juggle = line("Juggle ", size: 186, color: white, italic: true)
        let dude = line("Dude", size: 186, color: mint, italic: true)
        let a = CTLineGetTypographicBounds(juggle, nil, nil, nil)
        let b = CTLineGetTypographicBounds(dude, nil, nil, nil)
        let x = 650 - (a + b) / 2
        context.textPosition = CGPoint(x: x, y: 232); CTLineDraw(juggle, context)
        context.textPosition = CGPoint(x: x + a, y: 232); CTLineDraw(dude, context)

        context.setFillColor(mint)
        context.fill(CGRect(x: 1284, y: 174, width: 8, height: 210))
        for (index, text) in ["PRACTICE.", "IMPROVE.", "REPEAT."].enumerated() {
            let motto = line(text, size: 62, color: index == 2 ? mint : white)
            context.textPosition = CGPoint(x: 1380, y: 344 - index * 72)
            CTLineDraw(motto, context)
        }
        let footer = line("FOOTBALL LIVES HERE.", size: 36, color: white, kern: 7)
        context.textPosition = CGPoint(x: (Double(width) - CTLineGetTypographicBounds(footer, nil, nil, nil)) / 2, y: 66)
        CTLineDraw(footer, context)
        context.setFillColor(mint.copy(alpha: 0.65)!)
        context.fill(CGRect(x: 60, y: 18, width: width - 120, height: 3))
        guard let image = context.makeImage() else { throw ForegroundMaskProcessor.Failure.allocation }
        return image
    }
}
