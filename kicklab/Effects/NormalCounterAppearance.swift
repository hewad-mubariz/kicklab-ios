import CoreGraphics
import CoreText
import Foundation

/// Typography and colors from kicklab-lab/scripts/render_phone_replay.py.
nonisolated enum NormalCounterAppearance {
    static let fontName = "DINCondensed-Bold"
    static let white = CGColor(red: 249.0 / 255, green: 250.0 / 255, blue: 243.0 / 255, alpha: 1)
    static let lime = CGColor(red: 211.0 / 255, green: 1, blue: 64.0 / 255, alpha: 1)

    static func label(_ count: Int) -> String { String(format: "%02d", max(0, count)) }
    static func fontSize(_ count: Int, base: CGFloat) -> CGFloat {
        base * min(1, 3 / CGFloat(max(1, label(count).count)))
    }

    static func draw(in context: CGContext, counter: ExportCounterState) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: CGRect(x: 0, y: 0, width: 240, height: 180))
        let width = text(label(counter.count), topLeft: CGPoint(x: 8, y: 8),
                         name: fontName, size: fontSize(counter.count, base: 140), color: white, in: context)
        if !counter.isTotal, let age = counter.age, age >= 0, age < 0.3 {
            text("+1", topLeft: CGPoint(x: width + 22, y: 70), name: "HelveticaNeue-Medium", size: 22,
                 color: lime.copy(alpha: 1 - age / 0.3)!, in: context)
        }
        text(counter.label, topLeft: CGPoint(x: 9, y: 139), name: "HelveticaNeue-Medium", size: 16,
             color: white, tracking: 2.5, in: context)
    }

    @discardableResult
    private static func text(_ text: String, topLeft: CGPoint, name: String, size: CGFloat,
                             color: CGColor, tracking: CGFloat = 0, in context: CGContext) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(name as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTKernAttributeName as String): tracking
        ]))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.saveGState()
        context.translateBy(x: topLeft.x - bounds.minX, y: topLeft.y + bounds.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity; context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
        return bounds.width
    }
}
