import Foundation

/// Keeps sparse observations from acquiring a longer smoothing window simply
/// because inference is slower. Dense trajectories keep their established path.
nonisolated enum TimedTrajectory {
    static let referenceIntervalMs = 1000.0 / 30
    static let signature = "|timed-trajectory-v1"

    static func point(at frame: Int, in run: [Int], stamps: [Int: Int],
                      filled: [Int: BallObservation], observed: [Int: BallObservation],
                      config: CounterConfig) -> TrajectoryPoint? {
        guard let index = run.firstIndex(of: frame) else { return nil }
        let intervals = zip(run, run.dropFirst()).compactMap { a, b -> Double? in
            guard abs(a - frame) <= 3, abs(b - frame) <= 3 else { return nil }
            return Double(stamps[b]! - stamps[a]!)
        }
        // Require a short cadence history and ignore an isolated dropped frame.
        // An even sample count also keeps alternating 33/67 ms intervals (20 FPS
        // selected from 30 FPS video) from toggling between the two paths.
        guard intervals.count >= 4 else { return nil }
        let cadence = Array(intervals.suffix(intervals.count - intervals.count % 2)).sorted()
        let middle = cadence.count / 2
        guard (cadence[middle - 1] + cadence[middle]) / 2 > referenceIntervalMs * 1.2 else { return nil }
        let times = run.map { stamps[$0]! }
        let xs = run.map { filled[$0]!.x }, ys = run.map { filled[$0]!.y }
        let x = boundedSmooth(xs, times: times, config: config)
        let y = boundedSmooth(ys, times: times, config: config)
        let delta = index > 0 ? Double(times[index] - times[index - 1]) : 0
        // This slope belongs to the actual observed interval. A central slope
        // can cancel the descent and rebound when only a few samples span both.
        let velocity = delta > 0 ? (y[index] - y[index - 1]) / (delta / 1000) : 0
        let motion: MotionState = velocity > config.velocityThreshold ? .falling
            : velocity < -config.velocityThreshold ? .rising : .unknown
        let realInterval = index > 0 && observed[frame] != nil && observed[run[index - 1]] != nil
        let agrees = index > 0 && (motion == .falling ? ys[index] > ys[index - 1]
            : motion == .rising ? ys[index] < ys[index - 1] : false)
        // Interpolated detector gaps cannot supply time evidence. Cap credit so
        // an irregular long interval cannot stand in for an entire motion run.
        let evidence = realInterval && agrees && delta <= Double(config.maxGapDurationMs)
            ? min(delta, 2 * referenceIntervalMs) : 0
        return .init(frameIndex: frame, timestampMs: times[index], x: x[index], y: y[index],
                     vy: velocity, confidence: filled[frame]!.confidence, valid: true,
                     motion: motion, motionEvidenceMs: evidence)
    }

    private static func boundedSmooth(_ values: [Double], times: [Int], config: CounterConfig) -> [Double] {
        func stage(_ input: [Double], window: Int, median: Bool) -> [Double] {
            guard window > 1, input.count >= window else { return input }
            let half = window / 2
            let radius = Double(half) * referenceIntervalMs + 2
            return input.indices.map { i in
                // A partial/asymmetric window can shift the apparent impact.
                // Keep the observed point when there is too little nearby data.
                guard i >= half, i + half < input.count,
                      Double(times[i] - times[i - half]) <= radius,
                      Double(times[i + half] - times[i]) <= radius else { return input[i] }
                let values = Array(input[(i - half)...(i + half)])
                return median ? values.sorted()[values.count / 2] : values.reduce(0, +) / Double(values.count)
            }
        }
        return stage(stage(values, window: config.medianWindow, median: true),
                     window: config.smoothingWindow, median: false)
    }
}
