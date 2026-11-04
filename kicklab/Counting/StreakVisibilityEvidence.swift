import Foundation

/// Source-frame evidence only. Callback arrival time, cached boxes, missing
/// inference and a missing ball must never be recorded as an absent player.
nonisolated struct StreakVisibilityEvidence {
    static let signature = "|streak-visibility-v1"
    static let graceMS = 2_500
    static let maximumSampleGapMS = 600
    static let maximumSamples = 60_000

    struct Sample: Codable, Equatable, Sendable {
        let timeMS: Int
        let personVisible: Bool
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
    }

    private(set) var samples: [Sample] = []
    mutating func record(timeMS: Int, personVisible: Bool) {
        guard timeMS >= 0, samples.count < Self.maximumSamples else { return }
        samples.append(.init(timeMS: timeMS, personVisible: personVisible))
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
            if let time = Self.absenceStart(in: observed) {
                decisions.append(.init(window: gap, timeMS: time, kind: .playerOutOfView, recheckedFrames: 0))
                continue
            }
            for window in Self.unresolvedWindows(in: gap, samples: observed) {
                recheckWindows += 1
                let saved = recheck(window).filter { $0.timeMS > window.startMS && $0.timeMS < window.endMS }
                recheckedFrames += saved.count
                let combined = (observed.filter { $0.timeMS > window.startMS && $0.timeMS < window.endMS } + saved)
                    .sorted { $0.timeMS < $1.timeMS }
                if let time = Self.absenceStart(in: combined) {
                    decisions.append(.init(window: window, timeMS: time, kind: .playerOutOfView,
                                           recheckedFrames: saved.count))
                    break
                }
                if let unresolved = Self.unresolvedWindows(in: window, samples: combined).first {
                    // Do not call an unreadable interval a drop or a departure.
                    // Equally, do not claim two separated runs were continuous.
                    decisions.append(.init(window: unresolved, timeMS: unresolved.startMS+1,
                                           kind: .visibilityUnverified, recheckedFrames: saved.count))
                    break
                }
            }
        }
        return .init(policy: Self.signature, graceMS: Self.graceMS, freshFrames: samples.count,
                     decisions: decisions, recheckedFrames: recheckedFrames, recheckWindows: recheckWindows)
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
            // endpoint sampling from cutting a 2 s departure at a 2.5 s gap.
            let covered = zip(exposures, exposures.dropFirst()).allSatisfy { $1-$0 <= maximumSampleGapMS }
            return covered ? nil : Window(startMS: start, endMS: end)
        }
    }

    private static func absenceStart(in samples: [Sample]) -> Int? {
        // Conflicting observations of one exposure resolve to visible. Duplicate
        // replies must not increase the number of independent measurements.
        let grouped = Dictionary(grouping: samples, by: \.timeMS)
        var first: Int?, previous: Int?, count = 0
        for time in grouped.keys.sorted() {
            if grouped[time]!.contains(where: \.personVisible) {
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
