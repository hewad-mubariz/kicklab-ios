import CoreGraphics
import CoreText
import UIKit

/// The original capture counter: heavy system digits, white-to-mint fill and touch sparks.
/// Shared by the style picker, replay and encoded frames so a saved choice looks the same.
nonisolated enum ClassicCounterAppearance {
    static let mint = CGColor(red: 0.34, green: 0.96, blue: 0.65, alpha: 1)

    static func draw(in context: CGContext, counter: ExportCounterState) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: CGRect(x: 0, y: 0, width: 240, height: 180))

        let value = NormalCounterAppearance.label(counter.count)
        let line = numberLine(value)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let center = CGPoint(x: 12 + bounds.width / 2, y: 26 + bounds.height / 2)
        if !counter.isTotal, counter.count > 0, let age = counter.age, age.isFinite, (0..<1.05).contains(age) {
            burst(in: context, center: center, age: age, seed: counter.count)
        }

        context.saveGState()
        context.translateBy(x: 12 - bounds.minX, y: 26 + bounds.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: CGColor(gray: 0, alpha: 0.5))
        CTLineDraw(line, context)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setTextDrawingMode(.clip)
        context.textPosition = .zero
        CTLineDraw(line, context)
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [CGColor(gray: 1, alpha: 1), mint] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient,
            start: CGPoint(x: 0, y: bounds.maxY), end: CGPoint(x: 0, y: bounds.minY), options: [])
        context.restoreGState()

        let label = CTLineCreateWithAttributedString(NSAttributedString(string: counter.label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): UIFont.systemFont(ofSize: 16, weight: .semibold) as CTFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            NSAttributedString.Key(kCTKernAttributeName as String): 2.5
        ]))
        let labelBounds = CTLineGetBoundsWithOptions(label, .useGlyphPathBounds)
        context.translateBy(x: 14 - labelBounds.minX, y: 139 + labelBounds.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(label, context)
    }

    private static func numberLine(_ text: String) -> CTLine {
        func line(at size: CGFloat) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): UIFont.monospacedDigitSystemFont(ofSize: size, weight: .black) as CTFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): mint,
                NSAttributedString.Key(kCTKernAttributeName as String): -size * 2 / 62
            ]))
        }
        let initial = line(at: 114)
        let width = CTLineGetBoundsWithOptions(initial, .useGlyphPathBounds).width
        return width > 214 ? line(at: 114 * 214 / width) : initial
    }

    private static func burst(in context: CGContext, center: CGPoint, age: Double, seed: Int) {
        let fade = pow(1 - age / 1.05, 2)
        context.setLineCap(.round)
        for index in 0..<28 {
            let phase = Double(index) * 2.399963 + Double(seed % 19) * 0.17
            let variation = Double((index * 37 + seed % 31) % 29) / 29
            let radius = 48 + variation * 18 + age * (18 + variation * 25)
            let length = 2 + variation * 5
            let point = CGPoint(x: center.x + cos(phase) * radius,
                                y: center.y + sin(phase) * radius * 0.66)
            let color = index.isMultiple(of: 4) ? CGColor(gray: 1, alpha: fade) : mint.copy(alpha: fade * 0.85)!
            context.setStrokeColor(color)
            context.setLineWidth(1 + variation * 1.2)
            context.setShadow(offset: .zero, blur: 3, color: mint.copy(alpha: fade * 0.45))
            context.move(to: point)
            context.addLine(to: CGPoint(x: point.x + cos(phase) * length,
                                       y: point.y + sin(phase) * length * 0.66))
            context.strokePath()
        }
        context.setShadow(offset: .zero, blur: 0, color: nil)
    }
}
