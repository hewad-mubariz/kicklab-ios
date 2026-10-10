import CoreImage
import CoreVideo
import Foundation
import Vision

/// Inspect only candidate contacts, using a bounded cache of small images. No
/// pose inference runs in preview or on every camera frame. A suspected floor
/// contact may reuse three buffered views to establish approach and separation
/// at a foot; the same poses also serve the hand veto. Uncertain/missing
/// pose is not evidence of a hand; the trajectory gates still decide the touch.
nonisolated final class JugglingContactVerifier {
    /// Diagnostic opt-out is also included in the analysis cache signature.
    static let enabled = !ProcessInfo.processInfo.arguments.contains("--juggling-no-hand-check")
    private struct Frame {
        let index: Int
        let timestampMs: Int
        let pixels: CVPixelBuffer
        let ball: Detection
    }
    private let context = CIContext(options: [.useSoftwareRenderer: VideoWorkExecution.cpuOnly])
    private var frames: [Frame] = []
    private struct Pose {
        var joints: [String: JugglingContactRules.Point] = [:]
        var ankles: [String: FootContactRules.Point] = [:]
        var hips: [String: FootContactRules.Point] = [:]
    }
    private var poseCache: [Int: Pose] = [:]
    private(set) var footChecks = 0
    private(set) var footRecoveries = 0
    private(set) var footCheckMS = 0.0
    private(set) var poseRequests = 0
    private(set) var poseCacheHits = 0
    private(set) var checkedContacts = 0
    private(set) var rejectedContacts = 0
    private(set) var lastCheckMS = 0.0
    private(set) var totalCheckMS = 0.0
    private(set) var warmUpMS = 0.0
    private(set) var peakBufferedFrames = 0
    private(set) var lastError: String?
    private var warmed = false
    private let request = VNDetectHumanBodyPoseRequest()

    init() {
        do { try VisionComputePolicy.configure(request) }
        catch { lastError = error.localizedDescription }
    }

    func discardFrames() { frames.removeAll(keepingCapacity: true); poseCache.removeAll(keepingCapacity: true) }

    func reset() {
        discardFrames()
        context.clearCaches()
        footChecks = 0; footRecoveries = 0; footCheckMS = 0; poseRequests = 0; poseCacheHits = 0
        checkedContacts = 0
        rejectedContacts = 0
        lastCheckMS = 0
        totalCheckMS = 0
        peakBufferedFrames = 0
        lastError = nil
    }

    /// Called on the owning analysis queue during preparation, before capture
    /// opens its writer. Keep Vision's cold model load out of a live contact.
    /// No camera image or every-frame pose inference is needed for warmup.
    func warmUp() {
        guard !warmed, lastError == nil else { return }
        let start = ProcessInfo.processInfo.systemUptime
        defer { warmUpMS = (ProcessInfo.processInfo.systemUptime - start) * 1000 }
        var pixels: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 288, 512, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == kCVReturnSuccess,
              let pixels else { return }
        context.render(CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 288, height: 512)), to: pixels)
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixels).perform([request])
            warmed = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    func store(_ pixels: CVPixelBuffer, frameIndex: Int, timestampMs: Int,
               ball: Detection?, orientLandscapeAsPortrait: Bool = true) {
        guard lastError == nil else { return }
        frames.removeAll { frameIndex - $0.index > 15 || timestampMs - $0.timestampMs > 500 }
        let retained = Set(frames.map(\.index)); poseCache = poseCache.filter { retained.contains($0.key) }
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
        peakBufferedFrames = max(peakBufferedFrames, frames.count)
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
        defer {
            lastCheckMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            totalCheckMS += lastCheckMS
        }
        let rejected = isHand(first) && isHand(second)
        if rejected { rejectedContacts += 1 }
        return rejected
    }

    /// Uses only frames already buffered when the counter requests a decision.
    /// Exact observed contact, confidence and bounded time/size guards precede Vision.
    func footEvidence(at frameIndex: Int) -> FootContactEvidence? {
        guard lastError == nil, let contact = frames.first(where: { $0.index == frameIndex }) else { return nil }
        let before = frames.filter { (40...130).contains(contact.timestampMs - $0.timestampMs) }
            .min { abs(contact.timestampMs - $0.timestampMs - 100) < abs(contact.timestampMs - $1.timestampMs - 100) }
        let after = frames.filter { (40...130).contains($0.timestampMs - contact.timestampMs) }
            .min { abs($0.timestampMs - contact.timestampMs - 100) < abs($1.timestampMs - contact.timestampMs - 100) }
        guard let before, let after else { return nil }
        let trio = [before, contact, after]
        guard trio.allSatisfy({ $0.ball.score >= 0.5 }),
              trio.map({ $0.ball.height }).max()! <= 1.35 * trio.map({ $0.ball.height }).min()!,
              trio.map({ $0.ball.width }).max()! <= 1.35 * trio.map({ $0.ball.width }).min()! else { return nil }
        footChecks += 1
        let start = ProcessInfo.processInfo.systemUptime
        defer { footCheckMS += (ProcessInfo.processInfo.systemUptime - start) * 1000 }
        var samples: [FootContactRules.Sample] = []
        for frame in trio {
            guard let pose = pose(for: frame) else { return nil }
            let b = frame.ball
            samples.append(.init(timestampMs: frame.timestampMs, ballX: b.x, ballY: b.y,
                width: b.width, height: b.height, confidence: b.score, ankles: pose.ankles, hips: pose.hips))
        }
        let evidence = FootContactEvidence(before: samples[0], contact: samples[1], after: samples[2])
        if evidence.confirms { footRecoveries += 1 }
        return evidence
    }

    private func isHand(_ frame: Frame) -> Bool {
        guard let pose = pose(for: frame) else { return false }
        return JugglingContactRules.isHand(ball: .init(x: frame.ball.x, y: frame.ball.y),
                                           width: frame.ball.width, joints: pose.joints)
    }

    private func pose(for frame: Frame) -> Pose? {
        if let cached = poseCache[frame.index] { poseCacheHits += 1; return cached }
        return autoreleasepool {
            do {
                poseRequests += 1
                try VNImageRequestHandler(cvPixelBuffer: frame.pixels).perform([request])
                guard let poses = request.results, poses.count == 1 else {
                    let empty = Pose(); poseCache[frame.index] = empty; return empty
                }
                let recognized = try poses[0].recognizedPoints(.all)
                let names: [(String, VNHumanBodyPoseObservation.JointName)] = [
                    ("nose", .nose), ("left_shoulder", .leftShoulder), ("right_shoulder", .rightShoulder),
                    ("left_elbow", .leftElbow), ("right_elbow", .rightElbow),
                    ("left_wrist", .leftWrist), ("right_wrist", .rightWrist),
                    ("left_hip", .leftHip), ("right_hip", .rightHip),
                    ("left_knee", .leftKnee), ("right_knee", .rightKnee),
                    ("left_ankle", .leftAnkle), ("right_ankle", .rightAnkle)]
                var result = Pose()
                for (name,joint) in names {
                    guard let point = recognized[joint] else { continue }
                    if point.confidence >= 0.3 { result.joints[name] = .init(x: point.location.x, y: 1-point.location.y) }
                    if name.hasSuffix("_hip") {
                        result.hips[String(name.dropLast(4))] = .init(x: point.location.x, y: 1-point.location.y,
                            confidence: Double(point.confidence))
                    }
                    if name.hasSuffix("_ankle") {
                        result.ankles[String(name.dropLast(6))] = .init(x: point.location.x, y: 1-point.location.y,
                            confidence: Double(point.confidence))
                    }
                }
                poseCache[frame.index] = result
                return result
            } catch {
                lastError = error.localizedDescription
                discardFrames()
                return nil
            }
        }
    }
}
