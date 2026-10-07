//
//  AnnotationCanvas.swift
//  kicklab
//
//  The annotated replay, drawn the way the Python lab draws it.
//
//  The lab's renderer is the reason most counting bugs in this project were ever
//  found: it shows the ball box and its confidence, the trail it took, the
//  smoothed position the counter actually judged, the motion state and velocity
//  driving the decision, the body region a touch has to fall inside, the ground
//  line, and a flash at each touch. A count of 32 tells you nothing; this tells
//  you *why* 32.
//
//  Drawn in a SwiftUI `Canvas`: immediate-mode and GPU-backed, so an overlay this
//  busy still redraws cheaply over playing video.
//

import SwiftUI

struct AnnotationCanvas: View {
    let track: [RecordedFrame]
    let touches: [RecordedTouch]
    let time: Double

    /// Matching the lab's palette, so a screenshot from either is recognisable.
    private let detectedColor = Color(red: 0.39, green: 0.86, blue: 0.31)
    private let smoothedColor = Color(red: 0.96, green: 0.67, blue: 0.35)
    private let personColor = Color.white.opacity(0.55)
    private let regionColor = Color(red: 0.86, green: 0.55, blue: 0.86)
    private let groundColor = Color(red: 0.90, green: 0.27, blue: 0.27)
    private let touchColor = Color(red: 1.0, green: 0.24, blue: 0.24)

    /// How long a touch flash stays on screen.
    private let flashSeconds = 0.45
    /// How much of the recent path to draw.
    private let trailSeconds = 0.9

    var body: some View {
        Canvas { context, size in
            guard let now = nearestFrame else { return }

            drawGround(context, size, now)
            drawPerson(context, size, now)
            drawTrail(context, size)
            drawBall(context, size, now)
            drawTouches(context, size)
            drawHUD(context, size, now)
        }
    }

    // MARK: - Layers

    private func drawGround(_ ctx: GraphicsContext, _ size: CGSize, _ f: RecordedFrame) {
        guard let person = f.person else { return }
        // The counter takes the floor from the bottom of the person box; a touch
        // at or below it is a bounce, not a touch.
        let y = person.bottom * size.height
        var path = Path()
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: size.width, y: y))
        ctx.stroke(path, with: .color(groundColor.opacity(0.85)),
                   style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        ctx.draw(Text("ground").font(.system(size: 9, weight: .semibold))
            .foregroundStyle(groundColor),
                 at: CGPoint(x: 34, y: y - 9))
    }

    private func drawPerson(_ ctx: GraphicsContext, _ size: CGSize, _ f: RecordedFrame) {
        guard let person = f.person else { return }
        let box = CGRect(x: (person.x - person.width / 2) * size.width,
                         y: (person.y - person.height / 2) * size.height,
                         width: person.width * size.width,
                         height: person.height * size.height)
        ctx.stroke(Path(box), with: .color(personColor), lineWidth: 1)

        // The region a reversal must fall inside to count.
        let region = person.region(fraction: 1.0)
        let r = CGRect(x: region.xMin * size.width, y: region.yMin * size.height,
                       width: (region.xMax - region.xMin) * size.width,
                       height: (region.yMax - region.yMin) * size.height)
        ctx.fill(Path(r), with: .color(regionColor.opacity(0.10)))
        ctx.stroke(Path(r), with: .color(regionColor.opacity(0.7)), lineWidth: 1)
    }

    private func drawTrail(_ ctx: GraphicsContext, _ size: CGSize) {
        let recent = track.filter { $0.time <= time && $0.time > time - trailSeconds }
        guard recent.count > 1 else { return }
        // Segment by segment, fading with age, so direction of travel reads.
        for i in 1..<recent.count {
            let a = recent[i - 1], b = recent[i]
            let fade = Double(i) / Double(recent.count)
            var path = Path()
            path.move(to: CGPoint(x: a.smoothedX * size.width, y: a.smoothedY * size.height))
            path.addLine(to: CGPoint(x: b.smoothedX * size.width, y: b.smoothedY * size.height))
            ctx.stroke(path,
                       with: .color(smoothedColor.opacity(0.2 + 0.8 * fade)),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
    }

    private func drawBall(_ ctx: GraphicsContext, _ size: CGSize, _ f: RecordedFrame) {
        let box = CGRect(x: (f.x - f.width / 2) * size.width,
                         y: (f.y - f.height / 2) * size.height,
                         width: f.width * size.width,
                         height: f.height * size.height)
        ctx.stroke(Path(roundedRect: box, cornerRadius: 4),
                   with: .color(detectedColor), lineWidth: 2)

        // The smoothed point is what the counter judged; where it sits apart from
        // the raw box is exactly where a disputed count comes from.
        let smoothed = CGPoint(x: f.smoothedX * size.width, y: f.smoothedY * size.height)
        ctx.stroke(Path(ellipseIn: CGRect(x: smoothed.x - 5, y: smoothed.y - 5,
                                          width: 10, height: 10)),
                   with: .color(smoothedColor), lineWidth: 2)

        ctx.draw(Text(String(format: "ball %.2f", f.score))
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(detectedColor),
                 at: CGPoint(x: box.midX, y: max(10, box.minY - 9)))

        let arrow = f.motion == .falling ? "▼" : (f.motion == .rising ? "▲" : "•")
        let label = String(format: "%@ vy%+.2f", arrow, f.vy)
        ctx.draw(Text(label)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(f.motion == .rising ? detectedColor : smoothedColor),
                 at: CGPoint(x: box.midX, y: min(size.height - 10, box.maxY + 10)))
    }

    private func drawTouches(_ ctx: GraphicsContext, _ size: CGSize) {
        for touch in touches where touch.time <= time {
            let at = CGPoint(x: touch.x * size.width, y: touch.y * size.height)
            let age = time - touch.time

            if age <= flashSeconds {
                // Expanding ring, exactly as the lab's renderer flashes a touch.
                let progress = age / flashSeconds
                let radius = 16 + 54 * progress
                ctx.stroke(Path(ellipseIn: CGRect(x: at.x - radius, y: at.y - radius,
                                                  width: radius * 2, height: radius * 2)),
                           with: .color(touchColor.opacity(1 - progress)),
                           lineWidth: 3)
                ctx.draw(Text("TOUCH \(touch.index + 1)")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .foregroundStyle(touchColor.opacity(1 - progress * 0.6)),
                         at: CGPoint(x: at.x, y: at.y - radius - 10))
            } else {
                // A quiet dot stays, so the whole run's pattern is visible.
                ctx.fill(Path(ellipseIn: CGRect(x: at.x - 3, y: at.y - 3,
                                                width: 6, height: 6)),
                         with: .color(touchColor.opacity(0.45)))
            }
        }
    }

    private func drawHUD(_ ctx: GraphicsContext, _ size: CGSize, _ f: RecordedFrame) {
        let counted = touches.filter { $0.time <= time }.count
        let state = f.motion == .falling ? "FALLING"
            : (f.motion == .rising ? "RISING" : "UNKNOWN")
        let lines = [
            "touches  \(counted)",
            String(format: "t  %.2fs", time),
            String(format: "ball  %.2f", f.score),
            "motion  \(state)",
            String(format: "vy  %+.2f", f.vy),
        ]

        let panel = CGRect(x: 10, y: 10, width: 124, height: CGFloat(lines.count) * 15 + 12)
        ctx.fill(Path(roundedRect: panel, cornerRadius: 8),
                 with: .color(.black.opacity(0.55)))

        var y = panel.minY + 14
        for line in lines {
            ctx.draw(Text(line)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92)),
                     at: CGPoint(x: panel.minX + 62, y: y))
            y += 15
        }
    }

    // MARK: - State

    private var nearestFrame: RecordedFrame? {
        guard !track.isEmpty else { return nil }
        let nearest = track.min { abs($0.time - time) < abs($1.time - time) }
        guard let nearest, abs(nearest.time - time) < 0.1 else { return nil }
        return nearest
    }
}
