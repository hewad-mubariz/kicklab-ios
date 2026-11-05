import AVFoundation
import CoreImage
import Foundation

/// Runs after recording and live inference have drained, on the analysis queue.
/// Reuses the warm RF model, and decodes only uncertain intervals. Normal takes
/// incur no extra inference. A fixed per-take budget bounds work on older phones.
nonisolated final class SavedStreakVisibilityVerifier {
    private let worker: RFWorker
    private let generator: AVAssetImageGenerator?
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
    private var started: Double?
    private var attempts = 0
    private(set) var failure: String?
    static let maximumFrames = 60
    static let maximumSeconds = 6.0
    private let secondsAllowed: Double

    init(source: URL?, worker: RFWorker, secondsAllowed: Double = SavedStreakVisibilityVerifier.maximumSeconds) {
        self.worker = worker
        self.secondsAllowed = secondsAllowed
        generator = source.map { AVAssetImageGenerator(asset: AVURLAsset(url: $0)) }
        generator?.appliesPreferredTrackTransform = true
        generator?.maximumSize = CGSize(width: 640, height: 640)
        generator?.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator?.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
    }

    func check(_ window: StreakVisibilityEvidence.Window) -> [StreakVisibilityEvidence.Sample] {
        guard let generator else { failure = "original_unavailable"; return [] }
        if started == nil { started = ProcessInfo.processInfo.systemUptime }
        var samples: [StreakVisibilityEvidence.Sample] = []
        // Seven independent empty samples spanning 3 s are required; a single
        // failed decode or failed prediction is never an empty-camera sample.
        for target in stride(from: window.startMS+250, to: window.endMS, by: 500) {
            // Reuse the app's locked foreground/GPU permission snapshot. This
            // worker may own a GPU model; do not start new work after Home/lock.
            guard BallSkinMetalRenderer.isAllowed else {
                failure = "recheck_app_inactive"; break
            }
            guard attempts < Self.maximumFrames,
                  ProcessInfo.processInfo.systemUptime-started! < secondsAllowed,
                  ProcessInfo.processInfo.thermalState != .critical else {
                failure = "recheck_budget_or_thermal_limit"; break
            }
            attempts += 1
            let sample: StreakVisibilityEvidence.Sample? = autoreleasepool {
                do {
                    var actual = CMTime.invalid
                    let image = try generator.copyCGImage(at: CMTime(value: Int64(target), timescale: 1000), actualTime: &actual)
                    guard actual.seconds.isFinite, abs(actual.seconds-Double(target)/1000) <= 0.1 else {
                        failure = "source_time_mismatch"; return nil
                    }
                    var buffer: CVPixelBuffer?
                    guard CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
                          let buffer else { failure = "pixel_buffer_unavailable"; return nil }
                    context.render(CIImage(cgImage: image), to: buffer)
                    let frame = PacedFrame(index: attempts, time: actual.seconds,
                        due: ProcessInfo.processInfo.systemUptime, image: CIImage(cvPixelBuffer: buffer), pixels: buffer)
                    guard BallSkinMetalRenderer.isAllowed else {
                        failure = "recheck_app_inactive"; return nil
                    }
                    let reply = worker.infer(frame, hint: nil, purpose: "streak_visibility")
                    guard reply.error == nil else { failure = "prediction_failed"; return nil }
                    return .init(timeMS: Int((actual.seconds*1000).rounded()),
                                 personVisible: reply.found.person != nil || !reply.found.people.isEmpty,
                                 ballVisible: reply.found.ball != nil || reply.candidateCount > 0)
                } catch {
                    failure = "source_decode_failed"
                    return nil
                }
            }
            if let sample { samples.append(sample) }
        }
        return samples
    }
}
