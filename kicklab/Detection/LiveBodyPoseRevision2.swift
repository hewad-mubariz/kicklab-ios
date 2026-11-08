import CoreVideo
import Foundation
import Vision

/// Revision-2 request and landmark mapping from the validated comparison arm.
/// One request per serial observation store; the caller owns fallback selection.
nonisolated enum LiveBodyPoseRevision2 {
    enum Failure: Error { case requiresIOS18, requiresForeground, timeout, missingResult }
    /// Match the legacy request's lifetime: one request per serial observation
    /// store, retained across warm-up and contact frames. Do not reload a request
    /// for every cached contact frame in the async bridge.
    @available(iOS 18.0, *)
    final class Session: @unchecked Sendable {
        let request: DetectHumanBodyPoseRequest
        init() {
            var request = DetectHumanBodyPoseRequest(.revision2)
            request.detectsHands = false
            self.request = request
        }
    }
    static var isPermitted: Bool {
        guard !VideoWorkExecution.accuracyComparison else { return false }
        if VideoWorkExecution.lease != nil { return ContactPoseComputePolicy.canAccelerate() }
        return !VideoWorkExecution.cpuOnly
    }
    private final class Exchange: @unchecked Sendable {
        let pixels: CVPixelBuffer
        private let lock = NSLock()
        private var result: Result<[BodyPose], Error>?
        init(_ pixels: CVPixelBuffer) { self.pixels = pixels }
        func store(_ result: Result<[BodyPose], Error>) { lock.withLock { self.result = result } }
        func take() throws -> [BodyPose] {
            let value = lock.withLock { result }
            return try value?.get() ?? { throw Failure.missingResult }()
        }
    }
    @available(iOS 18.0, *)
    static func poses(in pixels: CVPixelBuffer, session: Session = Session()) throws -> [BodyPose] {
        guard #available(iOS 18.0, *) else { throw Failure.requiresIOS18 }
        guard isPermitted else { throw Failure.requiresForeground }
        let exchange = Exchange(pixels), finished = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: .userInitiated) {
            do {
                let observations = try await session.request.perform(on: exchange.pixels, orientation: .up)
                exchange.store(.success(observations.prefix(8).map(convert)))
            } catch { exchange.store(.failure(error)) }
            finished.signal()
        }
        guard finished.wait(timeout: .now() + 60) == .success else {
            task.cancel(); throw Failure.timeout
        }
        return try exchange.take()
    }
    @available(iOS 18.0, *)
    static func convert(_ observation: HumanBodyPoseObservation) -> BodyPose {
        let names: [(BodyJoint, HumanBodyPoseObservation.JointName)] = [
            (.nose, .nose), (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
            (.leftElbow, .leftElbow), (.rightElbow, .rightElbow),
            (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
            (.leftHip, .leftHip), (.rightHip, .rightHip),
            (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
            (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle)]
        var result = BodyPose()
        for (name, joint) in names {
            guard let point = observation.joint(for: joint) else { continue }
            append(name, x: point.location.x, visionY: point.location.y,
                   confidence: Double(point.confidence), to: &result)
        }
        return result
    }
    static func append(_ name: BodyJoint, x: Double, visionY: Double,
                       confidence: Double, to result: inout BodyPose) {
        if confidence >= 0.3 { result.joints[name] = .init(x: x, y: 1-visionY) }
        let point = PoseLandmark(x: x, y: 1-visionY, confidence: confidence)
        result.landmarks[name] = point
        switch name {
        case .leftWrist: result.wrists[.left] = point
        case .rightWrist: result.wrists[.right] = point
        case .leftHip: result.hips[.left] = point
        case .rightHip: result.hips[.right] = point
        case .leftAnkle: result.ankles[.left] = point
        case .rightAnkle: result.ankles[.right] = point
        default: break
        }
    }
}
