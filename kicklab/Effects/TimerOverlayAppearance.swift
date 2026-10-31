import CoreGraphics
import CoreText
import Foundation

/// Looks for the elapsed-time sticker. Each one says "time" with an icon, a pulse or a moving
/// dial rather than a caption.
nonisolated enum TimerStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case pill, clean, broadcast, stopwatch, digital, flip, neon
    var id: String { rawValue }
    var requiresPro: Bool { self != .pill }

    var title: String {
        switch self {
        case .pill: "Pill"
        case .clean: "Clean"
        case .broadcast: "Broadcast"
        case .stopwatch: "Stopwatch"
        case .digital: "Digital"
        case .flip: "Flip"
        case .neon: "Neon"
        }
    }

    /// Unknown saved styles fall back to the free Pill.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .pill
    }
}

/// The same elapsed-time sticker is drawn in the replay and into encoded frames.
/// Its clock is the video's presentation time, independent of analysis frame rate; every
/// motion (pulse, hand, flip, blink) is a function of that time, so seeking and export agree.
nonisolated enum TimerOverlayAppearance {
    /// The drawing canvas, top-left origin. The sticker's placement scales it onto the video.
    static let size = CGSize(width: 240, height: 120)

    static func image(style: TimerStyle, time: Double, scale: CGFloat = 2) -> CGImage? {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: scale, y: -scale)
        draw(style, in: context, time: time)
        return context.makeImage()
    }

    /// Draws into the canvas rectangle at the context's origin, top-left coordinates.
    static func draw(_ style: TimerStyle, in context: CGContext, time: Double) {
        let t = time.isFinite ? max(0, time) : 0
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: CGRect(origin: .zero, size: size))
        switch style {
        case .pill: pill(context, t)
        case .clean: clean(context, t)
        case .broadcast: broadcast(context, t)
        case .stopwatch: stopwatch(context, t)
        case .digital: digital(context, t)
        case .flip: flip(context, t)
        case .neon: neon(context, t)
        }
    }

    // MARK: - Palette

    private static let white = NormalCounterAppearance.white
    private static let lime = NormalCounterAppearance.lime
    private static let mint = CGColor(red: 0.34, green: 0.96, blue: 0.65, alpha: 1)
    private static let ink = CGColor(red: 0.035, green: 0.05, blue: 0.06, alpha: 1)
    private static func gray(_ value: CGFloat, _ alpha: CGFloat = 1) -> CGColor { CGColor(gray: value, alpha: alpha) }

    private static func fraction(_ t: Double) -> Double { t - floor(t) }
    /// Seconds into the current minute, continuous, as 0..<1.
    private static func minuteProgress(_ t: Double) -> Double { t.truncatingRemainder(dividingBy: 60) / 60 }

    // MARK: - Styles

    /// A dark glass capsule with a live dot that breathes once a second.
    private static func pill(_ ctx: CGContext, _ t: Double) {
        let capsule = CGRect(x: 6, y: 22, width: 228, height: 76)
        let path = CGPath(roundedRect: capsule, cornerWidth: 38, cornerHeight: 38, transform: nil)
        ctx.addPath(path); ctx.setFillColor(gray(0, 0.56)); ctx.fillPath()
        // A soft highlight across the upper half reads as glass on any footage.
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [gray(1, 0.16), gray(1, 0)] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: capsule.minY), end: CGPoint(x: 0, y: capsule.midY), options: [])
        }
        ctx.restoreGState()
        ctx.addPath(path); ctx.setStrokeColor(gray(1, 0.18)); ctx.setLineWidth(1.5); ctx.strokePath()
        let pulse = 0.5 + 0.5 * cos(fraction(t) * 2 * .pi)
        let dot = CGPoint(x: 40, y: 60)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 10, color: mint.copy(alpha: 0.85 * pulse))
        ctx.setFillColor(mint.copy(alpha: 0.5 + 0.5 * pulse)!)
        ctx.fillEllipse(in: CGRect(x: dot.x - 8, y: dot.y - 8, width: 16, height: 16))
        ctx.restoreGState()
        clock(label(t), in: ctx, center: CGPoint(x: 138, y: 60), maxWidth: 160,
              font: "ArialRoundedMTBold", size: 46, color: white)
    }

    /// Big condensed digits like the Normal counter, a lime stopwatch and a shadow; no box.
    private static func clean(_ ctx: CGContext, _ t: Double) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 10, color: gray(0, 0.6))
        stopwatchIcon(ctx, center: CGPoint(x: 32, y: 64), radius: 19, color: lime, lineWidth: 4.5,
                      hand: minuteProgress(t))
        clock(label(t), in: ctx, center: CGPoint(x: 149, y: 62), maxWidth: 168,
              font: NormalCounterAppearance.fontName, size: 92, color: white)
        ctx.restoreGState()
    }

    /// A match-clock bar: a slanted lime tab with the stopwatch, the time on ink, and a lime
    /// line along the bottom that fills once a minute.
    private static func broadcast(_ ctx: CGContext, _ t: Double) {
        let top: CGFloat = 26, bottom: CGFloat = 94
        let tab = CGMutablePath()
        tab.addLines(between: [CGPoint(x: 4, y: top), CGPoint(x: 82, y: top), CGPoint(x: 68, y: bottom), CGPoint(x: 4, y: bottom)])
        tab.closeSubpath()
        let panel = CGMutablePath()
        panel.addLines(between: [CGPoint(x: 86, y: top), CGPoint(x: 236, y: top), CGPoint(x: 236, y: bottom), CGPoint(x: 72, y: bottom)])
        panel.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 8, color: gray(0, 0.45))
        ctx.addPath(panel); ctx.setFillColor(ink.copy(alpha: 0.94)!); ctx.fillPath()
        ctx.addPath(tab); ctx.setFillColor(lime); ctx.fillPath()
        ctx.restoreGState()
        stopwatchIcon(ctx, center: CGPoint(x: 38, y: 62), radius: 17, color: ink, lineWidth: 4.5, hand: minuteProgress(t))
        clock(label(t), in: ctx, center: CGPoint(x: 160, y: 59), maxWidth: 136,
              font: NormalCounterAppearance.fontName, size: 60, color: white)
        ctx.saveGState()
        ctx.addPath(panel); ctx.clip()
        ctx.setFillColor(gray(1, 0.08)); ctx.fill(CGRect(x: 72, y: bottom - 5, width: 164, height: 5))
        ctx.setFillColor(lime); ctx.fill(CGRect(x: 72, y: bottom - 5, width: 164 * minuteProgress(t), height: 5))
        ctx.restoreGState()
    }

    /// An analogue stopwatch whose hand sweeps and whose mint ring fills each minute, beside the time.
    private static func stopwatch(_ ctx: CGContext, _ t: Double) {
        let center = CGPoint(x: 58, y: 64), r: CGFloat = 44
        let progress = minuteProgress(t)
        // Crown and side button.
        ctx.setFillColor(white)
        ctx.addPath(CGPath(roundedRect: CGRect(x: center.x - 8, y: center.y - r - 14, width: 16, height: 9),
                           cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.fillPath()
        ctx.fill(CGRect(x: center.x - 2.5, y: center.y - r - 6, width: 5, height: 7))
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y); ctx.rotate(by: .pi / 4)
        ctx.addPath(CGPath(roundedRect: CGRect(x: -5, y: -r - 9, width: 10, height: 7), cornerWidth: 2, cornerHeight: 2, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.setFillColor(gray(0, 0.62)); ctx.fillEllipse(in: circle(center, r))
        ctx.setStrokeColor(white); ctx.setLineWidth(3); ctx.strokeEllipse(in: circle(center, r))
        for tick in 0..<60 {
            let angle = Double(tick) / 60 * 2 * .pi, long = tick % 5 == 0
            let outer = r - 5, inner = long ? r - 12 : r - 8
            ctx.setStrokeColor(long ? white : gray(1, 0.45)); ctx.setLineWidth(long ? 2 : 1)
            ctx.move(to: point(center, inner, angle)); ctx.addLine(to: point(center, outer, angle)); ctx.strokePath()
        }
        ctx.setLineCap(.round)
        ctx.setStrokeColor(gray(1, 0.1)); ctx.setLineWidth(5)
        ctx.addArc(center: center, radius: r - 18, startAngle: 0, endAngle: 2 * .pi, clockwise: false); ctx.strokePath()
        if progress > 0.001 {
            ctx.setStrokeColor(mint)
            ctx.addArc(center: center, radius: r - 18, startAngle: -.pi / 2,
                       endAngle: -.pi / 2 + progress * 2 * .pi, clockwise: false)
            ctx.strokePath()
        }
        let hand = progress * 2 * .pi
        ctx.setStrokeColor(lime); ctx.setLineWidth(2.5)
        ctx.move(to: point(center, -7, hand)); ctx.addLine(to: point(center, r - 9, hand)); ctx.strokePath()
        ctx.setFillColor(lime); ctx.fillEllipse(in: circle(center, 4.5))
        ctx.setFillColor(ink); ctx.fillEllipse(in: circle(center, 1.8))
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: gray(0, 0.55))
        clock(label(t), in: ctx, center: CGPoint(x: 172, y: 63), maxWidth: 124,
              font: NormalCounterAppearance.fontName, size: 58, color: white)
        ctx.restoreGState()
    }

    /// A lime seven-segment clock with unlit ghost segments and a colon that blinks each second.
    private static func digital(_ ctx: CGContext, _ t: Double) {
        let panel = CGRect(x: 4, y: 14, width: 232, height: 92)
        let path = CGPath(roundedRect: panel, cornerWidth: 16, cornerHeight: 16, transform: nil)
        ctx.addPath(path); ctx.setFillColor(gray(0.02, 0.82)); ctx.fillPath()
        ctx.addPath(path); ctx.setStrokeColor(lime.copy(alpha: 0.28)!); ctx.setLineWidth(1.5); ctx.strokePath()
        let text = label(t)
        let digitWidth: CGFloat = 36, digitGap: CGFloat = 6, colonWidth: CGFloat = 16, height: CGFloat = 60
        let total = text.reduce(CGFloat(0)) { $0 + ($1 == ":" ? colonWidth : digitWidth + digitGap) } - digitGap
        let fit = min(1, 200 / total)
        ctx.saveGState()
        ctx.translateBy(x: panel.midX, y: panel.midY)
        ctx.scaleBy(x: fit, y: fit)
        // A slight forward lean, like a stadium clock.
        ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: -0.09, d: 1, tx: 0, ty: 0))
        var x = -total / 2
        let top = -height / 2
        let blinkOn = fraction(t) < 0.5
        for character in text {
            if character == ":" {
                for dy in [-12.0, 12.0] {
                    let square = CGRect(x: x + colonWidth / 2 - 3.5, y: CGFloat(dy) - 3.5, width: 7, height: 7)
                    ctx.setFillColor(lime.copy(alpha: blinkOn ? 1 : 0.12)!)
                    ctx.fill(square)
                }
                x += colonWidth
                continue
            }
            let digit = Int(String(character)) ?? 0
            sevenSegments(ctx, origin: CGPoint(x: x, y: top), width: digitWidth, height: height, lit: segments(digit))
            x += digitWidth + digitGap
        }
        ctx.restoreGState()
    }

    /// Split-flap cards; each card folds over when its digit changes on the second.
    private static func flip(_ ctx: CGContext, _ t: Double) {
        let now = label(t)
        let previous = label(max(0, floor(t) - 1))
        let card = CGSize(width: 44, height: 78), pairGap: CGFloat = 4, colonWidth: CGFloat = 16
        var total: CGFloat = 0
        let characters = Array(now)
        for (index, character) in characters.enumerated() {
            if character == ":" { total += colonWidth; continue }
            total += card.width
            if index + 1 < characters.count && characters[index + 1] != ":" { total += pairGap }
        }
        let fit = min(1, 230 / total)
        let progress = fraction(t) / 0.32
        ctx.saveGState()
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        ctx.scaleBy(x: fit, y: fit)
        ctx.translateBy(x: -total / 2, y: -card.height / 2)
        let old = Array(previous.count == now.count ? previous : now)
        var x: CGFloat = 0
        for (index, character) in characters.enumerated() {
            if character == ":" {
                ctx.setFillColor(gray(1, 0.9))
                for dy in [-13.0, 13.0] {
                    ctx.fillEllipse(in: CGRect(x: x + colonWidth / 2 - 4, y: card.height / 2 + CGFloat(dy) - 4, width: 8, height: 8))
                }
                x += colonWidth
                continue
            }
            let rect = CGRect(x: x, y: 0, width: card.width, height: card.height)
            let before = old[index]
            if before != character && progress < 1 {
                flipCard(ctx, rect, from: before, to: character, progress: progress)
            } else {
                cardFace(ctx, rect, character)
            }
            ctx.setFillColor(gray(0, 0.6)); ctx.fill(CGRect(x: rect.minX, y: rect.midY - 0.75, width: rect.width, height: 1.5))
            x += card.width
            if index + 1 < characters.count && characters[index + 1] != ":" { x += pairGap }
        }
        ctx.restoreGState()
    }

    /// Glowing tube digits inside a neon frame, with a rare flicker.
    private static func neon(_ ctx: CGContext, _ t: Double) {
        let pink = CGColor(red: 1, green: 0.32, blue: 0.76, alpha: 1)
        let cyan = CGColor(red: 0.32, green: 0.94, blue: 1, alpha: 1)
        // Mostly steady; every few seconds the tubes stutter for a frame or two.
        let cycle = t.truncatingRemainder(dividingBy: 6.4)
        let flicker: CGFloat = cycle > 4.1 && cycle < 4.16 ? 0.35 : cycle > 4.22 && cycle < 4.26 ? 0.6 : 1
        let frame = CGPath(roundedRect: CGRect(x: 8, y: 16, width: 224, height: 88), cornerWidth: 24, cornerHeight: 24, transform: nil)
        ctx.addPath(frame); ctx.setFillColor(gray(0, 0.5)); ctx.fillPath()
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 12, color: cyan.copy(alpha: 0.9)!)
        ctx.addPath(frame); ctx.setStrokeColor(cyan); ctx.setLineWidth(3); ctx.strokePath()
        ctx.restoreGState()
        ctx.addPath(frame); ctx.setStrokeColor(gray(1, 0.75)); ctx.setLineWidth(1); ctx.strokePath()
        let text = label(t), center = CGPoint(x: 120, y: 60)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 16, color: pink.copy(alpha: 0.95 * flicker)!)
        clock(text, in: ctx, center: center, maxWidth: 184, font: "AvenirNext-DemiBold", size: 54,
              color: pink.copy(alpha: flicker)!, strokeWidth: 7)
        ctx.restoreGState()
        clock(text, in: ctx, center: center, maxWidth: 184, font: "AvenirNext-DemiBold", size: 54,
              color: gray(1, 0.92 * flicker), strokeWidth: 2.4)
    }

    // MARK: - Pieces

    static func label(_ t: Double) -> String { ExportPreviewTime.label(at: t) }

    private static func circle(_ center: CGPoint, _ r: CGFloat) -> CGRect {
        CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    }

    /// A point `distance` from the centre, clockwise from twelve o'clock.
    private static func point(_ center: CGPoint, _ distance: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(x: center.x + distance * sin(angle), y: center.y - distance * cos(angle))
    }

    private static func stopwatchIcon(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: CGColor,
                                      lineWidth: CGFloat, hand: Double) {
        ctx.saveGState()
        ctx.setStrokeColor(color); ctx.setFillColor(color); ctx.setLineWidth(lineWidth); ctx.setLineCap(.round)
        ctx.strokeEllipse(in: circle(center, radius))
        ctx.addPath(CGPath(roundedRect: CGRect(x: center.x - radius * 0.28, y: center.y - radius - radius * 0.52,
                                               width: radius * 0.56, height: radius * 0.3),
                           cornerWidth: radius * 0.1, cornerHeight: radius * 0.1, transform: nil))
        ctx.fillPath()
        ctx.fill(CGRect(x: center.x - lineWidth * 0.45, y: center.y - radius - radius * 0.26,
                        width: lineWidth * 0.9, height: radius * 0.3))
        let angle = hand * 2 * .pi
        ctx.move(to: center); ctx.addLine(to: point(center, radius * 0.6, angle)); ctx.strokePath()
        ctx.fillEllipse(in: circle(center, lineWidth * 0.55))
        ctx.restoreGState()
    }

    /// Digits in fixed-width cells, so the time never jitters as it counts. Shrinks to fit.
    private static func clock(_ text: String, in ctx: CGContext, center: CGPoint, maxWidth: CGFloat,
                              font name: String, size requested: CGFloat, color: CGColor, strokeWidth: CGFloat? = nil) {
        func measure(_ size: CGFloat) -> (font: CTFont, digit: CGFloat, colon: CGFloat, total: CGFloat) {
            let font = CTFontCreateWithName(name as CFString, size, nil)
            func advance(_ string: String) -> CGFloat {
                CGFloat(CTLineGetTypographicBounds(line(string, font: font, color: color, strokeWidth: nil), nil, nil, nil))
            }
            let digit = advance("0"), colon = max(advance(":"), digit * 0.38)
            let total = text.reduce(CGFloat(0)) { $0 + ($1 == ":" ? colon : digit) }
            return (font, digit, colon, total)
        }
        var metrics = measure(requested)
        if metrics.total > maxWidth { metrics = measure(requested * maxWidth / metrics.total) }
        let baseline = center.y + CTFontGetCapHeight(metrics.font) / 2
        var x = center.x - metrics.total / 2
        for character in text {
            let cell = character == ":" ? metrics.colon : metrics.digit
            let glyph = line(String(character), font: metrics.font, color: color, strokeWidth: strokeWidth)
            let bounds = CTLineGetBoundsWithOptions(glyph, .useGlyphPathBounds)
            ctx.saveGState()
            ctx.translateBy(x: x + (cell - bounds.width) / 2 - bounds.minX, y: baseline)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textMatrix = .identity; ctx.textPosition = .zero
            CTLineDraw(glyph, ctx)
            ctx.restoreGState()
            x += cell
        }
    }

    private static func line(_ text: String, font: CTFont, color: CGColor, strokeWidth: CGFloat?) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        if let strokeWidth {
            // A positive width strokes without filling: the outline of a neon tube.
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = strokeWidth
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = color
        }
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    // MARK: Seven segments

    private static func segments(_ digit: Int) -> Set<Character> {
        switch digit {
        case 0: ["a", "b", "c", "d", "e", "f"]
        case 1: ["b", "c"]
        case 2: ["a", "b", "g", "e", "d"]
        case 3: ["a", "b", "g", "c", "d"]
        case 4: ["f", "g", "b", "c"]
        case 5: ["a", "f", "g", "c", "d"]
        case 6: ["a", "f", "g", "e", "d", "c"]
        case 7: ["a", "b", "c"]
        case 8: ["a", "b", "c", "d", "e", "f", "g"]
        default: ["a", "b", "c", "d", "f", "g"]
        }
    }

    private static func sevenSegments(_ ctx: CGContext, origin: CGPoint, width w: CGFloat, height h: CGFloat, lit: Set<Character>) {
        let thickness: CGFloat = 7, gap: CGFloat = 1.4
        func horizontal(_ y: CGFloat) -> CGPath {
            let x0 = origin.x + gap, x1 = origin.x + w - gap, half = thickness / 2
            let path = CGMutablePath()
            path.addLines(between: [CGPoint(x: x0, y: y), CGPoint(x: x0 + half, y: y - half), CGPoint(x: x1 - half, y: y - half),
                                    CGPoint(x: x1, y: y), CGPoint(x: x1 - half, y: y + half), CGPoint(x: x0 + half, y: y + half)])
            path.closeSubpath()
            return path
        }
        func vertical(_ x: CGFloat, from y0: CGFloat, to y1: CGFloat) -> CGPath {
            let top = y0 + gap, bottom = y1 - gap, half = thickness / 2
            let path = CGMutablePath()
            path.addLines(between: [CGPoint(x: x, y: top), CGPoint(x: x + half, y: top + half), CGPoint(x: x + half, y: bottom - half),
                                    CGPoint(x: x, y: bottom), CGPoint(x: x - half, y: bottom - half), CGPoint(x: x - half, y: top + half)])
            path.closeSubpath()
            return path
        }
        let mid = origin.y + h / 2
        let shapes: [(Character, CGPath)] = [
            ("a", horizontal(origin.y)), ("g", horizontal(mid)), ("d", horizontal(origin.y + h)),
            ("f", vertical(origin.x, from: origin.y, to: mid)), ("b", vertical(origin.x + w, from: origin.y, to: mid)),
            ("e", vertical(origin.x, from: mid, to: origin.y + h)), ("c", vertical(origin.x + w, from: mid, to: origin.y + h))
        ]
        for (name, shape) in shapes where !lit.contains(name) {
            ctx.addPath(shape); ctx.setFillColor(lime.copy(alpha: 0.08)!); ctx.fillPath()
        }
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 8, color: lime.copy(alpha: 0.7))
        for (name, shape) in shapes where lit.contains(name) {
            ctx.addPath(shape); ctx.setFillColor(lime); ctx.fillPath()
        }
        ctx.restoreGState()
    }

    // MARK: Flip cards

    private static func cardFace(_ ctx: CGContext, _ rect: CGRect, _ character: Character) {
        let path = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [gray(0.19, 0.96), gray(0.1, 0.96)] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
        }
        ctx.restoreGState()
        clock(String(character), in: ctx, center: CGPoint(x: rect.midX, y: rect.midY + 1), maxWidth: rect.width - 6,
              font: NormalCounterAppearance.fontName, size: 74, color: white)
    }

    /// One half of a card, squashed toward the hinge by `squash` and darkened by `shade`.
    private static func half(_ ctx: CGContext, _ rect: CGRect, _ character: Character, top: Bool,
                             squash: CGFloat = 1, shade: CGFloat = 0) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.midY); ctx.scaleBy(x: 1, y: max(0.001, squash)); ctx.translateBy(x: 0, y: -rect.midY)
        ctx.clip(to: CGRect(x: rect.minX, y: top ? rect.minY : rect.midY, width: rect.width, height: rect.height / 2))
        cardFace(ctx, rect, character)
        if shade > 0 { ctx.setFillColor(gray(0, shade)); ctx.fill(rect) }
        ctx.restoreGState()
    }

    private static func flipCard(_ ctx: CGContext, _ rect: CGRect, from old: Character, to new: Character, progress: Double) {
        let p = CGFloat(max(0, min(1, progress)))
        half(ctx, rect, new, top: true)
        half(ctx, rect, old, top: false)
        if p < 0.5 {
            half(ctx, rect, old, top: true, squash: 1 - p * 2, shade: 0.55 * p * 2)
        } else {
            half(ctx, rect, new, top: false, squash: (p - 0.5) * 2, shade: 0.55 * (1 - (p - 0.5) * 2))
        }
    }
}
