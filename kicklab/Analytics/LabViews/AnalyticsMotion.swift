// Copied from the Effects Lab (EffectLab/Graphs/AnalyticsMotion.swift), 2026-11-19; only isolation is added for the app.
import Foundation

/// Motion primitives. Every animated value is a pure function of the playhead, so playback,
/// scrubbing and the saved video draw identical frames. There is no UI animation state.
nonisolated enum Motion {
    static func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(hi, max(lo, x)) }
    static func lerp(_ a: Double, _ b: Double, _ f: Double) -> Double { a + (b - a) * f }
    static func easeOut(_ x: Double) -> Double { let u = 1 - clamp(x); return 1 - u * u * u }
    static func easeInOut(_ x: Double) -> Double {
        let x = clamp(x)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }
    /// Overshoots a little and settles: for things that land.
    static func backOut(_ x: Double, overshoot s: Double = 1.7) -> Double {
        let u = clamp(x) - 1
        return 1 + (s + 1) * u * u * u + s * u * u
    }
    /// 1 at the event, decaying after it. 0 before it.
    static func flash(_ age: Double, decay: Double = 0.16) -> Double { age < 0 ? 0 : exp(-age / decay) }
    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let f = clamp((x - a) / (b - a))
        return f * f * (3 - 2 * f)
    }
    /// Index of the last element at or before `value` in a sorted array.
    static func lastIndex(_ sorted: [Double], atOrBefore value: Double) -> Int? {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] <= value { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }
    static func median(_ values: [Double]) -> Double? { TimingSpread.quantile(values.sorted(), 0.5) }

    /// A number that eases from wherever it was to each new target. The start of every
    /// transition is derived from the one before it, so it is still a function of time only.
    struct Tween {
        let times: [Double]
        let targets: [Double]
        private let starts: [Double]
        let duration: Double

        init(_ changes: [(Double, Double)], duration: Double) {
            let sorted = changes.filter { $0.0.isFinite && $0.1.isFinite }.sorted { $0.0 < $1.0 }
            times = sorted.map(\.0)
            targets = sorted.map(\.1)
            self.duration = duration
            var starts = [Double]()
            for i in sorted.indices {
                if i == 0 { starts.append(targets[0]); continue }
                let progress = Motion.easeOut((times[i] - times[i - 1]) / duration)
                starts.append(Motion.lerp(starts[i - 1], targets[i - 1], progress))
            }
            self.starts = starts
        }

        func value(at t: Double) -> Double? {
            guard let i = Motion.lastIndex(times, atOrBefore: t) else { return nil }
            return Motion.lerp(starts[i], targets[i], Motion.easeOut((t - times[i]) / duration))
        }
        func target(at t: Double) -> Double? { Motion.lastIndex(times, atOrBefore: t).map { targets[$0] } }
        /// Seconds since the latest change, for pulses.
        func age(at t: Double) -> Double? { Motion.lastIndex(times, atOrBefore: t).map { t - times[$0] } }
    }
}

/// Three analytics graphs designed for motion: Beat Gates (touch timing), Arc Match (each
/// bounce against the player's usual bounce) and Control Surf (side-to-side control against
/// the player's own line). Built once per session; drawing asks for any time.
nonisolated enum AnalyticsMotion {
    static let names = ["Beat Gates", "Arc Match", "Control Surf"]
    static let slugs = ["beat-gates", "arc-match", "control-surf"]
    /// Lane half-width, in ball diameters either side of the player's own line.
    static let laneHalfWidth = 1.0
    static let curvePoints = 33
    static let pauseGap = 2.0

    struct Touch {
        let time: Double
        /// Expected gap from the previous touches, the signed miss and the on-beat window.
        let beat: Double?
        let error: Double?
        let tolerance: Double?
        /// -1 early, 0 on beat, 1 late.
        var verdict: Int? {
            guard let error, let tolerance else { return nil }
            return error < -tolerance ? -1 : error > tolerance ? 1 : 0
        }
    }

    /// Where the next touch should land, shown from the touch before it.
    struct Gate {
        let shownFrom: Double
        let at: Double
        let tolerance: Double
        let touch: Int?
    }

    struct Flight {
        let index: Int
        let start: Double
        let end: Double
        /// Rise above the starting contact, in body heights.
        let path: [(Double, Double)]
        let curve: [Double]
        let apex: Double
        let apexTime: Double
        var duration: Double { end - start }
    }

    /// The player's usual bounce from earlier completed flights.
    struct Usual {
        let curve: [Double]
        let duration: Double
        let apex: Double
        let apexPhase: Double
        let count: Int
    }

    struct SidePoint {
        let time: Double
        /// Smoothed ball offset from the player's line, in ball diameters; + is screen right.
        let offset: Double
        let continues: Bool
    }

    struct Excursion {
        let start: Double
        /// Confirmed outside the lane.
        let shownFrom: Double
        let reentry: Double?
        /// Confirmed back inside.
        let confirmed: Double?
        /// Tracking lost before a return was confirmed.
        let censoredAt: Double?
        let touches: [Double]
        var duration: Double? { reentry.map { $0 - start } }
    }


    /// Tracked ball and body, interpolated between neighbouring frames.
    struct Track {
        let samples: [AnalyticsSuite.Sample]
        let times: [Double]
        let bodyHeight: Double
        let ballDiameter: Double

        init(_ raw: [AnalyticsSuite.Sample]) {
            samples = raw.filter { $0.time.isFinite }.sorted { $0.time < $1.time }
            times = samples.map(\.time)
            let valid = samples.filter(\.bodyValid)
            bodyHeight = Motion.median(valid.map(\.personHeight)) ?? 1
            ballDiameter = 2 * (Motion.median(valid.map(\.radius)) ?? 30)
        }

        func ball(at t: Double) -> (x: Double, y: Double, personX: Double)? {
            guard let i = Motion.lastIndex(times, atOrBefore: t) else { return nil }
            let a = samples[i]
            if i + 1 < samples.count {
                let b = samples[i + 1]
                if a.bodyValid && b.bodyValid && b.time - a.time <= 0.101 {
                    let f = (t - a.time) / (b.time - a.time)
                    return (Motion.lerp(a.x, b.x, f), Motion.lerp(a.y, b.y, f), Motion.lerp(a.personX, b.personX, f))
                }
            }
            return a.bodyValid && t - a.time <= 0.05 ? (a.x, a.y, a.personX) : nil
        }

        /// The bounce from the touch at `start` up to `t`, as (time, rise in body heights),
        /// using only frames seen so far. Stops at the first tracking gap.
        func risePath(from start: Double, to t: Double) -> [(Double, Double)]? {
            guard t >= start, let origin = ball(at: start) else { return nil }
            var out: [(Double, Double)] = [(start, 0)], last = start
            var i = (Motion.lastIndex(times, atOrBefore: start) ?? -1) + 1
            while i < samples.count && samples[i].time < t {
                let s = samples[i]
                guard s.bodyValid, s.time - last <= 0.101 else { return out.count > 1 ? out : nil }
                out.append((s.time, (origin.y - s.y) / bodyHeight)); last = s.time; i += 1
            }
            if t - last <= 0.101, let head = ball(at: t) { out.append((t, (origin.y - head.y) / bodyHeight)) }
            return out
        }

        static func interpolate(_ path: [(Double, Double)], at time: Double) -> Double {
            guard let first = path.first else { return 0 }
            if time <= first.0 { return first.1 }
            for (a, b) in zip(path, path.dropFirst()) where time <= b.0 {
                let f = b.0 - a.0 > 0 ? (time - a.0) / (b.0 - a.0) : 1
                return Motion.lerp(a.1, b.1, f)
            }
            return path.last!.1
        }
    }

    final class Session {
        let track: Track
        let touchTimes: [Double]
        // Beat Gates
        let touches: [Touch]
        let gates: [Gate]
        let tempo: Motion.Tween
        let tolerance: Motion.Tween
        // Arc Match
        let flights: [Int: Flight]
        let usual: [Int: Usual]
        let riseScale: Double
        let riseChange: Motion.Tween
        let flightChange: Motion.Tween
        // Control Surf
        let line: Motion.Tween
        let side: [SidePoint]
        let sideTimes: [Double]
        let excursions: [Excursion]
        let returnSeconds: Motion.Tween
        let returnTouches: Motion.Tween
        private let cumulativeAll: [Double]
        private let cumulativeIn: [Double]

        init(_ input: AnalyticsSuite.Input) {
            let track = Track(input.samples)
            let touchTimes = Array(Set(input.events.map(\.time).filter { $0.isFinite && $0 >= 0 })).sorted()
            self.track = track
            self.touchTimes = touchTimes

            // MARK: Beat Gates. Each touch is judged against the median of up to four
            // earlier gaps in the same run; the gate for it is known from the touch before.
            var touches = [Touch](), gates = [Gate](), runGaps = [Double]()
            var tempoChanges = [(Double, Double)](), toleranceChanges = [(Double, Double)]()
            for (k, time) in touchTimes.enumerated() {
                guard k > 0 else { touches.append(Touch(time: time, beat: nil, error: nil, tolerance: nil)); continue }
                let gap = time - touchTimes[k - 1]
                if gap > AnalyticsMotion.pauseGap {
                    runGaps = []
                    touches.append(Touch(time: time, beat: nil, error: nil, tolerance: nil))
                    continue
                }
                if runGaps.count >= 2, let beat = Motion.median(Array(runGaps.suffix(4))) {
                    let window = max(0.06, 0.1 * beat)
                    touches.append(Touch(time: time, beat: beat, error: gap - beat, tolerance: window))
                    gates.append(Gate(shownFrom: touchTimes[k - 1], at: touchTimes[k - 1] + beat, tolerance: window, touch: k))
                } else {
                    touches.append(Touch(time: time, beat: nil, error: nil, tolerance: nil))
                }
                runGaps.append(gap)
                if runGaps.count >= 2, let beat = Motion.median(Array(runGaps.suffix(4))) {
                    tempoChanges.append((time, 60 / beat))
                    toleranceChanges.append((time, max(0.06, 0.1 * beat)))
                }
            }
            if let last = touchTimes.last, runGaps.count >= 2, let beat = Motion.median(Array(runGaps.suffix(4))) {
                gates.append(Gate(shownFrom: last, at: last + beat, tolerance: max(0.06, 0.1 * beat), touch: nil))
            }
            self.touches = touches
            self.gates = gates
            tempo = Motion.Tween(tempoChanges, duration: 0.45)
            tolerance = Motion.Tween(toleranceChanges, duration: 0.6)

            // MARK: Arc Match. A flight is a fully tracked bounce between two touches.
            var flights = [Int: Flight]()
            for k in 0..<max(0, touchTimes.count - 1) {
                let start = touchTimes[k], end = touchTimes[k + 1]
                guard end - start > 0.15, end - start <= 1.5,
                      let path = track.risePath(from: start, to: end), path.count >= 5,
                      let last = path.last, abs(last.0 - end) < 0.0005 else { continue }
                let curve = (0..<AnalyticsMotion.curvePoints).map { j -> Double in
                    let time = start + Double(j) / Double(AnalyticsMotion.curvePoints - 1) * (end - start)
                    return Track.interpolate(path, at: time)
                }
                let top = path.max { $0.1 < $1.1 }!
                flights[k] = Flight(index: k, start: start, end: end, path: path, curve: curve, apex: top.1, apexTime: top.0)
            }
            // The usual bounce for flight k uses only flights completed before it starts.
            var usual = [Int: Usual](), riseChanges = [(Double, Double)](), flightChanges = [(Double, Double)]()
            let flightKeys = flights.keys.sorted()
            for k in touchTimes.indices {
                let earlier = flightKeys.filter { $0 < k }.suffix(8).compactMap { flights[$0] }
                guard earlier.count >= 3 else { continue }
                let curve = (0..<AnalyticsMotion.curvePoints).map { j in Motion.median(earlier.map { $0.curve[j] }) ?? 0 }
                let apexIndex = curve.indices.max { curve[$0] < curve[$1] } ?? 0
                usual[k] = Usual(curve: curve, duration: Motion.median(earlier.map(\.duration)) ?? 0.6,
                                 apex: curve[apexIndex],
                                 apexPhase: Double(apexIndex) / Double(AnalyticsMotion.curvePoints - 1),
                                 count: earlier.count)
            }
            for (k, flight) in flights {
                guard let u = usual[k], u.apex > 0.01 else { continue }
                riseChanges.append((flight.end, (flight.apex / u.apex - 1) * 100))
                flightChanges.append((flight.end, flight.duration - u.duration))
            }
            self.flights = flights
            self.usual = usual
            riseScale = max(0.1, (TimingSpread.quantile(flights.values.map(\.apex).sorted(), 0.9) ?? 0.25) * 1.08)
            riseChange = Motion.Tween(riseChanges, duration: 0.5)
            flightChange = Motion.Tween(flightChanges, duration: 0.5)

            // MARK: Control Surf. The player's line is the median ball offset at their last
            // eight touches, so juggling beside the body still counts as steady.
            var contacts = [Double](), lineChanges = [(Double, Double)]()
            for time in touchTimes {
                guard let b = track.ball(at: time) else { continue }
                contacts.append((b.x - b.personX) / track.ballDiameter)
                if contacts.count >= 3, let m = Motion.median(Array(contacts.suffix(8))) { lineChanges.append((time, m)) }
            }
            let line = Motion.Tween(lineChanges, duration: 0.6)
            self.line = line
            var side = [SidePoint](), previous: (time: Double, value: Double)?
            for sample in track.samples where sample.bodyValid {
                let raw = (sample.x - sample.personX) / track.ballDiameter
                var value = raw, continues = false
                if let p = previous, sample.time - p.time <= 0.101 {
                    value = p.value + (1 - exp(-(sample.time - p.time) / 0.08)) * (raw - p.value)
                    continues = true
                }
                previous = (sample.time, value)
                guard let l = line.value(at: sample.time) else { continue }
                side.append(SidePoint(time: sample.time, offset: value - l,
                                      continues: continues && (side.last.map { sample.time - $0.time <= 0.101 } ?? false)))
            }
            self.side = side
            sideTimes = side.map(\.time)

            // Out after 0.12 s beyond the lane, back after 0.12 s inside. Lost tracking ends an
            // excursion without a return.
            let hw = AnalyticsMotion.laneHalfWidth
            var excursions = [Excursion](), outStart: Double?, active: (start: Double, shown: Double)?, inStart: Double?
            for point in side {
                if !point.continues {
                    if let a = active {
                        excursions.append(Excursion(start: a.start, shownFrom: a.shown, reentry: nil, confirmed: nil,
                                                    censoredAt: point.time, touches: []))
                    }
                    active = nil; outStart = nil; inStart = nil
                }
                if abs(point.offset) > hw {
                    inStart = nil
                    if active == nil {
                        let begin = outStart ?? point.time
                        outStart = begin
                        if point.time - begin >= 0.12 { active = (begin, point.time) }
                    }
                } else {
                    outStart = nil
                    if let a = active {
                        let back = inStart ?? point.time
                        inStart = back
                        if point.time - back >= 0.12 {
                            excursions.append(Excursion(start: a.start, shownFrom: a.shown, reentry: back, confirmed: point.time,
                                                        censoredAt: nil, touches: touchTimes.filter { $0 > a.start && $0 <= back }))
                            active = nil; inStart = nil
                        }
                    }
                }
            }
            if let a = active {
                excursions.append(Excursion(start: a.start, shownFrom: a.shown, reentry: nil, confirmed: nil, censoredAt: nil, touches: []))
            }
            self.excursions = excursions
            let returned = excursions.filter { $0.confirmed != nil }
            returnSeconds = Motion.Tween(returned.map { ($0.confirmed!, $0.duration!) }, duration: 0.5)
            returnTouches = Motion.Tween(returned.map { ($0.confirmed!, Double($0.touches.count)) }, duration: 0.3)

            var all = [Double](), inside = [Double]()
            for (i, point) in side.enumerated() {
                guard i > 0, point.continues else { all.append(all.last ?? 0); inside.append(inside.last ?? 0); continue }
                let dt = point.time - side[i - 1].time, mid = abs((point.offset + side[i - 1].offset) / 2)
                all.append((all.last ?? 0) + dt)
                inside.append((inside.last ?? 0) + (mid <= hw ? dt : 0))
            }
            cumulativeAll = all
            cumulativeIn = inside
        }

        func touchIndex(at t: Double) -> Int? { Motion.lastIndex(touchTimes, atOrBefore: t) }

        /// The smoothed side offset at any time, interpolated between frames.
        func sideOffset(at t: Double) -> Double? {
            guard let i = Motion.lastIndex(sideTimes, atOrBefore: t) else { return nil }
            if i + 1 < side.count, side[i + 1].continues {
                let a = side[i], b = side[i + 1]
                return Motion.lerp(a.offset, b.offset, (t - a.time) / (b.time - a.time))
            }
            return t - side[i].time <= 0.05 ? side[i].offset : nil
        }

        /// Share of tracked time inside the lane over the last `window` seconds. Changes
        /// continuously, so the number counts smoothly rather than jumping.
        func inLane(at t: Double, window: Double = 10) -> Double? {
            func cumulative(_ values: [Double], _ time: Double) -> Double {
                guard let i = Motion.lastIndex(sideTimes, atOrBefore: time) else { return 0 }
                if i + 1 < side.count, side[i + 1].continues {
                    let f = (time - side[i].time) / (side[i + 1].time - side[i].time)
                    return Motion.lerp(values[i], values[i + 1], Motion.clamp(f))
                }
                return values[i]
            }
            let all = cumulative(cumulativeAll, t) - cumulative(cumulativeAll, t - window)
            guard all >= 1 else { return nil }
            return (cumulative(cumulativeIn, t) - cumulative(cumulativeIn, t - window)) / all * 100
        }
    }
}
