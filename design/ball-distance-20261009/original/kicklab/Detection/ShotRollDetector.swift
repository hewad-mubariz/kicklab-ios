import CoreVideo
import Foundation

/// Owns one instance of the same configured detector used by Juggling. Serial,
/// bounded requests keep inference off ARKit's main-queue capture callbacks.
nonisolated final class ShotRollDetector: @unchecked Sendable {
    private final class PixelLease: @unchecked Sendable {
        let buffer: CVPixelBuffer
        init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
    }
    struct Result: Sendable {
        var uprightBallRect: CGRect?
        var confidence = 0.0
        var model = "Not loaded"
        var threshold = 0.0
        var milliseconds = 0.0
        var error: String?
    }

    // Mutable model state is confined to this serial queue.
    private let queue = DispatchQueue(label: "kicklab.roll-distance", qos: .userInitiated)
    private var detector: BallDetector?
    private var loadedResource: String?
    private var lastRotation: ShotRollRotation?

    func detect(pixels: CVPixelBuffer, resource: String, rotation: ShotRollRotation,
                timestamp: Double, completion: @escaping @Sendable (Result) -> Void) {
        let lease = PixelLease(pixels)
        queue.async { [self, lease] in
            let result: Result = autoreleasepool {
                var result = Result()
                do {
                    if detector == nil || loadedResource != resource || lastRotation != rotation {
                        detector = nil
                        detector = try BallDetector(resourceName: resource)
                        loadedResource = resource; lastRotation = rotation
                    }
                    guard let detector else { return result }
                    let detections = try detector.detect(lease.buffer, orientLandscapeAsPortrait: false,
                        timestamp: timestamp, imageOrientation: rotation.imageOrientation)
                    result.model = detector.modelName
                    result.threshold = max(0.25, detector.activeBallThreshold)
                    result.milliseconds = detector.lastTotalMS
                    if let ball = detections.ball, ball.score >= result.threshold {
                        result.uprightBallRect = CGRect(x: ball.x - ball.width / 2,
                            y: ball.y - ball.height / 2, width: ball.width, height: ball.height)
                        result.confidence = ball.score
                    }
                } catch { result.error = error.localizedDescription }
                return result
            }
            completion(result)
        }
    }

    func release() {
        queue.async { [self] in
            detector = nil; loadedResource = nil; lastRotation = nil
        }
    }
}
