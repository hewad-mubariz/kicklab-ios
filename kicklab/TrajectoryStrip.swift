//
//  TrajectoryStrip.swift
//  kicklab
//
//  The ball's height over time: the run as a row of arcs.
//
//  This is the most explanatory picture in the app. Juggling drawn this way is a
//  series of arches - the ball rises, falls to a trough, is struck, rises again.
//  A touch belongs at the bottom of a trough. One sitting mid-arc is visibly
//  wrong, and a trough with no marker is visibly a miss. Neither is apparent from
//  a number.
//
//  Two things matter for it to read at a glance:
//
//  * **Height is up.** Frame coordinates put y=0 at the top, so plotting them
//    directly drew juggling as upside-down valleys. The first version did exactly
//    that and it was unreadable. Here the axis is flipped, so up means up.
//  * **The curve is smoothed.** The underlying samples are 30 a second and
//    jagged; drawn as straight segments they read as noise. Catmull-Rom through
//    the points gives the arcs their actual shape.
//

import SwiftUI

struct TrajectoryStrip: View {
    let track: [RecordedFrame]
    let touches: [RecordedTouch]
    let time: Double
    /// Seconds of history shown. Several arcs - enough for rhythm to be visible.
    var window: Double = 5.0

    private let rising = Color(red: 0.24, green: 0.92, blue: 0.48)
    private let falling = Color(red: 1.00, green: 0.62, blue: 0.20)
    private let touchColor = Color(red: 1.0, green: 0.28, blue: 0.32)

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let from = time - window * 0.72
            let to = time + window * 0.28
            let visible = track.filter { $0.time >= from && $0.time <= to }
            let points = visible.map { f in
                CGPoint(x: xFor(f.time, from: from, to: to, width: size.width),
                        y: yFor(f.smoothedY, height: size.height))
            }

            ZStack {
                grid(size)

                if points.count > 2 {
                    let curve = smoothPath(points)

                    // Filled body under the curve, so the arcs read as shapes
                    // rather than as a wire.
                    curve.closedTo(bottom: size.height)
                        .fill(LinearGradient(
                            colors: [rising.opacity(0.30), rising.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom))

                    // The curve itself, coloured along its length by direction of
                    // travel: warm falling, green rising. The colour flipping at
                    // the bottom of an arc IS the reversal the counter detects.
                    curve.stroke(
                        LinearGradient(colors: strokeColors(visible),
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round,
                                           lineJoin: .round))
                    .shadow(color: rising.opacity(0.55), radius: 6)
                }

                touchMarkers(size, from: from, to: to)
                playhead(size, from: from, to: to, points: points)
            }
        }
        .frame(height: 92)
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.28)],
                           startPoint: .bottom, endPoint: .top)
        )
    }

    // MARK: - Layers

    /// Three faint rules: floor, middle, head height. Enough to judge height by,
    /// not enough to compete with the curve.
    private func grid(_ size: CGSize) -> some View {
        ForEach([0.25, 0.5, 0.75], id: \.self) { fraction in
            Path { p in
                let y = size.height * fraction
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
            }
            .stroke(.white.opacity(0.07), lineWidth: 1)
        }
    }

    private func touchMarkers(_ size: CGSize, from: Double, to: Double) -> some View {
        ForEach(touches.filter { $0.time >= from && $0.time <= to }) { t in
            let x = xFor(t.time, from: from, to: to, width: size.width)
            let y = yFor(t.y, height: size.height)
            let live = abs(t.time - time) < 0.3

            // A stem to the floor, so touches are countable along the bottom.
            Path { p in
                p.move(to: CGPoint(x: x, y: y))
                p.addLine(to: CGPoint(x: x, y: size.height))
            }
            .stroke(touchColor.opacity(live ? 0.55 : 0.22), lineWidth: 1)

            Circle()
                .fill(touchColor)
                .frame(width: live ? 11 : 6, height: live ? 11 : 6)
                .shadow(color: touchColor.opacity(0.9), radius: live ? 7 : 0)
                .position(x: x, y: y)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: live)
        }
    }

    private func playhead(_ size: CGSize, from: Double, to: Double,
                          points: [CGPoint]) -> some View {
        let x = xFor(time, from: from, to: to, width: size.width)
        return ZStack {
            Path { p in
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: size.height))
            }
            .stroke(.white.opacity(0.75), lineWidth: 1)

            // A bead riding the curve, so the eye follows the ball's height.
            if let nearest = points.min(by: { abs($0.x - x) < abs($1.x - x) }) {
                Circle()
                    .fill(.white)
                    .frame(width: 7, height: 7)
                    .shadow(color: .white.opacity(0.8), radius: 5)
                    .position(x: nearest.x, y: nearest.y)
            }
        }
    }

    // MARK: - Geometry

    private func xFor(_ t: Double, from: Double, to: Double, width: CGFloat) -> CGFloat {
        CGFloat((t - from) / max(to - from, 0.001)) * width
    }

    /// Flipped: a ball high in the frame draws high on the chart.
    private func yFor(_ ballY: Double, height: CGFloat) -> CGFloat {
        let clamped = min(max(ballY, 0), 1)
        return CGFloat(clamped) * (height - 18) + 9
    }

    private func strokeColors(_ frames: [RecordedFrame]) -> [Color] {
        guard !frames.isEmpty else { return [rising] }
        // One stop every few frames: enough for the gradient to follow the
        // direction changes without building a hundred-stop gradient per redraw.
        let step = max(1, frames.count / 24)
        return stride(from: 0, to: frames.count, by: step).map { i in
            frames[i].vy > 0 ? falling : rising
        }
    }

    /// Catmull-Rom through the samples, expressed as cubic Béziers.
    private func smoothPath(_ points: [CGPoint]) -> Path {
        Path { path in
            guard points.count > 1 else { return }
            path.move(to: points[0])
            for i in 0..<(points.count - 1) {
                let p0 = points[max(i - 1, 0)]
                let p1 = points[i]
                let p2 = points[i + 1]
                let p3 = points[min(i + 2, points.count - 1)]
                let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6,
                                 y: p1.y + (p2.y - p0.y) / 6)
                let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6,
                                 y: p2.y - (p3.y - p1.y) / 6)
                path.addCurve(to: p2, control1: c1, control2: c2)
            }
        }
    }
}

private extension Path {
    /// The same curve, closed down to a baseline, for filling underneath it.
    func closedTo(bottom: CGFloat) -> Path {
        var filled = self
        let end = cgPath.currentPoint
        filled.addLine(to: CGPoint(x: end.x, y: bottom))
        if let first = firstPoint {
            filled.addLine(to: CGPoint(x: first.x, y: bottom))
            filled.addLine(to: first)
        }
        filled.closeSubpath()
        return filled
    }

    var firstPoint: CGPoint? {
        var found: CGPoint?
        cgPath.applyWithBlock { element in
            if found == nil, element.pointee.type == .moveToPoint {
                found = element.pointee.points[0]
            }
        }
        return found
    }
}
