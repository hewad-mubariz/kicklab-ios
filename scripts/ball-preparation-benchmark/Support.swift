// CLI-only stand-ins for app lifecycle/cache services and decoded frame types.
// Appearance algorithms, video decoding and rotation all use production sources.
import Foundation
import CoreGraphics
nonisolated enum MotionState: Int { case unknown, rising, falling }
nonisolated struct PersonBox: Sendable { let x,y,width,height: Double }
nonisolated struct BallStyleSample: Sendable {
    /// Normalized, top-left coordinates in the UPRIGHT video, before preview cropping.
    var center: CGPoint
    var radius: CGFloat
    var boxSize: CGSize? = nil
    var confidence: Double
    var velocityY: Double?
    var time: Double = 0

    // The detector is calibrated at 0.05. Accepted low-score detections must not
    // make the material blink off; only genuinely missing tracks fade away.
    var visibility: Double { confidence >= 0.05 ? 1 : max(0, confidence / 0.05) }

    init(center: CGPoint, radius: CGFloat, confidence: Double, velocityY: Double? = nil) {
        self.center = center; self.radius = radius; self.confidence = confidence; self.velocityY = velocityY
    }

    init?(box: CGRect, confidence: Double, velocityY: Double? = nil) {
        guard box.width > 0, box.height > 0 else { return nil }
        center = CGPoint(x: box.midX, y: box.midY)
        radius = box.width / 2
        boxSize = box.size
        self.confidence = confidence; self.velocityY = velocityY
    }

    init(frame: RecordedFrame) {
        // Counter coordinates include motion compensation and smoothing lag.
        // Visuals must follow the actual ball in the recorded pixels instead.
        center = CGPoint(x: frame.x, y: frame.y)
        boxSize = CGSize(width: frame.width, height: frame.height)
        radius = frame.width / 2
        confidence = frame.detected ? frame.score : 0
        velocityY = frame.vy
        time = frame.time
    }

    func pixelRadius(in size: CGSize) -> CGFloat {
        guard let boxSize else { return radius * size.width }
        // A circle has different normalized width/height in a portrait frame.
        // The shorter physical axis also resists elongated motion-blur boxes.
        return min(boxSize.width * size.width, boxSize.height * size.height) / 2
    }
}

nonisolated struct RecordedFrame {
    /// Seconds from the start of the recording.
    let time: Double
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let score: Double
    /// Smoothed position the counter actually judged, which is not quite the raw
    /// detection - the difference is worth seeing when a count looks wrong.
    let smoothedX: Double
    let smoothedY: Double
    /// Vertical velocity in frame-heights per second, and the state derived from
    /// it. This is what the counter keys on, so showing it explains a count.
    let vy: Double
    let motion: MotionState
    /// Whether this frame had a real detection or was filled in.
    let detected: Bool
    /// The person box, for the body region and the ground line.
    let person: PersonBox?
    var ballMask: BallMask? = nil
    var usesBallMasks: Bool = false
    /// Appearance-only recovered mask; never a motion or counting observation.
    var isVisualMaskRepair: Bool = false
    /// Fresh crop detection for appearance; absent from counting/statistics input.
    var isVisualRecovery: Bool = false
    var identity: RecordedFrameIdentity? = nil
}


nonisolated struct RecordedFrameIdentity: Sendable {}

nonisolated enum VideoWorkExecution {
    static func checkpoint(requiresGPU: Bool = true) async throws { try Task.checkCancellation() }
    static func detached<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) -> Task<T, Error> {
        Task.detached(operation: operation)
    }
}
nonisolated enum SessionAnalysisStore {
    static func sourceDigest(_ url: URL) throws -> String { fatalError("Benchmark bypasses the app cache") }
    static func digest(_ data: Data) -> String { fatalError("Benchmark bypasses the app cache") }
    static func pipelineSignature() -> String { fatalError("Benchmark bypasses the app cache") }
}
