import Foundation
import CoreGraphics

/// Indexed, deterministic sampling shared by replay and export. Interpolate only
/// brief gaps; never leave an invented ball hanging through an occlusion.
nonisolated struct BallEffectTrack: Sendable {
    private(set) var samples: [BallStyleSample]
    private var segmentStarts: [Double]
    private var masks: [BallMask?]
    let usesBallMasks: Bool
    static let maximumGap = 0.12

    init(frames: [RecordedFrame]) {
        let valid = frames.filter { $0.detected && $0.score.isFinite && $0.score >= 0.05
            && $0.time.isFinite && $0.x.isFinite && $0.y.isFinite
            && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }
            .sorted { $0.time < $1.time }
        samples = valid.map(BallStyleSample.init(frame:))
        masks = valid.map(\.ballMask)
        usesBallMasks = frames.contains(where: \.usesBallMasks)
        segmentStarts = []
        for i in valid.indices {
            let startsNew = i == 0 || valid[i].time - valid[i - 1].time > Self.maximumGap
                || hypot(valid[i].x - valid[i - 1].x, valid[i].y - valid[i - 1].y) >= 0.3
            segmentStarts.append(startsNew ? valid[i].time : segmentStarts[i - 1])
        }
        // Stabilize diameter only. Smoothing the centre delays the effect at kicks.
        for i in samples.indices {
            let neighbors = (max(0, i - 2)...min(valid.count - 1, i + 2))
                .filter { segmentStarts[$0] == segmentStarts[i] && abs(valid[$0].time - valid[i].time) < 0.09 }
                .map { valid[$0] }
            let widths = neighbors.map(\.width).sorted()
            let heights = neighbors.map(\.height).sorted()
            if !widths.isEmpty {
                samples[i].boxSize = CGSize(width: widths[widths.count / 2], height: heights[heights.count / 2])
            }
        }
    }

    private func insertionIndex(_ time: Double) -> Int {
        var lo = 0, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].time < time { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Allow only timestamp rounding, never reuse a silhouette through a gap.
    func mask(at time: Double) -> BallMask? {
        guard usesBallMasks, time.isFinite else { return nil }
        let i = insertionIndex(time)
        let candidates = [i-1, i].filter { samples.indices.contains($0) }
        guard let nearest = candidates.min(by: { abs(samples[$0].time-time) < abs(samples[$1].time-time) }),
              abs(samples[nearest].time-time) < 0.003 else { return nil }
        return masks[nearest]
    }

    func sample(at time: Double) -> BallStyleSample? {
        guard time.isFinite, let first = samples.first, time >= first.time else { return nil }
        let index = insertionIndex(time)
        if index < samples.count, abs(samples[index].time - time) < 0.001 { return samples[index] }
        if index > 0, index < samples.count {
            let a = samples[index - 1], b = samples[index]
            let gap = b.time - a.time
            let jump = hypot(b.center.x - a.center.x, b.center.y - a.center.y)
            if gap > 0, gap <= Self.maximumGap, jump < 0.3 {
                let f = (time - a.time) / gap
                var result = a
                result.center = CGPoint(x: a.center.x + (b.center.x - a.center.x) * f,
                                        y: a.center.y + (b.center.y - a.center.y) * f)
                if let sa = a.boxSize, let sb = b.boxSize {
                    result.boxSize = CGSize(width: sa.width + (sb.width - sa.width) * f,
                                            height: sa.height + (sb.height - sa.height) * f)
                }
                result.time = time
                return result
            }
        }
        // Up to one frame of endpoint tolerance, with a quick fade to nothing.
        let nearest = samples[min(samples.count - 1, index == 0 ? 0 : index - 1)]
        let distance = abs(nearest.time - time)
        guard distance < 0.05 else { return nil }
        var result = nearest
        result.confidence = min(0.05, nearest.confidence) * (1 - distance / 0.05)
        return result
    }

    /// Search seed for opaque replacement, never a confirmed silhouette.
    /// Current-frame pixel support is required before drawing. Effects/counts
    /// keep the original observations and their existing gap policy.
    func replacementGuide(at time: Double) -> BallStyleSample? {
        guard time.isFinite, let first=samples.first, time >= first.time else { return nil }
        let index=insertionIndex(time)
        if index < samples.count, abs(samples[index].time-time) < 0.001 {
            return replacementObservation(at:index)
        }
        guard index > 0, index < samples.count else { return nil }
        let a=replacementObservation(at:index-1), b=replacementObservation(at:index)
        let gap=b.time-a.time
        guard gap > 0, gap <= 0.20, let sa=a.boxSize, let sb=b.boxSize,
              sa.width > 0, sa.height > 0, sb.width > 0, sb.height > 0,
              hypot(b.center.x-a.center.x,b.center.y-a.center.y) < 0.3 else { return nil }
        if gap > Self.maximumGap {
            guard max(sa.width/sb.width,sb.width/sa.width) < 1.4,
                  max(sa.height/sb.height,sb.height/sa.height) < 1.4,
                  hypot((b.center.x-a.center.x)/max(sa.width,sb.width),
                        (b.center.y-a.center.y)/max(sa.height,sb.height)) < 1.5 else { return nil }
        }
        let fraction=(time-a.time)/gap
        var guide=a
        guide.center=CGPoint(x:a.center.x+(b.center.x-a.center.x)*fraction,
                             y:a.center.y+(b.center.y-a.center.y)*fraction)
        guide.boxSize=CGSize(width:sa.width+(sb.width-sa.width)*fraction,
                            height:sa.height+(sb.height-sa.height)*fraction)
        guide.time=time
        guide.confidence=min(a.confidence,b.confidence)
        return guide
    }

    private func replacementObservation(at index: Int) -> BallStyleSample {
        var sample=samples[index]
        guard index > 0, index+1 < samples.count, let box=sample.boxSize,
              box.width > 0, box.height > 0 else { return sample }
        let before=samples[index-1], after=samples[index+1]
        let dt=after.time-before.time
        // Correct only an isolated discontinuity with agreeing neighbors.
        // Normal movement, including rapid touches, stays at the recorded centre.
        guard dt > 0, dt <= 0.09,
              hypot((after.center.x-before.center.x)/box.width,
                    (after.center.y-before.center.y)/box.height) < 0.6 else { return sample }
        let f=(sample.time-before.time)/dt
        let expected=CGPoint(x:before.center.x+(after.center.x-before.center.x)*f,
                             y:before.center.y+(after.center.y-before.center.y)*f)
        if hypot((sample.center.x-expected.x)/box.width,
                 (sample.center.y-expected.y)/box.height) > 0.3 {
            sample.center=expected
        }
        return sample
    }

    func trail(at time: Double, duration: Double = 0.42) -> [BallStyleSample] {
        guard time.isFinite, duration.isFinite, duration >= 0, sample(at: time) != nil else { return [] }
        let insertion = insertionIndex(time)
        let index = insertion < samples.count && abs(samples[insertion].time - time) < 0.001
            ? insertion : max(0, insertion - 1)
        // Reacquisition starts a fresh trail. Older detections must not produce
        // a streak or inferred velocity between separate tracking segments.
        let start = max(0, time - duration, segmentStarts[index])
        // Fixed time spacing keeps 30/60 fps recordings visually identical.
        return stride(from: start, through: time, by: 1.0 / 60).compactMap { t in
            guard var sample = sample(at: t) else { return nil }
            sample.time = t
            return sample
        }
    }
}
