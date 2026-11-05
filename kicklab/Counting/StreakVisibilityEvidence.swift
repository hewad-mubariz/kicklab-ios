import Foundation

/// Source-frame evidence only. Callback arrival time, cached boxes and missing
/// inference must never be recorded as an absence, and a missing ball is never
/// an absent player.
nonisolated struct StreakVisibilityEvidence {
    static let signature = "|streak-visibility-v2"
    static let graceMS = 3_000
    static let maximumSampleGapMS = 600
    static let maximumSamples = 60_000
    /// Readable saved frames an absence needs before it can end a streak.
    static let secondLookFrames = 5
    /// A ball just touched, or about to be, is in frame whatever the detector says.
    static let touchGuardMS = 300
    /// Two sightings this close together count as really seen.
    static let sightingPairMS = 600

    struct Sample: Codable, Equatable, Sendable {
        let timeMS: Int
        let personVisible: Bool
        let ballVisible: Bool
    }
    struct Window: Codable, Equatable, Sendable {
        let startMS: Int
        let endMS: Int
    }
    struct Decision: Codable, Equatable, Sendable {
        let window: Window
        let timeMS: Int
        let kind: ContactReviewReason
        let recheckedFrames: Int
    }
    struct Assessment: Codable, Sendable {
        let policy: String
        let graceMS: Int
        let freshFrames: Int
        let decisions: [Decision]
        let recheckedFrames: Int
        let recheckWindows: Int
        /// Live absences checked on the saved video, and those it overruled.
        let secondLooks: Int
        let absencesOverruled: Int
    }

    private(set) var samples: [Sample] = []
    mutating func record(timeMS: Int, personVisible: Bool, ballVisible: Bool) {
        guard timeMS >= 0, samples.count < Self.maximumSamples else { return }
        samples.append(.init(timeMS: timeMS, personVisible: personVisible, ballVisible: ballVisible))
    }

    /// Accepted contacts bound the interval under consideration. Only gaps
    /// within a run need checking; already-proven catches/bounces remain final.
    /// A fresh positive person observation interrupts a possible absence.
    func assess(touchTimes: [Double], existingBoundaries: [Double],
                recheck: (Window) -> [Sample]) -> Assessment {
        let times = Array(Set(touchTimes.filter { $0.isFinite && $0 >= 0 && $0 <= 86_400 }
            .map { Int(($0 * 1000).rounded()) })).sorted()
        let boundaries = existingBoundaries.filter { $0.isFinite && $0 >= 0 && $0 <= 86_400 }
            .map { Int(($0 * 1000).rounded()) }.sorted()
        let ordered = samples.sorted { $0.timeMS < $1.timeMS }
        var decisions: [Decision] = []
        var recheckedFrames = 0, recheckWindows = 0, cursor = 0, cut = 0
        var secondLooks = 0, absencesOverruled = 0
        for (before, after) in zip(times, times.dropFirst()) {
            while cut < boundaries.count, boundaries[cut] <= before { cut += 1 }
            while cursor < ordered.count, ordered[cursor].timeMS <= before { cursor += 1 }
            let start = cursor
            while cursor < ordered.count, ordered[cursor].timeMS < after { cursor += 1 }
            guard after-before >= Self.graceMS,
                  cut == boundaries.count || boundaries[cut] > after else { continue }
            let observed = Array(ordered[start..<cursor])
            let gap = Window(startMS: before, endMS: after)
            // A single boundary separates these contacts. Preserve both runs
            // and every counted touch, regardless of how long the gap was.
            if let time = Self.absenceStart(in: observed, \.personVisible) {
                let look = Self.secondLook(from: time, until: after, \.personVisible, known: observed, recheck: recheck)
                recheckedFrames += look.frames
                secondLooks += 1
                if look.agrees {
                    decisions.append(.init(window: gap, timeMS: time, kind: .playerOutOfView, recheckedFrames: look.frames))
                    continue
                }
                absencesOverruled += 1
            }
            var savedInGap: [Sample] = [], decided = false
            for window in Self.unresolvedWindows(in: gap, samples: observed) {
                recheckWindows += 1
                let saved = recheck(window).filter { $0.timeMS > window.startMS && $0.timeMS < window.endMS }
                recheckedFrames += saved.count
                savedInGap += saved
                let combined = (observed.filter { $0.timeMS > window.startMS && $0.timeMS < window.endMS } + saved)
                    .sorted { $0.timeMS < $1.timeMS }
                if let time = Self.absenceStart(in: combined, \.personVisible) {
                    decisions.append(.init(window: window, timeMS: time, kind: .playerOutOfView,
                                           recheckedFrames: saved.count))
                    decided = true
                    break
                }
                if let unresolved = Self.unresolvedWindows(in: window, samples: combined).first {
                    // Do not call an unreadable interval a drop or a departure.
                    // Equally, do not claim two separated runs were continuous.
                    decisions.append(.init(window: unresolved, timeMS: unresolved.startMS+1,
                                           kind: .visibilityUnverified, recheckedFrames: saved.count))
                    decided = true
                    break
                }
            }
            // A counted touch is itself a sighting of the ball.
            let touches = [before, after], end = after-Self.touchGuardMS
            let known = (observed+savedInGap).filter { $0.timeMS > before+Self.touchGuardMS && $0.timeMS < end }
            guard !decided, let time = Self.absenceStart(in: known, \.ballVisible, alsoSeen: touches) else { continue }
            let look = Self.secondLook(from: time, until: end, \.ballVisible, known: known, alsoSeen: touches, recheck: recheck)
            recheckedFrames += look.frames
            secondLooks += 1
            guard look.agrees else {
                absencesOverruled += 1
                continue
            }
            decisions.append(.init(window: look.window, timeMS: time, kind: .ballOutOfView, recheckedFrames: look.frames))
        }
        return .init(policy: Self.signature, graceMS: Self.graceMS, freshFrames: samples.count,
                     decisions: decisions, recheckedFrames: recheckedFrames, recheckWindows: recheckWindows,
                     secondLooks: secondLooks, absencesOverruled: absencesOverruled)
    }

    /// Detectors miss things, so a live absence also needs the saved video to
    /// agree. Video that cannot be read proves nothing, and the streak carries on.
    private static func secondLook(from time: Int, until end: Int, _ visible: KeyPath<Sample, Bool>, known: [Sample],
                                   alsoSeen: [Int] = [], recheck: (Window) -> [Sample]) -> (agrees: Bool, window: Window, frames: Int) {
        let look = Window(startMS: time-1, endMS: min(end, time+graceMS+500))
        let inLook = { (sample: Sample) in sample.timeMS > look.startMS && sample.timeMS < look.endMS }
        let frames = recheck(look).filter(inLook)
        let agrees = frames.count >= secondLookFrames
            && absenceStart(in: known.filter(inLook)+frames, visible, alsoSeen: alsoSeen) != nil
        return (agrees, look, frames.count)
    }

    private static func unresolvedWindows(in window: Window, samples: [Sample]) -> [Window] {
        let visible = Array(Set(samples.filter { $0.personVisible && $0.timeMS > window.startMS && $0.timeMS < window.endMS }
            .map(\.timeMS))).sorted()
        let anchors = [window.startMS] + visible + [window.endMS]
        return zip(anchors, anchors.dropFirst()).compactMap { start, end in
            guard end-start >= graceMS else { return nil }
            let observed = Array(Set(samples.filter { $0.timeMS > start && $0.timeMS < end }.map(\.timeMS))).sorted()
            let exposures = [start] + observed + [end]
            // Dense fresh negatives that did not reach the absence threshold
            // are a short miss, not an unresolved interval. This also prevents
            // endpoint sampling from cutting a 2 s departure at a 3 s gap.
            let covered = zip(exposures, exposures.dropFirst()).allSatisfy { $1-$0 <= maximumSampleGapMS }
            return covered ? nil : Window(startMS: start, endMS: end)
        }
    }

    private static func absenceStart(in samples: [Sample], _ visible: KeyPath<Sample, Bool>, alsoSeen: [Int] = []) -> Int? {
        // Conflicting observations of one exposure resolve to visible. Duplicate
        // replies must not increase the number of independent measurements.
        let grouped = Dictionary(grouping: samples, by: \.timeMS)
        let times = grouped.keys.sorted()
        // A false detection in an empty frame must not restart the clock, or one
        // video gives different answers on different runs. It takes a second
        // sighting close by to say the ball or player is back.
        let sightings = (times.filter { time in grouped[time]!.contains { $0[keyPath: visible] } } + alsoSeen).sorted()
        let confirmed = Set(zip(sightings, sightings.dropFirst())
            .filter { $1-$0 <= sightingPairMS }.flatMap { [$0, $1] })
        var first: Int?, previous: Int?, count = 0
        for time in times {
            if confirmed.contains(time) {
                first = nil; previous = nil; count = 0
                continue
            }
            if previous == nil || time-previous! > maximumSampleGapMS {
                first = time; count = 0
            }
            previous = time; count += 1
            if let first, time-first >= graceMS, count >= 6 { return first }
        }
        return nil
    }
}

/// What the recording screen can say while a session runs. Only a warning: the
/// saved video still has the last word when the session ends.
nonisolated struct LiveAbsenceWarning: Equatable, Sendable {
    enum Subject: Equatable, Sendable { case player, ball }
    let subject: Subject
    /// Whole seconds until the streak would end; 0 once it would have.
    let secondsLeft: Int
}

/// The rule's clock, run as replies arrive. It takes the same detections and
/// limits as `StreakVisibilityEvidence`, so the screen warns before the rule acts.
nonisolated struct LiveAbsenceClock {
    /// Valid juggling rarely stays unseen this long: 3 warnings in 92 measured minutes,
    /// against 11 at one second, most of them a player the detector briefly lost.
    static let warnAfterMS = 1_500

    private struct Track {
        private var lastSighting: Int?, first: Int?, previous: Int?

        mutating func record(timeMS: Int, visible: Bool) {
            if visible {
                defer { lastSighting = timeMS }
                if let lastSighting, timeMS-lastSighting <= StreakVisibilityEvidence.sightingPairMS {
                    restart()
                    return
                }
            }
            if previous.map({ timeMS-$0 > StreakVisibilityEvidence.maximumSampleGapMS }) ?? true {
                first = timeMS
            }
            previous = timeMS
        }
        mutating func restart() { first = nil; previous = nil }
        func secondsLeft(at timeMS: Int) -> Int? {
            guard let first, let previous, timeMS-previous <= StreakVisibilityEvidence.maximumSampleGapMS,
                  previous-first >= LiveAbsenceClock.warnAfterMS else { return nil }
            let left = StreakVisibilityEvidence.graceMS-(previous-first)
            return max(0, Int((Double(left)/1000).rounded(.up)))
        }
    }
    private var person = Track(), ball = Track(), touches = 0

    mutating func record(timeMS: Int, personVisible: Bool, ballVisible: Bool) {
        person.record(timeMS: timeMS, visible: personVisible)
        ball.record(timeMS: timeMS, visible: ballVisible)
    }
    /// A streak starts with the first counted touch, and each touch starts the clocks over.
    mutating func counted(_ total: Int) {
        guard total > touches else { return }
        touches = total
        person.restart(); ball.restart()
    }
    func warning(at timeMS: Int) -> LiveAbsenceWarning? {
        guard touches > 0 else { return nil }
        if let left = person.secondsLeft(at: timeMS) { return .init(subject: .player, secondsLeft: left) }
        return ball.secondsLeft(at: timeMS).map { .init(subject: .ball, secondsLeft: $0) }
    }
}
