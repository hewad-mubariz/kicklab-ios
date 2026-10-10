import CoreGraphics
import Foundation

/// The struck ball's flight as seen in the video: where it went across the frame and how
/// long it was in the air. Everything here is measured in the picture (no metres, no km/h),
/// so the graphs say "in frame".
nonisolated struct ShotFlight: Sendable, Equatable {
    struct Point: Sendable, Equatable {
        let time: Double
        /// Frame space: the picture's height is 1, its width is the aspect ratio. y grows down.
        let x: Double
        let y: Double
        /// The ball's radius in the same units; it shrinks as the ball flies away.
        let radius: Double
    }

    /// Evenly spaced (60 a second) from the strike to the last sighting of this flight.
    let points: [Point]
    /// Up to a second of the ball just before the strike, on the same clock, so time-based
    /// graphs can show it resting (or being dribbled) and then launching.
    let lead: [Point]
    /// Widest gap from the straight line between strike and end, as a share of that line.
    let bend: Double
    /// Where that widest gap is.
    let bendIndex: Int
    /// Which side the path bulges to, seen along the flight: +1 right, -1 left, 0 straight.
    let bulge: Int
    /// The bulge points up the picture rather than sideways: the ball rose and came down
    /// (a dipping shot seen from behind), not a sideways curl.
    let dips: Bool

    var launch: Double { points[0].time }
    var end: Double { points[points.count - 1].time }
    var airTime: Double { end - launch }

    enum Phase: Equatable { case waiting, flying, done }

    func phase(at time: Double) -> Phase {
        time < launch ? .waiting : time <= end + 0.001 ? .flying : .done
    }

    /// How much of the flight has been flown at `time`, by index into `points`.
    func flownIndex(at time: Double) -> Int {
        guard time >= launch else { return -1 }
        return min(points.count - 1, Int(((time - launch) * 60).rounded(.down)))
    }

    var curveLabel: String {
        if dips { return "Dips" }
        if bend < 0.04 { return "Straight" }
        // A path that bulges right curls back to the left at the end, and the other way round.
        let side = bulge > 0 ? "left" : "right"
        return bend < 0.1 ? "Slight, \(side)" : bend < 0.2 ? "Curls \(side)" : "Big curl \(side)"
    }

    /// How many times farther from the camera than at the strike the ball has been seen, up to
    /// `time`. A ball's size in the picture halves when its distance doubles, so this is a ratio of
    /// sizes; each size is the median of three neighbours (the detector's box jitters by a pixel or
    /// two) and the value only grows, so jitter never brings the ball back.
    func depth(at time: Double) -> Double {
        guard time >= launch else { return 1 }
        return depthSoFar[max(0, min(points.count - 1, flownIndex(at: time)))]
    }

    /// The farthest the ball was seen, as a multiple of its distance at the strike.
    var depthRatio: Double { depthSoFar.last ?? 1 }

    private let depthSoFar: [Double]

    /// The longest fast run in the track, from the moment of the strike.
    static func find(in track: BallEffectTrack, aspect: Double) -> ShotFlight? {
        let sightings = track.samples
        guard sightings.count >= 6, aspect > 0 else { return nil }
        // Split into stretches the shot trails would also bridge.
        var segments: [[BallStyleSample]] = [[sightings[0]]]
        for sample in sightings.dropFirst() {
            if let last = segments[segments.count - 1].last, EffectFrame.bridges(last, sample) {
                segments[segments.count - 1].append(sample)
            } else {
                segments.append([sample])
            }
        }
        var best: ShotFlight?
        var bestLength = 0.0
        for segment in segments where segment.count >= 3 {
            let resampled = EffectFrame.resample(segment, until: segment[segment.count - 1].time)
            let points = resampled.map { sample -> Point in
                let width = sample.boxSize?.width ?? sample.radius * 2
                return Point(time: sample.time, x: sample.center.x * aspect, y: sample.center.y,
                             radius: max(0.002, width * aspect / 2))
            }
            for range in fastRuns(points) {
                let run = Array(points[range])
                let length = zip(run, run.dropFirst()).reduce(0.0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
                guard run.count >= 6, length > bestLength, length > (run.first?.radius ?? 1) * 3 else { continue }
                bestLength = length
                best = ShotFlight(points: run, lead: Array(points[max(0, range.lowerBound - 60)..<range.lowerBound]))
            }
        }
        return best
    }

    /// Stretches where the ball moves at least 6 of its own radii a second, each starting one
    /// point early so the flight begins at the strike. Brief slow moments do not break a run.
    private static func fastRuns(_ points: [Point]) -> [ClosedRange<Int>] {
        guard points.count > 1 else { return [] }
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        var lastFast = 0
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            let pace = hypot(b.x - a.x, b.y - a.y) / max(0.002, a.radius) / max(0.001, b.time - a.time)
            if pace >= 6 {
                if start == nil { start = index - 1 }
                lastFast = index
            } else if let begun = start, index - lastFast > 4 {
                runs.append(begun...lastFast)
                start = nil
            }
        }
        if let begun = start { runs.append(begun...lastFast) }
        return runs
    }

    init(points: [Point], lead: [Point] = []) {
        self.points = points
        self.lead = lead
        let a = points[0], b = points[points.count - 1]
        let chord = hypot(b.x - a.x, b.y - a.y)
        var widest = 0.0, at = 0, side = 0.0
        var gapX = 0.0, gapY = 0.0
        if chord > 0.0001 {
            let dx = (b.x - a.x) / chord, dy = (b.y - a.y) / chord
            for (index, p) in points.enumerated() {
                let cross = dx * (p.y - a.y) - dy * (p.x - a.x)
                if abs(cross) > widest {
                    widest = abs(cross); at = index; side = cross
                    // From the straight line out to the path.
                    gapX = -dy * cross; gapY = dx * cross
                }
            }
        }
        bend = chord > 0.0001 ? widest / chord : 0
        bendIndex = at
        bulge = bend < 0.04 ? 0 : side > 0 ? 1 : -1
        // Rose and came down: the bulge points up the picture, or (flying straight away from the
        // camera) the ball climbed well above where it was last seen.
        let smoothed = points.indices.map { index -> Double in
            let values = points[max(0, index - 1)...min(points.count - 1, index + 1)].map(\.radius).sorted()
            return max(0.0005, values[values.count / 2])
        }
        var farthest = 1.0
        depthSoFar = smoothed.map { radius in
            farthest = max(farthest, smoothed[0] / radius)
            return farthest
        }
        let apex = points.indices.min { points[$0].y < points[$1].y } ?? 0
        let climbedAbove = apex > 0 && apex < points.count - 1 && b.y - points[apex].y > 0.15 * max(chord, 0.0001)
        dips = (bend >= 0.04 && gapY < 0 && abs(gapY) > abs(gapX) * 1.2) || climbedAbove
    }

    /// An illustrative shot for picker thumbnails, struck near the camera and flying away while
    /// it curls a little; replays always use the shot's own flight.
    static let sample: ShotFlight = {
        let points = (0...48).map { index -> Point in
            let t = Double(index) / 48
            let u = 1 - t
            let x = u * u * u * 0.34 + 3 * u * u * t * 0.2 + 3 * u * t * t * 0.18 + t * t * t * 0.3
            let y = u * u * u * 0.92 + 3 * u * u * t * 0.62 + 3 * u * t * t * 0.36 + t * t * t * 0.3
            return Point(time: 0.5 + Double(index) / 60, x: x, y: y, radius: 0.045 / (1 + 2.6 * t))
        }
        // Half a second resting on the spot before the strike.
        let lead = (0..<30).map { index in
            Point(time: Double(index) / 60, x: points[0].x, y: points[0].y, radius: points[0].radius)
        }
        return ShotFlight(points: points, lead: lead)
    }()
}
