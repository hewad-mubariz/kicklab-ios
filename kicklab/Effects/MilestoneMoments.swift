import CoreGraphics
import CoreText
import Foundation

/// Streak milestones: the counter celebrates the 10th, 25th, 50th, 75th and 100th touch, then
/// every 50th. Each counter style celebrates in its own way, with its own look, badge motion and
/// fanfare, so picking a counter picks its milestone. Everything follows the counter's own
/// timeline, so replay and export agree.
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

    /// The level a milestone reaches: the 10th touch is level 2, the 25th level 3, and so on.
    static func level(_ count: Int) -> Int { count < 10 ? 1 : (10...count).filter(isMilestone).count + 1 }

    /// A word for the moment that grows with the streak.
    static func cheer(_ count: Int) -> String {
        switch count {
        case ..<25: "NICE!"
        case 25: "GREAT!"
        case 50: "WOW!"
        case 75: "HUGE!"
        case 100: "LEGEND!"
        default: ["UNREAL!", "ON FIRE!", "BOOM!", "INSANE!"][(count / 50) % 4]
        }
    }

    /// The counter's size through the moment: a quick swell, a springy overshoot, then rest.
    static func pulse(_ progress: Double) -> CGFloat {
        let t = max(0, progress) * duration
        if t < 0.12 { return 1 + 0.22 * t / 0.12 }
        let settle = t - 0.12
        return 1 + 0.22 * exp(-settle * 6.5) * cos(settle * 15)
    }

    /// How each counter's badge moves through its celebration. Every motion ends at rest.
    static func motion(_ style: ExportBadgeStyle, progress: Double) -> MilestoneMotion {
        let t = max(0, progress) * duration
        func spring(_ amount: Double, decay: Double, rate: Double, delay: Double = 0) -> CGFloat {
            let s = t - delay
            return s < 0 ? 0 : CGFloat(amount * exp(-s * decay) * sin(s * rate))
        }
        let swell = pulse(progress)
        var motion = MilestoneMotion()
        switch style {
        case .normal, .classic, .broadcast:
            motion.scale(swell)
        case .odometer:
            // A mechanical clunk: the drums drop into place and bounce.
            motion.dy = CGFloat(t < 0.06 ? 9 * t / 0.06 : 9 * exp(-(t - 0.06) * 9) * cos((t - 0.06) * 24))
            motion.scale(1 + (swell - 1) * 0.4)
        case .comic:
            // Slammed in oversized, then a rubbery wobble.
            motion.scale(t < 0.08 ? CGFloat(1.35 - 0.35 * t / 0.08) : 1 + spring(0.12, decay: 7, rate: 22, delay: 0.08))
            motion.angle = spring(0.14, decay: 6, rate: 18)
        case .neon:
            motion.scale(1 + CGFloat(0.06 * neonPower(t) * exp(-t * 2.5)))
        case .molten:
            // It rumbles as it erupts.
            let shake = max(0, 1 - t / 0.6)
            motion.dx = CGFloat(5 * shake * sin(t * 83))
            motion.dy = CGFloat(4 * shake * sin(t * 67 + 1))
            motion.scale(1 + (swell - 1) * 0.6)
        case .glitch:
            // It skips sideways for a few frames, then locks back in.
            let frame = Int(t / 0.05)
            if t < 0.4, CounterArt.hash(frame, 301) > 0.4 {
                motion.dx = CGFloat(CounterArt.hash(frame, 302) - 0.5) * 26
                motion.scaleX = CounterArt.hash(frame, 303) > 0.7 ? 1.12 : 1
            }
        case .graffiti:
            motion.scale(1 + (swell - 1) * 0.7)
            motion.angle = spring(0.12, decay: 5, rate: 14)
        case .jelly:
            // Squash and stretch, like jelly set down hard.
            let wobble = spring(0.24, decay: 4, rate: 16)
            motion.scaleX = 1 + wobble
            motion.scaleY = 1 - wobble
        case .goldCoin:
            // The medal hops on its ribbon.
            motion.dy = CGFloat(-16 * sin(.pi * min(1, t / 0.45)))
            motion.scale(1 + (swell - 1) * 0.5)
        case .chalk:
            motion.angle = spring(0.05, decay: 4, rate: 12)
            motion.scale(1 + (swell - 1) * 0.4)
        }
        return motion
    }

    /// A neon tube striking: a few stutters, then steady light.
    static func neonPower(_ t: Double) -> Double {
        if t >= 0.19 { return 1 }
        return t < 0.035 || (t >= 0.075 && t < 0.1) || t >= 0.13 ? 0.85 : 0.06
    }
}

/// How the counter badge moves through a celebration, in badge units about its centre.
nonisolated struct MilestoneMotion: Equatable, Sendable {
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var angle: CGFloat = 0
    var dx: CGFloat = 0
    var dy: CGFloat = 0

    mutating func scale(_ factor: CGFloat) {
        scaleX = factor
        scaleY = factor
    }

    /// Moves `ctx` the way the badge moves: scaled, then turned about `center`, then shifted.
    func apply(to ctx: CGContext, center: CGPoint) {
        ctx.translateBy(x: center.x + dx, y: center.y + dy)
        ctx.rotate(by: angle)
        ctx.scaleBy(x: scaleX, y: scaleY)
        ctx.translateBy(x: -center.x, y: -center.y)
    }
}

/// The celebration around the counter badge, chosen by the counter's style. Drawn in the badge's
/// own 240×180 space, reaching half a badge past it on every side and clipped there, so the
/// editor's image and the export match. Most of it sits behind the counter; a few styles also
/// draw over it (`front`), moving with the badge.
nonisolated enum MilestoneAppearance {
    /// The canvas for a standalone image: twice the badge, with the badge centred.
    static let canvas = CGSize(width: 480, height: 360)
    static let badgeOrigin = CGPoint(x: 120, y: 90)
    static let center = CGPoint(x: 120, y: 90)

    private static let lime = NormalCounterAppearance.lime
    private static let mint = CGColor(red: 0.34, green: 0.96, blue: 0.65, alpha: 1)
    private static let palette: [CGColor] = [
        NormalCounterAppearance.lime, CGColor(red: 0.34, green: 0.96, blue: 0.65, alpha: 1),
        CGColor(gray: 1, alpha: 1), CGColor(red: 1, green: 0.82, blue: 0.3, alpha: 1),
        CGColor(red: 1, green: 0.42, blue: 0.75, alpha: 1)
    ]

    /// Styles that also draw over the counter: glints, a speech bubble, a sticker.
    static func hasFront(_ style: ExportBadgeStyle) -> Bool {
        switch style {
        case .classic, .comic, .glitch, .goldCoin, .chalk: true
        default: false
        }
    }

    /// The layer behind the counter, or with `front` the one over it (nil when the style has none).
    static func image(style: ExportBadgeStyle = .normal, count: Int, progress: Double, front: Bool = false,
                      scale: CGFloat = 2) -> CGImage? {
        guard !front || hasFront(style) else { return nil }
        let width = Int(canvas.width * scale), height = Int(canvas.height * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // A new bitmap's memory is not guaranteed to be empty.
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: badgeOrigin.x, y: badgeOrigin.y)
        draw(in: ctx, style: style, count: count, progress: progress, front: front)
        return ctx.makeImage()
    }

    /// Top-left badge coordinates. A pure function of the style, count and progress.
    static func draw(in ctx: CGContext, style: ExportBadgeStyle = .normal, count: Int, progress: Double, front: Bool = false) {
        guard progress >= 0, progress < 1, !front || hasFront(style) else { return }
        let t = progress * Milestones.duration
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: CGRect(origin: CGPoint(x: -badgeOrigin.x, y: -badgeOrigin.y), size: canvas))
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        if front {
            switch style {
            case .classic: classicFront(ctx, t: t)
            case .comic: comicFront(ctx, count: count, t: t)
            case .glitch: glitchFront(ctx, count: count, t: t)
            case .goldCoin: goldCoinFront(ctx, t: t)
            case .chalk: chalkFront(ctx, count: count, t: t)
            default: break
            }
            return
        }
        switch style {
        case .normal: burst(ctx, count: count, t: t)
        case .classic: classic(ctx, count: count, t: t)
        case .odometer: odometer(ctx, count: count, t: t)
        case .broadcast: broadcast(ctx, count: count, t: t)
        case .comic: comic(ctx, count: count, t: t)
        case .neon: neon(ctx, count: count, t: t)
        case .molten: molten(ctx, count: count, t: t)
        case .glitch: glitch(ctx, count: count, t: t)
        case .graffiti: graffiti(ctx, count: count, t: t)
        case .jelly: jelly(ctx, count: count, t: t)
        case .goldCoin: goldCoin(ctx, count: count, t: t)
        case .chalk: chalk(ctx, count: count, t: t)
        }
    }

    // MARK: - Normal: a lime flash, two rings, rays, confetti and a tag under the count.

    private static func burst(_ ctx: CGContext, count: Int, t: Double) {
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
