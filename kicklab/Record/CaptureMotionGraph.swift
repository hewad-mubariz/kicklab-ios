import SwiftUI

/// Replay uses the full clip as its time axis; live capture uses the last six seconds.
/// The vertical axis is relative image position, as in the Python presentation.
nonisolated struct CaptureGraphLayout {
    struct Sample {
        let time: Double
        let point: CGPoint?
    }

    let samples: [Sample]
    let timeRange: ClosedRange<Double>
    let verticalRange: ClosedRange<Double>
    let time: Double
    let status: String
    let currentPoint: CGPoint?
    /// True when a long session shows a moving window instead of the whole clip.
    let scrolls: Bool
    var cursor: Double { (time - timeRange.lowerBound) / (timeRange.upperBound - timeRange.lowerBound) }

    /// Where the playhead rests while a long session scrolls: most of the window is the past.
    static let scrollingCursor = 0.8
    /// Share of the width at the left edge where older motion fades out.
    static let fadeWidth = 0.14

    /// How strongly the left edge fades: not at all while the clip's start is still on screen,
    /// fully once a fade's width of earlier motion has scrolled off.
    var edgeFade: Double {
        guard scrolls else { return 0 }
        return min(1, timeRange.lowerBound / ((timeRange.upperBound - timeRange.lowerBound) * Self.fadeWidth))
    }

    /// `window`: seconds shown at once when the clip is longer; nil shows the whole clip.
    /// `vertical`: a fixed height range, so the scale holds still while the window moves.
    init(points: [CaptureMotionPoint], time: Double, duration: Double? = nil,
         window: Double? = nil, vertical fixedVertical: ClosedRange<Double>? = nil) {
        let now = time.isFinite ? max(0, time) : 0
        if let duration, duration.isFinite, duration > 0, let window, window.isFinite, window > 0, duration > window {
            // The playhead stays at 80 % across; the window starts at zero and stops at the end.
            let start = min(max(0, now - window * Self.scrollingCursor), duration - window)
            timeRange = start...(start + window)
            self.time = min(now, duration)
            scrolls = true
        } else if let duration, duration.isFinite, duration > 0 {
            timeRange = 0...duration
            self.time = min(now, duration)
            scrolls = false
        } else {
            scrolls = false
            let start = max(0, now - 6)
            timeRange = start...(start + 6)
            self.time = now
        }
        let range = timeRange
        let visible = points.filter { $0.time.isFinite && range.contains($0.time) }.sorted { $0.time < $1.time }
        let values = visible.compactMap(\.y).filter(\.isFinite).map { min(1, max(0, $0)) }
        if let fixedVertical {
            verticalRange = fixedVertical
        } else if let low = values.min(), let high = values.max() {
            let center = (low + high) / 2
            let halfSpan = max(0.04, (high - low) / 2 + 0.012)
            verticalRange = (center - halfSpan)...(center + halfSpan)
        } else {
            verticalRange = 0...1
        }
        let vertical = verticalRange
        samples = visible.map { sample in
            let point = sample.y.flatMap { y -> CGPoint? in
                guard y.isFinite else { return nil }
                return CGPoint(x: (sample.time - range.lowerBound) / (range.upperBound - range.lowerBound),
                               y: (min(1, max(0, y)) - vertical.lowerBound) / (vertical.upperBound - vertical.lowerBound))
            }
            return Sample(time: sample.time, point: point)
        }
        let playhead = self.time
        let played = samples.filter { $0.time <= playhead }
        let latest = played.last
        if let latest, let point = latest.point, self.time - latest.time <= 0.3 {
            currentPoint = point
            if played.count >= 2, let previous = played[played.count - 2].point,
               latest.time - played[played.count - 2].time <= 0.3 {
                let delta = (point.y - previous.y) * (vertical.upperBound - vertical.lowerBound)
                let velocity = delta / max(0.001, latest.time - played[played.count - 2].time)
                status = velocity < -0.06 ? "RISING ↑" : velocity > 0.06 ? "FALLING ↓" : "AT THE TURN"
            } else { status = "AT THE TURN" }
        } else {
            // The line's gap already shows the ball is out of sight; the word stays blank.
            currentPoint = nil
            status = ""
        }
    }
}

struct CaptureMotionGraph: View {
    let layout: CaptureGraphLayout
    let touchTimes: [Double]

    var body: some View {
        Canvas { context, size in
            let top: CGFloat = 4, height = max(1, size.height - 17)
            func pixel(_ point: CGPoint) -> CGPoint {
                CGPoint(x: point.x * size.width, y: top + point.y * height)
            }
            func path(through samples: [CaptureGraphLayout.Sample]) -> Path {
                var path = Path(), previousTime: Double?
                for sample in samples {
                    guard let point = sample.point else { previousTime = nil; continue }
                    if let previousTime, sample.time - previousTime <= 0.3 {
                        path.addLine(to: pixel(point))
                    } else { path.move(to: pixel(point)) }
                    previousTime = sample.time
                }
                return path
            }
            var grid = Path()
            for index in 0...2 {
                let y = top + CGFloat(index) / 2 * height
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            // While scrolling, the vertical grid travels with the line, so the motion reads as movement.
            let span = layout.timeRange.upperBound - layout.timeRange.lowerBound
            let step = span / 8
            let first = layout.scrolls ? (layout.timeRange.lowerBound / step).rounded(.up) * step : layout.timeRange.lowerBound
            for line in stride(from: first, through: layout.timeRange.upperBound + 0.0001, by: step) {
                let x = CGFloat((line - layout.timeRange.lowerBound) / span) * size.width
                grid.move(to: CGPoint(x: x, y: top)); grid.addLine(to: CGPoint(x: x, y: top + height))
            }
            context.stroke(grid, with: .color(.white.opacity(0.11)), lineWidth: 0.5)
            context.stroke(path(through: layout.samples), with: .color(Color(red: 0.76, green: 0.88, blue: 0.83).opacity(0.28)),
                           style: StrokeStyle(lineWidth: 0.7, lineJoin: .round))
            let played = layout.samples.filter { $0.time <= layout.time }
            context.stroke(path(through: played), with: .color(Color(cgColor: NormalCounterAppearance.lime)),
                           style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            if !played.isEmpty {
                let x = layout.cursor * size.width
                var cursor = Path()
                cursor.move(to: CGPoint(x: x, y: 0)); cursor.addLine(to: CGPoint(x: x, y: top + height + 4))
                context.stroke(cursor, with: .color(.white.opacity(0.8)), lineWidth: 0.7)
            }
            if let point = layout.currentPoint {
                let p = pixel(point)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(.white))
            }
            var ticks = Path()
            for time in touchTimes where time.isFinite && time <= layout.time && layout.timeRange.contains(time) {
                let x = (time - layout.timeRange.lowerBound) / (layout.timeRange.upperBound - layout.timeRange.lowerBound) * size.width
                ticks.move(to: CGPoint(x: x, y: size.height - 5)); ticks.addLine(to: CGPoint(x: x, y: size.height - 1))
            }
            context.stroke(ticks, with: .color(Color(cgColor: NormalCounterAppearance.lime).opacity(0.75)), lineWidth: 0.8)
        }
        .scrollFade(layout.edgeFade)
    }
}

extension View {
    /// The oldest part of a scrolling graph fades out at the left edge, once there is older motion to hide.
    @ViewBuilder func scrollFade(_ amount: Double) -> some View {
        if amount > 0 {
            mask(LinearGradient(stops: [.init(color: .black.opacity(1 - amount), location: 0),
                                        .init(color: .black, location: CaptureGraphLayout.fadeWidth),
                                        .init(color: .black, location: 1)], startPoint: .leading, endPoint: .trailing))
        } else {
            self
        }
    }
}
