import CoreGraphics
import CoreText
import Foundation

/// The same elapsed-time badge is drawn in the replay and into encoded frames.
/// Its clock is the video's presentation time, independent of analysis frame rate.
nonisolated enum TimerOverlayAppearance {
    static let size = CGSize(width: 160, height: 64)

    static func rect(in video: CGSize) -> CGRect {
        let width = min(video.width, video.height) * 0.28
        return CGRect(x: video.width - video.width * 0.04 - width,
                      y: video.height * 0.10, width: width, height: width * size.height / size.width)
    }

    static func image(time: Double, scale: CGFloat = 2) -> CGImage? {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: scale, y: -scale)
        draw(in: context, rect: CGRect(origin: .zero, size: size), time: time)
        return context.makeImage()
    }

    static func draw(in context: CGContext, rect: CGRect, time: Double) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / size.width, y: rect.height / size.height)
        context.setFillColor(CGColor(gray: 0, alpha: 0.48))
        context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size),
                              cornerWidth: 18, cornerHeight: 18, transform: nil))
        context.fillPath()
        text("TIME", top: 10, fontSize: 10, color: CGColor(gray: 1, alpha: 0.75), in: context)
        let label = ExportPreviewTime.label(at: time)
        text(label, top: 28, fontSize: label.count > 5 ? 23 : 28, color: NormalCounterAppearance.white, in: context)
    }

    private static func text(_ text: String, top: CGFloat, fontSize: CGFloat, color: CGColor,
                             in context: CGContext) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.saveGState()
        context.translateBy(x: (size.width - bounds.width) / 2 - bounds.minX, y: top + bounds.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity; context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
