import Foundation
import CoreGraphics

/// Immutable session data. Bounce extraction happens once, not on every playback frame.
nonisolated struct MotionStyleTimeline: Equatable, Sendable {
    struct Peak: Equatable {
        let number: Int
        /// The touch that started the bounce and the one that ended it.
        let start: Double
        let end: Double
        /// When the ball was highest, and that image position.
        let apex: Double
        let top: Double
        /// Rise above the higher of its two contact points, as a fraction of the frame.
        let height: Double
    }
    let points: [CaptureMotionPoint]
    let touches: [Double]
    let peaks: [Peak]
    /// The lowest and highest the ball went this session, in image coordinates (y grows down).
    let floorY: Double
    let ceilingY: Double

    init(points: [CaptureMotionPoint], touchTimes: [Double]) {
        self.points = points.filter { $0.time.isFinite && $0.time >= 0 }.sorted { $0.time < $1.time }
        touches = Array(Set(touchTimes.filter { $0.isFinite && $0 >= 0 })).sorted()
        let heights = self.points.compactMap(\.validY)
        floorY = heights.max() ?? 1
        ceilingY = heights.min() ?? 0
        var result: [Peak] = [], cursor = 0
        for index in 0..<max(0, touches.count - 1) {
            let start = touches[index], end = touches[index + 1]
            while cursor < self.points.count && self.points[cursor].time < start { cursor += 1 }
            var samples: [CaptureMotionPoint] = [], scan = cursor
            while scan < self.points.count && self.points[scan].time <= end {
                samples.append(self.points[scan]); scan += 1
            }
            guard end - start > 0.05, samples.count >= 3,
                  let first = samples.first, let last = samples.last,
                  first.time - start <= 0.15, end - last.time <= 0.15,
                  samples.allSatisfy({ $0.validY != nil }),
                  zip(samples, samples.dropFirst()).allSatisfy({ $1.time - $0.time <= 0.3 }),
                  let highest = samples.min(by: { $0.validY! < $1.validY! }), let low = highest.validY,
                  let firstY = first.validY, let lastY = last.validY else { continue }
            result.append(Peak(number: index + 1, start: start, end: end, apex: highest.time, top: low,
                               height: max(0, max(firstY, lastY) - low)))
        }
        peaks = result
    }

    /// 0 at the ball's lowest point this session, 1 at its highest.
    func lift(_ y: Double) -> Double {
        guard floorY - ceilingY > 0.02 else { return 0 }
        return min(1, max(0, (floorY - y) / (floorY - ceilingY)))
    }

    func snapshot(at time: Double, duration: Double? = nil) -> MotionStyleSnapshot {
        MotionStyleSnapshot(timeline: self, time: time, duration: duration)
    }
}

nonisolated extension CaptureMotionPoint {
    var validY: Double? { y.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil } }
    var position: CGPoint? {
        guard let x, x.isFinite, let y = validY else { return nil }
        return CGPoint(x: min(1, max(0, x)), y: y)
    }
}

nonisolated struct MotionStyleSnapshot {
    struct Bounce {
        let phase: Double
        let height: Double
        let scale: CGSize

        static func scale(age: Double, reduceMotion: Bool = false) -> CGSize {
            guard !reduceMotion else { return CGSize(width: 1, height: 1) }
            let age = max(0, age)
            if age < 0.09 {
                let t = age / 0.09
                return CGSize(width: 1.45 - 0.45 * t, height: 0.58 + 0.42 * t)
            }
            if age < 0.23 {
                let pulse = sin((age - 0.09) / 0.14 * .pi)
                return CGSize(width: 1 - 0.2 * pulse, height: 1 + 0.3 * pulse)
            }
            return CGSize(width: 1, height: 1)
        }
    }

    /// A completed bounce, scaled 0…1 against the session's own range.
    struct Arc: Equatable {
        let number: Int
        let start: Double
        let end: Double
        let apex: Double
        let lift: Double
    }

    /// The bounce in the air right now.
    struct Flight: Equatable {
        let start: Double
        let apex: Double
        let peak: Double
        let lift: Double
        /// Past the top and on the way down.
        let falling: Bool
    }

    /// A rhythm streak: touches keep coming at a steady pace.
    struct Combo: Equatable {
        let streak: Int
        let best: Int
        /// Seconds since the streak broke, while that is still recent.
        let brokenAge: Double?
        var level: Int { streak / 10 + 1 }
        var fill: Int { streak % 10 }
    }

    let graph: CaptureGraphLayout
    let touchTimes: [Double]
    /// Confirmed touches up to the playhead.
    let played: [Double]
    let nextTouch: Double?
    let currentPosition: CGPoint?
    let peaks: [MotionStyleTimeline.Peak]
    let arcs: [Arc]
    /// The session's lowest and highest bounce (0…1), so pitch and scale stay put while scrubbing.
    let arcRange: ClosedRange<Double>
    let flight: Flight?
    /// Highest completed bounce so far (0…1), and how long ago it was set.
    let best: Double
    let bestAge: Double?
    let lift: Double?
    let combo: Combo
    let rhythm: CaptureRhythm
    let bounce: Bounce?

    init(timeline: MotionStyleTimeline, time: Double, duration: Double?) {
        graph = CaptureGraphLayout(points: timeline.points, time: time, duration: duration)
        let now = graph.time
        touchTimes = timeline.touches
        played = timeline.touches.filter { $0 <= now }
        nextTouch = timeline.touches.first { $0 > now }
        rhythm = CaptureRhythm(touchTimes: timeline.touches, at: now)
        let latest = timeline.points.last { $0.time <= now }
        let fresh = latest.flatMap { now - $0.time <= 0.3 ? $0 : nil }
        currentPosition = fresh?.position
        lift = fresh?.validY.map(timeline.lift)
        peaks = Array(timeline.peaks.prefix { $0.end <= now }.suffix(5))

        let completed = timeline.peaks.prefix { $0.end <= now }
        arcs = completed.suffix(16).map {
            Arc(number: $0.number, start: $0.start, end: $0.end, apex: $0.apex, lift: timeline.lift($0.top))
        }
        let lifts = timeline.peaks.map { timeline.lift($0.top) }
        arcRange = (lifts.min() ?? 0)...max((lifts.min() ?? 0) + 0.05, lifts.max() ?? 1)
        var best = 0.0, bestAge: Double?
        for peak in completed {
            let value = timeline.lift(peak.top)
            if value > best + 0.001 { best = value; bestAge = now - peak.apex }
        }
        self.best = best
        self.bestAge = bestAge

        // The bounce in flight: measured from the last touch, only while tracking holds.
        if let start = played.last, fresh != nil {
            var top: CaptureMotionPoint?, previous: Double?, continuous = true
            for point in timeline.points where point.time >= start && point.time <= now {
                if let previous, point.time - previous > 0.3 { continuous = false }
                previous = point.time
                guard let y = point.validY else { continuous = false; continue }
                if top == nil || y < top!.validY! { top = point }
            }
            if continuous, let top, let topY = top.validY, let currentY = fresh?.validY {
                flight = Flight(start: start, apex: top.time, peak: timeline.lift(topY), lift: timeline.lift(currentY),
                                falling: now - top.time > 0.04 && currentY > topY + 0.004)
            } else { flight = nil }
        } else { flight = nil }

        combo = Self.combo(played: played, now: now)

        if let contact = played.last, let current = graph.currentPoint {
            let age = now - contact
            let interval = nextTouch.map { $0 - contact }
                ?? (played.count > 1 ? contact - played[played.count - 2] : 0.8)
            // A missed touch must not leave a ball hopping indefinitely.
            if age <= max(0.4, min(2, interval * 1.5)) {
                bounce = Bounce(phase: min(1, age / max(0.05, interval)),
                                height: min(1, max(0, 1 - current.y)), scale: Bounce.scale(age: age))
            } else { bounce = nil }
        } else { bounce = nil }
    }

    /// A touch keeps the streak when it comes at roughly the usual pace (half to 1.75× the recent
    /// median gap, at most 1.5 s). Waiting too long for the next one breaks it.
    static func combo(played: [Double], now: Double) -> Combo {
        func median(_ values: ArraySlice<Double>) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        var streak = 0, best = 0, gaps: [Double] = [], brokeAt: Double?
        for (index, touch) in played.enumerated() {
            if index == 0 { streak = 1; best = 1; continue }
            let gap = touch - played[index - 1]
            let typical = gaps.count >= 2 ? median(gaps.suffix(5)) : nil
            if gap <= 1.5, typical.map({ gap >= 0.5 * $0 && gap <= 1.75 * $0 }) ?? true {
                streak += 1
            } else {
                brokeAt = touch; streak = 1
            }
            gaps.append(gap)
            best = max(best, streak)
        }
        if let last = played.last {
            let limit = max(1.2, (median(gaps.suffix(5)) ?? 0.8) * 1.8)
            if now - last > limit { brokeAt = last + limit; streak = 0 }
        }
        let age = brokeAt.map { now - $0 }
        return Combo(streak: streak, best: best, brokenAge: age.flatMap { $0 >= 0 && $0 < 1.2 ? $0 : nil })
    }
}
