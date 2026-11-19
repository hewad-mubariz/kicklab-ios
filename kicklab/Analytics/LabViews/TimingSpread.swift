// Copied from the Effects Lab (EffectLab/Graphs/TimingSpread.swift), 2026-11-19; only isolation is added for the app.
import Foundation

/// Causal, seekable analytics. No UI clock, global state or future normalization.
nonisolated enum TimingSpread {
    static let window = 20
    static let pauseThreshold = 2.0
    static let minimumDistributionSamples = 5
    static let lower = 0.30, upper = 0.90, binWidth = 0.05

    struct Interval: Codable, Equatable {
        let start, end, seconds: Double
    }
    struct Snapshot: Codable, Equatable {
        let time: Double
        let touchCount: Int
        let intervals: [Interval]
        let bins: [Int] // <0.30, twelve regular bins [0.30,0.90), >=0.90
        let median, q10, q90, latest: Double?
        let pauseCount: Int
        let completedPauseSeconds: Double
        let awaitingTouchAfterPause: Bool
        let sinceLastTouch: Double?
        var count: Int { intervals.count }
        var distributionReady: Bool { count >= minimumDistributionSamples }
    }

    struct Timeline {
        let touches: [Double]
        init(touches: [Double]) {
            // Reject invalid observations; exact duplicates are not contacts.
            // Distinct close events remain visible rather than being hidden.
            self.touches = Array(Set(touches.filter { $0.isFinite && $0 >= 0 })).sorted()
        }
        func snapshot(at requestedTime: Double) -> Snapshot {
            let time = requestedTime.isFinite ? max(0, requestedTime) : 0
            let played = touches.prefix { $0 <= time }
            var run = [Interval](), pauses = 0, pausedSeconds = 0.0
            for (a,b) in zip(played,played.dropFirst()) {
                let gap = b-a
                if gap > pauseThreshold {
                    pauses += 1; pausedSeconds += gap; run.removeAll(keepingCapacity:true)
                } else {
                    run.append(Interval(start:a,end:b,seconds:gap))
                }
            }
            let elapsed = played.last.map { time-$0 }
            let waiting = elapsed.map { $0 > pauseThreshold } ?? false
            if waiting { run.removeAll(keepingCapacity:true) }
            let samples = Array(run.suffix(window))
            let sorted = samples.map(\.seconds).sorted()
            var bins = [Int](repeating:0,count:14)
            for value in sorted { bins[bin(for:value)] += 1 }
            return Snapshot(time:time,touchCount:played.count,intervals:samples,bins:bins,
                median:quantile(sorted,0.5),
                q10:samples.count >= minimumDistributionSamples ? quantile(sorted,0.1):nil,
                q90:samples.count >= minimumDistributionSamples ? quantile(sorted,0.9):nil,
                latest:samples.last?.seconds,pauseCount:pauses,completedPauseSeconds:pausedSeconds,
                awaitingTouchAfterPause:waiting,sinceLastTouch:elapsed)
        }
    }
    static func bin(for value:Double)->Int {
        guard value.isFinite else { return 0 }
        if value < lower { return 0 }
        if value >= upper { return 13 }
        return min(12,max(1,1+Int(floor((value-lower)/binWidth+1e-9))))
    }
    /// Linear interpolation, h=(n-1)*p (the common type-7 sample quantile).
    static func quantile(_ sorted:[Double],_ p:Double)->Double? {
        guard !sorted.isEmpty else { return nil }
        let h=Double(sorted.count-1)*min(1,max(0,p)),i=Int(floor(h)),f=h-Double(i)
        return sorted[i]*(1-f)+sorted[min(i+1,sorted.count-1)]*f
    }
}
