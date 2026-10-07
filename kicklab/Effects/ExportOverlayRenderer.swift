import CoreGraphics
import CoreText
import Foundation

/// One deterministic drawing path for the editor and encoded video frames.
/// Motion is evaluated from media timestamps, so export and scrubbing agree.
nonisolated enum ExportOverlayRenderer {
    static let badgeSize = CGSize(width: 240, height: 180)

    static func image(style: ExportBadgeStyle,
                      time: Double, counter: ExportCounterState, scale: CGFloat = 2) -> CGImage? {
        let size = badgeSize
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: scale, y: -scale)
        drawBadge(in: ctx, style: style, time: time, counter: counter)
        return ctx.makeImage()
    }

    static func draw(in ctx: CGContext, size: CGSize, settings: ExportOverlaySettings,
                     time: Double, counter: ExportCounterState) {
        guard settings.counter.enabled else { return }
        let item = settings.counter, rect = item.placement.rect(in: size)
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.rotate(by: item.placement.radians)
        ctx.scaleBy(x: rect.width / badgeSize.width, y: rect.height / badgeSize.height)
        ctx.translateBy(x: -badgeSize.width / 2, y: -badgeSize.height / 2)
        drawBadge(in: ctx, style: item.style, time: time, counter: counter)
        ctx.restoreGState()
    }

    private static func drawBadge(in ctx: CGContext, style: ExportBadgeStyle,
                                  time: Double, counter: ExportCounterState) {
        if style == .normal {
            NormalCounterAppearance.draw(in: ctx, counter: counter)
            return
        }
        let time = time.isFinite ? max(0, time) : 0
        let value = counter.count
        let text = String(counter.count)
        let age = counter.age ?? 20
        let pulse = exp(-max(0, age) * 5)
        let milestone = !counter.isTotal && value > 0 && value % 50 == 0 && age < 1.2
        let tint = milestone ? color(1, 0.80, 0.25) : accent(style)
        let center = CGPoint(x: 120, y: 73)
        let fontSize: CGFloat = min(80, 235 / CGFloat(max(3, text.count)))
        ctx.saveGState()
        ctx.clip(to: CGRect(origin: .zero, size: badgeSize))
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        // A soft local scrim, not a large card obscuring the player.
        let scrim = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [color(0.005, 0.035, 0.04, 0.78), color(0, 0, 0, 0)] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y); ctx.scaleBy(x: 1, y: 0.56)
        ctx.drawRadialGradient(scrim, startCenter: .zero, startRadius: 14, endCenter: .zero, endRadius: 118, options: [])
        ctx.restoreGState()

        switch style {
        case .particleBurst, .goldenSparks:
            for i in 0..<38 {
                let phase = random(i, 7), angle = Double(i) * 2.39996
                let travel = min(1, age / 0.8)
                let radius = 57 + phase * 29 + travel * 22
                let point = radial(center, angle, radius)
                let alpha = (0.13 + pulse * 0.85) * (0.45 + phase * 0.55)
                ctx.setStrokeColor(tint.copy(alpha: alpha)!); ctx.setFillColor(tint.copy(alpha: alpha)!)
                ctx.setLineWidth(0.8 + phase)
                if style == .goldenSparks {
                    star(in: ctx, at: point, radius: 1.3 + phase * 2.8, cross: i % 3 == 0)
                } else {
                    ctx.move(to: point); ctx.addLine(to: radial(center, angle, radius + 3 + phase * 5)); ctx.strokePath()
                }
            }
        case .fire:
            for i in 0..<27 {
                let seed = random(i, 12), x = 49 + Double(i) * 5.45
                let flicker = sin(time * (9 + seed * 5) + seed * 30)
                let baseY = center.y - 5 + sin(Double(i)) * 8
                let height = min(baseY - 5, 17 + seed * 25 + pulse * 13 + flicker * 6)
                let flame = CGMutablePath()
                flame.move(to: CGPoint(x: x - 4, y: baseY))
                flame.addCurve(to: CGPoint(x: x + flicker * 5, y: baseY - height),
                    control1: CGPoint(x: x - 12, y: baseY - height * 0.35),
                    control2: CGPoint(x: x + 8, y: baseY - height * 0.55))
                flame.addQuadCurve(to: CGPoint(x: x + 5, y: baseY), control: CGPoint(x: x + 1, y: baseY - height * 0.4))
                flame.closeSubpath()
                ctx.saveGState(); ctx.addPath(flame); ctx.clip()
                gradient(in: ctx, from: CGPoint(x: x, y: baseY), to: CGPoint(x: x, y: baseY - height),
                         colors: [color(1, 0.90, 0.35, 0.94), color(1, 0.26, 0.02, 0.75), color(1, 0.09, 0, 0)])
                ctx.restoreGState()
                let emberY = 10 + (seed * 95 - time * (12 + seed * 8)).truncatingRemainder(dividingBy: 90)
                if emberY > 5 {
                    ctx.setFillColor(color(1, 0.6, 0.12, 0.6)); ctx.fillEllipse(in: CGRect(x: x, y: emberY, width: 1.3, height: 3))
                }
            }
        case .ice:
            // Same idea as fire wisps — colder lateral drift, no ring around the ball.
            for i in 0..<27 {
                let seed = random(i, 12), x = 49 + Double(i) * 5.45
                let flicker = sin(time * (5 + seed * 3) + seed * 30)
                let drift = cos(time * (2.2 + seed) + Double(i) * 0.4) * (8 + seed * 10)
                let baseY = center.y + 2 + sin(Double(i) * 1.3) * 10
                let height = min(abs(baseY - center.y) + 40, 14 + seed * 22 + pulse * 11 + flicker * 5)
                let frost = CGMutablePath()
                frost.move(to: CGPoint(x: x - 3.5 + drift * 0.15, y: baseY))
                frost.addCurve(to: CGPoint(x: x + drift * 0.55 + flicker * 4, y: baseY - height * 0.35),
                    control1: CGPoint(x: x - 10 + drift * 0.2, y: baseY - height * 0.2),
                    control2: CGPoint(x: x + 6 + drift * 0.4, y: baseY - height * 0.15))
                frost.addQuadCurve(to: CGPoint(x: x + 4 + drift * 0.1, y: baseY + height * 0.25),
                    control: CGPoint(x: x + drift * 0.7, y: baseY + height * 0.05))
                frost.closeSubpath()
                ctx.saveGState(); ctx.addPath(frost); ctx.clip()
                gradient(in: ctx, from: CGPoint(x: x, y: baseY + height * 0.2), to: CGPoint(x: x + drift * 0.4, y: baseY - height * 0.4),
                         colors: [color(0.85, 0.97, 1, 0.88), color(0.25, 0.75, 1, 0.62), color(0.05, 0.35, 0.9, 0)])
                ctx.restoreGState()
            }
            for i in 0..<18 {
                let seed = random(i, 3)
                let spin = time * (0.7 + seed) + Double(i) * 2.39996
                let orbit = 48 + seed * 36 + pulse * 28 + sin(time * 2 + Double(i)) * 5
                let point = radial(center, spin, orbit)
                ctx.saveGState(); ctx.translateBy(x: point.x, y: point.y); ctx.rotate(by: spin + seed)
                let r = 1.8 + seed * 3 + pulse * 1.4
                let shard = CGMutablePath(); shard.move(to: CGPoint(x: 0, y: -r * 2.4))
                shard.addLine(to: CGPoint(x: r * 0.85, y: r * 0.3))
                shard.addLine(to: CGPoint(x: 0, y: r * 1.9))
                shard.addLine(to: CGPoint(x: -r * 0.7, y: r * 0.2))
                shard.closeSubpath(); ctx.addPath(shard)
                ctx.setFillColor(color(0.55, 0.9, 1, 0.28 + pulse * 0.5)); ctx.fillPath()
                ctx.addPath(shard); ctx.setStrokeColor(color(0.85, 0.97, 1, 0.85)); ctx.setLineWidth(0.7); ctx.strokePath()
                ctx.restoreGState()
            }
        case .lightning:
            let tick = Int(time * 12)
            for side in [-1.0, 1.0] {
                var points: [CGPoint] = []
                for i in 0..<12 {
                    let x = center.x + side * (84 + (random(i + tick, 6) - 0.5) * 17)
                    points.append(CGPoint(x: x, y: center.y - 46 + Double(i) * 8))
                }
                ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 6 + pulse * 4, color: tint)
                ctx.setLineWidth(1.2 + pulse); ctx.setStrokeColor(tint.copy(alpha: 0.4 + pulse * 0.6)!)
                ctx.addLines(between: points); ctx.strokePath(); ctx.restoreGState()
                for i in [3, 7, 9] {
                    let p = points[i]
                    ctx.setLineWidth(0.65); ctx.setStrokeColor(color(0.8, 0.94, 1, 0.6))
                    ctx.addLines(between: [p, CGPoint(x: p.x + side * 12, y: p.y - 4), CGPoint(x: p.x + side * 18, y: p.y + 1)])
                    ctx.strokePath()
                }
            }
        case .galaxy:
            ctx.saveGState(); ctx.translateBy(x: center.x, y: center.y); ctx.rotate(by: -0.32)
            ctx.setStrokeColor(tint.copy(alpha: 0.68)!); ctx.setLineWidth(0.9)
            ctx.strokeEllipse(in: CGRect(x: -106, y: -28, width: 212, height: 56))
            let angle = time * 0.85
            ctx.setShadow(offset: .zero, blur: 8, color: tint); ctx.setFillColor(color(0.96, 0.82, 1))
            ctx.fillEllipse(in: CGRect(x: cos(angle) * 106 - 2.2, y: sin(angle) * 28 - 2.2, width: 4.4, height: 4.4))
            ctx.restoreGState()
            for i in 0..<43 {
                let point = CGPoint(x: 18 + random(i, 4) * 204, y: 8 + random(i, 9) * 112)
                let twinkle = 0.25 + 0.6 * abs(sin(time * 1.8 + Double(i)))
                ctx.setFillColor(tint.copy(alpha: twinkle)!); ctx.setStrokeColor(color(0.95, 0.85, 1, twinkle)); ctx.setLineWidth(0.7)
                star(in: ctx, at: point, radius: i % 9 == 0 ? 2.7 : 0.8, cross: i % 9 == 0)
            }
        case .neonRing:
            let radius: CGFloat = 62
            ctx.saveGState(); ctx.translateBy(x: center.x, y: center.y)
            ctx.setStrokeColor(tint.copy(alpha: 0.2)!); ctx.setLineWidth(1.4)
            ctx.strokeEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
            let progress = (value > 0 && value % 50 == 0 ? 1 : Double(value % 50) / 50)
            if progress > 0 {
                ctx.setShadow(offset: .zero, blur: 4 + pulse * 4, color: tint)
                ctx.setStrokeColor(tint); ctx.setLineWidth(2)
                ctx.addArc(center: .zero, radius: radius, startAngle: -.pi / 2, endAngle: -.pi / 2 + progress * .pi * 2, clockwise: false)
                ctx.strokePath()
            }
            ctx.restoreGState()
        case .ripple:
            for i in 0..<4 {
                let progress = (min(age, 1.5) / 1.5 + Double(i) / 4).truncatingRemainder(dividingBy: 1)
                let width = 116 + progress * 106, height = 34 + progress * 51
                ctx.setStrokeColor(tint.copy(alpha: (1 - progress) * (0.25 + pulse * 0.65))!); ctx.setLineWidth(0.85)
                ctx.strokeEllipse(in: CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height))
            }
        case .normal, .flipboard, .pixelBurst: break
        }

        if style == .flipboard {
            flipboard(in: ctx, text: text, previous: String(max(0, value - 1)),
                      center: center, tint: tint, age: age)
        } else if style == .pixelBurst {
            pixelText(in: ctx, text: text, center: center, color: tint)
            for i in 0..<22 {
                let p = radial(center, Double(i) * 2.39996, 71 + random(i, 4) * 29 + min(age, 0.8) * 10)
                let side = 1.5 + random(i, 5) * 2.5
                ctx.setFillColor(tint.copy(alpha: 0.18 + pulse * 0.8)!); ctx.fill(CGRect(x: p.x, y: p.y, width: side, height: side))
            }
        } else {
            ctx.saveGState(); ctx.translateBy(x: center.x, y: center.y)
            let bump = 1 + pulse * 0.045; ctx.scaleBy(x: bump, y: bump)
            drawText(text, at: .zero, size: fontSize, color: tint, glow: 7, in: ctx)
            ctx.restoreGState()
        }

        drawText(counter.label,
                 at: CGPoint(x: 120, y: 139), size: 10, color: color(0.91, 0.98, 0.97), glow: 2, in: ctx)
        if !counter.isTotal, milestone {
            let pill = CGRect(x: 72, y: 153, width: 96, height: 21)
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 10.5, cornerHeight: 10.5, transform: nil))
            ctx.setFillColor(color(0.005, 0.04, 0.035, 0.84)); ctx.setStrokeColor(tint.copy(alpha: 0.65)!)
            ctx.setLineWidth(0.65); ctx.drawPath(using: .fillStroke)
            drawText("\(value) REACHED!",
                     at: CGPoint(x: 120, y: 163), size: 9, color: tint, glow: 0, in: ctx)
        }
        if milestone {
            for i in 0..<12 {
                ctx.setFillColor(color(1, 0.8, 0.25, max(0, 1 - age / 1.2)))
                star(in: ctx, at: radial(center, Double(i) * .pi / 6, 70 + age * 24), radius: 3, cross: false)
            }
        }
        ctx.restoreGState()
    }

    private static func flipboard(in ctx: CGContext, text: String, previous: String, center: CGPoint, tint: CGColor, age: Double) {
        let chars = Array(text), old = Array(previous)
        let cellWidth = min(64.0, 198.0 / Double(chars.count)), height = min(82.0, cellWidth * 1.35)
        for (i, char) in chars.enumerated() {
            let x = center.x + (Double(i) - Double(chars.count - 1) / 2) * cellWidth
            let rect = CGRect(x: x - cellWidth / 2 + 2, y: center.y - height / 2, width: cellWidth - 4, height: height)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 7, cornerHeight: 7, transform: nil))
            ctx.setFillColor(color(0.07, 0.13, 0.14, 0.94)); ctx.setStrokeColor(color(0.55, 0.74, 0.72, 0.6)); ctx.setLineWidth(0.65)
            ctx.drawPath(using: .fillStroke)
            let changing = old.count == chars.count && old[i] != char && age < 0.3
            drawText(String(char), at: CGPoint(x: x, y: center.y), size: cellWidth * 1.04, color: tint, glow: 0, in: ctx)
            if changing {
                // Only the changed digit flips; it is derived from the event age.
                ctx.saveGState()
                let top = age < 0.15
                ctx.clip(to: CGRect(x: rect.minX, y: top ? rect.minY : center.y, width: rect.width, height: height / 2))
                ctx.setFillColor(color(0.10, 0.19, 0.19)); ctx.fill(rect)
                ctx.translateBy(x: x, y: center.y)
                ctx.scaleBy(x: 1, y: max(0.05, abs(cos(age / 0.3 * .pi))))
                drawText(String(top ? old[i] : char), at: .zero, size: cellWidth * 1.04, color: tint, glow: 0, in: ctx)
                ctx.restoreGState()
            }
            ctx.setStrokeColor(color(0, 0, 0, 0.8)); ctx.setLineWidth(1.4)
            ctx.move(to: CGPoint(x: rect.minX, y: center.y)); ctx.addLine(to: CGPoint(x: rect.maxX, y: center.y)); ctx.strokePath()
            ctx.setFillColor(color(0.49, 0.65, 0.62))
            for side in [rect.minX, rect.maxX - 2] { ctx.fill(CGRect(x: side, y: center.y - 3, width: 2, height: 6)) }
        }
    }

    private static let pixelGlyphs: [Character: [String]] = [
        "0": ["01110","11011","11011","11011","11011","11011","01110"],
        "1": ["00100","01100","00100","00100","00100","00100","01110"],
        "2": ["11110","00011","00011","01110","11000","11000","11111"],
        "3": ["11110","00011","00011","01110","00011","00011","11110"],
        "4": ["11011","11011","11011","11111","00011","00011","00011"],
        "5": ["11111","11000","11000","11110","00011","00011","11110"],
        "6": ["01111","11000","11000","11110","11011","11011","01110"],
        "7": ["11111","00011","00010","00110","00100","01100","01100"],
        "8": ["01110","11011","11011","01110","11011","11011","01110"],
        "9": ["01110","11011","11011","01111","00011","00011","11110"],
        ":": ["0","1","1","0","1","1","0"]]

    private static func pixelText(in ctx: CGContext, text: String, center: CGPoint, color: CGColor) {
        let glyphs = text.compactMap { pixelGlyphs[$0] }
        let columns = glyphs.reduce(0) { $0 + ($1.first?.count ?? 0) + 1 } - 1
        let unit = min(9, 186 / Double(max(1, columns)))
        var x = center.x - Double(columns) * unit / 2
        ctx.saveGState(); ctx.setFillColor(color); ctx.setShadow(offset: .zero, blur: 3, color: color.copy(alpha: 0.45))
        for glyph in glyphs {
            for (row, pixels) in glyph.enumerated() {
                for (col, value) in pixels.enumerated() where value == "1" {
                    ctx.fill(CGRect(x: x + Double(col) * unit, y: center.y + (Double(row) - 3.5) * unit,
                                    width: unit * 0.79, height: unit * 0.79))
                }
            }
            x += Double((glyph.first?.count ?? 0) + 1) * unit
        }
        ctx.restoreGState()
    }

    private static func drawText(_ value: String, at center: CGPoint, size: CGFloat, color: CGColor, glow: Double, in ctx: CGContext) {
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.saveGState(); ctx.translateBy(x: center.x - bounds.midX, y: center.y + bounds.midY); ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity; ctx.textPosition = .zero
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: max(3, glow), color: glow > 0 ? color.copy(alpha: 0.6) : CGColor(gray: 0, alpha: 1))
        CTLineDraw(line, ctx)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setTextDrawingMode(.clip); ctx.textPosition = .zero; CTLineDraw(line, ctx)
        gradient(in: ctx, from: CGPoint(x: 0, y: bounds.maxY), to: CGPoint(x: 0, y: bounds.minY),
                 colors: [CGColor(gray: 1, alpha: 1), color])
        ctx.restoreGState()
    }

    private static func star(in ctx: CGContext, at p: CGPoint, radius: Double, cross: Bool) {
        if cross {
            ctx.move(to: CGPoint(x: p.x - radius, y: p.y)); ctx.addLine(to: CGPoint(x: p.x + radius, y: p.y))
            ctx.move(to: CGPoint(x: p.x, y: p.y - radius)); ctx.addLine(to: CGPoint(x: p.x, y: p.y + radius)); ctx.strokePath()
        } else {
            for i in 0..<8 {
                let a = Double(i) * .pi / 4 - .pi / 2, r = i % 2 == 0 ? radius : radius * 0.32
                let v = CGPoint(x: p.x + cos(a) * r, y: p.y + sin(a) * r)
                if i == 0 { ctx.move(to: v) } else { ctx.addLine(to: v) }
            }
            ctx.closePath(); ctx.fillPath()
        }
    }

    private static func gradient(in ctx: CGContext, from: CGPoint, to: CGPoint, colors: [CGColor]) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil) else { return }
        ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    private static func random(_ i: Int, _ seed: Int) -> Double {
        let n = sin(Double(i * 71 + seed * 97) * 12.9898) * 43758.5453
        return n - floor(n)
    }
    private static func radial(_ center: CGPoint, _ angle: Double, _ radius: Double) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius * 0.62)
    }
    private static func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: a)
    }
    private static func accent(_ style: ExportBadgeStyle) -> CGColor {
        switch style {
        case .normal: NormalCounterAppearance.white
        case .particleBurst, .neonRing: color(0.28, 1, 0.65)
        case .fire: color(1, 0.55, 0.14)
        case .ice: color(0.48, 0.84, 1)
        case .lightning: color(0.56, 0.77, 1)
        case .galaxy: color(0.77, 0.43, 1)
        case .ripple: color(0.43, 0.93, 0.87)
        case .flipboard: color(0.78, 0.96, 0.90)
        case .pixelBurst: color(0.3, 0.91, 1)
        case .goldenSparks: color(1, 0.78, 0.21)
        }
    }
}
