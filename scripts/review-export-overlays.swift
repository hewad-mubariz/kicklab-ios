// Compile with ExportCounter.swift, ExportOverlaySettings.swift and ExportOverlayRenderer.swift.
// This fixture supplies only the event fields used by the shared timeline.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RecordedTouch { let time: Double }

@main struct ReviewExportOverlays {
    static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let ctx = CGContext(data: nil, width: 1600, height: 580, bitsPerComponent: 8, bytesPerRow: 6400,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 0.018, green: 0.048, blue: 0.06, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 580))
            for (i, style) in ExportBadgeStyle.allCases.enumerated() {
                let image = ExportOverlayRenderer.image(style: style, time: style == .flipboard ? 24.4 : 24.15,
                    counter: .init(count: 24, isTotal: false, age: style == .flipboard ? 0.4 : 0.15), scale: 2)!
                let x = Double(i % 5) * 320 + 20, y = 580 - Double(i / 5 + 1) * 290
                let height = 210.0
                ctx.draw(image, in: CGRect(x: x, y: y + 55, width: 280, height: height))
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: style.title, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 18, nil),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.95, alpha: 1)]))
                let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                ctx.textMatrix = .identity; ctx.textPosition = CGPoint(x: x + 140 - bounds.midX, y: y + 30)
                CTLineDraw(line, ctx)
            }
            let url = folder.appendingPathComponent("counter-styles.png")
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
            guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "Review", code: 1) }
            print(url.path)
        }
    }
}
