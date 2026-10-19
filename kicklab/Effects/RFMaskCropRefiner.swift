import AVFoundation
import Foundation

/// A bounded second look at weak silhouettes, using the same RF model on a
/// current-frame crop. This returns an appearance sidecar, never counter input.
nonisolated enum RFMaskCropRefiner {
    static let signature = "|rf-mask-crop-v1"
    struct Request {
        let time: Double
        let guide: RecordedFrame
        let index: Int?
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
        let gaps = BallMaskGapRefiner.requests(frames: frames, frameDuration: frameDuration).compactMap { gap -> Request? in
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
        let weak = frames.enumerated().compactMap { index, frame -> Request? in
            guard frame.detected, !frame.isVisualRecovery, !frame.isVisualMaskRepair,
                  frame.score >= 0.4, frame.time.isFinite, frame.width > 0, frame.height > 0,
                  let mask = frame.ballMask else { return nil }
            let fraction = area(mask) / (frame.width * frame.height)
            // A normal circular mask occupies about pi/4 of its box. Very small
            // fragments may be real occlusion and are deliberately left alone.
            guard (0.5...0.76).contains(fraction) else { return nil }
            return Request(time: frame.time, guide: frame, index: index)
        }
        let budget = min(240, max(12, Int(ceil(Double(frames.count) * 0.2))))
        // Spread optional work over the recording instead of exhausting the
        // entire budget in its first seconds. Missing masks have priority.
        func spread(_ values: [Request], limit: Int) -> [Request] {
            guard limit > 0 else { return [] }
            guard values.count > limit else { return values }
            return (0..<limit).map { values[$0 * values.count / limit] }
        }
        let missing = spread(gaps, limit: budget)
        return (missing + spread(weak, limit: budget - missing.count)).sorted { $0.time < $1.time }
    }

    static func region(_ request: Request, size: CGSize) -> CGRect? {
        let f = request.guide
        let diameter = max(f.width * size.width, f.height * size.height)
        guard [f.x, f.y, diameter].allSatisfy(\.isFinite), diameter >= 12,
              diameter < min(size.width, size.height) * 0.3 else { return nil }
        let side = max(128, diameter * 3.5)
        let roi = CGRect(x: f.x * size.width - side / 2, y: f.y * size.height - side / 2,
                         width: side, height: side).integral.intersection(CGRect(origin: .zero, size: size))
        return roi.isEmpty || roi.isNull ? nil : roi
    }

    static func accepted(_ result: FrameDetections, request: Request, roi: CGRect, size: CGSize) -> BallMask? {
        guard let b = result.ball, b.score >= 0.9, let raw = result.ballMask,
              [b.x, b.y, b.width, b.height, b.score].allSatisfy(\.isFinite), b.width > 0, b.height > 0,
              raw.width > 1, raw.height > 1, raw.alpha.count == raw.width * raw.height else { return nil }
        let f = request.guide, mask = raw.expanded()
        let shift = hypot((b.x - f.x) / f.width, (b.y - f.y) / f.height)
        guard shift < 0.45, (0.65...1.4).contains(b.width / f.width),
              (0.65...1.4).contains(b.height / f.height) else { return nil }
        let box = CGRect(x: (b.x - b.width / 2) * size.width, y: (b.y - b.height / 2) * size.height,
                         width: b.width * size.width, height: b.height * size.height)
        // Clipping against the actual source edge is fine; touching an artificial
        // crop edge means the retry did not contain enough context.
        guard (roi.minX == 0 || box.minX > roi.minX + 2),
              (roi.minY == 0 || box.minY > roi.minY + 2),
              (roi.maxX == size.width || box.maxX < roi.maxX - 2),
              (roi.maxY == size.height || box.maxY < roi.maxY - 2) else { return nil }
        let candidateArea = area(mask)
        guard (0.48...1.05).contains(candidateArea / (b.width * b.height)) else { return nil }
        if let old = f.ballMask?.expanded() {
            let oldArea = area(old)
            // Keep the old semantic support and accept only a modest addition.
            // A smaller/different mask is not evidence of repaired undercoverage.
            guard candidateArea >= oldArea * 1.02, candidateArea <= oldArea * 1.45 else { return nil }
            var support = 0.0, retained = 0.0
            for y in 0..<32 { for x in 0..<32 {
                let px = old.rect.minX + (Double(x) + 0.5) / 32 * old.rect.width
                let py = old.rect.minY + (Double(y) + 0.5) / 32 * old.rect.height
                let a = old.coverage(x: px, y: py)
                support += a; retained += min(a, mask.coverage(x: px, y: py))
            } }
            guard support > 0, retained / support >= 0.9 else { return nil }
        }
        return mask.compacted()
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
        var acceptedTimes: [Double] = []
        var pacer = VideoAnalysisPacer()
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            #if DEBUG
            let report: [String: Any] = ["source": source.lastPathComponent, "requests": pending.count,
                "attempted": attempted, "accepted_times": acceptedTimes, "failures": failures,
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
            guard let roi = region(request, size: size) else { continue }
            let frameStart = try await pacer.beginFrame { _ in }
            do {
                if detector == nil { detector = try BallDetector() }
                attempted += 1
                let found = try autoreleasepool { try detector!.inferRFMaskCrop(pixels, roi: roi) }
                try await pacer.finishFrame(started: frameStart)
                guard let mask = accepted(found, request: request, roi: roi, size: size) else { continue }
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
