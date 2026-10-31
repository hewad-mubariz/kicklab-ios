import CoreGraphics
import Foundation

/// The showpiece counters' celebrations, each made from its counter's own materials: an arcade
/// marquee and prize ticket for the Odometer, a TV banner for Broadcast, a sprayed crown for
/// Graffiti and so on. Badge space (240 × 180, y down); `MilestoneAppearance` clips them to its
/// canvas and picks one by counter. Pure functions of the count and the time since the touch.
extension MilestoneAppearance {
    private typealias Art = CounterArt

    // MARK: - Classic: mint ripples and sparkles, with glints landing on the number.

    static func classic(_ ctx: CGContext, count: Int, t: Double) {
        let mint = rgb(0.45, 0.98, 0.74)
        for (delay, width) in [(0.0, 5.0), (0.18, 3.0)] {
            let u = ease((t - delay) / 0.95)
            guard t >= delay, u < 1 else { continue }
            ring(ctx, center, rx: 110 + 120 * u, ry: 84 + 82 * u, color: mint.copy(alpha: CGFloat(0.8 * (1 - u)))!,
                 width: width * (1 - u) + 1)
        }
        for i in 0..<12 {
            let v = blip(t, start: 0.04 + Double(i) * 0.06, life: 0.5)
            guard v > 0 else { continue }
            let p = point(center, angle: Double(i) / 12 * 2 * .pi + 0.4,
                          rx: 150 + 40 * noise(count, i, 1), ry: 104 + 26 * noise(count, i, 2))
            ctx.setFillColor(i % 3 == 0 ? mint : rgb(1, 1, 1, 0.95))
            Art.sparkle(ctx, at: p, size: CGFloat((8 + 8 * noise(count, i, 3)) * v))
        }
        tag(ctx, t: t, start: 0.04, text: "\(count) TOUCHES", ink: rgb(0.02, 0.2, 0.12),
            fill: [rgb(0.72, 1, 0.87), rgb(0.36, 0.9, 0.66)])
    }

    static func classicFront(_ ctx: CGContext, t: Double) {
        for (i, p) in [CGPoint(x: 18, y: 32), CGPoint(x: 116, y: 44), CGPoint(x: 66, y: 104)].enumerated() {
            let v = blip(t, start: 0.12 + Double(i) * 0.14, life: 0.36)
            guard v > 0 else { continue }
            ctx.setFillColor(rgb(1, 1, 1, 0.95))
            Art.sparkle(ctx, at: p, size: CGFloat(13 * v))
        }
    }

    // MARK: - Odometer: an arcade marquee chases round the drums and a prize ticket feeds out.

    static func odometer(_ ctx: CGContext, count: Int, t: Double) {
        let on = min(1, t / 0.08) * ending(t)
        let frame = CGRect(x: 30, y: -4, width: 180, height: 158)
        let plate = CGPath(roundedRect: frame, cornerWidth: 20, cornerHeight: 20, transform: nil)
        Art.stroke(ctx, plate, rgb(0.1, 0.07, 0.09, 0.92 * on), 15)
        for inset in [-7.5, 7.5] {
            let edge = frame.insetBy(dx: CGFloat(inset), dy: CGFloat(inset)), radius = CGFloat(20 - inset)
            Art.stroke(ctx, CGPath(roundedRect: edge, cornerWidth: radius, cornerHeight: radius, transform: nil),
                       rgb(0.95, 0.72, 0.3, 0.8 * on), 1.2)
        }
        // Every third bulb lit, the pattern stepping clockwise.
        let chase = Int(t * 16)
        for i in 0..<28 {
            let p = point(around: frame, radius: 20, at: Double(i) / 28)
            if ((i - chase) % 3 + 3) % 3 == 0 {
                ctx.setFillColor(rgb(1, 0.8, 0.35, 0.35 * on)); ctx.fillEllipse(in: dot(p, 9))
                ctx.setFillColor(rgb(1, 0.96, 0.72, on)); ctx.fillEllipse(in: dot(p, 4.4))
            } else {
                ctx.setFillColor(rgb(0.5, 0.36, 0.18, 0.85 * on)); ctx.fillEllipse(in: dot(p, 3.8))
            }
        }

        let feed = Art.easeOut((t - 0.15) / 0.55)
        guard feed > 0 else { return }
        let top: CGFloat = 162, full: CGFloat = 96, length = full * CGFloat(feed)
        let ticket = CGRect(x: 80, y: top, width: 80, height: length)
        ctx.saveGState()
        ctx.setAlpha(CGFloat(ending(t)))
        ctx.saveGState()
        // It sways a little as it feeds out of the slot.
        ctx.translateBy(x: 120, y: top); ctx.rotate(by: CGFloat(0.06 * sin(t * 9) * (1 - feed * 0.6))); ctx.translateBy(x: -120, y: -top)
        let paper = CGPath(rect: ticket, transform: nil)
        Art.fillGradient(ctx, paper, [rgb(1, 0.68, 0.54), rgb(1, 0.5, 0.45)], from: CGPoint(x: 0, y: top), to: CGPoint(x: 0, y: top + full))
        ctx.addPath(paper); ctx.clip()
        // The printing travels with the paper: the last line out of the slot comes first.
        let shift = length - full, ink = rgb(0.55, 0.08, 0.12)
        ctx.setStrokeColor(rgb(0.7, 0.25, 0.25, 0.7)); ctx.setLineWidth(1); ctx.setLineDash(phase: 0, lengths: [3, 3])
        for y in [top + shift + 32, top + shift + 64] {
            ctx.move(to: CGPoint(x: ticket.minX, y: y)); ctx.addLine(to: CGPoint(x: ticket.maxX, y: y)); ctx.strokePath()
        }
        ctx.setLineDash(phase: 0, lengths: [])
        let lines: [(String, CGFloat, CGFloat)] = [("\(count) TOUCHES", 13, 16), ("★ ★ ★", 14, 48), ("WINNER", 15, 80)]
        for (text, size, y) in lines {
            Art.fill(ctx, Art.Lettering(text, font: "Courier-Bold", size: size, tracking: 1)
                .placed(at: CGPoint(x: 120, y: top + shift + y), fit: CGSize(width: 70, height: 16)), ink)
        }
        ctx.restoreGState()
        Art.fill(ctx, CGPath(roundedRect: CGRect(x: 74, y: top - 4, width: 92, height: 7), cornerWidth: 3.5, cornerHeight: 3.5,
                             transform: nil), rgb(0.08, 0.06, 0.07))
        ctx.restoreGState()
    }

    // MARK: - Broadcast: flares race along the scorebug and a MILESTONE banner wipes in under it.

    static func broadcast(_ ctx: CGContext, count: Int, t: Double) {
        let navy = rgb(0.05, 0.09, 0.22)
        for (i, y) in [CGFloat(56), 120].enumerated() {
            let u = (t - Double(i) * 0.08) / 0.5
            guard u > 0, u < 1 else { continue }
            let head = CGFloat(-120 + 480 * Art.easeInOut(u)), alpha = sin(u * .pi)
            let streak = CGRect(x: head - 190, y: y - 1.5, width: 190, height: 3)
            Art.fillGradient(ctx, CGPath(rect: streak, transform: nil), [rgb(1, 1, 1, 0), rgb(1, 0.88, 0.55, 0.9 * alpha), rgb(1, 1, 1, alpha)],
                             from: CGPoint(x: streak.minX, y: 0), to: CGPoint(x: streak.maxX, y: 0))
            ctx.setFillColor(rgb(1, 0.95, 0.75, 0.45 * alpha))
            ctx.fillEllipse(in: CGRect(x: head - 16, y: y - 4.5, width: 32, height: 9))
            ctx.setFillColor(rgb(1, 1, 1, alpha)); ctx.fillEllipse(in: dot(CGPoint(x: head, y: y), 3))
        }
        // Stripes shoot out from behind the bar's left end.
        for (i, color) in [Art.lime, Art.gold, rgb(1, 1, 1)].enumerated() {
            let u = (t - Double(i) * 0.05) / 0.45
            guard u > 0, u < 1 else { continue }
            let travel = CGFloat(Art.easeOut(u)) * 150
            Art.fill(ctx, slant(CGRect(x: 30 - travel - CGFloat(i) * 8, y: 62 + CGFloat(i) * 18, width: 60, height: 12), 10),
                     color.copy(alpha: CGFloat(1 - u))!)
        }
        // The banner wipes in from the left, holds, and wipes away to the right.
        let wipeIn = Art.easeOut((t - 0.12) / 0.3), wipeOut = t > 1.0 ? Art.easeInOut((t - 1.0) / 0.26) : 0
        guard wipeIn > wipeOut else { return }
        let banner = CGRect(x: 48, y: 146, width: 164, height: 28)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: banner.minX - 12 + 190 * CGFloat(wipeOut), y: banner.minY - 2,
                            width: 190 * CGFloat(wipeIn - wipeOut), height: banner.height + 14))
        Art.fillGradient(ctx, slant(banner, 10), [rgb(1, 0.88, 0.4), Art.gold, rgb(0.95, 0.62, 0.1)],
                         from: CGPoint(x: 0, y: banner.minY), to: CGPoint(x: 0, y: banner.maxY))
        Art.fill(ctx, slant(CGRect(x: banner.minX - 4, y: banner.maxY + 3, width: 124, height: 4), 3), Art.lime)
        Art.fill(ctx, Art.Lettering("MILESTONE", font: "AvenirNextCondensed-HeavyItalic", size: 20, tracking: 2)
            .placed(at: CGPoint(x: banner.minX + 64, y: banner.midY), fit: CGSize(width: 112, height: 22)), navy)
        Art.fill(ctx, slant(CGRect(x: banner.maxX - 46, y: banner.minY, width: 46, height: banner.height), 10), navy)
        Art.fill(ctx, Art.Lettering("\(count)", font: "AvenirNextCondensed-HeavyItalic", size: 20)
            .placed(at: CGPoint(x: banner.maxX - 22, y: banner.midY), fit: CGSize(width: 32, height: 22)), Art.lime)
        ctx.restoreGState()
    }

    // MARK: - Comic: a red blast behind the starburst and a speech bubble shouting the moment.

    static func comic(_ ctx: CGContext, count: Int, t: Double) {
        let c = CGPoint(x: 120, y: 80)
        if t < 0.5 {
            let fade = 1 - t / 0.5
            for i in 0..<22 {
                let a = Double(i) / 22 * 2 * .pi + 0.07
                let inner = 0.62 + 0.12 * noise(count, i, 1) + 0.18 * t / 0.5
                ctx.setStrokeColor(i % 2 == 0 ? rgb(0, 0, 0, 0.85 * fade) : rgb(1, 1, 1, 0.9 * fade))
                ctx.setLineWidth(i % 2 == 0 ? 3.2 : 2)
                ctx.move(to: point(c, angle: a, rx: 230 * inner, ry: 168 * inner))
                ctx.addLine(to: point(c, angle: a, rx: 225, ry: 164))
                ctx.strokePath()
            }
        }
        let grow = t < 0.12 ? Art.easeOut(t / 0.12) * 1.12 : 1 + 0.12 * exp(-(t - 0.12) * 8) * cos((t - 0.12) * 20)
        let leave = t > 1.0 ? max(0, 1 - (t - 1.0) / 0.3) : 1
        guard leave > 0 else { return }
        let blast = CGMutablePath()
        for i in 0..<36 {
            let k = (i % 2 == 0 ? 1 : 0.76) * (0.9 + 0.1 * noise(count, i, 4)) * grow * (0.6 + 0.4 * leave)
            let p = point(c, angle: Double(i) / 36 * 2 * .pi, rx: 128 * k, ry: 98 * k)
            if i == 0 { blast.move(to: p) } else { blast.addLine(to: p) }
        }
        blast.closeSubpath()
        ctx.saveGState()
        ctx.setAlpha(CGFloat(leave))
        var drop = CGAffineTransform(translationX: 7, y: 7)
        Art.fill(ctx, blast.copy(using: &drop)!, rgb(0, 0, 0, 0.9))
        ctx.saveGState(); ctx.addPath(blast); ctx.clip()
        if let fire = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [rgb(1, 0.5, 0.2), rgb(0.93, 0.15, 0.2), rgb(0.68, 0.04, 0.14)] as CFArray, locations: [0, 0.5, 1]) {
            ctx.drawRadialGradient(fire, startCenter: c, startRadius: 0, endCenter: c, endRadius: 140, options: [])
        }
        // Halftone dots, as one path. The middle sits behind the counter's own starburst.
        for y in stride(from: c.y - 112, through: c.y + 112, by: 9) {
            for x in stride(from: c.x - 146, through: c.x + 146, by: 9) {
                let d = hypot((x - c.x) / 1.3, y - c.y)
                if d > 58 { ctx.addEllipse(in: dot(CGPoint(x: x, y: y), 0.5 + 2.4 * min(1, d / 100))) }
            }
        }
        ctx.setFillColor(rgb(0.5, 0.02, 0.1, 0.45)); ctx.fillPath()
        ctx.restoreGState()
        Art.stroke(ctx, blast, rgb(0, 0, 0), 4.5)
        ctx.restoreGState()
    }

    static func comicFront(_ ctx: CGContext, count: Int, t: Double) {
        guard t > 0.18 else { return }
        let pop = t < 0.3 ? Art.easeOut((t - 0.18) / 0.12) * 1.15 : 1 + 0.15 * exp(-(t - 0.3) * 9) * cos((t - 0.3) * 18)
        let leave = t > 1.02 ? max(0, 1 - (t - 1.02) / 0.22) : 1
        let scale = CGFloat(pop * (0.5 + 0.5 * leave))
        guard scale > 0.01, leave > 0 else { return }
        ctx.saveGState()
        ctx.setAlpha(CGFloat(leave))
        ctx.translateBy(x: 46, y: 4); ctx.rotate(by: -0.16); ctx.scaleBy(x: scale, y: scale)
        let body = CGPath(ellipseIn: CGRect(x: -56, y: -29, width: 112, height: 58), transform: nil)
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: 8, y: 22)); tail.addLine(to: CGPoint(x: 30, y: 42)); tail.addLine(to: CGPoint(x: 24, y: 18))
        tail.closeSubpath()
        var drop = CGAffineTransform(translationX: 4, y: 4)
        for shape in [body, tail] { Art.fill(ctx, shape.copy(using: &drop)!, rgb(0, 0, 0, 0.85)) }
        // Outline first, then the fill over it, so the tail joins the bubble without a seam.
        for shape in [body, tail] { Art.stroke(ctx, shape, rgb(0, 0, 0), 7) }
        for shape in [body, tail] { Art.fill(ctx, shape, rgb(1, 1, 1)) }
        let word = Art.Lettering(Milestones.cheer(count), font: "Futura-CondensedExtraBold", size: 30)
            .placed(at: CGPoint(x: 0, y: 1), fit: CGSize(width: 92, height: 34))
        Art.stroke(ctx, word, rgb(0, 0, 0), 5)
        Art.fillGradient(ctx, word, [rgb(1, 0.92, 0.3), rgb(1, 0.25, 0.15)], from: CGPoint(x: 0, y: -14), to: CGPoint(x: 0, y: 14))
        ctx.restoreGState()
    }

    // MARK: - Neon Sign: the sign's frame strikes up, lights chase round it, and a word lights below.

    static func neon(_ ctx: CGContext, count: Int, t: Double) {
        let power = Milestones.neonPower(t) * ending(t)
        guard power > 0.02 else { return }
        let pink = rgb(1, 0.2, 0.62), cyan = rgb(0.3, 0.95, 1)
        tube(ctx, CGPath(roundedRect: CGRect(x: 2, y: 0, width: 236, height: 172), cornerWidth: 30, cornerHeight: 30, transform: nil),
             color: cyan, power: power, width: 5)
        ctx.saveGState()
        ctx.setLineDash(phase: CGFloat(t * 110), lengths: [12, 9])
        tube(ctx, CGPath(roundedRect: CGRect(x: -12, y: -14, width: 264, height: 200), cornerWidth: 40, cornerHeight: 40, transform: nil),
             color: pink, power: power * 0.9, width: 4, layers: 1)
        ctx.restoreGState()
        if t < 0.3 {
            let u = t / 0.3
            ctx.setStrokeColor(rgb(0.85, 1, 1, 1 - u)); ctx.setLineWidth(1.6)
            let corners = [CGPoint(x: 10, y: 8), CGPoint(x: 230, y: 8), CGPoint(x: 10, y: 164), CGPoint(x: 230, y: 164)]
            for i in 0..<12 {
                let corner = corners[i % 4]
                let a = atan2(Double(corner.y - 86), Double(corner.x - 120)) + (noise(count, i, 6) - 0.5) * 1.4
                let r = 6 + 40 * u
                ctx.move(to: point(corner, angle: a, rx: r, ry: r)); ctx.addLine(to: point(corner, angle: a, rx: r + 10, ry: r + 10))
                ctx.strokePath()
            }
        }
        // The word, in the counter's own script, strikes a beat later.
        let lit = (t < 0.22 ? 0 : Milestones.neonPower(t - 0.22)) * ending(t)
        guard lit > 0.02 else { return }
        let word = Art.Lettering(Milestones.cheer(count).lowercased(), font: "SnellRoundhand-Black", size: 44)
            .placed(at: CGPoint(x: 120, y: 214), fit: CGSize(width: 200, height: 48))
        glow(ctx, word, color: pink, power: lit, width: 2.4)
        Art.fill(ctx, word, rgb(1, 0.86, 0.95, lit))
        Art.stroke(ctx, word, pink.copy(alpha: CGFloat(0.9 * lit))!, 1)
    }

    /// A lit glass tube: a coloured glow round a white-hot core. The glow is wide, faint strokes
    /// rather than a blurred shadow, which is far cheaper to draw every frame.
    private static func tube(_ ctx: CGContext, _ path: CGPath, color: CGColor, power: Double, width: CGFloat, layers: Int = 2) {
        glow(ctx, path, color: color, power: power, width: width, layers: layers)
        Art.stroke(ctx, path, color.copy(alpha: CGFloat(min(1, power)))!, width)
        Art.stroke(ctx, path, rgb(1, 1, 1, 0.85 * power), width * 0.35)
    }

    private static func glow(_ ctx: CGContext, _ path: CGPath, color: CGColor, power: Double, width: CGFloat, layers: Int = 2) {
        for (spread, alpha) in [(4.2, 0.09), (2.4, 0.24)].suffix(layers) {
            Art.stroke(ctx, path, color.copy(alpha: CGFloat(alpha * min(1, power)))!, width * CGFloat(spread))
        }
    }

    // MARK: - Molten: the number erupts: a heat bloom, a shock ring, embers and blobs of lava.

    static func molten(_ ctx: CGContext, count: Int, t: Double) {
        let c = CGPoint(x: 120, y: 70)
        let heat = min(1, t / 0.1) * max(0, 1 - t / 1.25)
        if heat > 0, let bloom = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [rgb(1, 0.55, 0.1, 0.6 * heat), rgb(1, 0.25, 0.05, 0.25 * heat), rgb(1, 0.2, 0, 0)] as CFArray,
                locations: [0, 0.5, 1]) {
            ctx.saveGState(); ctx.translateBy(x: c.x, y: c.y); ctx.scaleBy(x: 1, y: 0.75)
            ctx.drawRadialGradient(bloom, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 170, options: [])
            ctx.restoreGState()
        }
        let u = ease(t / 0.7)
        if u < 1 { ring(ctx, c, rx: 90 + 140 * u, ry: 70 + 85 * u, color: rgb(1, 0.6, 0.15, 0.85 * (1 - u)), width: 7 * (1 - u) + 1) }
        // Embers in a fountain from the top of the number, cooling from white to red.
        for i in 0..<36 {
            let age = t - (0.02 + 0.3 * noise(count, i, 1))
            let life = 0.55 + 0.3 * noise(count, i, 4)
            guard age > 0, age < life else { continue }
            let angle = -Double.pi / 2 + (noise(count, i, 2) - 0.5) * 1.6, speed = 170 + 130 * noise(count, i, 3)
            func at(_ a: Double) -> CGPoint {
                CGPoint(x: c.x + CGFloat(cos(angle) * speed * a), y: c.y - 20 + CGFloat(sin(angle) * speed * a + 260 * a * a))
            }
            let cool = age / life, fade = (1 - cool) * ending(t)
            ctx.setStrokeColor(rgb(1, 0.95 - 0.6 * cool, 0.55 - 0.5 * cool, fade))
            ctx.setLineWidth(CGFloat(3.2 - 1.8 * cool))
            ctx.move(to: at(max(0, age - 0.035))); ctx.addLine(to: at(age)); ctx.strokePath()
        }
        // Heavier blobs of lava arc out and fall.
        for i in 0..<7 {
            let age = t - (0.05 + 0.15 * noise(count, i, 11))
            guard age > 0, age < 0.9 else { continue }
            let angle = -Double.pi / 2 + (Double(i) / 6 - 0.5) * 1.8, speed = 150 + 70 * noise(count, i, 12)
            let p = CGPoint(x: c.x + CGFloat(cos(angle) * speed * age), y: c.y + CGFloat(sin(angle) * speed * age + 300 * age * age))
            let r = CGFloat(4.5 + 2.5 * noise(count, i, 13)), alpha = min(1, (0.9 - age) / 0.25) * ending(t)
            ctx.setFillColor(rgb(0.85, 0.22, 0.04, alpha)); ctx.fillEllipse(in: dot(p, r))
            ctx.setFillColor(rgb(1, 0.78, 0.3, alpha)); ctx.fillEllipse(in: dot(CGPoint(x: p.x - r * 0.25, y: p.y - r * 0.25), r * 0.5))
        }
        tag(ctx, t: t, start: 0.1, text: "\(count) TOUCHES", ink: rgb(1, 0.74, 0.32), fill: [rgb(0.16, 0.08, 0.05, 0.92)],
            edge: rgb(1, 0.45, 0.1, 0.9), glow: rgb(1, 0.4, 0.05, 0.8))
    }

    // MARK: - Glitch: the HUD tears: RGB slices, dead pixels, the brackets blowing out, LEVEL UP.

    static func glitch(_ ctx: CGContext, count: Int, t: Double) {
        let cyan = rgb(0.3, 0.95, 1), magenta = rgb(1, 0.2, 0.62)
        let frame = Int(t / 0.05) + count * 1000
        ctx.saveGState()
        ctx.setLineCap(.square); ctx.setLineJoin(.miter)
        for (k, delay) in [0.0, 0.16].enumerated() {
            let u = ease((t - delay) / 0.6)
            guard t >= delay, u < 1 else { continue }
            let w = CGFloat(104 + 110 * u), h = CGFloat(66 + 80 * u)
            brackets(ctx, CGRect(x: 120 - w, y: 74 - h, width: w * 2, height: h * 2),
                     color: (k == 0 ? cyan : magenta).copy(alpha: CGFloat(1 - u))!)
        }
        ctx.restoreGState()
        // Slices and dead pixels, reshuffled every frame: a storm, then a few late flickers.
        let storm = t < 0.45 ? 1 : (t < 0.95 && Art.hash(frame, 310) > 0.75 ? 0.6 : 0)
        if storm > 0 {
            for i in 0..<9 {
                let n = frame * 9 + i
                ctx.setFillColor((i % 2 == 0 ? cyan : magenta).copy(alpha: CGFloat(0.55 * storm))!)
                ctx.fill(CGRect(x: -100 + 380 * Art.hash(n, 312), y: -60 + 300 * Art.hash(n, 311),
                                width: 40 + 140 * Art.hash(n, 313), height: 2 + 9 * Art.hash(n, 314)))
            }
            for i in 0..<14 {
                let n = frame * 14 + i
                let x = floor((-80 + 400 * Art.hash(n, 315)) / 4) * 4, y = floor((-60 + 300 * Art.hash(n, 316)) / 4) * 4
                let side = Art.hash(i, 317) > 0.5 ? 6.0 : 4.0
                ctx.setFillColor([rgb(1, 1, 1), cyan, magenta][i % 3].copy(alpha: CGFloat(0.9 * storm))!)
                ctx.fill(CGRect(x: x, y: y, width: side, height: side))
            }
        }
        let age = t - 0.06
        if age > 0 {
            let alpha = min(1, age / 0.05) * ending(t)
            let jitter = age < 0.3 ? CGFloat(Art.hash(frame, 318) - 0.5) * 10 : 0
            let split: CGFloat = age < 0.35 ? 4 : 1.5
            let text = Art.Lettering("LEVEL UP", font: "Menlo-Bold", size: 34, tracking: 3)
            let fit = CGSize(width: 220, height: 40)
            for (dx, color) in [(-split, magenta.copy(alpha: CGFloat(0.8 * alpha))!), (split, cyan.copy(alpha: CGFloat(0.8 * alpha))!),
                                (0, rgb(0.92, 1, 1, alpha))] {
                Art.fill(ctx, text.placed(at: CGPoint(x: 120 + jitter + dx, y: -34), fit: fit), color)
            }
        }
        tag(ctx, t: t, start: 0.18, text: "LV \(Milestones.level(count))", font: "Menlo-Bold", ink: cyan,
            fill: [rgb(0.02, 0.08, 0.12, 0.9)], edge: cyan)
    }

    static func glitchFront(_ ctx: CGContext, count: Int, t: Double) {
        let frame = Int(t / 0.05) + count * 1000
        guard t < 0.4, Art.hash(frame, 320) > 0.3 else { return }
        for i in 0..<3 {
            let n = frame * 3 + i
            ctx.setFillColor(i % 2 == 0 ? rgb(0.3, 0.95, 1, 0.5) : rgb(1, 0.2, 0.62, 0.5))
            ctx.fill(CGRect(x: 20 + 30 * Art.hash(n, 322), y: 30 + 100 * Art.hash(n, 321),
                            width: 140 + 40 * Art.hash(n, 323), height: 2 + 4 * Art.hash(n, 324)))
        }
    }

    private static func brackets(_ ctx: CGContext, _ r: CGRect, color: CGColor, arm: CGFloat = 22) {
        ctx.setStrokeColor(color); ctx.setLineWidth(3)
        for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            ctx.move(to: CGPoint(x: x + arm * dx, y: y)); ctx.addLine(to: CGPoint(x: x, y: y))
            ctx.addLine(to: CGPoint(x: x, y: y + arm * dy)); ctx.strokePath()
        }
    }

    // MARK: - Graffiti: paint splats burst round the piece and a crown is sprayed on top.

    static func graffiti(_ ctx: CGContext, count: Int, t: Double) {
        let palette = [rgb(1, 0.3, 0.6), rgb(1, 0.6, 0.1), rgb(1, 0.9, 0.2), rgb(0.55, 0.3, 1), rgb(0.3, 0.95, 0.7)]
        let fade = ending(t, tail: 0.35)
        for i in 0..<8 {
            let start = 0.02 + Double(i) * 0.035, u = (t - start) / 0.09
            guard u > 0 else { continue }
            let pop = CGFloat(u < 1 ? Art.easeOut(u) * 1.15 : 1 + 0.15 * max(0, 1 - (u - 1) * 2))
            let p = point(CGPoint(x: 120, y: 80), angle: Double(i) / 8 * 2 * .pi + 0.3 + (noise(count, i, 1) - 0.5) * 0.5,
                          rx: 150 + 30 * noise(count, i, 2), ry: 96 + 16 * noise(count, i, 3))
            let r = CGFloat(12 + 9 * noise(count, i, 4)) * pop
            ctx.setFillColor(palette[(i + count) % palette.count].copy(alpha: CGFloat(fade))!)
            ctx.fillEllipse(in: dot(p, r))
            for j in 0..<7 {
                let n = i * 7 + j, d = Double(r) * (1.25 + 0.9 * noise(count, n, 6))
                ctx.fillEllipse(in: dot(point(p, angle: Double(j) / 7 * 2 * .pi + noise(count, n, 5) * 0.8, rx: d, ry: d),
                                        CGFloat(1.5 + 3.5 * noise(count, n, 7)) * pop))
            }
            // The paint runs.
            let run = CGFloat(Art.easeOut((t - start - 0.15) / 0.8) * (10 + 16 * noise(count, i, 8)))
            if run > 0 {
                ctx.fill(CGRect(x: p.x - 1.6, y: p.y, width: 3.2, height: r * 0.6 + run))
                ctx.fillEllipse(in: dot(CGPoint(x: p.x, y: p.y + r * 0.6 + run), 2.6))
            }
        }
        let sprayed = Art.easeInOut((t - 0.12) / 0.35)
        guard sprayed > 0 else { return }
        let yellow = rgb(1, 0.9, 0.2, fade)
        ctx.saveGState()
        ctx.translateBy(x: 116, y: 0); ctx.rotate(by: -0.12); ctx.translateBy(x: -116, y: 0)
        let crown = [(84, 18), (88, -22), (102, -4), (116, -34), (130, -4), (144, -22), (148, 18), (84, 18)]
            .map { CGPoint(x: $0.0, y: $0.1) }
        let path = partial(crown, sprayed)
        Art.stroke(ctx, path, rgb(1, 0.9, 0.2, 0.25 * fade), 11)
        Art.stroke(ctx, path, yellow, 5)
        if sprayed >= 1 {
            ctx.setFillColor(yellow)
            for (k, x) in [CGFloat(94), 116, 138].enumerated() {
                let length = CGFloat(Art.easeOut((t - 0.5 - Double(k) * 0.06) / 0.5)) * CGFloat(k == 1 ? 14 : 8)
                guard length > 0 else { continue }
                ctx.fill(CGRect(x: x - 1.3, y: 18, width: 2.6, height: length))
                ctx.fillEllipse(in: dot(CGPoint(x: x, y: 18 + length), 2.2))
            }
        }
        ctx.setStrokeColor(rgb(1, 1, 1, fade)); ctx.setLineWidth(2.4)
        for (k, p) in [CGPoint(x: 68, y: -26), CGPoint(x: 164, y: -34), CGPoint(x: 116, y: -56)].enumerated() {
            let size = CGFloat(9 * blip(t, start: 0.45 + Double(k) * 0.08, life: 0.45))
            guard size > 0 else { continue }
            ctx.move(to: CGPoint(x: p.x - size, y: p.y)); ctx.addLine(to: CGPoint(x: p.x + size, y: p.y))
            ctx.move(to: CGPoint(x: p.x, y: p.y - size)); ctx.addLine(to: CGPoint(x: p.x, y: p.y + size))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // MARK: - Jelly: a wobbling ring of jelly and glossy bubbles that rise and pop.

    static func jelly(_ ctx: CGContext, count: Int, t: Double) {
        let candy = [rgb(0.35, 0.65, 1), rgb(1, 0.45, 0.75), rgb(0.4, 0.95, 0.75)]
        let c = CGPoint(x: 120, y: 80), u = ease(t / 0.9)
        if u < 1 {
            let wave = CGMutablePath()
            for i in 0...72 {
                let a = Double(i) / 72 * 2 * .pi, wobble = 1 + 0.06 * sin(a * 6 + t * 14) * (1 - u)
                let p = point(c, angle: a, rx: (100 + 120 * u) * wobble, ry: (76 + 78 * u) * wobble)
                if i == 0 { wave.move(to: p) } else { wave.addLine(to: p) }
            }
            Art.stroke(ctx, wave, candy[0].copy(alpha: CGFloat(0.8 * (1 - u)))!, CGFloat(9 * (1 - u) + 2))
        }
        for i in 0..<16 {
            let start = 0.03 + 0.35 * noise(count, i, 1)
            // Every bubble has popped before the moment ends.
            let life = min(0.55 + 0.4 * noise(count, i, 2), 1.12 - start), age = t - start
            guard age > 0, age < life + 0.14 else { continue }
            let p = CGPoint(x: 20 + 200 * noise(count, i, 3) + CGFloat(8 * sin(age * 9 + Double(i))),
                            y: 150 + 30 * noise(count, i, 4) - CGFloat((60 + 70 * noise(count, i, 5)) * min(age, life)))
            let r = CGFloat(6 + 8 * noise(count, i, 6)) * CGFloat(min(1, age / 0.08))
            if age < life {
                ctx.setFillColor(candy[i % candy.count].copy(alpha: 0.22)!); ctx.fillEllipse(in: dot(p, r))
                ctx.setStrokeColor(rgb(1, 1, 1, 0.75)); ctx.setLineWidth(1.4); ctx.strokeEllipse(in: dot(p, r))
                ctx.setFillColor(rgb(1, 1, 1, 0.9))
                ctx.fillEllipse(in: CGRect(x: p.x - r * 0.55, y: p.y - r * 0.6, width: r * 0.42, height: r * 0.32))
            } else {
                let k = (age - life) / 0.14
                ctx.setStrokeColor(rgb(1, 1, 1, 0.8 * (1 - k))); ctx.setLineWidth(1.2)
                ctx.strokeEllipse(in: dot(p, r * CGFloat(1 + 0.8 * k)))
                ctx.setFillColor(rgb(1, 1, 1, 0.8 * (1 - k)))
                for j in 0..<5 {
                    let d = Double(r) * (1.3 + k)
                    ctx.fillEllipse(in: dot(point(p, angle: Double(j) / 5 * 2 * .pi + 0.5, rx: d, ry: d), 1.4))
                }
            }
        }
        tag(ctx, t: t, start: 0.06, text: "\(count) TOUCHES", ink: rgb(1, 1, 1), fill: [rgb(0.45, 0.72, 1), rgb(0.2, 0.42, 0.95)])
    }

    // MARK: - Gold Coin: a sunburst turns behind the medal while coins shower out of it.

    static func goldCoin(_ ctx: CGContext, count: Int, t: Double) {
        let c = CGPoint(x: 120, y: 100)
        let glow = min(1, t / 0.2) * ending(t, tail: 0.4), reach = 70 + 100 * ease(t / 0.4)
        let rays = CGMutablePath()
        for i in 0..<14 {
            let a = Double(i) / 14 * 2 * .pi + t * 0.6
            rays.move(to: c)
            rays.addLine(to: point(c, angle: a - 0.09, rx: reach, ry: reach))
            rays.addLine(to: point(c, angle: a + 0.09, rx: reach, ry: reach))
            rays.closeSubpath()
        }
        if glow > 0, let shine = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [rgb(1, 0.9, 0.45, 0.75 * glow), rgb(1, 0.75, 0.2, 0.3 * glow), rgb(1, 0.7, 0.2, 0)] as CFArray,
                locations: [0, 0.6, 1]) {
            ctx.saveGState(); ctx.addPath(rays); ctx.clip()
            ctx.drawRadialGradient(shine, startCenter: c, startRadius: 30, endCenter: c, endRadius: CGFloat(reach), options: [])
            ctx.restoreGState()
        }
        for i in 0..<14 {
            let age = t - (0.05 + 0.22 * noise(count, i, 1))
            guard age > 0, age < 0.95 else { continue }
            let angle = -Double.pi / 2 + (noise(count, i, 2) - 0.5) * 1.6, speed = 200 + 80 * noise(count, i, 3)
            let p = CGPoint(x: c.x + CGFloat(cos(angle) * speed * age), y: c.y - 30 + CGFloat(sin(angle) * speed * age + 300 * age * age))
            // Spinning: the face narrows to its edge and back.
            let spin = CGFloat(max(0.12, abs(cos(age * (10 + 8 * noise(count, i, 4)) + Double(i)))))
            let r = CGFloat(8 + 3 * noise(count, i, 5)), alpha = min(1, (0.95 - age) / 0.25) * ending(t)
            let face = CGRect(x: p.x - r * spin, y: p.y - r, width: 2 * r * spin, height: 2 * r)
            ctx.setFillColor(rgb(0.72, 0.48, 0.08, alpha)); ctx.fillEllipse(in: face.offsetBy(dx: 1.4, dy: 0))
            ctx.setFillColor(rgb(1, 0.8, 0.25, alpha)); ctx.fillEllipse(in: face)
            ctx.setFillColor(rgb(1, 0.95, 0.65, alpha)); ctx.fillEllipse(in: face.insetBy(dx: face.width * 0.3, dy: r * 0.3))
        }
        tag(ctx, t: t, start: 0.08, text: "\(count) TOUCHES", ink: rgb(0.32, 0.18, 0.02), fill: [rgb(1, 0.93, 0.6), rgb(0.95, 0.68, 0.14)])
    }

    static func goldCoinFront(_ ctx: CGContext, t: Double) {
        let c = CGPoint(x: 120, y: 100), r: CGFloat = 54
        // Once the medal has landed face up, a shine crosses it.
        let u = (t - 0.55) / 0.4
        if u > 0, u < 1 {
            ctx.saveGState()
            ctx.addEllipse(in: dot(c, r - 2)); ctx.clip()
            ctx.translateBy(x: c.x - r - 30 + CGFloat(u) * (2 * r + 60), y: c.y); ctx.rotate(by: 0.35)
            Art.fillGradient(ctx, CGPath(rect: CGRect(x: -14, y: -r * 1.3, width: 28, height: r * 2.6), transform: nil),
                             [rgb(1, 1, 1, 0), rgb(1, 1, 1, 0.6), rgb(1, 1, 1, 0)], from: CGPoint(x: -14, y: 0), to: CGPoint(x: 14, y: 0))
            ctx.restoreGState()
        }
        for (i, p) in [CGPoint(x: 86, y: 70), CGPoint(x: 152, y: 124), CGPoint(x: 148, y: 72)].enumerated() {
            let v = blip(t, start: 0.5 + Double(i) * 0.15, life: 0.3)
            guard v > 0 else { continue }
            ctx.setFillColor(rgb(1, 1, 0.92, 0.95))
            Art.sparkle(ctx, at: p, size: CGFloat(12 * v))
        }
    }

    // MARK: - Chalkboard: the coach circles the number, sticks a gold star on the board, and dust flies.

    static func chalk(_ ctx: CGContext, count: Int, t: Double) {
        let board = CGRect(x: 14, y: 8, width: 212, height: 162), middle = CGPoint(x: 120, y: 89)
        // Dust knocked off the frame: soft puffs that spread and thin out, and specks thrown further.
        for i in 0..<22 {
            let age = t - 0.06 * noise(count, i, 1)
            guard age > 0 else { continue }
            let origin = point(around: board, radius: 12, at: noise(count, i, 2))
            let away = atan2(Double(origin.y - middle.y), Double(origin.x - middle.x)) + (noise(count, i, 4) - 0.5) * 0.6
            let spread = Art.easeOut(age / 0.9), thin = max(0, 1 - age / 1.1) * ending(t)
            if i % 2 == 0 {
                let p = point(origin, angle: away, rx: 34 * spread, ry: 34 * spread)
                let r = CGFloat((5 + 7 * noise(count, i, 3)) * (0.7 + spread))
                for (k, share) in [(1.0, 0.035), (0.7, 0.04), (0.4, 0.05)] {
                    ctx.setFillColor(rgb(1, 1, 1, share * thin)); ctx.fillEllipse(in: dot(p, r * CGFloat(k)))
                }
            } else {
                let p = point(origin, angle: away, rx: 70 * spread, ry: 70 * spread)
                ctx.setFillColor(rgb(1, 1, 1, 0.55 * thin)); ctx.fillEllipse(in: dot(p, CGFloat(1 + 1.2 * noise(count, i, 3))))
            }
        }
        // The word, written left to right above the board.
        let write = (t - 0.3) / 0.35
        guard write > 0 else { return }
        let word = Art.Lettering(Milestones.cheer(count).capitalized, font: "Chalkduster", size: 34)
            .placed(at: CGPoint(x: 120, y: -30), fit: CGSize(width: 200, height: 44))
        let b = word.boundingBoxOfPath
        ctx.saveGState()
        ctx.clip(to: CGRect(x: b.minX - 4, y: b.minY - 6, width: (b.width + 8) * CGFloat(min(1, write)), height: b.height + 12))
        Art.shadow(ctx, offset: CGSize(width: 0, height: 2), blur: 4, color: rgb(0, 0, 0, 0.5))
        Art.fill(ctx, word, rgb(0.97, 0.97, 0.94, 0.95 * ending(t)))
        ctx.restoreGState()
    }

    static func chalkFront(_ ctx: CGContext, count: Int, t: Double) {
        let fade = ending(t)
        // One loop round the number and a little past where it started, like by hand.
        let loop = Art.easeInOut((t - 0.05) / 0.4)
        if loop > 0 {
            let points = (0...60).map { i -> CGPoint in
                let f = Double(i) / 60 * 1.12, wobble = (1 + 0.04 * sin(f * 13 + Double(count))) * (1 + 0.05 * f)
                return point(CGPoint(x: 120, y: 61), angle: -2.6 + f * 2 * .pi, rx: 74 * wobble, ry: 42 * wobble)
            }
            chalkStroke(ctx, partial(points, loop), alpha: fade)
        }
        let slap = (t - 0.4) / 0.12
        guard slap > 0 else { return }
        let size = CGFloat(slap < 1 ? 2.2 - 1.2 * Art.easeOut(slap) : 1 + 0.08 * exp(-(t - 0.52) * 10) * cos((t - 0.52) * 30))
        ctx.saveGState()
        ctx.setAlpha(CGFloat(min(1, slap * 2) * fade))
        ctx.translateBy(x: 200, y: 32); ctx.rotate(by: 0.22); ctx.scaleBy(x: size, y: size)
        ctx.saveGState()
        Art.shadow(ctx, offset: CGSize(width: 1, height: 2), blur: 3, color: rgb(0, 0, 0, 0.45))
        ctx.setFillColor(rgb(0.98, 0.74, 0.12)); Art.starShape(ctx, at: .zero, radius: 18, scaleX: 1)
        ctx.restoreGState()
        ctx.setFillColor(rgb(1, 0.9, 0.45)); Art.starShape(ctx, at: CGPoint(x: -1.5, y: -2), radius: 11, scaleX: 1)
        ctx.restoreGState()
    }

    /// A chalk line: broken, with a fainter second pass beside it.
    private static func chalkStroke(_ ctx: CGContext, _ path: CGPath, alpha: Double, width: CGFloat = 3.4) {
        ctx.saveGState()
        ctx.setLineDash(phase: 0, lengths: [7, 1.6, 3, 1.2])
        Art.stroke(ctx, path, rgb(0.97, 0.97, 0.94, 0.85 * alpha), width)
        ctx.setLineDash(phase: 2, lengths: [2, 2.6])
        var nudge = CGAffineTransform(translationX: 0.9, y: 0.7)
        Art.stroke(ctx, path.copy(using: &nudge) ?? path, rgb(1, 1, 1, 0.5 * alpha), width * 0.5)
        ctx.restoreGState()
    }

    // MARK: - Shared

    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { Art.rgb(r, g, b, a) }

    private static func ease(_ x: Double) -> Double { let c = min(1, max(0, x)); return 1 - (1 - c) * (1 - c) }

    /// 1 through the celebration, easing to 0 over its last `tail` seconds.
    private static func ending(_ t: Double, tail: Double = 0.3) -> Double { min(1, max(0, (Milestones.duration - t) / tail)) }

    /// 0 → 1 → 0 over `life` seconds from `start`.
    private static func blip(_ t: Double, start: Double, life: Double) -> Double {
        let u = (t - start) / life
        return u <= 0 || u >= 1 ? 0 : sin(u * .pi)
    }

    /// A stable number in 0..<1 for this milestone, particle and property.
    private static func noise(_ count: Int, _ index: Int, _ lane: Int) -> Double { Art.hash(count &* 37 &+ index, lane) }

    private static func point(_ center: CGPoint, angle: Double, rx: Double, ry: Double) -> CGPoint {
        CGPoint(x: center.x + CGFloat(cos(angle) * rx), y: center.y + CGFloat(sin(angle) * ry))
    }

    private static func dot(_ p: CGPoint, _ r: CGFloat) -> CGRect { CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2) }

    private static func ring(_ ctx: CGContext, _ c: CGPoint, rx: Double, ry: Double, color: CGColor, width: Double) {
        ctx.setStrokeColor(color); ctx.setLineWidth(CGFloat(width))
        ctx.strokeEllipse(in: CGRect(x: c.x - CGFloat(rx), y: c.y - CGFloat(ry), width: CGFloat(rx * 2), height: CGFloat(ry * 2)))
    }

    /// A parallelogram leaning right by `lean`, like the scorebug's own blocks.
    private static func slant(_ rect: CGRect, _ lean: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + lean, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - lean, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    /// The point `fraction` of the way clockwise round a rounded rectangle, from the top edge's start.
    private static func point(around rect: CGRect, radius r: CGFloat, at fraction: Double) -> CGPoint {
        let w = rect.width - 2 * r, h = rect.height - 2 * r, arc = CGFloat.pi / 2 * r
        var d = CGFloat(fraction - floor(fraction)) * (2 * w + 2 * h + 4 * arc)
        func corner(_ cx: CGFloat, _ cy: CGFloat, from start: CGFloat, _ along: CGFloat) -> CGPoint {
            let a = start + along / r
            return CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r)
        }
        let segments: [(CGFloat, (CGFloat) -> CGPoint)] = [
            (w, { CGPoint(x: rect.minX + r + $0, y: rect.minY) }),
            (arc, { corner(rect.maxX - r, rect.minY + r, from: -.pi / 2, $0) }),
            (h, { CGPoint(x: rect.maxX, y: rect.minY + r + $0) }),
            (arc, { corner(rect.maxX - r, rect.maxY - r, from: 0, $0) }),
            (w, { CGPoint(x: rect.maxX - r - $0, y: rect.maxY) }),
            (arc, { corner(rect.minX + r, rect.maxY - r, from: .pi / 2, $0) }),
            (h, { CGPoint(x: rect.minX, y: rect.maxY - r - $0) }),
            (arc, { corner(rect.minX + r, rect.minY + r, from: .pi, $0) })
        ]
        for (length, at) in segments {
            if d <= length { return at(d) }
            d -= length
        }
        return CGPoint(x: rect.minX + r, y: rect.minY)
    }

    /// The first `fraction` of a polyline, for strokes drawn as you watch.
    private static func partial(_ points: [CGPoint], _ fraction: Double) -> CGPath {
        let path = CGMutablePath()
        guard points.count > 1, fraction > 0 else { return path }
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        var remaining = lengths.reduce(0, +) * CGFloat(min(1, fraction))
        path.move(to: points[0])
        for (i, length) in lengths.enumerated() {
            if remaining >= length {
                path.addLine(to: points[i + 1]); remaining -= length
                continue
            }
            let f = remaining / max(length, 0.001)
            path.addLine(to: CGPoint(x: points[i].x + (points[i + 1].x - points[i].x) * f,
                                     y: points[i].y + (points[i + 1].y - points[i].y) * f))
            break
        }
        return path
    }

    /// A pill that rises in under the counter, like the Normal counter's tag.
    private static func tag(_ ctx: CGContext, t: Double, start: Double = 0, text: String, font: String = "HelveticaNeue-Bold",
                            ink: CGColor, fill: [CGColor], edge: CGColor? = nil, glow: CGColor? = nil) {
        let age = t - start
        let alpha = min(1, max(0, age / 0.15)) * ending(t)
        guard alpha > 0.01 else { return }
        let rise = CGFloat(Art.easeOut(age / 0.28))
        let label = Art.Lettering(text, font: font, size: 22, tracking: 1.5)
        let width = max(80, label.bounds.width + 30)
        let rect = CGRect(x: 120 - width / 2, y: 196 + 22 * (1 - rise), width: width, height: 40)
        let shape = CGPath(roundedRect: rect, cornerWidth: 20, cornerHeight: 20, transform: nil)
        ctx.saveGState()
        ctx.setAlpha(CGFloat(alpha))
        ctx.saveGState()
        Art.shadow(ctx, offset: CGSize(width: 0, height: glow == nil ? 3 : 0), blur: glow == nil ? 10 : 14, color: glow ?? rgb(0, 0, 0, 0.4))
        Art.fill(ctx, shape, fill[0])
        ctx.restoreGState()
        if fill.count > 1 { Art.fillGradient(ctx, shape, fill, from: CGPoint(x: 0, y: rect.minY), to: CGPoint(x: 0, y: rect.maxY)) }
        if let edge { Art.stroke(ctx, shape, edge, 2) }
        Art.fill(ctx, label.placed(at: CGPoint(x: rect.midX, y: rect.midY)), ink)
        ctx.restoreGState()
    }
}
