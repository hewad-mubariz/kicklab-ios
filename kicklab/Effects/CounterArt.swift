import CoreGraphics
import CoreText
import Foundation

/// The ten showpiece counters. Each has its own lettering and a signature move on every
/// touch, computed only from the count, the time since the last touch and media time, so
/// the editor, scrubbing and the exported video always agree. Drawn in a 240 × 180 badge, y down.
nonisolated enum CounterArt {
    static let canvas = CGSize(width: 240, height: 180)

    /// The moment after a touch that best shows each style, for picker thumbnails.
    static func previewAge(_ style: ExportBadgeStyle) -> Double {
        switch style {
        case .odometer: 0.6
        case .broadcast: 0.4
        case .comic: 0.16
        case .neon: 0.6
        case .molten: 0.12
        case .glitch: 0.22
        case .graffiti: 1.6
        case .jelly: 0.08
        case .goldCoin: 0.62
        case .chalk: 0.3
        case .normal, .classic: 0.15
        }
    }

    static func draw(_ style: ExportBadgeStyle, in ctx: CGContext, time: Double, counter: ExportCounterState) {
        let moment = Moment(counter: counter, time: time)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: CGRect(origin: .zero, size: canvas))
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        switch style {
        case .odometer: odometer(ctx, moment)
        case .broadcast: broadcast(ctx, moment)
        case .comic: comic(ctx, moment)
        case .neon: neon(ctx, moment)
        case .molten: molten(ctx, moment)
        case .glitch: glitch(ctx, moment)
        case .graffiti: graffiti(ctx, moment)
        case .jelly: jelly(ctx, moment)
        case .goldCoin: goldCoin(ctx, moment)
        case .chalk: chalk(ctx, moment)
        case .normal, .classic: break
        }
    }

    // MARK: - Odometer: mechanical drums that roll up to the new count, with a carry.

    private static func odometer(_ ctx: CGContext, _ s: Moment) {
        let places = max(2, String(s.count).count)
        let new = Array(String(format: "%0\(places)d", s.count))
        let old = Array(String(format: "%0\(places)d", s.previous))
        let gap: CGFloat = 4
        let cell = min(60, (200 - gap * CGFloat(places - 1)) / CGFloat(places))
        let height = cell * 1.42
        let span = cell * CGFloat(places) + gap * CGFloat(places - 1)
        let windows = CGRect(x: 120 - span / 2, y: 66 - height / 2, width: span, height: height)
        let housing = windows.insetBy(dx: -11, dy: -10)
        let shell = CGPath(roundedRect: housing, cornerWidth: 14, cornerHeight: 14, transform: nil)

        ctx.saveGState()
        if s.milestone {
            shadow(ctx, offset: .zero, blur: 18, color: lime.copy(alpha: 0.95 * (1 - s.progress(1.2)))!)
        } else {
            shadow(ctx, offset: CGSize(width: 0, height: 4), blur: 10, color: rgb(0, 0, 0, 0.55))
        }
        fill(ctx, shell, rgb(0.1, 0.11, 0.12))
        ctx.restoreGState()
        fillGradient(ctx, shell, [rgb(0.38, 0.4, 0.42), rgb(0.17, 0.18, 0.19), rgb(0.08, 0.085, 0.09)],
                     from: CGPoint(x: 0, y: housing.minY), to: CGPoint(x: 0, y: housing.maxY))
        stroke(ctx, shell, rgb(1, 1, 1, 0.3), 1)
        for x in [housing.minX + 5.5, housing.maxX - 5.5] {
            let screw = CGRect(x: x - 2.2, y: housing.midY - 2.2, width: 4.4, height: 4.4)
            ctx.setFillColor(rgb(0.55, 0.57, 0.6)); ctx.fillEllipse(in: screw)
            ctx.setStrokeColor(rgb(0.1, 0.1, 0.1, 0.8)); ctx.setLineWidth(0.8)
            ctx.move(to: CGPoint(x: x - 1.4, y: housing.midY)); ctx.addLine(to: CGPoint(x: x + 1.4, y: housing.midY)); ctx.strokePath()
        }

        let glass = CGMutablePath()
        for i in 0..<places {
            let rect = CGRect(x: windows.minX + CGFloat(i) * (cell + gap), y: windows.minY, width: cell, height: height)
            glass.addPath(CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil))
            let place = places - 1 - i
            // Higher places roll a beat later, like a real carry.
            let rolling = old[i] != new[i] && s.within(0.9)
            let progress = rolling ? roll(s.age - Double(place) * 0.05) : 1
            drum(ctx, rect, old: String(old[i]), new: String(new[i]), progress: progress, highlight: place == 0)
        }
        // A glint sweeps across the glass on each touch.
        if s.within(0.55) {
            let p = CGFloat(s.progress(0.42, delay: 0.04))
            let x = housing.minX - 30 + (housing.width + 60) * p
            ctx.saveGState(); ctx.addPath(glass); ctx.clip()
            let band = CGMutablePath()
            band.addLines(between: [CGPoint(x: x, y: housing.minY), CGPoint(x: x + 16, y: housing.minY),
                                    CGPoint(x: x + 2, y: housing.maxY), CGPoint(x: x - 14, y: housing.maxY)])
            band.closeSubpath()
            fill(ctx, band, rgb(1, 1, 1, 0.3 * (1 - p * 0.5)))
            ctx.restoreGState()
        }
        label(ctx, s.label, font: "DINCondensed-Bold", size: 19, tracking: 4,
              center: CGPoint(x: 120, y: min(168, housing.maxY + 16)), color: rgb(1, 1, 1, 0.95))
    }

    private static func drum(_ ctx: CGContext, _ rect: CGRect, old: String, new: String,
                             progress p: Double, highlight: Bool) {
        let window = CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.saveGState()
        ctx.addPath(window); ctx.clip()
        gradient(ctx, [rgb(0.03, 0.03, 0.035), rgb(0.15, 0.155, 0.16), rgb(0.03, 0.03, 0.035)],
                 from: CGPoint(x: 0, y: rect.minY), to: CGPoint(x: 0, y: rect.maxY))
        let ink = highlight ? lime : rgb(0.96, 0.97, 0.94)
        let shift = CGFloat(p) * rect.height
        let blur = CGFloat(abs(sin(min(1, max(0, p)) * .pi)))
        for (digit, offset) in [(old, -shift), (new, rect.height - shift)] {
            let y = rect.midY + offset
            guard y > rect.minY - rect.height, y < rect.maxY + rect.height else { continue }
            let glyphs = Lettering(digit, font: "DINCondensed-Bold", size: rect.height * 0.92)
            // Motion blur trails the roll.
            if blur > 0.1 {
                for k in 1...3 {
                    fill(ctx, glyphs.placed(at: CGPoint(x: rect.midX, y: y + CGFloat(k) * 4.5 * blur)), ink.copy(alpha: 0.2)!)
                }
            }
            fill(ctx, glyphs.placed(at: CGPoint(x: rect.midX, y: y + rect.height * 0.04)), ink)
        }
        // Drum curvature and glass.
        let shade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [rgb(0, 0, 0, 0.82), rgb(0, 0, 0, 0), rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.82)] as CFArray,
            locations: [0, 0.3, 0.7, 1])!
        ctx.drawLinearGradient(shade, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
        gradient(ctx, [rgb(1, 1, 1, 0.16), rgb(1, 1, 1, 0)],
                 from: CGPoint(x: 0, y: rect.minY), to: CGPoint(x: 0, y: rect.minY + rect.height * 0.42))
        ctx.restoreGState()
        stroke(ctx, window, rgb(0, 0, 0, 0.85), 1.5)
    }

    private static func roll(_ age: Double) -> Double {
        age <= 0 ? 0 : 1 - exp(-7 * age) * cos(10 * age)
    }

    // MARK: - Broadcast: a sports scorebug. Each touch wipes the new number across the bar.

    private static func broadcast(_ ctx: CGContext, _ s: Moment) {
        let accent = s.milestone ? gold : lime
        let bar = CGRect(x: 38, y: 58, width: 176, height: 60)
        // "+1" drops out from behind the bar, then tucks back.
        if s.within(0.9) && s.count > 0 {
            let out = easeOut(s.progress(0.14)), back = easeInOut(s.progress(0.15, delay: 0.68))
            let tab = CGRect(x: 62, y: bar.maxY - 20 + 20 * (out - back), width: 44, height: 20)
            fill(ctx, slanted(tab), accent)
            label(ctx, "+1", font: "AvenirNextCondensed-HeavyItalic", size: 15, center: CGPoint(x: tab.midX + 2, y: tab.midY),
                  color: rgb(0.02, 0.05, 0.08))
        }
        ctx.saveGState()
        shadow(ctx, offset: CGSize(width: 0, height: 5), blur: 12, color: rgb(0, 0, 0, 0.5))
        fill(ctx, slanted(bar), rgb(0.03, 0.06, 0.12))
        ctx.restoreGState()
        fillGradient(ctx, slanted(bar), [rgb(0.08, 0.14, 0.26, 0.97), rgb(0.02, 0.05, 0.1, 0.97)],
                     from: CGPoint(x: 0, y: bar.minY), to: CGPoint(x: 0, y: bar.maxY))
        stroke(ctx, slanted(bar), rgb(1, 1, 1, 0.12), 1)

        let block = CGRect(x: 18, y: bar.minY, width: 24, height: bar.height)
        fill(ctx, slanted(block), accent)
        ctx.saveGState(); ctx.addPath(slanted(block)); ctx.clip()
        ctx.setStrokeColor(rgb(0, 0, 0, 0.16)); ctx.setLineWidth(3)
        for k in 0..<5 {
            let x = block.minX - 20 + CGFloat(k) * 11
            ctx.move(to: CGPoint(x: x, y: block.maxY)); ctx.addLine(to: CGPoint(x: x + 30, y: block.minY)); ctx.strokePath()
        }
        ctx.restoreGState()
        let tab = CGRect(x: 52, y: 38, width: 100, height: 20)
        fill(ctx, slanted(tab), accent)
        label(ctx, s.label, font: "AvenirNextCondensed-HeavyItalic", size: 12.5, tracking: 1.2,
              center: CGPoint(x: tab.midX + 2, y: tab.midY), color: rgb(0.02, 0.05, 0.08))

        // Match clock from the video's own time.
        let seconds = Int(s.time)
        label(ctx, String(format: "%02d:%02d", seconds / 60 % 100, seconds % 60), font: "DINCondensed-Bold", size: 25,
              center: CGPoint(x: 186, y: bar.midY + 1), color: rgb(1, 1, 1, 0.82))
        ctx.setStrokeColor(rgb(1, 1, 1, 0.18)); ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: 156 + bar.height * 0.75 * skew, y: bar.minY + 9)); ctx.addLine(to: CGPoint(x: 156 + 6, y: bar.maxY - 9))
        ctx.strokePath()

        // The wipe: new number left of the edge, the old one right of it.
        let wiping = s.within(0.5) && s.count > 0
        let p = wiping ? easeInOut(s.progress(0.26)) : 1
        let edge = bar.minX - 6 + (124) * CGFloat(p)
        let numberAt = CGPoint(x: 98, y: bar.midY + 1)
        func number(_ value: Int) -> CGPath {
            Lettering(String(format: "%02d", value), font: "AvenirNextCondensed-HeavyItalic", size: 62)
                .placed(at: numberAt, fit: CGSize(width: 104, height: 52))
        }
        ctx.saveGState(); ctx.addPath(slanted(bar)); ctx.clip()
        ctx.saveGState(); ctx.addPath(region(left: true, of: edge, in: bar)); ctx.clip()
        fillGradient(ctx, number(s.count), [rgb(1, 1, 1), rgb(0.82, 0.88, 0.95)],
                     from: CGPoint(x: 0, y: bar.minY + 8), to: CGPoint(x: 0, y: bar.maxY - 8))
        ctx.restoreGState()
        if wiping {
            ctx.saveGState(); ctx.addPath(region(left: false, of: edge, in: bar)); ctx.clip()
            fill(ctx, number(s.previous), rgb(1, 1, 1))
            ctx.restoreGState()
            let band = slanted(CGRect(x: edge - 18, y: bar.minY, width: 18, height: bar.height))
            fill(ctx, band, accent.copy(alpha: p < 1 ? 1 : 0)!)
            fill(ctx, slanted(CGRect(x: edge - 2, y: bar.minY, width: 3, height: bar.height)), rgb(1, 1, 1, p < 1 ? 0.9 : 0))
        }
        ctx.restoreGState()
    }

    private static let skew: CGFloat = 0.21

    /// A parallelogram leaning forward like broadcast graphics.
    private static func slanted(_ r: CGRect) -> CGPath {
        let lean = r.height * skew, path = CGMutablePath()
        path.addLines(between: [CGPoint(x: r.minX + lean, y: r.minY), CGPoint(x: r.maxX + lean, y: r.minY),
                                CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)])
        path.closeSubpath()
        return path
    }

    private static func region(left: Bool, of edge: CGFloat, in bar: CGRect) -> CGPath {
        let lean = bar.height * skew, path = CGMutablePath(), far: CGFloat = left ? -400 : 640
        path.addLines(between: [CGPoint(x: far, y: bar.minY - 1), CGPoint(x: edge + lean, y: bar.minY - 1),
                                CGPoint(x: edge, y: bar.maxY + 1), CGPoint(x: far, y: bar.maxY + 1)])
        path.closeSubpath()
        return path
    }

    // MARK: - Comic: a halftone starburst and a sound effect on every touch.

    private static func comic(_ ctx: CGContext, _ s: Moment) {
        let c = CGPoint(x: 120, y: 80)
        let live = s.within(1.0)
        let pop = live ? 1 - 0.32 * exp(-8 * s.age) * cos(15 * s.age) : 1
        let wobble = live ? 0.12 * exp(-6 * s.age) * sin(12 * s.age) : 0
        if s.within(0.4) {
            ctx.setStrokeColor(rgb(0, 0, 0, 0.85 * (1 - s.age / 0.4))); ctx.setLineWidth(2.6)
            for i in 0..<14 {
                let a = Double(i) / 14 * 2 * .pi + 0.2
                ctx.move(to: CGPoint(x: c.x + cos(a) * 82, y: c.y + sin(a) * 66))
                ctx.addLine(to: CGPoint(x: c.x + cos(a) * 104, y: c.y + sin(a) * 84))
                ctx.strokePath()
            }
        }
        let burst = starburst(c, spikes: 14, inner: 47, outer: 74, scale: pop, rotation: -0.1 + wobble)
        var drop = CGAffineTransform(translationX: 6, y: 6)
        fill(ctx, burst.copy(using: &drop)!, rgb(0, 0, 0, 0.9))
        ctx.saveGState(); ctx.addPath(burst); ctx.clip()
        let rays = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [rgb(1, 0.96, 0.4), rgb(1, 0.82, 0.12), rgb(1, 0.5, 0.08)] as CFArray, locations: [0, 0.55, 1])!
        ctx.drawRadialGradient(rays, startCenter: c, startRadius: 0, endCenter: c, endRadius: 80, options: [])
        ctx.setFillColor(rgb(0.95, 0.28, 0.05, 0.45))
        for y in stride(from: c.y - 84, through: c.y + 84, by: 7) {
            for x in stride(from: c.x - 84, through: c.x + 84, by: 7) {
                let r = 0.4 + 2.1 * min(1, hypot(x - c.x, y - c.y) / 82)
                ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
        }
        ctx.restoreGState()
        stroke(ctx, burst, rgb(0, 0, 0), 4)

        // The number squashes on impact and springs back.
        let squash = live ? exp(-7 * s.age) * cos(17 * s.age) : 0
        let digits = Lettering(s.text, font: "Futura-CondensedExtraBold", size: 100)
            .placed(at: CGPoint(x: c.x, y: c.y + 4), scaleX: 1 + 0.18 * squash, scaleY: 1 - 0.22 * squash,
                    rotation: -0.06, fit: CGSize(width: 140, height: 88))
        var shadow = CGAffineTransform(translationX: 5, y: 5)
        fill(ctx, digits.copy(using: &shadow)!, rgb(0.86, 0.1, 0.16))
        stroke(ctx, digits, rgb(0, 0, 0), 10)
        fillGradient(ctx, digits, [rgb(1, 1, 1), rgb(0.82, 0.93, 1)],
                     from: CGPoint(x: 0, y: c.y - 40), to: CGPoint(x: 0, y: c.y + 44))

        if s.within(0.8) && s.count > 0 {
            let words = ["POW!", "BAM!", "WHAM!", "BOOM!", "ZAP!", "KAPOW!", "BIFF!", "SMASH!"]
            let size = 1 - 0.6 * exp(-10 * s.age) * cos(16 * s.age)
            let word = Lettering(words[(s.count * 7) % words.count], font: "Futura-CondensedExtraBold", size: 34)
                .placed(at: CGPoint(x: 184, y: 26), scaleX: size, scaleY: size, rotation: 0.2, fit: CGSize(width: 104, height: 40))
            ctx.saveGState()
            ctx.setAlpha(s.age < 0.55 ? 1 : max(0, 1 - (s.age - 0.55) / 0.25))
            stroke(ctx, word, rgb(0, 0, 0), 7)
            fillGradient(ctx, word, [rgb(1, 0.92, 0.3), rgb(1, 0.25, 0.15)],
                         from: CGPoint(x: 0, y: 12), to: CGPoint(x: 0, y: 40))
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.translateBy(x: 62, y: 154); ctx.rotate(by: -0.05)
        let caption = CGPath(rect: CGRect(x: -54, y: -14, width: 108, height: 28), transform: nil)
        fill(ctx, caption, rgb(1, 1, 1)); stroke(ctx, caption, rgb(0, 0, 0), 2.5)
        label(ctx, s.label, font: "AvenirNextCondensed-Heavy", size: 16, tracking: 0.8, center: .zero, color: rgb(0, 0, 0))
        ctx.restoreGState()
    }

    private static func starburst(_ c: CGPoint, spikes: Int, inner: CGFloat, outer: CGFloat,
                                  scale: Double, rotation: Double) -> CGPath {
        let path = CGMutablePath()
        for i in 0..<(spikes * 2) {
            let a = Double(i) / Double(spikes * 2) * 2 * .pi + rotation
            let tip = i.isMultiple(of: 2)
            let r = (tip ? outer * CGFloat(0.85 + 0.25 * hash(i, 3)) : inner) * CGFloat(scale)
            let p = CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r * 0.82)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Neon: glass tubes that buzz on with a flicker for every new number.

    private static func neon(_ ctx: CGContext, _ s: Moment) {
        let pink = rgb(1, 0.2, 0.62), cyan = rgb(0.3, 0.95, 1)
        var level: CGFloat = 1
        if s.within(0.6) && s.count > 0 {
            let a = s.age
            level = a < 0.05 ? 0.06 : a < 0.09 ? 1 : a < 0.15 ? 0.14 : CGFloat(1 + 0.3 * max(0, 1 - (a - 0.15) / 0.45))
        } else if hash(Int(s.time * 9), 41) < 0.05 {
            level = 0.72
        }
        let tubes = Lettering(s.text, font: "ArialRoundedMTBold", size: 100)
            .placed(at: CGPoint(x: 120, y: 66), fit: CGSize(width: 200, height: 92))
        let wall = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [pink.copy(alpha: 0.24 * min(1, level))!, pink.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
        ctx.saveGState(); ctx.translateBy(x: 120, y: 74); ctx.scaleBy(x: 1, y: 0.62)
        ctx.drawRadialGradient(wall, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 118, options: [])
        ctx.restoreGState()
        // Unlit glass is always there; the gas lights inside it.
        stroke(ctx, tubes, rgb(0.34, 0.12, 0.24, 0.65), 6.5)
        if level > 0.1 {
            ctx.saveGState()
            shadow(ctx, offset: .zero, blur: 16 * level, color: pink.copy(alpha: min(1, 0.95 * level))!)
            stroke(ctx, tubes, pink.copy(alpha: min(1, level))!, 6)
            ctx.restoreGState()
            stroke(ctx, tubes, rgb(1, 0.87, 0.95, min(1, level)), 2.3)
        }
        let script = Lettering(s.isTotal ? "total touches" : "touches", font: "SnellRoundhand-Black", size: 36)
            .placed(at: CGPoint(x: 124, y: 142), fit: CGSize(width: 190, height: 40))
        ctx.saveGState()
        shadow(ctx, offset: .zero, blur: 10, color: cyan)
        fill(ctx, script, rgb(0.82, 1, 1))
        ctx.restoreGState()
        stroke(ctx, script, cyan.copy(alpha: 0.9)!, 0.9)
    }

    // MARK: - Molten: white-hot on a touch, cooling to forged steel. Juggle fast to keep it glowing.

    private static func molten(_ ctx: CGContext, _ s: Moment) {
        let heat = s.age >= 99 ? 0 : exp(-s.age / 1.5)
        let flash = s.within(0.3) ? exp(-s.age * 12) : 0
        let digits = Lettering(s.text, font: "Futura-CondensedExtraBold", size: 104)
            .placed(at: CGPoint(x: 120, y: 68), fit: CGSize(width: 190, height: 100))
        let b = digits.boundingBoxOfPath

        // Drips run while it's hot and set as it cools.
        let drips = anchors(on: digits, y: b.maxY - 4, count: 3, seed: s.count)
        for (i, x) in drips.enumerated() {
            let full = 9 + 16 * CGFloat(hash(i, 30 + s.count))
            let length = full * CGFloat(s.within(1.2) ? easeOut(s.progress(0.9)) : 1)
            let ink = heatColor(heat * 0.85)
            ctx.setStrokeColor(ink); ctx.setLineWidth(4.6)
            ctx.move(to: CGPoint(x: x, y: b.maxY - 6)); ctx.addLine(to: CGPoint(x: x, y: b.maxY + length)); ctx.strokePath()
            ctx.setFillColor(ink); ctx.fillEllipse(in: CGRect(x: x - 3.4, y: b.maxY + length - 3.4, width: 6.8, height: 7.4))
        }

        ctx.saveGState()
        if heat > 0.05 {
            shadow(ctx, offset: .zero, blur: CGFloat(4 + 20 * heat), color: heatColor(heat).copy(alpha: CGFloat(0.95 * heat))!)
        } else {
            shadow(ctx, offset: CGSize(width: 0, height: 2), blur: 5, color: rgb(0, 0, 0, 0.7))
        }
        fill(ctx, digits, heatColor(max(0.02, heat)))
        ctx.restoreGState()
        // A dark cast edge keeps white-hot digits readable on bright footage.
        stroke(ctx, digits, rgb(0.14, 0.04, 0.02, 0.9), 5)

        // Heat haze: the hot body wobbles in thin slices.
        let slices = 8
        for i in 0..<slices {
            let band = CGRect(x: 0, y: b.minY + b.height * CGFloat(i) / CGFloat(slices) - 0.5,
                              width: 240, height: b.height / CGFloat(slices) + 1)
            ctx.saveGState(); ctx.clip(to: band)
            ctx.translateBy(x: CGFloat(sin(s.time * 23 + Double(i) * 1.7) * 1.8 * heat), y: 0)
            fillGradient(ctx, digits, [heatColor(heat * 0.82), heatColor(min(1, heat * 1.06 + 0.04))],
                         from: CGPoint(x: 0, y: b.minY), to: CGPoint(x: 0, y: b.maxY))
            ctx.restoreGState()
        }
        ctx.saveGState(); ctx.addPath(digits); ctx.clip()
        // Crust forms as it cools, with the last glow showing through the cracks.
        if heat < 0.75 {
            let crust = min(0.9, (0.75 - heat) * 1.6)
            // Soft dark patches spread over the surface as it sets.
            fill(ctx, digits, rgb(0.16, 0.07, 0.04, CGFloat(crust * 0.45)))
            for i in 0..<16 {
                let c = CGPoint(x: b.minX + CGFloat(hash(i, 1 + s.count)) * b.width, y: b.minY + CGFloat(hash(i, 2 + s.count)) * b.height)
                let r = 10 + 16 * CGFloat(hash(i, 3))
                let patch = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [rgb(0.12, 0.08, 0.06, CGFloat(crust * 0.8)), rgb(0.12, 0.08, 0.06, 0)] as CFArray, locations: [0, 1])!
                ctx.drawRadialGradient(patch, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
            }
            if heat > 0.04 {
                ctx.setStrokeColor(heatColor(min(1, heat + 0.4)).copy(alpha: CGFloat(min(1, heat * 3)))!)
                ctx.setLineWidth(1.1)
                for i in 0..<10 {
                    var p = CGPoint(x: b.minX + CGFloat(hash(i, 6 + s.count)) * b.width, y: b.minY + CGFloat(hash(i, 7 + s.count)) * b.height)
                    ctx.move(to: p)
                    for k in 0..<3 {
                        p.x += CGFloat(hash(i * 3 + k, 8) - 0.5) * 14; p.y += CGFloat(hash(i * 3 + k, 9) - 0.5) * 12
                        ctx.addLine(to: p)
                    }
                    ctx.strokePath()
                }
            }
        }
        if flash > 0 { fill(ctx, digits, rgb(1, 1, 0.95, CGFloat(flash * 0.85))) }
        ctx.restoreGState()
        stroke(ctx, digits, rgb(1, 1, 1, CGFloat(0.4 * (1 - heat))), 1.2)

        if s.within(1.2) && s.count > 0 {
            for i in 0..<16 {
                let life = 0.5 + 0.6 * hash(i, 5 + s.count)
                let t = s.age - 0.12 * hash(i, 9)
                guard t > 0, t < life else { continue }
                let f = t / life
                let x = b.minX + CGFloat(hash(i, 3 + s.count)) * b.width + CGFloat((hash(i, 4) - 0.5) * 70 * t)
                let y = b.minY + 8 - CGFloat((60 + 80 * hash(i, 6)) * t) + CGFloat(45 * t * t)
                let r = CGFloat(1.4 + 2.2 * hash(i, 7)) * CGFloat(1 - f * 0.5)
                ctx.saveGState()
                shadow(ctx, offset: .zero, blur: 4, color: heatColor(1 - f * 0.6))
                ctx.setFillColor(heatColor(1 - f * 0.7).copy(alpha: CGFloat(1 - f))!)
                ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                ctx.restoreGState()
            }
        }
        label(ctx, s.label, font: "AvenirNextCondensed-Bold", size: 17, tracking: 4,
              center: CGPoint(x: 120, y: 152), color: rgb(1, 0.88, 0.76))
    }

    private static func heatColor(_ value: Double) -> CGColor {
        let stops: [(Double, (Double, Double, Double))] = [
            (0, (0.32, 0.33, 0.35)), (0.18, (0.45, 0.1, 0.05)), (0.4, (0.86, 0.22, 0.03)),
            (0.62, (1, 0.5, 0.08)), (0.82, (1, 0.8, 0.32)), (1, (1, 0.97, 0.84))]
        let h = min(1, max(0, value))
        for k in 1..<stops.count where h <= stops[k].0 {
            let (a, b) = (stops[k - 1], stops[k]), f = (h - a.0) / (b.0 - a.0)
            return rgb(a.1.0 + (b.1.0 - a.1.0) * f, a.1.1 + (b.1.1 - a.1.1) * f, a.1.2 + (b.1.2 - a.1.2) * f)
        }
        return rgb(1, 0.97, 0.84)
    }

    // MARK: - Glitch: a cyan HUD readout that tears and splits on every touch.

    private static func glitch(_ ctx: CGContext, _ s: Moment) {
        let cyan = rgb(0.25, 0.95, 1)
        let frame = Int(s.time * 24)
        var g = s.within(0.34) && s.count > 0 ? 1 - s.age / 0.34 : 0
        if g == 0, hash(Int(s.time * 7), 77) < 0.05 { g = 0.35 }
        let digits = Lettering(s.padded, font: "AvenirNextCondensed-Bold", size: 104)
            .placed(at: CGPoint(x: 120, y: 72), fit: CGSize(width: 176, height: 94))
        let b = digits.boundingBoxOfPath

        let grow = CGFloat(1 + 0.18 * g)
        let box = CGRect(x: 120 - (b.width / 2 + 22) * grow, y: 72 - (b.height / 2 + 14) * grow,
                         width: (b.width + 44) * grow, height: (b.height + 28) * grow)
        ctx.setStrokeColor(cyan.copy(alpha: 0.9)!); ctx.setLineWidth(2)
        for (corner, dx, dy) in [(CGPoint(x: box.minX, y: box.minY), 1.0, 1.0), (CGPoint(x: box.maxX, y: box.minY), -1.0, 1.0),
                                 (CGPoint(x: box.minX, y: box.maxY), 1.0, -1.0), (CGPoint(x: box.maxX, y: box.maxY), -1.0, -1.0)] {
            ctx.addLines(between: [CGPoint(x: corner.x + 14 * dx, y: corner.y), corner, CGPoint(x: corner.x, y: corner.y + 14 * dy)])
            ctx.strokePath()
        }
        ctx.setStrokeColor(cyan.copy(alpha: 0.3)!); ctx.setLineWidth(1)
        for x in stride(from: box.minX + 22, to: box.maxX - 20, by: 10) {
            ctx.move(to: CGPoint(x: x, y: box.minY)); ctx.addLine(to: CGPoint(x: x, y: box.minY + 3))
            ctx.move(to: CGPoint(x: x, y: box.maxY)); ctx.addLine(to: CGPoint(x: x, y: box.maxY - 3))
            ctx.strokePath()
        }

        // Torn slices with a chromatic split.
        let split = CGFloat(1.2 + 7 * g), bands = 7
        for i in 0..<bands {
            let band = CGRect(x: 0, y: b.minY + b.height * CGFloat(i) / CGFloat(bands) - 0.3,
                              width: 240, height: b.height / CGFloat(bands) + 0.6)
            let tear = g > 0 && hash(frame * 13 + i, 5 + s.count) > 0.45 ? CGFloat((hash(frame * 7 + i, 9) - 0.5) * 42 * g) : 0
            ctx.saveGState(); ctx.clip(to: band); ctx.translateBy(x: tear, y: 0)
            ctx.setBlendMode(.plusLighter)
            var left = CGAffineTransform(translationX: -split, y: 0), right = CGAffineTransform(translationX: split, y: 0)
            fill(ctx, digits.copy(using: &left)!, rgb(1, 0.15, 0.42, 0.9))
            fill(ctx, digits.copy(using: &right)!, rgb(0.1, 0.45, 1, 0.9))
            ctx.setBlendMode(.normal)
            fillGradient(ctx, digits, [rgb(0.92, 1, 1), cyan], from: CGPoint(x: 0, y: b.minY), to: CGPoint(x: 0, y: b.maxY))
            ctx.restoreGState()
        }
        ctx.saveGState(); ctx.addPath(digits); ctx.clip()
        ctx.setFillColor(rgb(0, 0.05, 0.08, 0.3))
        for y in stride(from: b.minY, to: b.maxY, by: 3) { ctx.fill(CGRect(x: b.minX - 10, y: y, width: b.width + 20, height: 1)) }
        let scan = b.minY - 10 + CGFloat((s.time * 70).truncatingRemainder(dividingBy: Double(b.height + 20)))
        ctx.setFillColor(rgb(1, 1, 1, 0.22)); ctx.fill(CGRect(x: b.minX - 10, y: scan, width: b.width + 20, height: 5))
        ctx.restoreGState()
        if g > 0 {
            for i in 0..<7 {
                let r = CGRect(x: 30 + CGFloat(hash(frame + i, 21)) * 180, y: b.minY - 6 + CGFloat(hash(frame + i, 22)) * (b.height + 12),
                               width: 6 + CGFloat(hash(frame + i, 23)) * 36, height: 1.5 + CGFloat(hash(frame + i, 24)) * 4)
                let tint = [cyan, rgb(1, 0.2, 0.5), rgb(1, 1, 1)][i % 3]
                ctx.setFillColor(tint.copy(alpha: CGFloat(0.75 * g))!); ctx.fill(r)
            }
        }
        let caption = s.label + (Int(s.time * 2).isMultiple(of: 2) ? " ▌" : "")
        let text = Lettering(caption, font: "Menlo-Bold", size: 14, tracking: 2)
        ctx.saveGState()
        shadow(ctx, offset: CGSize(width: 0, height: 1), blur: 3, color: rgb(0, 0.05, 0.1, 0.85))
        fill(ctx, text.placed(at: CGPoint(x: box.minX + text.bounds.width / 2 + 2, y: min(170, box.maxY + 15))), cyan)
        ctx.restoreGState()
    }

    // MARK: - Graffiti: bubble letters sprayed on, with paint that runs after every touch.

    private static func graffiti(_ ctx: CGContext, _ s: Moment) {
        let pink = rgb(1, 0.18, 0.62), orange = rgb(1, 0.62, 0.08)
        let spray = s.within(0.6) && s.count > 0 ? 1 + 0.12 * exp(-8 * s.age) * cos(12 * s.age) : 1
        let digits = Lettering(s.text, font: "ArialRoundedMTBold", size: 100)
            .placed(at: CGPoint(x: 116, y: 70), scaleX: spray, scaleY: spray, rotation: -0.12, fit: CGSize(width: 196, height: 90))
        let b = digits.boundingBoxOfPath
        let mist = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [pink.copy(alpha: 0.34)!, pink.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
        ctx.saveGState(); ctx.translateBy(x: b.midX, y: b.midY); ctx.scaleBy(x: 1, y: 0.62)
        ctx.drawRadialGradient(mist, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 112, options: [])
        ctx.restoreGState()
        let puff = s.within(0.35) && s.count > 0 ? 0.35 * (1 - s.age / 0.35) : 0
        for i in 0..<70 {
            let a = hash(i, 11 + s.count) * 2 * .pi, d = (0.55 + 0.55 * hash(i, 12 + s.count)) * (1 + puff)
            let p = CGPoint(x: b.midX + CGFloat(cos(a) * d * 100), y: b.midY + CGFloat(sin(a) * d * 60))
            let r = CGFloat(0.6 + 1.6 * hash(i, 13))
            ctx.setFillColor((i.isMultiple(of: 3) ? orange : pink).copy(alpha: 0.55)!)
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
        for k in stride(from: 8, to: 0, by: -1) {
            var depth = CGAffineTransform(translationX: CGFloat(k) * 1.1, y: CGFloat(k) * 1.3)
            fill(ctx, digits.copy(using: &depth)!, rgb(0.2, 0.04, 0.28))
        }
        let runs = anchors(on: digits, y: b.maxY - 7, count: 5, seed: s.count)
        let flow = s.within(1.6) && s.count > 0 ? easeOut(s.progress(1.3, delay: 0.12)) : 1
        func drip(_ i: Int, _ x: CGFloat, width: CGFloat, bulb: CGFloat, ink: CGColor) {
            let length = (12 + 26 * CGFloat(hash(i, 40 + s.count))) * CGFloat(flow)
            ctx.setStrokeColor(ink); ctx.setLineWidth(width)
            ctx.move(to: CGPoint(x: x, y: b.maxY - 9)); ctx.addLine(to: CGPoint(x: x, y: b.maxY + length)); ctx.strokePath()
            ctx.setFillColor(ink); ctx.fillEllipse(in: CGRect(x: x - bulb, y: b.maxY + length - bulb * 0.8, width: bulb * 2, height: bulb * 2.1))
        }
        for (i, x) in runs.enumerated() { drip(i, x, width: 9, bulb: 5.4, ink: rgb(0, 0, 0)) }
        stroke(ctx, digits, rgb(0, 0, 0), 10)
        for (i, x) in runs.enumerated() { drip(i, x, width: 5.4, bulb: 3.9, ink: orange) }
        fillGradient(ctx, digits, [pink, orange], from: CGPoint(x: 0, y: b.minY), to: CGPoint(x: 0, y: b.maxY))
        ctx.saveGState(); ctx.addPath(digits); ctx.clip()
        ctx.setStrokeColor(rgb(1, 1, 1, 0.92)); ctx.setLineWidth(3.6)
        for i in 0..<6 {
            let x = b.minX + (CGFloat(i) + 0.5) / 6 * b.width
            guard digits.contains(CGPoint(x: x, y: b.minY + b.height * 0.24)) else { continue }
            ctx.move(to: CGPoint(x: x - 5, y: b.minY + b.height * 0.32)); ctx.addLine(to: CGPoint(x: x + 3, y: b.minY + b.height * 0.17))
            ctx.strokePath()
        }
        ctx.restoreGState()
        ctx.saveGState()
        ctx.translateBy(x: 172, y: 154); ctx.rotate(by: 0.07)
        let tape = CGMutablePath()
        tape.move(to: CGPoint(x: -48, y: -11))
        for k in 0...4 { tape.addLine(to: CGPoint(x: -48 + CGFloat(k % 2) * 3, y: -11 + CGFloat(k) * 5.5)) }
        tape.addLine(to: CGPoint(x: 48, y: 11))
        for k in 0...4 { tape.addLine(to: CGPoint(x: 48 - CGFloat(k % 2) * 3, y: 11 - CGFloat(k) * 5.5)) }
        tape.closeSubpath()
        shadow(ctx, offset: CGSize(width: 0, height: 2), blur: 3, color: rgb(0, 0, 0, 0.5))
        fill(ctx, tape, rgb(0.96, 0.94, 0.86, 0.96))
        shadow(ctx, offset: .zero, blur: 0, color: nil)
        label(ctx, s.label, font: "MarkerFelt-Wide", size: 15, center: .zero, color: rgb(0.08, 0.05, 0.1))
        ctx.restoreGState()
    }

    // MARK: - Jelly: glossy candy digits that wobble on every touch and blow bubbles.

    private static func jelly(_ ctx: CGContext, _ s: Moment) {
        let live = s.within(1.0) && s.count > 0
        let k = live ? exp(-6.5 * s.age) * cos(19 * s.age) : 0
        let digits = Lettering(s.text, font: "ArialRoundedMTBold", size: 104)
            .placed(at: CGPoint(x: 120, y: 118), scaleX: 1 - 0.18 * k, scaleY: 1 + 0.26 * k, anchorY: 1, fit: CGSize(width: 200, height: 92))
        let b = digits.boundingBoxOfPath
        let shade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [rgb(0, 0.05, 0.2, 0.45), rgb(0, 0.05, 0.2, 0)] as CFArray, locations: [0, 1])!
        ctx.saveGState(); ctx.translateBy(x: b.midX, y: 122); ctx.scaleBy(x: 1, y: 0.16)
        ctx.drawRadialGradient(shade, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: b.width * 0.55, options: [])
        ctx.restoreGState()
        stroke(ctx, digits, rgb(0.03, 0.18, 0.55), 7)
        fillGradient(ctx, digits, [rgb(0.62, 0.9, 1), rgb(0.1, 0.42, 1)], from: CGPoint(x: 0, y: b.minY), to: CGPoint(x: 0, y: b.maxY))
        ctx.saveGState(); ctx.addPath(digits); ctx.clip()
        gradient(ctx, [rgb(0, 0.1, 0.45, 0), rgb(0, 0.1, 0.45, 0.5)],
                 from: CGPoint(x: 0, y: b.midY), to: CGPoint(x: 0, y: b.maxY))
        let gloss = CGRect(x: b.minX - 10, y: b.minY - b.height * 0.35, width: b.width + 20, height: b.height * 0.78)
        ctx.addEllipse(in: gloss); ctx.clip()
        gradient(ctx, [rgb(1, 1, 1, 0.75), rgb(1, 1, 1, 0.05)], from: CGPoint(x: 0, y: gloss.minY), to: CGPoint(x: 0, y: gloss.maxY))
        ctx.restoreGState()
        ctx.setFillColor(rgb(1, 1, 1, 0.95))
        for i in 0..<7 {
            let p = CGPoint(x: b.minX + (CGFloat(i) + 0.3) / 7 * b.width, y: b.minY + b.height * 0.2)
            guard digits.contains(p) else { continue }
            ctx.fillEllipse(in: CGRect(x: p.x - 2.6, y: p.y - 1.6, width: 5.2, height: 3.2))
        }
        if s.within(1.3) && s.count > 0 {
            for i in 0..<8 {
                let life = 0.6 + 0.5 * hash(i, 50 + s.count), t = s.age - 0.15 * hash(i, 51)
                guard t > 0, t < life else { continue }
                let x = b.minX + CGFloat(hash(i, 52 + s.count)) * b.width + CGFloat(sin(t * 9 + Double(i)) * 3)
                let y = b.maxY - 10 - CGFloat((55 + 45 * hash(i, 53)) * t)
                var r = CGFloat(2.2 + 3 * hash(i, 54))
                var alpha: CGFloat = 0.85
                if t > life * 0.85 {
                    let pop = CGFloat((t - life * 0.85) / (life * 0.15))
                    r *= 1 + pop * 1.5; alpha *= 1 - pop
                }
                ctx.setStrokeColor(rgb(1, 1, 1, alpha)); ctx.setLineWidth(1.2)
                ctx.strokeEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                ctx.setFillColor(rgb(1, 1, 1, alpha)); ctx.fillEllipse(in: CGRect(x: x - r * 0.45, y: y - r * 0.5, width: r * 0.4, height: r * 0.4))
            }
        }
        let caption = Lettering(s.label.lowercased(), font: "ArialRoundedMTBold", size: 18)
            .placed(at: CGPoint(x: 120, y: 148), fit: CGSize(width: 200, height: 24))
        var drop = CGAffineTransform(translationX: 0, y: 2)
        fill(ctx, caption.copy(using: &drop)!, rgb(0.03, 0.18, 0.55))
        fill(ctx, caption, rgb(1, 1, 1))
    }

    // MARK: - Gold coin: a medal that flips over to the new number on every touch.

    private static func goldCoin(_ ctx: CGContext, _ s: Moment) {
        let flipping = s.within(0.5) && s.count > 0
        let p = flipping ? easeInOut(s.age / 0.5) : 1
        let face = cos(.pi * p)
        let sx = CGFloat(max(0.04, abs(face)))
        let r: CGFloat = 54
        let c = CGPoint(x: 120, y: 100 - (flipping ? 20 * CGFloat(sin(.pi * p)) : 0))
        let shown = p < 0.5 ? s.previous : s.count
        ribbon(ctx, center: c.x, bottom: c.y - r + 10)

        let edge = CGFloat(sin(.pi * p)) * 8 * (face >= 0 ? 1 : -1)
        if flipping && abs(edge) > 0.5 {
            let side = CGRect(x: c.x - r * sx, y: c.y - r, width: 2 * r * sx, height: 2 * r)
            let shift = CGAffineTransform(translationX: edge, y: 0)
            let rim = CGMutablePath()
            rim.addEllipse(in: side, transform: shift)
            rim.addRect(CGRect(x: min(c.x, c.x + edge), y: c.y - r, width: abs(edge), height: 2 * r))
            fill(ctx, rim, rgb(0.6, 0.4, 0.08))
            ctx.saveGState(); ctx.addPath(rim); ctx.clip()
            ctx.setStrokeColor(rgb(0.38, 0.24, 0.03, 0.7)); ctx.setLineWidth(0.8)
            for y in stride(from: c.y - r, to: c.y + r, by: 3) {
                ctx.move(to: CGPoint(x: c.x - r, y: y)); ctx.addLine(to: CGPoint(x: c.x + r + 10, y: y)); ctx.strokePath()
            }
            ctx.restoreGState()
        }

        let disc = CGRect(x: c.x - r * sx, y: c.y - r, width: 2 * r * sx, height: 2 * r)
        ctx.saveGState()
        shadow(ctx, offset: CGSize(width: 0, height: 5), blur: 10, color: rgb(0, 0, 0, 0.5))
        ctx.setFillColor(rgb(0.8, 0.56, 0.12)); ctx.fillEllipse(in: disc)
        ctx.restoreGState()
        ctx.saveGState(); ctx.addEllipse(in: disc); ctx.clip()
        let metal = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [rgb(1, 0.96, 0.7), rgb(0.98, 0.77, 0.25), rgb(0.72, 0.48, 0.1)] as CFArray, locations: [0, 0.5, 1])!
        let light = CGPoint(x: c.x - r * 0.32 * sx, y: c.y - r * 0.38)
        ctx.drawRadialGradient(metal, startCenter: light, startRadius: 0, endCenter: c, endRadius: r * 1.15, options: [.drawsAfterEndLocation])
        ctx.restoreGState()
        ctx.setStrokeColor(rgb(0.62, 0.4, 0.06)); ctx.setLineWidth(2.2)
        ctx.strokeEllipse(in: disc.insetBy(dx: 6 * sx, dy: 6))
        ctx.setStrokeColor(rgb(1, 0.92, 0.6, 0.85)); ctx.setLineWidth(1)
        ctx.strokeEllipse(in: disc.insetBy(dx: 8 * sx, dy: 8))
        ctx.setStrokeColor(rgb(0.55, 0.35, 0.05, 0.55)); ctx.setLineWidth(0.8)
        for i in 0..<64 {
            let a = Double(i) / 64 * 2 * .pi
            ctx.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * (r - 4.5) * sx, y: c.y + CGFloat(sin(a)) * (r - 4.5)))
            ctx.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * (r - 1) * sx, y: c.y + CGFloat(sin(a)) * (r - 1)))
        }
        ctx.strokePath()
        ctx.setFillColor(rgb(0.62, 0.4, 0.06))
        for a in [-Double.pi / 2 - 0.42, -Double.pi / 2, -Double.pi / 2 + 0.42] {
            starShape(ctx, at: CGPoint(x: c.x + CGFloat(cos(a)) * (r - 17) * sx, y: c.y + CGFloat(sin(a)) * (r - 17)), radius: 3.8, scaleX: sx)
        }
        let number = Lettering(String(shown), font: "AvenirNext-Heavy", size: 50)
            .placed(at: CGPoint(x: c.x, y: c.y + 3), scaleX: sx, fit: CGSize(width: r * 1.5, height: r * 0.9))
        var up = CGAffineTransform(translationX: 0.9 * sx, y: 1.2), down = CGAffineTransform(translationX: -0.9 * sx, y: -1.2)
        fill(ctx, number.copy(using: &up)!, rgb(1, 0.96, 0.75, 0.9))
        fill(ctx, number.copy(using: &down)!, rgb(0.42, 0.25, 0.03))
        fillGradient(ctx, number, [rgb(0.88, 0.63, 0.15), rgb(0.64, 0.4, 0.06)],
                     from: CGPoint(x: 0, y: c.y - 22), to: CGPoint(x: 0, y: c.y + 26))
        fill(ctx, Lettering(s.label, font: "AvenirNext-Bold", size: 8.5, tracking: 1.6)
                .placed(at: CGPoint(x: c.x, y: c.y + 31), scaleX: sx, fit: CGSize(width: r * 1.4, height: 12)),
             rgb(0.5, 0.32, 0.05))

        // A shine crosses the face after it lands, and every few seconds while idle.
        let idle = s.time.truncatingRemainder(dividingBy: 4.2)
        let sweep: Double? = s.within(1.0) && s.count > 0 && s.age > 0.5 ? (s.age - 0.5) / 0.45
            : (!s.within(1.0) && idle < 0.5 ? idle / 0.5 : nil)
        if let sweep, sweep < 1 {
            let x = disc.minX - 30 + (disc.width + 60) * CGFloat(sweep)
            ctx.saveGState(); ctx.addEllipse(in: disc); ctx.clip()
            let band = CGMutablePath()
            band.addLines(between: [CGPoint(x: x, y: disc.minY), CGPoint(x: x + 18, y: disc.minY),
                                    CGPoint(x: x - 6, y: disc.maxY), CGPoint(x: x - 24, y: disc.maxY)])
            band.closeSubpath()
            fill(ctx, band, rgb(1, 1, 0.92, 0.55))
            ctx.restoreGState()
        }
        if s.within(1.1) && s.count > 0 && s.age > 0.42 {
            let q = s.progress(0.55, delay: 0.42), n = s.milestone ? 12 : 7
            ctx.saveGState()
            shadow(ctx, offset: .zero, blur: 6, color: gold)
            ctx.setFillColor(rgb(1, 0.97, 0.82, CGFloat(1 - q)))
            for i in 0..<n {
                let a = Double(i) / Double(n) * 2 * .pi + 0.3
                let d = r + 8 + 16 * CGFloat(q)
                sparkle(ctx, at: CGPoint(x: c.x + CGFloat(cos(a)) * d, y: c.y + CGFloat(sin(a)) * d),
                        size: (5 + 4 * CGFloat(hash(i, 60))) * CGFloat(1 - q * 0.6))
            }
            ctx.restoreGState()
        }
    }

    private static func ribbon(_ ctx: CGContext, center x: CGFloat, bottom: CGFloat) {
        for side in [-1.0, 1.0] as [CGFloat] {
            let strap = CGMutablePath()
            strap.addLines(between: [CGPoint(x: x + side * 52, y: -4), CGPoint(x: x + side * 26, y: -4),
                                     CGPoint(x: x - side * 4, y: bottom), CGPoint(x: x + side * 20, y: bottom)])
            strap.closeSubpath()
            fill(ctx, strap, side < 0 ? rgb(0.24, 0.86, 0.52) : rgb(0.14, 0.6, 0.36))
            ctx.setStrokeColor(rgb(1, 1, 1, 0.75)); ctx.setLineWidth(2.4)
            ctx.move(to: CGPoint(x: x + side * 39, y: -4)); ctx.addLine(to: CGPoint(x: x + side * 8, y: bottom)); ctx.strokePath()
        }
    }

    // MARK: - Chalk: a coach's slate. The number is rewritten and a tally stroke drawn each touch.

    private static func chalk(_ ctx: CGContext, _ s: Moment) {
        let frame = CGRect(x: 14, y: 8, width: 212, height: 162)
        ctx.saveGState()
        shadow(ctx, offset: CGSize(width: 0, height: 4), blur: 10, color: rgb(0, 0, 0, 0.5))
        fill(ctx, CGPath(roundedRect: frame, cornerWidth: 12, cornerHeight: 12, transform: nil), rgb(0.55, 0.36, 0.18))
        ctx.restoreGState()
        fillGradient(ctx, CGPath(roundedRect: frame, cornerWidth: 12, cornerHeight: 12, transform: nil),
                     [rgb(0.66, 0.45, 0.24), rgb(0.45, 0.28, 0.13)], from: CGPoint(x: 0, y: frame.minY), to: CGPoint(x: 0, y: frame.maxY))
        let slate = frame.insetBy(dx: 7, dy: 7)
        let board = rgb(0.1, 0.17, 0.14)
        fill(ctx, CGPath(roundedRect: slate, cornerWidth: 6, cornerHeight: 6, transform: nil), board)
        ctx.saveGState(); ctx.addRect(slate); ctx.clip()
        ctx.setFillColor(rgb(1, 1, 1, 0.035))
        for i in 0..<3 {
            ctx.saveGState()
            ctx.translateBy(x: slate.minX + 40 + CGFloat(i) * 65, y: slate.minY + 30 + CGFloat(i % 2) * 70)
            ctx.rotate(by: CGFloat(hash(i, 70)) - 0.5)
            ctx.fillEllipse(in: CGRect(x: -55, y: -18, width: 110, height: 36))
            ctx.restoreGState()
        }
        ctx.restoreGState()

        let place = CGPoint(x: 120, y: 60)
        let fit = CGSize(width: 176, height: 72)
        if s.within(0.25) && s.count > 0 {
            let wipe = CGFloat(min(1, s.age / 0.2))
            let old = Lettering(String(s.previous), font: "Chalkduster", size: 66).placed(at: place, fit: fit)
            for k in 0..<3 {
                var smear = CGAffineTransform(translationX: wipe * 30 + CGFloat(k) * 4, y: 0)
                fill(ctx, old.copy(using: &smear)!, rgb(0.92, 0.92, 0.9, (1 - wipe) * 0.35))
            }
        }
        let rotation = s.within(0.3) && s.count > 0 ? 0.05 * exp(-12 * s.age) : 0
        let number = Lettering(s.text, font: "Chalkduster", size: 66).placed(at: place, rotation: rotation, fit: fit)
        let written = s.within(0.25) && s.count > 0 ? CGFloat(min(1, s.age / 0.12)) : 1
        fill(ctx, number, rgb(0.97, 0.97, 0.95, written))
        ctx.saveGState(); ctx.addPath(number); ctx.clip()
        ctx.setFillColor(board.copy(alpha: 0.45)!)
        let nb = number.boundingBoxOfPath
        for i in 0..<150 {
            let x = nb.minX + CGFloat(hash(i, 80 + s.count)) * nb.width, y = nb.minY + CGFloat(hash(i, 81 + s.count)) * nb.height
            ctx.fill(CGRect(x: x, y: y, width: 1.2, height: 1.2))
        }
        ctx.restoreGState()

        let marks = s.count == 0 ? 0 : (s.count - 1) % 5 + 1
        let base = CGPoint(x: 120, y: 120), spacing: CGFloat = 14
        var newest: CGPoint?
        for m in stride(from: 1, through: marks, by: 1) {
            let reveal = m == marks && s.within(0.4) ? CGFloat(min(1, s.age / 0.14)) : 1
            let from: CGPoint, to: CGPoint
            if m < 5 {
                let x = base.x - 1.5 * spacing + CGFloat(m - 1) * spacing
                from = CGPoint(x: x + CGFloat(hash(m, 90) - 0.5) * 3, y: base.y - 15)
                to = CGPoint(x: x + CGFloat(hash(m, 91) - 0.5) * 3, y: base.y + 15)
            } else {
                from = CGPoint(x: base.x - 2.4 * spacing, y: base.y + 9)
                to = CGPoint(x: base.x + 2.4 * spacing, y: base.y - 9)
            }
            let end = CGPoint(x: from.x + (to.x - from.x) * reveal, y: from.y + (to.y - from.y) * reveal)
            chalkLine(ctx, from: from, to: end, seed: m)
            if m == marks { newest = end }
        }
        if let newest, s.within(0.6) && s.count > 0 {
            let t = s.age
            for i in 0..<10 {
                let a = hash(i, 95) * 2 * .pi
                let p = CGPoint(x: newest.x + CGFloat(cos(a) * 16 * t * hash(i, 96) * 3), y: newest.y + CGFloat(sin(a) * 8 * t + 22 * t * t))
                let r = CGFloat(0.6 + 1.2 * hash(i, 97))
                ctx.setFillColor(rgb(0.95, 0.95, 0.92, CGFloat(0.6 * (1 - t / 0.6))))
                ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            }
        }
        fill(ctx, Lettering(s.label.lowercased(), font: "Chalkduster", size: 15).placed(at: CGPoint(x: 120, y: 152), fit: CGSize(width: 190, height: 18)),
             rgb(0.95, 0.95, 0.92, 0.85))
    }

    private static func chalkLine(_ ctx: CGContext, from: CGPoint, to: CGPoint, seed: Int) {
        guard hypot(to.x - from.x, to.y - from.y) > 0.5 else { return }
        ctx.setStrokeColor(rgb(0.97, 0.97, 0.95, 0.9)); ctx.setLineWidth(3.6)
        ctx.move(to: from); ctx.addLine(to: to); ctx.strokePath()
        ctx.setStrokeColor(rgb(0.97, 0.97, 0.95, 0.35)); ctx.setLineWidth(1.2)
        for offset in [-1.6, 1.6] as [CGFloat] {
            ctx.move(to: CGPoint(x: from.x + offset, y: from.y)); ctx.addLine(to: CGPoint(x: to.x + offset * 0.6, y: to.y)); ctx.strokePath()
        }
        ctx.setFillColor(rgb(0.1, 0.17, 0.14, 0.55))
        for i in 0..<8 {
            let f = CGFloat(hash(i, seed * 10 + 1))
            ctx.fill(CGRect(x: from.x + (to.x - from.x) * f - 0.6, y: from.y + (to.y - from.y) * f - 0.6, width: 1.3, height: 1.3))
        }
    }

    // MARK: - Shared

    nonisolated struct Moment {
        let count: Int
        let previous: Int
        /// Seconds since the last recorded touch; 99 when there is none.
        let age: Double
        let time: Double
        let isTotal: Bool
        let label: String

        init(counter: ExportCounterState, time: Double) {
            count = max(0, counter.count)
            let raw = counter.age ?? .infinity
            age = counter.isTotal || !raw.isFinite || raw < 0 ? 99 : raw
            previous = age < 99 ? max(0, count - 1) : count
            self.time = time.isFinite ? max(0, time) : 0
            isTotal = counter.isTotal
            label = counter.label
        }

        var text: String { String(count) }
        var padded: String { String(format: "%02d", count) }
        var milestone: Bool { !isTotal && count > 0 && count.isMultiple(of: 10) && age < 1.2 }
        func within(_ seconds: Double) -> Bool { age < seconds }
        /// 0 → 1 across `duration` after the touch (plus any delay), then held at 1.
        func progress(_ duration: Double, delay: Double = 0) -> Double { min(1, max(0, (age - delay) / duration)) }
    }

    /// Text as one path, y down with its baseline at 0, so it can be stroked, clipped and transformed.
    nonisolated struct Lettering {
        let path: CGPath
        var bounds: CGRect { path.boundingBoxOfPath }

        init(_ text: String, font name: String, size: CGFloat, tracking: CGFloat = 0) {
            let font = CTFontCreateWithName(name as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTKernAttributeName as String): tracking]))
            let path = CGMutablePath()
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let runFont = attributes[kCTFontAttributeName as String].map { $0 as! CTFont } ?? font
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                for i in 0..<count {
                    guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                    let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: positions[i].x, ty: -positions[i].y)
                    path.addPath(glyph, transform: flip)
                }
            }
            self.path = path
        }

        /// Centered on `center` (or anchored at a fraction of its height), scaled and rotated,
        /// and shrunk if needed to fit `fit`.
        func placed(at center: CGPoint, scaleX: Double = 1, scaleY: Double = 1, rotation: Double = 0,
                    anchorY: CGFloat = 0.5, fit: CGSize? = nil) -> CGPath {
            let b = bounds
            guard b.width > 0, b.height > 0 else { return path }
            var factor: CGFloat = 1
            if let fit { factor = min(1, fit.width / b.width, fit.height / b.height) }
            var t = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: CGFloat(rotation))
                .scaledBy(x: factor * CGFloat(scaleX), y: factor * CGFloat(scaleY))
                .translatedBy(x: -b.midX, y: -(b.minY + b.height * anchorY))
            return path.copy(using: &t) ?? path
        }
    }

    /// Up to `count` x positions inside the lettering along a line, spread across its width.
    private static func anchors(on path: CGPath, y: CGFloat, count: Int, seed: Int) -> [CGFloat] {
        let b = path.boundingBoxOfPath
        let inside = (0..<24).map { b.minX + (CGFloat($0) + 0.5) / 24 * b.width }.filter { path.contains(CGPoint(x: $0, y: y)) }
        guard !inside.isEmpty else { return [] }
        var picked: [CGFloat] = []
        for i in 0..<(count * 3) where picked.count < count {
            let x = inside[Int(hash(i, 200 + seed) * Double(inside.count)) % inside.count]
            if picked.allSatisfy({ abs($0 - x) > b.width / CGFloat(count + 2) }) { picked.append(x) }
        }
        return picked
    }

    private static func label(_ ctx: CGContext, _ text: String, font: String, size: CGFloat, tracking: CGFloat = 0,
                              center: CGPoint, color: CGColor) {
        let path = Lettering(text, font: font, size: size, tracking: tracking).placed(at: center, fit: CGSize(width: 220, height: size * 1.4))
        ctx.saveGState()
        shadow(ctx, offset: CGSize(width: 0, height: 1), blur: 2, color: rgb(0, 0, 0, 0.55))
        fill(ctx, path, color)
        ctx.restoreGState()
    }

    /// Core Graphics applies shadows in device pixels, ignoring the transform. Converting them
    /// keeps glows and drop shadows turning and scaling with a rotated or resized sticker, so
    /// the export matches the editor preview, which rotates a finished image.
    private static func shadow(_ ctx: CGContext, offset: CGSize, blur: CGFloat, color: CGColor?) {
        let m = ctx.ctm
        let device = CGSize(width: offset.width * m.a + offset.height * m.c, height: offset.width * m.b + offset.height * m.d)
        ctx.setShadow(offset: device, blur: blur * sqrt(abs(m.a * m.d - m.b * m.c)), color: color)
    }

    private static func fill(_ ctx: CGContext, _ path: CGPath, _ color: CGColor) {
        ctx.addPath(path); ctx.setFillColor(color); ctx.fillPath()
    }

    private static func stroke(_ ctx: CGContext, _ path: CGPath, _ color: CGColor, _ width: CGFloat) {
        ctx.addPath(path); ctx.setStrokeColor(color); ctx.setLineWidth(width); ctx.strokePath()
    }

    private static func fillGradient(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        gradient(ctx, colors, from: from, to: to)
        ctx.restoreGState()
    }

    private static func gradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil) else { return }
        ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func starShape(_ ctx: CGContext, at p: CGPoint, radius: CGFloat, scaleX: CGFloat) {
        for i in 0..<10 {
            let a = Double(i) * .pi / 5 - .pi / 2, r = i.isMultiple(of: 2) ? radius : radius * 0.42
            let v = CGPoint(x: p.x + CGFloat(cos(a)) * r * scaleX, y: p.y + CGFloat(sin(a)) * r)
            if i == 0 { ctx.move(to: v) } else { ctx.addLine(to: v) }
        }
        ctx.closePath(); ctx.fillPath()
    }

    private static func sparkle(_ ctx: CGContext, at p: CGPoint, size: CGFloat) {
        let w = size * 0.22
        ctx.move(to: CGPoint(x: p.x, y: p.y - size))
        ctx.addQuadCurve(to: CGPoint(x: p.x + size, y: p.y), control: CGPoint(x: p.x + w, y: p.y - w))
        ctx.addQuadCurve(to: CGPoint(x: p.x, y: p.y + size), control: CGPoint(x: p.x + w, y: p.y + w))
        ctx.addQuadCurve(to: CGPoint(x: p.x - size, y: p.y), control: CGPoint(x: p.x - w, y: p.y + w))
        ctx.addQuadCurve(to: CGPoint(x: p.x, y: p.y - size), control: CGPoint(x: p.x - w, y: p.y - w))
        ctx.fillPath()
    }

    private static func hash(_ i: Int, _ seed: Int) -> Double {
        let n = sin(Double(i &* 71 &+ seed &* 97) * 12.9898) * 43758.5453
        return n - floor(n)
    }

    private static func easeOut(_ x: Double) -> Double { 1 - pow(1 - min(1, max(0, x)), 3) }
    private static func easeInOut(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: a)
    }
    private static let lime = CGColor(red: 0.83, green: 1, blue: 0.25, alpha: 1)
    private static let gold = CGColor(red: 1, green: 0.78, blue: 0.2, alpha: 1)
}
