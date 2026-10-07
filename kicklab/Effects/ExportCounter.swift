import CoreGraphics
import CoreText
import Foundation

/// Recorded events, never an estimated ramp from the final score.
nonisolated struct ExportCounterTimeline: Equatable, Sendable {
    let times: [Double]
    let total: Int

    init(touches: [RecordedTouch], total: Int) {
        times = touches.map(\.time).filter { $0.isFinite && $0 >= 0 }.sorted()
        self.total = max(0, total)
    }

    func state(at time: Double) -> ExportCounterState {
        guard !times.isEmpty else { return .init(count: total, isTotal: true, age: nil) }
        let time = time.isFinite ? max(0, time) : 0
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] <= time { lo = mid + 1 } else { hi = mid }
        }
        return .init(count: lo, isTotal: false, age: lo > 0 ? time - times[lo-1] : nil)
    }
}

nonisolated struct ExportCounterState: Equatable, Sendable {
    let count: Int
    let isTotal: Bool
    let age: Double?
    var label: String { isTotal ? "TOTAL TOUCHES" : "TOUCHES" }
}

/// Shared CoreText badge for the share preview and the actual encoded pixels.
/// Draw after the video grade/effects so the count stays legible in every style.
nonisolated enum ExportCounterRenderer {
    static let badgeSize = CGSize(width: 220, height: 132)

    static func rect(in size: CGSize) -> CGRect {
        let width = min(size.width * 0.56, size.height * 0.36)
        return CGRect(x: (size.width-width)/2, y: size.height*0.055,
                      width: width, height: width * badgeSize.height / badgeSize.width)
    }

    static func image(state: ExportCounterState, scale: CGFloat = 2) -> CGImage? {
        let width = Int(badgeSize.width*scale), height = Int(badgeSize.height*scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: scale, y: -scale)
        drawBadge(in: ctx, state: state)
        return ctx.makeImage()
    }

    static func draw(in ctx: CGContext, size: CGSize, state: ExportCounterState) {
        let rect = rect(in: size)
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / badgeSize.width, y: rect.height / badgeSize.height)
        drawBadge(in: ctx, state: state)
        ctx.restoreGState()
    }

    private static func drawBadge(in ctx: CGContext, state: ExportCounterState) {
        let mint = CGColor(red: 0.32, green: 1, blue: 0.63, alpha: 1)
        let card = CGPath(roundedRect: CGRect(x: 15, y: 7, width: 190, height: 116),
                          cornerWidth: 25, cornerHeight: 25, transform: nil)
        ctx.saveGState()
        ctx.addPath(card)
        ctx.setFillColor(CGColor(red: 0.015, green: 0.07, blue: 0.065, alpha: 0.76))
        ctx.fillPath()
        ctx.addPath(card)
        ctx.setStrokeColor(CGColor(red: 0.35, green: 1, blue: 0.65, alpha: 0.38))
        ctx.setLineWidth(0.8); ctx.strokePath()
        let pulse = state.age.map { exp(-max(0, $0) * 9) } ?? 0
        text(String(state.count), top: 20, fontSize: min(70, 230 / CGFloat(max(3, String(state.count).count))),
             color: mint, glow: 5 + pulse * 6, in: ctx)
        text(state.label, top: 98, fontSize: 10, color: CGColor(gray: 1, alpha: 0.92), glow: 0, in: ctx)
        ctx.restoreGState()
    }

    private static func text(_ text: String, top: CGFloat, fontSize: CGFloat, color: CGColor, glow: Double, in ctx: CGContext) {
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.saveGState()
        ctx.translateBy(x: badgeSize.width/2-bounds.midX, y: top+bounds.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = .zero
        if glow > 0 { ctx.setShadow(offset: .zero, blur: glow, color: color.copy(alpha: 0.65)) }
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
