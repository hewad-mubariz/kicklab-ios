import CoreGraphics
import CoreText
import Foundation

/// Streak milestones: the counter celebrates the 10th, 25th, 50th, 75th and 100th touch, then
/// every 50th. Everything follows the counter's own timeline, so replay and export agree.
nonisolated enum Milestones {
    /// Seconds the celebration stays on screen after the milestone touch.
    static let duration = 1.3

    static func isMilestone(_ count: Int) -> Bool {
        [10, 25, 50, 75, 100].contains(count) || (count > 100 && count % 50 == 0)
    }

    /// Positions in the sorted touch list whose touch reaches a milestone.
    static func touchIndices(touchCount: Int) -> [Int] {
        guard touchCount >= 10 else { return [] }
        return (10...touchCount).filter(isMilestone).map { $0 - 1 }
    }

    /// The celebration in progress for this counter state, with its progress in 0..<1.
    static func active(_ state: ExportCounterState) -> (count: Int, progress: Double)? {
        guard !state.isTotal, let age = state.age, age >= 0, age < duration, isMilestone(state.count) else { return nil }
        return (state.count, age / duration)
    }

    /// The counter's size through the moment: a quick swell, a springy overshoot, then rest.
    static func pulse(_ progress: Double) -> CGFloat {
        let t = max(0, progress) * duration
        if t < 0.12 { return 1 + 0.22 * t / 0.12 }
        let settle = t - 0.12
        return 1 + 0.22 * exp(-settle * 6.5) * cos(settle * 15)
    }
}

/// The celebration around the counter badge: a flash, two rings, rays, confetti and a tag that
/// rises under the count. Drawn in the badge's own 240×180 space, reaching past it on every side.
nonisolated enum MilestoneAppearance {
    /// The canvas for a standalone image: twice the badge, with the badge centred.
    static let canvas = CGSize(width: 480, height: 360)
    static let badgeOrigin = CGPoint(x: 120, y: 90)
    private static let center = CGPoint(x: 120, y: 90)

    private static let lime = NormalCounterAppearance.lime
    private static let mint = CGColor(red: 0.34, green: 0.96, blue: 0.65, alpha: 1)
    private static let palette: [CGColor] = [
        NormalCounterAppearance.lime, CGColor(red: 0.34, green: 0.96, blue: 0.65, alpha: 1),
        CGColor(gray: 1, alpha: 1), CGColor(red: 1, green: 0.82, blue: 0.3, alpha: 1),
        CGColor(red: 1, green: 0.42, blue: 0.75, alpha: 1)
    ]

    static func image(count: Int, progress: Double, scale: CGFloat = 2) -> CGImage? {
        let width = Int(canvas.width * scale), height = Int(canvas.height * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: badgeOrigin.x, y: badgeOrigin.y)
        draw(in: ctx, count: count, progress: progress)
        return ctx.makeImage()
    }

    /// Top-left badge coordinates. A pure function of the count and progress.
    static func draw(in ctx: CGContext, count: Int, progress: Double) {
        guard progress >= 0, progress < 1 else { return }
        let t = progress * Milestones.duration
        ctx.saveGState()
        defer { ctx.restoreGState() }
        func ease(_ x: Double) -> Double { let c = min(1, max(0, x)); return 1 - (1 - c) * (1 - c) }
        func circle(_ r: Double) -> CGRect { CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2) }

        // Flash behind the count.
        let flash = max(0, 1 - t / 0.35)
        if flash > 0 {
            ctx.setBlendMode(.plusLighter)
            for step in 0..<5 {
                let f = Double(step) / 4, r = 70 + 70 * f
                ctx.setFillColor(lime.copy(alpha: 0.11 * flash * (1 - f * 0.8))!)
                ctx.fillEllipse(in: circle(r))
            }
            ctx.setBlendMode(.normal)
        }
        // Two rings racing out.
        for (delay, color) in [(0.0, lime), (0.12, mint)] {
            let u = ease((t - delay) / 0.8)
            guard t >= delay, u < 1 else { continue }
            ctx.setStrokeColor(color.copy(alpha: 1 - u)!)
            ctx.setLineWidth(10 * (1 - u) + 1.5)
            ctx.strokeEllipse(in: circle(70 + 190 * u))
        }
        // Rays.
        let rays = ease(t / 0.6)
        if rays < 1 {
            ctx.setLineCap(.round)
            for index in 0..<16 {
                let angle = Double(index) / 16 * 2 * .pi + 0.1
                let inner = 78 + 50 * rays, outer = 100 + 160 * rays
                ctx.setStrokeColor((index % 2 == 0 ? lime : CGColor(gray: 1, alpha: 1)).copy(alpha: (1 - rays) * (1 - rays))!)
                ctx.setLineWidth(5 * (1 - rays) + 1)
                ctx.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                ctx.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
                ctx.strokePath()
            }
        }
        // Confetti thrown up and out, pulled back down.
        for index in 0..<28 {
            func noise(_ lane: Int) -> Double {
                let v = sin(Double(count * 31 + index) * 12.9898 + Double(lane) * 78.233) * 43758.5453
                return v - floor(v)
            }
            let angle = -.pi * (0.08 + 0.84 * noise(1))
            let speed = 190 + 170 * noise(2)
            let x = center.x + cos(angle) * speed * t
            let y = center.y + sin(angle) * speed * t + 0.5 * 520 * t * t
            let alpha = t < 0.8 ? 1 : max(0, 1 - (t - 0.8) / 0.5)
            guard alpha > 0 else { continue }
            ctx.saveGState()
            ctx.translateBy(x: x, y: y)
            ctx.rotate(by: t * (noise(3) - 0.5) * 16)
            ctx.setFillColor(palette[index % palette.count].copy(alpha: alpha)!)
            ctx.fill(CGRect(x: -3.5, y: -5.5, width: 7, height: 11))
            ctx.restoreGState()
        }
        tag("★ \(count) TOUCHES", ctx: ctx, t: t)
    }

    /// A lime tag that rises under the count and fades out at the end.
    private static func tag(_ text: String, ctx: CGContext, t: Double) {
        let appear = min(1, t / 0.15), leave = t > 1.0 ? max(0, (Milestones.duration - t) / 0.3) : 1
        let alpha = appear * leave
        guard alpha > 0.01 else { return }
        let rise = 1 - pow(1 - min(1, t / 0.28), 3)
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 22, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.015, green: 0.12, blue: 0.08, alpha: alpha),
            NSAttributedString.Key(kCTKernAttributeName as String): 1.5
        ]))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let width = bounds.width + 30, height: CGFloat = 40
        let y = 196 + 22 * (1 - rise)
        let pill = CGRect(x: center.x - width / 2, y: y, width: width, height: height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 10, color: CGColor(gray: 0, alpha: 0.4 * alpha))
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 20, cornerHeight: 20, transform: nil))
        ctx.setFillColor(lime.copy(alpha: alpha)!); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.translateBy(x: pill.midX - bounds.width / 2 - bounds.minX, y: pill.midY + bounds.height / 2 + bounds.minY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity; ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
