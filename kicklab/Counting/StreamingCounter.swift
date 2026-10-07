//
//  StreamingCounter.swift
//  kicklab
//
//  Counting from a live camera, where the future does not exist yet.
//
//  Three stages of the trajectory each read one frame ahead: the median filter,
//  the moving average, and the central-difference velocity. Holding every frame
//  back by three before judging it gives them exactly what they had offline.
//  Measured in the lab across eight hand-counted clips, three frames reproduces
//  the offline count *identically* on every clip, while zero lookahead costs 12
//  touches. Three frames is 100ms at 30fps - invisible in a number that ticks up.
//
//  Ported from kicklab-lab's analysis/streaming.py. Keep them in step.
//

import Foundation

struct BallObservation {
    var frameIndex: Int
    var timestampMs: Int
    var x, y, width, height: Double
    var confidence: Double
}

final class StreamingCounter {
    private let config: CounterConfig
    private let machine: TouchStateMachine

    private var stamps: [Int: Int] = [:]
    private var balls: [Int: BallObservation] = [:]
    private var cameraOffsets: [Int: Double] = [:]
    private var latest: Int?
    private var next: Int?

    /// Frames of past context kept for smoothing and gap interpolation. Must
    /// comfortably exceed `maxGapFrames` plus the smoothing windows, or a gap
    /// spanning the buffer edge would be filled differently than the lab fills it.
    private let history = 64

    var count: Int { machine.count }
    /// Events in original video coordinates, suitable for replay/effects.
    private(set) var touches: [Touch] = []
    /// The most recently judged point - smoothed position, velocity and motion
    /// state. The annotated replay shows these, the way the Python renderer does.
    private(set) var lastPoint: TrajectoryPoint?

    init(config: CounterConfig = CounterConfig(), rejectsHandContact: ((Int) -> Bool)? = nil) {
        self.config = config
        self.machine = TouchStateMachine(config: config)
        self.machine.rejectsHandContact = rejectsHandContact
    }

    /// Feed one frame. Returns touches confirmed by frames now leaving the window.
    ///
    /// `ball` is nil for a frame where the detector found nothing - which is
    /// information, not an absence: enough of them in a row abandons the arc
    /// rather than inventing a reversal across the hole.
    @discardableResult
    func push(frameIndex: Int, timestampMs: Int,
              ball: BallObservation?, person: PersonBox?,
              cameraOffsetY: Double = 0, reliable: Bool = true) -> [Touch] {
        guard reliable, cameraOffsetY.isFinite else {
            breakContinuity()
            return []
        }
        if let last = latest, let stamp = stamps[last],
           frameIndex != last + 1 || timestampMs <= stamp || timestampMs - stamp > config.maxGapDurationMs {
            breakContinuity()
        }
        stamps[frameIndex] = timestampMs
        cameraOffsets[frameIndex] = cameraOffsetY
        if var ball {
            ball.y += cameraOffsetY
            balls[frameIndex] = ball
            machine.detectedFrames.insert(frameIndex)
        }
        if var person {
            person.y += cameraOffsetY
            machine.personBoxes[frameIndex] = person
        }
        latest = frameIndex
        if next == nil { next = frameIndex }

        var emitted: [Touch] = []
        while let n = next, n + config.lookahead <= frameIndex {
            if let touch = judge(n) { emitted.append(touch) }
            next = n + 1
            trim()
        }
        return emitted
    }

    /// Judge the frames still held in the lookahead window. Call once, at the end.
    @discardableResult
    func flush() -> [Touch] {
        var emitted: [Touch] = []
        guard let last = latest else { return emitted }
        while let n = next, n <= last {
            if let touch = judge(n) { emitted.append(touch) }
            next = n + 1
        }
        return emitted
    }

    private func judge(_ frame: Int) -> Touch? {
        guard let point = point(for: frame) else { return nil }
        lastPoint = point
        guard var touch = machine.push(point) else { return nil }
        touch.y -= cameraOffsets[touch.frameIndex] ?? 0
        touches.append(touch)
        return touch
    }

    private func breakContinuity() {
        machine.discardPendingArc()
        machine.personBoxes.removeAll(keepingCapacity: true)
        machine.detectedFrames.removeAll(keepingCapacity: true)
        stamps.removeAll(keepingCapacity: true)
        balls.removeAll(keepingCapacity: true)
        cameraOffsets.removeAll(keepingCapacity: true)
        latest = nil
        next = nil
        lastPoint = nil
    }

    /// Smooth `frame` using only what a live system would hold by now.
    ///
    /// The window is rebuilt rather than updated incrementally: wasteful, and
    /// much harder to get subtly wrong. An incremental version that quietly
    /// disagreed with the lab would be near-impossible to diagnose on a phone.
    private func point(for frame: Int) -> TrajectoryPoint? {
        let low = frame - history
        let high = frame + config.lookahead
        guard stamps[frame] != nil else { return nil }

        let frames = (low...high).filter { stamps[$0] != nil }
        guard !frames.isEmpty else { return nil }

        // Fill short holes between real detections, exactly as the lab does.
        var filled: [Int: BallObservation] = [:]
        let seen = frames.filter { balls[$0] != nil }
        guard !seen.isEmpty else { return nil }
        for f in seen { filled[f] = balls[f] }
        for (a, b) in zip(seen, seen.dropFirst()) {
            let gap = b - a - 1
            guard gap > 0, gap <= config.maxGapFrames, let s = balls[a], let e = balls[b],
                  e.timestampMs > s.timestampMs,
                  e.timestampMs - s.timestampMs <= config.maxGapDurationMs else {
                continue
            }
            for step in 1...gap {
                guard let stamp = stamps[a + step] else { continue }
                let t = Double(stamp - s.timestampMs) / Double(e.timestampMs - s.timestampMs)
                filled[a + step] = BallObservation(
                    frameIndex: a + step,
                    timestampMs: stamps[a + step] ?? s.timestampMs,
                    x: s.x + (e.x - s.x) * t,
                    y: s.y + (e.y - s.y) * t,
                    width: s.width + (e.width - s.width) * t,
                    height: s.height + (e.height - s.height) * t,
                    confidence: min(s.confidence, e.confidence))
            }
        }

        // Smooth within the contiguous run containing `frame`, never across a
        // hole: values carried over a gap are inventions.
        let run = contiguousRun(containing: frame, in: filled)
        guard run.contains(frame), let index = run.firstIndex(of: frame) else {
            return TrajectoryPoint(frameIndex: frame, timestampMs: stamps[frame]!,
                                   x: 0, y: 0, vy: 0, confidence: 0,
                                   valid: false, motion: .unknown)
        }

        let ys = run.map { filled[$0]!.y }
        let xs = run.map { filled[$0]!.x }
        let smoothedY = movingAverage(medianFilter(ys, config.medianWindow), config.smoothingWindow)
        let smoothedX = movingAverage(medianFilter(xs, config.medianWindow), config.smoothingWindow)

        let vy = centralVelocity(smoothedY, at: index, frames: run, stamps: stamps)
        let motion: MotionState = vy > config.velocityThreshold ? .falling
            : (vy < -config.velocityThreshold ? .rising : .unknown)

        return TrajectoryPoint(frameIndex: frame, timestampMs: stamps[frame]!,
                               x: smoothedX[index], y: smoothedY[index], vy: vy,
                               confidence: filled[frame]!.confidence,
                               valid: true, motion: motion)
    }

    private func contiguousRun(containing frame: Int,
                               in filled: [Int: BallObservation]) -> [Int] {
        guard filled[frame] != nil else { return [] }
        var lo = frame, hi = frame
        while filled[lo - 1] != nil { lo -= 1 }
        while filled[hi + 1] != nil { hi += 1 }
        return Array(lo...hi)
    }

    private func trim() {
        guard let n = next else { return }
        let cutoff = n - history - 1
        guard cutoff > 0 else { return }
        stamps = stamps.filter { $0.key >= cutoff }
        balls = balls.filter { $0.key >= cutoff }
        cameraOffsets = cameraOffsets.filter { $0.key >= cutoff }
        machine.personBoxes = machine.personBoxes.filter { $0.key >= cutoff }
        machine.detectedFrames = machine.detectedFrames.filter { $0 >= cutoff }
    }
}

// MARK: - Filters
//
// Centred and clamped at the edges, matching trajectory.py. A one-sided filter
// would be genuinely causal and need no lookahead, but it lags the signal and
// shifts every reversal later - which moves the apex the counter keys on.

func medianFilter(_ values: [Double], _ window: Int) -> [Double] {
    guard window > 1, values.count >= 3 else { return values }
    let half = window / 2
    return values.indices.map { i in
        let lo = max(0, i - half), hi = min(values.count - 1, i + half)
        let chunk = values[lo...hi].sorted()
        return chunk[chunk.count / 2]
    }
}

func movingAverage(_ values: [Double], _ window: Int) -> [Double] {
    guard window > 1, values.count >= 3 else { return values }
    let half = window / 2
    return values.indices.map { i in
        let lo = max(0, i - half), hi = min(values.count - 1, i + half)
        let chunk = values[lo...hi]
        return chunk.reduce(0, +) / Double(chunk.count)
    }
}

/// Central-difference vertical velocity, in frame-heights per second.
func centralVelocity(_ ys: [Double], at index: Int, frames: [Int],
                     stamps: [Int: Int]) -> Double {
    let lo = index > 0 ? index - 1 : index
    let hi = index < ys.count - 1 ? index + 1 : index
    guard lo != hi,
          let t0 = stamps[frames[lo]], let t1 = stamps[frames[hi]], t1 != t0 else { return 0 }
    return (ys[hi] - ys[lo]) / (Double(t1 - t0) / 1000.0)
}
