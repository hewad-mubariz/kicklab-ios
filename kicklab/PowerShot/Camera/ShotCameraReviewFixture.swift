import AVFoundation
import SwiftUI

#if DEBUG
/// A real encoded clip and cached detections for UI regressions, without running inference.
struct ShotCameraReviewFixture: View {
    var style: ShotTrailStyle = .none
    @State private var request: (URL, URL)?
    @State private var problem: String?
    var body: some View {
        Group {
            if let request {
                ShotEffectsReplayView(video: request.0, style: style, trackCache: request.1, onClose: {})
            } else if let problem {
                Text(problem)
            } else {
                ProgressView("Preparing review clip…")
            }
        }
        .task {
            do { request = try await Self.prepare() }
            catch { problem = error.localizedDescription }
        }
    }
    nonisolated private static func prepare() async throws -> (URL, URL) {
        let folder = URL.temporaryDirectory.appendingPathComponent("shot-camera-ui-fixture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let video = folder.appendingPathComponent("camera-v1.mp4"), cache = folder.appendingPathComponent("camera-v1.plist")
        if FileManager.default.fileExists(atPath: video.path), FileManager.default.fileExists(atPath: cache.path) { return (video, cache) }
        try? FileManager.default.removeItem(at: video)
        let width = 160, height = 284
        let movie = try PreviewMovie(url: video, size: CGSize(width: width, height: height), frameRate: 30)
        var frames: [RecordedFrame] = []
        for index in 0..<120 {
            try Task.checkCancellation()
            let time = Double(index) / 30, u = min(1, max(0, time - 1))
            let x = 0.28 + 0.38 * u, y = 0.82 - 0.48 * u - 0.08 * sin(.pi * u)
            let radius = 8 - 4 * u
            let pixels = try movie.buffer()
            CVPixelBufferLockBaseAddress(pixels, [])
            if let address = CVPixelBufferGetBaseAddress(pixels) {
                let bytes = address.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(pixels)
                for py in 0..<height { for px in 0..<width {
                    let i = py * stride + px * 4
                    let ball = hypot(Double(px) - x * Double(width), Double(py) - y * Double(height)) <= radius
                    bytes[i] = ball ? 245 : 35
                    bytes[i + 1] = ball ? 247 : UInt8(py / 28 % 2 == 0 ? 95 : 80)
                    bytes[i + 2] = ball ? 240 : 25
                    bytes[i + 3] = 255
                }}
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            try await movie.append(pixels, time: CMTime(value: Int64(index), timescale: 30))
            frames.append(RecordedFrame(time: time, x: x, y: y, width: radius * 2 / Double(width),
                height: radius * 2 / Double(height), score: 0.9, smoothedX: x, smoothedY: y,
                vy: 0, motion: .unknown, detected: true, person: nil))
        }
        try await movie.finish(duration: CMTime(value: 120, timescale: 30))
        try SessionAnalysisStore.frameData(frames).write(to: cache, options: .atomic)
        return (video, cache)
    }
}
#endif
