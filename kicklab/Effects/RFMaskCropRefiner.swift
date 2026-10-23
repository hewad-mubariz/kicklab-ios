import AVFoundation
import Foundation

/// A bounded second look at weak silhouettes, using the same RF model on a
/// current-frame crop. This returns an appearance sidecar, never counter input.
nonisolated enum RFMaskCropRefiner {
    static let signature = "|rf-mask-crop-consensus-v3-long-gaps"
    // Count model calls, not just frames: agreement can need three contexts.
    static func modelCallBudget(frameCount: Int) -> Int {
        min(240, max(24, Int(ceil(Double(frameCount) * 0.4))))
    }
    struct Request {
        let time: Double
        let guide: RecordedFrame
        let index: Int?
        var requiresConsensus = false
        var minimumCalls: Int { requiresConsensus ? 2 : 1 }
    }

    static func area(_ mask: BallMask) -> Double {
        guard mask.width > 0, mask.height > 0 else { return 0 }
        return Double(mask.alphaSum) / 255
            / Double(mask.width * mask.height) * mask.rect.width * mask.rect.height
    }

    static func requests(frames: [RecordedFrame], frameDuration: Double) -> [Request] {
        // Missing silhouettes need two original observations. Flow repairs and
        // crop repairs never become anchors for another recovery.
        let occupied = frames.filter { $0.ballMask != nil }.map(\.time).sorted()
        func hasMask(at time: Double) -> Bool {
            var low = 0, high = occupied.count
            while low < high {
                let mid = (low + high) / 2
                if occupied[mid] < time { low = mid + 1 } else { high = mid }
            }
            return [low - 1, low].contains { occupied.indices.contains($0) && abs(occupied[$0] - time) < 0.003 }
        }
        let short = BallMaskGapRefiner.requests(frames: frames, frameDuration: frameDuration).compactMap { gap -> Request? in
            guard !hasMask(at: gap.time) else { return nil }
            let a = gap.before, b = gap.after, f = gap.fraction
            func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * f }
            let guide = RecordedFrame(time: gap.time, x: mix(a.x, b.x), y: mix(a.y, b.y),
                width: mix(a.width, b.width), height: mix(a.height, b.height), score: min(a.score, b.score),
                smoothedX: mix(a.smoothedX, b.smoothedX), smoothedY: mix(a.smoothedY, b.smoothedY),
                vy: 0, motion: .unknown, detected: true, person: nil,
                usesBallMasks: true, isVisualMaskRepair: true)
            return Request(time: gap.time, guide: guide, index: nil)
        }
        let gaps = (short + longGaps(frames: frames, frameDuration: frameDuration).filter { !hasMask(at: $0.time) })
            .sorted { $0.time < $1.time }
        let areas = frames.map { $0.ballMask.map(area) ?? 0 }
        var unstable = [Request]()
        let weak = frames.enumerated().compactMap { index, frame -> Request? in
            guard frame.detected, !frame.isVisualRecovery, !frame.isVisualMaskRepair,
                  frame.score >= 0.4, frame.time.isFinite, frame.width > 0, frame.height > 0,
                  let mask = frame.ballMask else { return nil }
            let fraction = area(mask) / (frame.width * frame.height)
            // Box and mask can shrink together, hiding a fragment from a mask/box
            // ratio. Nearby ORIGINAL observations only nominate a retry; they
            // never supply pixels or prove that the current ball is unoccluded.
            let neighbors = max(0, index - 4)...min(frames.count - 1, index + 4)
            let reference = neighbors.filter { other in
                let f = frames[other]
                return other != index && f.detected && !f.isVisualRecovery && !f.isVisualMaskRepair
                    && abs(f.time - frame.time) <= 0.10
                    && hypot((f.x - frame.x) / frame.width, (f.y - frame.y) / frame.height) < 2
            }.map { areas[$0] }.sorted()
            // Two larger nearby observations avoid responding to one anomalous
            // box, while still finding several consecutive fragmented masks.
            let typical = reference.count < 2 ? areas[index] : reference[reference.count - 2]
            let request = Request(time: frame.time, guide: frame, index: index)
            if fraction >= 0.5, areas[index] < typical * 0.8 {
                unstable.append(Request(time: frame.time, guide: frame, index: index, requiresConsensus: true))
                return nil
            }
            guard (0.5...0.76).contains(fraction) else { return nil }
            return request
        }
        let budget = modelCallBudget(frameCount: frames.count)
        // Spread optional work over the recording instead of exhausting the
        // entire budget in its first seconds. Missing masks have priority.
        func spread(_ values: [Request], limit: Int) -> [Request] {
            guard limit > 0 else { return [] }
            guard values.count > limit else { return values }
            return (0..<limit).map { values[$0 * values.count / limit] }
        }
        let missing = spread(gaps, limit: budget)
        let fragments = spread(unstable, limit: (budget - missing.count) / 2)
        return (missing + fragments + spread(weak, limit: budget - missing.count - fragments.count * 2))
            .sorted { $0.time < $1.time }
    }

    /// Gaps too long for flow repair (more than `BallMaskGapRefiner.maximumMissingFrames`)
    /// but at most `BallEffectTrack.maximumRepairedGap`. A white ball in front of a
    /// white shirt can stay unseen by the full frame for 5–12 frames while a zoomed
    /// crop of the same pixels still finds it. Seeds follow a cubic Hermite curve
    /// through both observations with their own velocities, closer to a ball's arc
    /// than a straight line; only current-frame crop evidence becomes a mask.
    static func longGaps(frames: [RecordedFrame], frameDuration: Double) -> [Request] {
        guard frameDuration.isFinite, frameDuration > 0, frameDuration <= 1.0 / 24 else { return [] }
        let original = frames.filter { f in
            f.detected && !f.isVisualMaskRepair && !f.isVisualRecovery && f.ballMask != nil
                && [f.time, f.x, f.y, f.width, f.height].allSatisfy(\.isFinite) && f.width > 0 && f.height > 0
        }.sorted { $0.time < $1.time }
        guard original.count >= 2 else { return [] }
        var result = [Request]()
        for i in 0..<(original.count - 1) {
            let a = original[i], b = original[i + 1], gap = b.time - a.time
            let missing = Int((gap / frameDuration).rounded()) - 1
            guard missing > BallMaskGapRefiner.maximumMissingFrames, gap <= BallEffectTrack.maximumRepairedGap,
                  abs(gap - Double(missing + 1) * frameDuration) < 0.0025 * Double(missing + 1),
                  a.score >= 0.4, b.score >= 0.4,
                  max(a.width / b.width, b.width / a.width, a.height / b.height, b.height / a.height) < 1.5 else { continue }
            func velocity(_ p: RecordedFrame?, _ q: RecordedFrame?) -> (x: Double, y: Double)? {
                guard let p, let q, q.time > p.time, q.time - p.time <= 0.06 else { return nil }
                return ((q.x - p.x) / (q.time - p.time), (q.y - p.y) / (q.time - p.time))
            }
            let chord = (x: (b.x - a.x) / gap, y: (b.y - a.y) / gap)
            let va = velocity(i > 0 ? original[i - 1] : nil, a) ?? chord
            let vb = velocity(b, i + 2 < original.count ? original[i + 2] : nil) ?? chord
            for k in 1...missing {
                let s = Double(k) / Double(missing + 1), s2 = s * s, s3 = s2 * s
                let x = (2 * s3 - 3 * s2 + 1) * a.x + (s3 - 2 * s2 + s) * gap * va.x + (3 * s2 - 2 * s3) * b.x + (s3 - s2) * gap * vb.x
                let y = (2 * s3 - 3 * s2 + 1) * a.y + (s3 - 2 * s2 + s) * gap * va.y + (3 * s2 - 2 * s3) * b.y + (s3 - s2) * gap * vb.y
                let guide = RecordedFrame(time: a.time + gap * s, x: x, y: y,
                    width: a.width + (b.width - a.width) * s, height: a.height + (b.height - a.height) * s,
                    score: min(a.score, b.score), smoothedX: x, smoothedY: y, vy: 0, motion: .unknown,
                    detected: true, person: nil, usesBallMasks: true, isVisualMaskRepair: true)
                result.append(Request(time: guide.time, guide: guide, index: nil))
            }
        }
        return result
    }

    static func region(_ request: Request, size: CGSize, context: Double = 3.5) -> CGRect? {
        let f = request.guide
        let diameter = max(f.width * size.width, f.height * size.height)
        guard [f.x, f.y, diameter].allSatisfy(\.isFinite), diameter >= 12,
              diameter < min(size.width, size.height) * 0.3 else { return nil }
        let side = max(128, diameter * context)
        let roi = CGRect(x: f.x * size.width - side / 2, y: f.y * size.height - side / 2,
                         width: side, height: side).integral.intersection(CGRect(origin: .zero, size: size))
        return roi.isEmpty || roi.isNull ? nil : roi
    }

    static func refine(source: URL, frames: [RecordedFrame],
                       onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> [RecordedFrame] {
        try await VideoAnalysisScheduler.shared.perform {
            try await compute(source: source, frames: frames, onProgress: onProgress)
        }
    }

    private static func compute(source: URL, frames: [RecordedFrame],
                                onProgress: (@Sendable (Double) -> Void)?) async throws -> [RecordedFrame] {
        try Task.checkCancellation()
        guard RFSmallModel(rawValue: BallDetector.configuredResourceName) != nil,
              frames.contains(where: { $0.ballMask != nil }) else { onProgress?(1); return frames }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { return frames }
        let composition = try await EffectVideoGeometry.composition(track: video, duration: asset.load(.duration), shortEdge: 720)
        let pending = requests(frames: frames, frameDuration: composition.frameDuration.seconds)
        guard !pending.isEmpty else { onProgress?(1); return frames }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings:
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = composition; output.alwaysCopiesSampleData = false; reader.add(output)
        guard reader.startReading() else { throw reader.error ?? VideoSafetyPolicy.Failure.analysis }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var detector: BallDetector?
        var result = frames, next = 0, failures = 0, attempted = 0
        let callBudget = modelCallBudget(frameCount: frames.count)
        var acceptedTimes: [Double] = []
        var pacer = VideoAnalysisPacer()
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            #if DEBUG
            let report: [String: Any] = ["source": source.lastPathComponent, "requests": pending.count,
                "attempted": attempted, "model_call_budget": callBudget, "accepted_times": acceptedTimes, "failures": failures,
                "elapsed_seconds": ProcessInfo.processInfo.systemUptime - started,
                "input_frames": frames.count, "output_frames": result.count, "signature": signature]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL.documentsDirectory.appendingPathComponent("rf-mask-crop-last.json"), options: .atomic)
            }
            #endif
        }
        while next < pending.count {
            try await VideoWorkExecution.checkpoint(requiresGPU: true)
            guard let sample = output.copyNextSampleBuffer() else { break }
            let time = sample.presentationTimeStamp.seconds
            while next < pending.count, pending[next].time < time - 0.003 { next += 1 }
            guard next < pending.count else { break }
            guard abs(pending[next].time - time) < 0.003, let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let request = pending[next]
            next += 1; onProgress?(Double(next) / Double(pending.count))
            let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
            guard region(request, size: size) != nil else { continue }
            do {
                if detector == nil { detector = try BallDetector() }
                var candidates = [RFMaskCropConsensus.Candidate]()
                var repair: BallMask?
                var visited = [CGRect]()
                for context in RFMaskCropConsensus.contexts {
                    // Reserve enough looks for every remaining planned frame,
                    // including both contexts for mandatory consensus. Extra
                    // contexts cannot consume the tail of a long recording.
                    let reserved = pending.dropFirst(next).reduce(0) { $0 + $1.minimumCalls }
                    guard attempted < callBudget - reserved,
                          let roi = region(request, size: size, context: context),
                          !visited.contains(roi) else { continue }
                    // Two identical clipped crops are not independent contexts.
                    visited.append(roi)
                    let started = try await pacer.beginFrame { _ in }
                    attempted += 1
                    let found = try autoreleasepool { try detector!.inferRFMaskCrop(pixels, roi: roi) }
                    try await pacer.finishFrame(started: started)
                    if let candidate = RFMaskCropConsensus.candidate(found, guide: request.guide, roi: roi, size: size) {
                        candidates.append(candidate)
                        if visited.count == 1, !request.requiresConsensus,
                           let mask = RFMaskCropConsensus.conservativeAddition(candidate, guide: request.guide) {
                            repair = mask; break
                        }
                    }
                    if let mask = RFMaskCropConsensus.accepted(candidates, guide: request.guide) {
                        repair = mask; break
                    }
                }
                guard let mask = repair else { continue }
                acceptedTimes.append(time)
                if let index = request.index { result[index].ballMask = mask }
                else {
                    let f = request.guide
                    result.append(RecordedFrame(time: time, x: f.x, y: f.y, width: f.width, height: f.height,
                        score: f.score, smoothedX: f.smoothedX, smoothedY: f.smoothedY, vy: f.vy,
                        motion: f.motion, detected: true, person: nil, ballMask: mask,
                        usesBallMasks: true, isVisualMaskRepair: true))
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                // Optional appearance work must not destroy a usable replay.
                failures += 1
                if failures >= 3 { break }
            }
        }
        if reader.status == .failed { throw reader.error ?? VideoSafetyPolicy.Failure.analysis }
        try Task.checkCancellation()
        onProgress?(1)
        return result.sorted { $0.time < $1.time }
    }
}
