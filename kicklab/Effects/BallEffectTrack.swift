import Foundation
import CoreGraphics

/// Indexed, deterministic sampling shared by replay and export. Interpolate only
/// brief gaps; never leave an invented ball hanging through an occlusion.
nonisolated struct BallEffectTrack: Sendable {
    private(set) var samples: [BallStyleSample]
    private var segmentStarts: [Double]
    private var masks: [BallMask?]
    private var maskTimes: [Double]
    private let touchTimes: [Double]
    /// Unsmoothed detector boxes of `samples`, normalized. Their stretch along the
    /// motion measures the camera's exposure; smoothing would hide it.
    private var rawBoxes: [CGSize] = []
    private var recoverySamples: [Bool] = []
    private let exposureCache = BallExposureCache()
    var surfaceMotion: BallSurfaceTimeline? = nil
    let usesBallMasks: Bool
    static let maximumGap = 0.12

    init(frames: [RecordedFrame], touchTimes: [Double] = []) {
        self.touchTimes = touchTimes.filter { $0.isFinite && $0 >= 0 }.sorted()
        let masked = frames.filter { $0.detected && $0.score.isFinite && $0.score >= 0.05
            && $0.time.isFinite && $0.x.isFinite && $0.y.isFinite
            && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }
            .sorted { $0.time < $1.time }
        maskTimes = masked.map(\.time)
        masks = masked.map(\.ballMask)
        // Repaired mattes must not perturb sizing, trails or source-spin fitting.
        let valid = masked.filter { !$0.isVisualMaskRepair }
        samples = valid.map(BallStyleSample.init(frame:))
        rawBoxes = valid.map { CGSize(width: $0.width, height: $0.height) }
        recoverySamples = valid.map(\.isVisualRecovery)
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

    /// Events share the source video clock, including after a backward seek.
    func latestTouch(at time: Double) -> Double? {
        guard time.isFinite else { return nil }
        var lo = 0, hi = touchTimes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if touchTimes[mid] <= time { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? touchTimes[lo - 1] : nil
    }

    /// Allow only timestamp rounding, never reuse a silhouette through a gap.
    func mask(at time: Double) -> BallMask? {
        guard usesBallMasks, time.isFinite else { return nil }
        var lo=0,hi=maskTimes.count
        while lo<hi {let mid=(lo+hi)/2;if maskTimes[mid]<time {lo=mid+1} else {hi=mid}}
        let candidates = [lo-1, lo].filter { maskTimes.indices.contains($0) }
        guard let nearest = candidates.min(by: { abs(maskTimes[$0]-time) < abs(maskTimes[$1]-time) }),
              abs(maskTimes[nearest]-time) < 0.003 else { return nil }
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
        // Recovery times use the existing millisecond archive clock. Honor the
        // same fresh observation just after its rounded time, including at a
        // segment endpoint. Do not change sampling of the original track.
        if index > 0, recoverySamples[index-1], time-samples[index-1].time < 0.001 {
            return replacementObservation(at:index-1)
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

    /// Photographed motion smear at `time`, in source pixels: velocity × exposure.
    /// Exposure is estimated once per clip from how much detector boxes stretch
    /// along the motion. A sharply photographed fast ball yields zero exposure,
    /// so speed alone never adds blur. Deterministic for replay and export.
    func smear(at time: Double, size: CGSize) -> CGVector {
        guard time.isFinite, size.width > 0, size.height > 0, samples.count >= 3 else { return .zero }
        let exposure = exposure(size: size)
        guard exposure > 0, let v = velocity(at: time, size: size) else { return .zero }
        var s = CGVector(dx: v.dx*exposure, dy: v.dy*exposure)
        let i = min(samples.count-1, max(0, insertionIndex(time)))
        let box = rawBoxes[i], limit = 1.5*max(box.width*size.width, box.height*size.height)
        let length = hypot(s.dx, s.dy)
        if length > limit { s = CGVector(dx: s.dx/length*limit, dy: s.dy/length*limit) }
        return s
    }

    /// Source pixels per second from the nearest observations on each side, within one segment.
    private func velocity(at time: Double, size: CGSize) -> CGVector? {
        var index = insertionIndex(time)
        if index < samples.count, abs(samples[index].time-time) < 0.001 {
            let a = index > 0 ? index-1 : index, b = index+1 < samples.count ? index+1 : index
            return velocity(a, b, size: size)
        }
        index = max(1, min(samples.count-1, index))
        return velocity(index-1, index, size: size)
    }

    private func velocity(_ a: Int, _ b: Int, size: CGSize) -> CGVector? {
        guard a != b, segmentStarts[a] == segmentStarts[b] else { return nil }
        let dt = samples[b].time-samples[a].time
        guard dt > 0, dt <= 0.1 else { return nil }
        return CGVector(dx: (samples[b].center.x-samples[a].center.x)*size.width/dt,
                        dy: (samples[b].center.y-samples[a].center.y)*size.height/dt)
    }

    /// Seconds. Least squares of box stretch against speed through the origin, using
    /// interior observations away from the frame edge; zero when unsupported.
    func exposure(size: CGSize) -> Double {
        // The observations are immutable. Re-fitting the entire clip on every
        // rendered frame made long replays/export quadratic in clip length.
        exposureCache.value(size: size) { calculateExposure(size: size) }
    }

    private func calculateExposure(size: CGSize) -> Double {
        var num = 0.0, den = 0.0, used = 0, intervals = [Double]()
        for i in samples.indices.dropFirst().dropLast() {
            let dtA = samples[i].time-samples[i-1].time, dtB = samples[i+1].time-samples[i].time
            guard dtA > 0, dtB > 0, dtA <= 0.05, dtB <= 0.05,
                  segmentStarts[i-1] == segmentStarts[i], segmentStarts[i+1] == segmentStarts[i] else { continue }
            intervals.append(dtB)
            let c = samples[i].center, box = rawBoxes[i]
            guard c.x-box.width/2 > 0.005, c.y-box.height/2 > 0.005,
                  c.x+box.width/2 < 0.995, c.y+box.height/2 < 0.995,
                  let v = velocity(i-1, i+1, size: size) else { continue }
            let speed = hypot(v.dx, v.dy)
            guard speed > 1e-6 else { continue }
            let w = box.width*size.width, h = box.height*size.height
            let ux = abs(v.dx)/speed, uy = abs(v.dy)/speed
            // An axis-aligned box lengthens by (|ux|-|uy|)^2 × smear: a diagonal
            // smear leaves the box square, so diagonal motion carries no evidence.
            let stretch = (ux*w+uy*h)-(uy*w+ux*h), d = min(w, h)
            guard stretch > -0.3*d, stretch < 1.5*d else { continue }
            let predictor = speed*(ux-uy)*(ux-uy)
            num += predictor*stretch; den += predictor*predictor; used += 1
        }
        guard used >= 20, den > 0, !intervals.isEmpty else { return 0 }
        let frame = intervals.sorted()[intervals.count/2]
        return min(max(0, num/den), 0.9*frame)
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

/// Copies of a track may render on different queues. Cache exact canvas sizes,
/// retaining the original floating-point calculation and at most four results.
private nonisolated final class BallExposureCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(CGSize, Double)] = []
    func value(size: CGSize, calculate: () -> Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        if let found = entries.first(where: { $0.0 == size }) { return found.1 }
        let result = calculate()
        if entries.count == 4 { entries.removeFirst() }
        entries.append((size, result))
        return result
    }
}
