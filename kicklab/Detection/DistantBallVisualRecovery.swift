import CoreVideo
import Foundation

/// Extra observations for saved-video appearance only. The caller keeps the
/// original detector result for counting, contact evidence and session stats.
nonisolated final class DistantBallVisualRecovery {
    private let policy = DistantBallRecoveryPolicy()
    private(set) var calls = 0
    private(set) var errors = 0
    private(set) var seconds = 0.0
    private(set) var lastKind = "none"

    static func enabled(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains("--distant-ball-recovery") && !arguments.contains("--disable-distant-ball-recovery")
    }

    static func signature(arguments: [String] = ProcessInfo.processInfo.arguments) -> String {
        enabled(arguments: arguments) ? "|distant-visual-v5" : ""
    }

    func reset() { policy.reset(); lastKind = "none" }

    func recover(pixels: CVPixelBuffer, time: Double, baseline: FrameDetections,
                 detector: BallDetector) throws -> FrameDetections? {
        try Task.checkCancellation()
        lastKind = "none"
        guard detector.supportsDistantVisualRecovery else { reset(); return nil }
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        guard let request = policy.request(time: time, size: size, direct: baseline.ball,
            baselineCalls: detector.lastFollowCalls, sceneCut: detector.lastSceneCut,
            kind: detector.lastFollowKind) else { return nil }
        calls += 1
        let start = ProcessInfo.processInfo.systemUptime
        defer { seconds += ProcessInfo.processInfo.systemUptime - start }
        let result: FrameDetections
        do { result = try detector.inferVisualCrop(pixels, roi: request.roi) }
        catch {
            try Task.checkCancellation()
            errors += 1
            _ = policy.accept(FrameDetections(ball: nil, person: nil), request: request, time: time)
            lastKind = "error"
            return nil
        }
        try Task.checkCancellation()
        guard policy.accept(result, request: request, time: time) else {
            lastKind = policy.rejection
            return nil
        }
        lastKind = request.context ? "context" : "local"
        return result
    }
}
