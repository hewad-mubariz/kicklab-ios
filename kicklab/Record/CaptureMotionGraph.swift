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
    var cursor: Double { (time - timeRange.lowerBound) / (timeRange.upperBound - timeRange.lowerBound) }

    init(points: [CaptureMotionPoint], time: Double, duration: Double? = nil) {
        let now = time.isFinite ? max(0, time) : 0
        if let duration, duration.isFinite, duration > 0 {
            timeRange = 0...duration
            self.time = min(now, duration)
        } else {
            let start = max(0, now - 6)
            timeRange = start...(start + 6)
            self.time = now
        }
        let range = timeRange
        let visible = points.filter { $0.time.isFinite && range.contains($0.time) }.sorted { $0.time < $1.time }
        let values = visible.compactMap(\.y).filter(\.isFinite).map { min(1, max(0, $0)) }
        if let low = values.min(), let high = values.max() {
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
            currentPoint = nil
            let hasTrackedBall = played.contains { $0.point != nil }
            status = !hasTrackedBall && self.time < 0.3 ? "ACQUIRING" : "TRACK LOST"
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
            for index in 0...8 {
                let x = CGFloat(index) / 8 * size.width
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
    }
}
