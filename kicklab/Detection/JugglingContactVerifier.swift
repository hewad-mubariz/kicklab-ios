import CoreImage
import CoreVideo
import Foundation
import Vision

/// Inspect only candidate contacts, using a bounded cache of small images. No
/// pose inference runs in preview or on every camera frame. Uncertain/missing
/// pose is not evidence of a hand; the trajectory gates still decide the touch.
nonisolated final class JugglingContactVerifier {
    /// Remains a validation candidate until combined phone latency/memory pass.
    /// The detector weights and normal-launch selection are unchanged.
    static let enabled = ProcessInfo.processInfo.arguments.contains("--juggling-hand-check")
    private struct Frame {
        let index: Int
        let timestampMs: Int
        let pixels: CVPixelBuffer
        let ball: Detection
    }
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var frames: [Frame] = []
    private(set) var checkedContacts = 0
    private(set) var rejectedContacts = 0
    private(set) var lastCheckMS = 0.0
    private(set) var lastError: String?
    private let request = VNDetectHumanBodyPoseRequest()

    func discardFrames() { frames.removeAll(keepingCapacity: true) }

    func reset() {
        discardFrames()
        context.clearCaches()
        checkedContacts = 0
        rejectedContacts = 0
        lastCheckMS = 0
        lastError = nil
    }

    func store(_ pixels: CVPixelBuffer, frameIndex: Int, timestampMs: Int,
               ball: Detection?, orientLandscapeAsPortrait: Bool = true) {
        guard lastError == nil else { return }
        frames.removeAll { frameIndex - $0.index > 15 || timestampMs - $0.timestampMs > 500 }
        guard let ball else { return }
        var image = CIImage(cvPixelBuffer: pixels)
        if orientLandscapeAsPortrait && image.extent.width > image.extent.height { image = image.oriented(.right) }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let scale = min(1, 512 / max(image.extent.width, image.extent.height))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(image.extent.width), Int(image.extent.height),
            kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { return }
        context.render(image, to: buffer)
        frames.append(Frame(index: frameIndex, timestampMs: timestampMs, pixels: buffer, ball: ball))
    }

    func rejectsHandContact(at frameIndex: Int) -> Bool {
        guard lastError == nil else { return false }
        // Never substitute a frame far from the reversal. Two adjacent views
        // must agree, so one misplaced wrist cannot remove a genuine touch.
        guard let first = frames.min(by: { abs($0.index - frameIndex) < abs($1.index - frameIndex) }),
              abs(first.index - frameIndex) <= 1,
              let second = frames.first(where: { $0.index > first.index && $0.index <= first.index + 2
                  && $0.timestampMs > first.timestampMs && $0.timestampMs - first.timestampMs <= 100 }) else { return false }
        checkedContacts += 1
        let start = ProcessInfo.processInfo.systemUptime
        defer { lastCheckMS = (ProcessInfo.processInfo.systemUptime - start) * 1000 }
        let rejected = isHand(first) && isHand(second)
        if rejected { rejectedContacts += 1 }
        return rejected
    }

    private func isHand(_ frame: Frame) -> Bool {
        autoreleasepool {
            do {
                try VNImageRequestHandler(cvPixelBuffer: frame.pixels).perform([request])
                // Multi-person identity needs a separate association policy.
                // Do not reject a touch using another player's hand.
                guard let poses = request.results, poses.count == 1 else { return false }
                let recognized = try poses[0].recognizedPoints(.all)
                let names: [(String, VNHumanBodyPoseObservation.JointName)] = [
                    ("nose", .nose), ("left_shoulder", .leftShoulder), ("right_shoulder", .rightShoulder),
                    ("left_elbow", .leftElbow), ("right_elbow", .rightElbow),
                    ("left_wrist", .leftWrist), ("right_wrist", .rightWrist),
                    ("left_hip", .leftHip), ("right_hip", .rightHip),
                    ("left_knee", .leftKnee), ("right_knee", .rightKnee),
                    ("left_ankle", .leftAnkle), ("right_ankle", .rightAnkle)]
                let points = Dictionary(uniqueKeysWithValues: names.compactMap { name, joint -> (String, JugglingContactRules.Point)? in
                    guard let point = recognized[joint], point.confidence >= 0.3 else { return nil }
                    return (name, JugglingContactRules.Point(x: point.location.x, y: 1 - point.location.y))
                })
                return JugglingContactRules.isHand(ball: .init(x: frame.ball.x, y: frame.ball.y),
                                                   width: frame.ball.width, joints: points)
            } catch {
                // Some simulator runtimes lack the Vision pose weights. A failed
                // model is not proof of a legal contact; preserve a diagnostic
                // and avoid retrying the same unavailable model every touch.
                lastError = error.localizedDescription
                discardFrames()
                return false
            }
        }
    }
}
