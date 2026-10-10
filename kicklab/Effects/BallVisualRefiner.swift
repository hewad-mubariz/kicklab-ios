import AVFoundation
import CoreVideo
import Foundation

/// Tightens the detector's semantic box to the visible circular edge. The SSD
/// runs at 320px and its box can include a foot during a kick. This local pass
/// uses full decoded pixels; it never searches outside the detector's vicinity.
/// Counting continues to use the original detections.
nonisolated struct BallVisualRefiner {
    private var last: (x: Double, y: Double, time: Double, vx: Double, vy: Double)?
    private static let directions: [(Double, Double)] = (0..<40).map {
        let angle = Double($0) / 40 * .pi * 2
        return (cos(angle), sin(angle))
    }

    mutating func refine(_ box: Detection, in pixels: CVPixelBuffer, at time: Double = 0) -> Detection {
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let boxWidth = box.width * Double(width), boxHeight = box.height * Double(height)
        // SSD can underestimate just one axis. Search around the box's area,
        // then fit a circle, rather than permanently inheriting its shortest axis.
        let rawRadius = sqrt(boxWidth * boxHeight) / 2
        guard rawRadius >= 5, rawRadius < Double(width) * 0.2 else { return box }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let data = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return box }
        let rawX = box.x * Double(width), rawY = box.y * Double(height)
        let aspect = box.width * Double(width) / (box.height * Double(height))
        // A confident, already-circular model box is a strong anchor. Do not
        // let a nearby round head or clothing edge pull refinement away from it.
        let anchored = box.score >= 0.14 && (0.9...1.12).contains(aspect)
        // Always size the search from this detection. Feeding fitted radii back
        // into the next search lets a bright panel shrink the circle repeatedly.
        let expected = rawRadius
        let step = max(1, expected * 0.16)
        let reach = rawRadius * (anchored ? 0.35 : 1.1)
        let shell = max(1.5, expected * 0.075)
        let previous = last.flatMap { time > $0.time && time - $0.time <= 0.12 ? $0 : nil }
        let prediction = previous.map { p in
            (x: p.x + p.vx * (time - p.time), y: p.y + p.vy * (time - p.time))
        }

        func contrast(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
            let ax = Int(x1.rounded()), ay = Int(y1.rounded()), bx = Int(x2.rounded()), by = Int(y2.rounded())
            guard ax >= 0, ax < width, ay >= 0, ay < height, bx >= 0, bx < width, by >= 0, by < height else { return 0 }
            let a = data + ay * stride + ax * 4, b = data + by * stride + bx * 4
            // Count boundary support rather than brightness. A white panel on
            // black print must not beat a complete, lower-contrast silhouette.
            let delta = max(abs(Int(a[0]) - Int(b[0])), abs(Int(a[1]) - Int(b[1])), abs(Int(a[2]) - Int(b[2])))
            return min(1, Double(delta) / 24)
        }
        func score(_ x: Double, _ y: Double, _ r: Double) -> Double {
            let support = Self.directions.map { dx, dy in
                contrast(x + dx * (r - shell), y + dy * (r - shell),
                         x + dx * (r + shell), y + dy * (r + shell))
            }
            let edge = support.reduce(0, +) / Double(support.count)
            let locationPenalty = hypot(x - rawX, y - rawY) / expected * 6
            let sizePenalty = abs(log(r / expected)) * 25
            let continuity = prediction.map { min(4, hypot(x - $0.x, y - $0.y) / expected) * 2 } ?? 0
            return edge * 70 - locationPenalty - sizePenalty - continuity
        }
        var best = (x: rawX, y: rawY, r: expected, score: score(rawX, rawY, expected))
        for scale in anchored ? [0.85, 0.95, 1.05, 1.1] : [0.65, 0.75, 0.85, 0.95, 1.05, 1.15, 1.25] {
            let r = expected * scale
            for x in Swift.stride(from: rawX - reach, through: rawX + reach, by: step) {
                for y in Swift.stride(from: rawY - reach, through: rawY + reach, by: step) {
                    let quality = score(x, y, r)
                    if quality > best.score { best = (x, y, r, quality) }
                }
            }
        }
        guard best.score >= 30 else { return box }
        // A subpixel pass keeps the replacement edge steady as the ball moves.
        let coarse = best
        for dr in [-0.04, 0.0, 0.04] {
            for dx in [-0.08, 0.0, 0.08] { for dy in [-0.08, 0.0, 0.08] {
                let x = coarse.x + dx * expected, y = coarse.y + dy * expected, r = coarse.r + dr * expected
                let quality = score(x, y, r)
                if quality > best.score { best = (x, y, r, quality) }
            } }
        }
        guard best.score >= 45 else { return box }
        let dt = previous.map { time - $0.time } ?? 1
        let speedLimit = expected * 2 / max(dt, 0.001)
        let vx = previous.map { max(-speedLimit, min(speedLimit, (best.x - $0.x) / dt)) } ?? 0
        let vy = previous.map { max(-speedLimit, min(speedLimit, (best.y - $0.y) / dt)) } ?? 0
        last = (best.x, best.y, time, vx, vy)
        return Detection(score: box.score, x: best.x / Double(width), y: best.y / Double(height),
                         width: best.r * 2 / Double(width), height: best.r * 2 / Double(height))
    }
}


extension BallVisualRefiner {
    /// Revisit the captured track at the same timestamps after recording stops.
    /// The original track remains available to statistics and diagnostics.
    static func refineVideo(
        source: URL,
        frames: [RecordedFrame],
        framesUseCompositionClock: Bool = false,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [RecordedFrame] {
        try Task.checkCancellation()
        guard !frames.isEmpty else { return [] }
        let content = try SessionAnalysisStore.sourceDigest(source)
        let mode = framesUseCompositionClock ? "composition" : frames.contains(where: \.usesBallMasks) ? "capture-masks" : "capture-boxes"
        // Capture-mask reconstruction is independent of the sparse live track.
        // Imports and legacy box refinement depend on their exact seed observations.
        let seed = mode == "capture-masks" ? "" : try SessionAnalysisStore.digest(SessionAnalysisStore.frameData(frames))
        if ProcessInfo.processInfo.arguments.contains("--analysis-ignore-cache") {
            return try await computeVideo(source:source,frames:frames,framesUseCompositionClock:framesUseCompositionClock,
                                          onProgress:onProgress)
        }
        let key = SessionAnalysisStore.digest(Data("visual-v1|\(content)|\(mode)|\(seed)|\(SessionAnalysisStore.visualPipelineSignature())".utf8))
        return try await SessionAnalysisStore.shared.prepare(key: key, onProgress: onProgress ?? { _ in }) { progress in
            try await computeVideo(source: source, frames: frames, framesUseCompositionClock: framesUseCompositionClock,
                                   onProgress: progress)
        }
    }

    private static func computeVideo(source: URL, frames: [RecordedFrame], framesUseCompositionClock: Bool,
                                     onProgress: (@Sendable (Double) -> Void)?) async throws -> [RecordedFrame] {
        // Imports have already been analysed on the replay clock. Retain that
        // inference and add only the same appearance repair used by recordings.
        if framesUseCompositionClock {
            return try await BallMaskGapRefiner.refine(source: source, frames: frames, onProgress: onProgress)
        }
        let asset = AVURLAsset(url: source)
        if frames.contains(where: \.usesBallMasks) {
            // Live capture can drop frames. Its irregular mask timestamps do
            // not match the composition's regular replay/export timestamps.
            // Analyse the saved pixels afresh; never widen mask age tolerance
            // or reuse an old silhouette across a missing observation.
            let fresh = try await VideoAnalyzer.replayTrack(source: source) { onProgress?($0 * 0.9) }
            return try await BallMaskGapRefiner.refine(source: source, frames: fresh) { onProgress?(0.9 + $0 * 0.1) }
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return frames }
        let duration = try await asset.load(.duration)
        let composition = try await EffectVideoGeometry.composition(track: track, duration: duration, shortEdge: 720)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "KickLab.Refine", code: 1) }
        var refiner = BallVisualRefiner()
        var result: [RecordedFrame] = []
        var index = 0
        let ordered = frames.sorted { $0.time < $1.time }
        let total = max(1, ordered.count)
        let halfFrame = CMTimeGetSeconds(composition.frameDuration) * 0.55
        var lastReported = -1
        while index < ordered.count {
            try await VideoWorkExecution.checkpoint()
            guard let sample = output.copyNextSampleBuffer() else { break }
            try Task.checkCancellation()
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            while index < ordered.count, ordered[index].time < time - halfFrame {
                result.append(ordered[index]); index += 1
            }
            guard index < ordered.count, abs(ordered[index].time - time) <= halfFrame else { continue }
            let frame = ordered[index]
            let box = Detection(score: frame.score, x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            let tight = frame.detected ? refiner.refine(box, in: pixels, at: frame.time) : box
            result.append(RecordedFrame(time: frame.time, x: tight.x, y: tight.y, width: tight.width, height: tight.height,
                score: frame.score, smoothedX: frame.smoothedX, smoothedY: frame.smoothedY, vy: frame.vy,
                motion: frame.motion, detected: frame.detected, person: frame.person))
            index += 1
            let pct = Double(index) / Double(total)
            let bucket = Int(pct * 20)
            if bucket != lastReported {
                lastReported = bucket
                onProgress?(pct)
            }
        }
        if reader.status == .failed { throw reader.error ?? NSError(domain: "KickLab.Refine", code: 2) }
        result.append(contentsOf: ordered.dropFirst(index))
        reader.cancelReading()
        onProgress?(1)
        return result
    }
}
