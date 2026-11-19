// Copied from the Effects Lab (EffectLab/Graphs/TechniqueLens.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import CoreGraphics

/// Touch Replay Lens (concept 32), lab prototype 2026-11-18.
/// At every touch a lens docks beside the player: three zoomed views of the contact (80 ms
/// before, the detected touch, 80 ms after). The middle one replays the contact at 0.25× and
/// flashes gold on the exact detected frame. Under it: touch number, which foot, and how high
/// the ball was met (cm above the ground, and ankle / shin / high against the player's knee).
/// Each view appears only once its moment has happened, so the lens is causal.
nonisolated extension TechniqueDrawing {
    /// Crops around each touch's contact point, from the source frames within ±0.1 s of it.
    nonisolated(unsafe) static var lensFrames = [Int: [(t: Double, image: CGImage)]]()
    /// Crop size around the contact point, in ball radii (the renderer uses the same).
    static let lensCropRadii = 2.5

    static func lensFrame(_ k: Int, at time: Double) -> CGImage? {
        guard let frames = lensFrames[k], !frames.isEmpty else { return nil }
        return frames.min { abs($0.t - time) < abs($1.t - time) }!.image
    }

    static func touchLens(_ p: Pen, _ m: Technique.Model, _ t: Double, _ u: CGFloat) {
        guard let k = m.touchIndex(at: t) else { return }
        let age = t - m.touches[k]
        // The previous lens slides out under the new one.
        if k > 0, age < 0.14 { lens(p, m, k - 1, t: t, u: u, exit: age / 0.14) }
        lens(p, m, k, t: t, u: u, exit: 0)
    }

    private static func lens(_ p: Pen, _ m: Technique.Model, _ k: Int, t: Double, u: CGFloat, exit: Double) {
        let c = p.c
        let touch = m.touches[k], age = t - touch
        guard let b = m.ball.ball(at: touch), let s = m.body.scale(at: touch) else { return }
        let contact = CGPoint(x: b.p.x / u, y: (b.p.y + b.r * 0.8) / u)
        let leave = 1 - Motion.easeInOut(exit)
        guard leave > 0.01 else { return }

        // Dock on the side away from the ball, inside what the camera shows, so it never covers the action.
        let view = visible.map { CGRect(x: $0.minX / u, y: $0.minY / u, width: $0.width / u, height: $0.height / u) } ?? CGRect(x: 0, y: 0, width: 372, height: 661)
        let side: CGFloat = contact.x >= CGFloat(s.rootX) / u ? -1 : 1
        let big: CGFloat = 0.31 * view.width, small: CGFloat = 0.2 * view.width, gap: CGFloat = 0.022 * view.width
        let px = side > 0 ? view.maxX - 0.045 * view.width - big / 2 : view.minX + 0.045 * view.width + big / 2
        let midY = min(max(contact.y - 0.1 * view.height, view.minY + 0.28 * view.height), view.maxY - 0.33 * view.height)
        let slide = CGFloat(side) * CGFloat(30 * (1 - Motion.easeOut(age / 0.3)))

        // In the scene: a gold ring where the ball was met, and a leader to the lens.
        let pulse = 0.5 + 0.5 * sin(age * 2 * .pi / 0.6)
        let ringIn = Motion.backOut(age / 0.25)
        glowing(c, Pen.alpha(Pen.gold, leave), blur: 8) {
            p.ring(contact, (b.r / u) * CGFloat(0.42 + 0.06 * pulse) * CGFloat(ringIn), Pen.alpha(Pen.gold, leave), 1.6)
        }
        let middle = CGRect(x: px - big / 2 + slide, y: midY - big / 2, width: big, height: big)
        let edge = CGPoint(x: side > 0 ? middle.minX : middle.maxX, y: middle.midY)
        let draw = Motion.easeOut((age - 0.05) / 0.25)
        if draw > 0 {
            let end = CGPoint(x: contact.x + (edge.x - contact.x) * CGFloat(draw), y: contact.y + (edge.y - contact.y) * CGFloat(draw))
            glowing(c, Pen.col(0, 0, 0, 0.6), blur: 3) { p.line(contact.x, contact.y, end.x, end.y, Pen.alpha(Pen.gold, 0.9 * leave), 1.1) }
        }

        // The three views: before, the touch (live slow-motion), after.
        let slots: [(offset: Double, rect: CGRect, label: String, appearAt: Double)] = [
            (-0.08, CGRect(x: px - small / 2 + slide, y: middle.minY - gap - small, width: small, height: small), "−80 ms", 0),
            (0, middle, "TOUCH", 0.02),
            (0.08, CGRect(x: px - small / 2 + slide, y: middle.maxY + gap, width: small, height: small), "+80 ms", 0.08),
        ]
        for slot in slots {
            let a = age - slot.appearAt
            guard a >= 0 else { continue }
            let (o, sc) = enter(a)
            var frameTime = touch + slot.offset
            var replaying = false
            if slot.offset == 0 && age > 0.08 {
                // 0.25× replay of ±60 ms around the touch, looping.
                let phase = ((age - 0.08) * 0.25).truncatingRemainder(dividingBy: 0.12)
                frameTime = touch - 0.06 + phase
                replaying = true
            }
            guard let image = lensFrame(k, at: frameTime) else { continue }
            let onTouch = replaying ? Motion.flash(abs(frameTime - touch) / 0.25 * 4 - 0.02, decay: 0.05) : (slot.offset == 0 ? Motion.flash(a, decay: 0.25) : 0)
            thumbnail(p, image, slot.rect, scale: sc, opacity: o * leave, highlight: slot.offset == 0 ? 0.5 + 0.5 * onTouch : 0)
            // Time tag inside the view's top-left corner.
            let tag = slot.offset == 0 && replaying ? String(format: "%+.0f ms", (frameTime - touch) * 1000) : slot.label
            let tagSize: CGFloat = slot.offset == 0 ? 7.4 : 6.2
            let tw = width(tag, tagSize, 0.7, 0) + 8
            let tagRect = CGRect(x: slot.rect.minX + 4, y: slot.rect.minY + 4, width: tw, height: tagSize + 5)
            c.saveGState(); c.setAlpha(CGFloat(o * leave))
            p.fill(tagRect, Pen.col(0.02, 0.06, 0.05, 0.78), radius: (tagSize + 5) / 2)
            p.text(tag, tagRect.midX, tagRect.minY + 2.3, tagSize, slot.offset == 0 ? Pen.gold : Pen.white, weight: 0.7, align: 0.5, mono: true)
            c.restoreGState()
        }
        // The replay pill at the bottom of the touch view.
        if age > 0.08 {
            let (o, _) = enter(age - 0.08)
            let pill = CGRect(x: middle.midX - 30, y: middle.maxY - 17, width: 60, height: 12)
            c.saveGState(); c.setAlpha(CGFloat(o * leave))
            p.fill(pill, Pen.col(0.02, 0.06, 0.05, 0.8), radius: 6)
            let tri = CGMutablePath(); tri.addLines(between: [CGPoint(x: pill.minX + 7, y: pill.minY + 3), CGPoint(x: pill.minX + 7, y: pill.maxY - 3), CGPoint(x: pill.minX + 12, y: pill.midY)]); tri.closeSubpath()
            c.addPath(tri); c.setFillColor(Pen.gold); c.fillPath()
            p.text("REPLAY 0.25×", pill.minX + 15, pill.minY + 2.8, 6, Pen.white, weight: 0.7, kern: 0.3)
            c.restoreGState()
        }

        // The facts: touch number and foot, and the contact height against the player's body.
        let L = s.ground - s.head
        let heightCm = max(0, (s.ground - Double(b.p.y + b.r)) * m.cmPerPx(at: touch))
        let v = (s.ground - Double(b.p.y + b.r)) / L
        let zone = v < m.body.knee / 2 ? "ANKLE" : v < m.body.knee ? "SHIN" : "HIGH"
        let foot = k < m.sides.count ? (m.sides[k] == .left ? "LEFT FOOT" : m.sides[k] == .right ? "RIGHT FOOT" : "FOOT") : "FOOT"
        // Pinned under the lens (drawn here, not laid out, so it never wanders).
        let (o, _) = enter(age - 0.1)
        let infoY = slots[2].rect.maxY + 6
        c.saveGState(); c.setAlpha(CGFloat(o * leave)); c.setShadow(offset: CGSize(width: 0, height: 0.6), blur: 5, color: Pen.col(0, 0, 0, 0.8))
        // Aligned to the lens's outer edge, so it can't run off the frame.
        let ix = side < 0 ? middle.minX : middle.maxX, ia: CGFloat = side < 0 ? 0 : 1
        p.text("TOUCH #\(k + 1) · \(foot)", ix, infoY, 7, Pen.white, weight: 0.65, align: ia, kern: 0.8)
        p.text(rolled(String(format: "%.0f cm", heightCm), rollIn(age - 0.1)) + " · " + zone, ix, infoY + 9.5, 14, Pen.gold, weight: 0.78, align: ia, mono: true)
        c.restoreGState()
    }

    /// A zoomed view: rounded, with a soft shadow and a border; `highlight` (0…1) turns the border gold.
    static func thumbnail(_ p: Pen, _ image: CGImage, _ rect: CGRect, scale: Double, opacity: Double, highlight: Double) {
        let c = p.c
        guard opacity > 0.01 else { return }
        c.saveGState(); c.setAlpha(CGFloat(opacity))
        if scale < 0.999 { c.translateBy(x: rect.midX, y: rect.midY); c.scaleBy(x: CGFloat(scale), y: CGFloat(scale)); c.translateBy(x: -rect.midX, y: -rect.midY) }
        let shape = CGPath(roundedRect: rect, cornerWidth: 7, cornerHeight: 7, transform: nil)
        c.saveGState(); c.setShadow(offset: CGSize(width: 0, height: 2), blur: 10, color: Pen.col(0, 0, 0, 0.6))
        c.addPath(shape); c.setFillColor(Pen.col(0, 0, 0, 1)); c.fillPath(); c.restoreGState()
        c.saveGState(); c.addPath(shape); c.clip()
        c.translateBy(x: rect.minX, y: rect.maxY); c.scaleBy(x: 1, y: -1)
        c.interpolationQuality = .high
        c.draw(image, in: CGRect(origin: .zero, size: rect.size))
        c.restoreGState()
        let border = Pen.mix(Pen.white, Pen.gold, highlight)
        if highlight > 0.01 {
            glowing(c, Pen.alpha(Pen.gold, highlight), blur: 10) { p.stroke(shape, border, 1.4 + 0.8 * CGFloat(highlight)) }
        } else {
            p.stroke(shape, Pen.alpha(Pen.white, 0.85), 1.0)
        }
        c.restoreGState()
    }
}
