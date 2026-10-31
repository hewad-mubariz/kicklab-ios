import Foundation
import Vision

/// Independent lab arms. The explicitly compiled field-test profile may select
/// body revision2 on normal launch; production and ball tracking keep their defaults.
nonisolated enum VisionRevisionExperiment {
    private final class Timing: @unchecked Sendable {
        let lock = NSLock()
        var calls = 0, failures = 0, empty = 0
        var milliseconds = 0.0, maximumMilliseconds = 0.0
        var warmup: [String: Any] = [:]
    }
    private static let timing = Timing()
    static func recordWarmup(_ value: [String: Any]) {
        #if DEBUG
        timing.lock.withLock { timing.warmup = value }
        #endif
    }
    static func recordPose(milliseconds: Double, poses: Int, failed: Bool) {
        #if DEBUG
        timing.lock.withLock {
            timing.calls += 1; timing.milliseconds += milliseconds
            timing.maximumMilliseconds = max(timing.maximumMilliseconds,milliseconds)
            if failed { timing.failures += 1 }
            if poses == 0 { timing.empty += 1 }
        }
        #endif
    }
    static var poseTiming: [String: Any] {
        timing.lock.withLock { ["calls":timing.calls,"errors":timing.failures,
            "empty":timing.empty,"totalMS":timing.milliseconds,"maximumMS":timing.maximumMilliseconds] }
    }
    static var warmupReport: [String: Any] { timing.lock.withLock { timing.warmup } }
    static func bodyPose2(arguments: [String]? = nil) -> Bool {
        #if DEBUG
        #if TOUCH_COUNTING_DEBUG
        let effective = arguments ?? TouchCountingDebugProfile.arguments
        #else
        let effective = arguments ?? ProcessInfo.processInfo.arguments
        #endif
        return effective.contains("--vision-body-pose-revision2")
        #else
        return false
        #endif
    }
    static func trackingRevision(arguments: [String] = ProcessInfo.processInfo.arguments) -> Int {
        #if DEBUG
        arguments.contains("--follow-vision-revision2") ? 2 : 1
        #else
        1
        #endif
    }
    static func signature(arguments: [String]) -> String {
        (trackingRevision(arguments: arguments) == 2 ? "|vision-track-r2" : "")
        + (bodyPose2(arguments: arguments) ? "|vision-body-pose-swift-r2" : "")
        + computeSignature(arguments: arguments)
        + historySignature(arguments: arguments)
        + lateralContactSignature(arguments: arguments)
        + compactWindowSignature(arguments: arguments)
        + (PoseEmptyFallbackPolicy.enabled(arguments: arguments) ? "|pose-empty-legacy-fallback-v1" : "")
        + (ImpactGapReservation.enabled(arguments: arguments) ? "|rf-reserved-gap-v\(ImpactGapReservation.version(arguments: arguments))" : "")
        + (TrackingDrainBudget.enabled(arguments: arguments) ? "|rf-drain-budget-v1" : "")
        + (RFIndependentRegularClock.enabled(arguments: arguments) ? RFIndependentRegularClock.signature : "")
        + (RFFailedRetryClock.enabled(arguments: arguments) ? RFFailedRetryClock.signature : "")
        + (RFSourceCadence.version(arguments: arguments) >= 4 ? RFSourceCadence.signatureV4
            : RFSourceCadence.version(arguments: arguments) >= 3 ? RFSourceCadence.signatureV3
            : RFSourceCadence.version(arguments: arguments) >= 2 ? RFSourceCadence.signatureV2
            : RFSourceCadence.enabled(arguments: arguments) ? RFSourceCadence.signature : "")
    }
    private static func lateralContactSignature(arguments: [String]) -> String {
        #if DEBUG
        return arguments.contains("--shallow-lateral-contact-v1") ? "|shallow-lateral-contact-v1" : ""
        #else
        return ""
        #endif
    }
    private static func compactWindowSignature(arguments: [String]) -> String {
        #if DEBUG
        return (arguments.contains("--compact-release-window-v1") ? "|compact-release-window-v1" : "")
            + (arguments.contains("--resolved-floor-margin-v1") ? "|resolved-floor-margin-v1" : "")
        #else
        return ""
        #endif
    }
    private static func historySignature(arguments: [String]) -> String {
        #if DEBUG
        return arguments.contains("--pose-shared-history-v1") ? "|pose-shared-history-v1" : ""
        #else
        return ""
        #endif
    }
    private static func computeSignature(arguments: [String]) -> String {
        #if DEBUG
        if let index = arguments.firstIndex(of: "--vision-pose-compute"), arguments.indices.contains(index+1) {
            return "|vision-pose-main-device="+arguments[index+1]
        }
        #endif
        return ""
    }
    static var report: [String: Any] {
        var value: [String: Any] = [
            "objectTrackingSelected": trackingRevision(),
            "objectTrackingSupported": Array(VNTrackObjectRequest.supportedRevisions),
            "legacyBodyDefault": VNDetectHumanBodyPoseRequest.defaultRevision,
            "legacyBodySelected": VNDetectHumanBodyPoseRequest().revision,
            "legacyBodySupported": Array(VNDetectHumanBodyPoseRequest.supportedRevisions),
            "legacyHandSelected": VNDetectHumanHandPoseRequest().revision,
            "legacyHandSupported": Array(VNDetectHumanHandPoseRequest.supportedRevisions),
            "bodyPoseImplementation": bodyPose2() ? "Swift revision2" : "VN legacy",
            "integratedHandDetection": false
        ]
        #if DEBUG
        value["bodyPoseRequestedCompute"] = VisionPoseComputeProbe.requested ?? "automatic"
        value["sharedPoseHistory"] = ProcessInfo.processInfo.arguments.contains("--pose-shared-history-v1")
        value["sourceCadence"] = RFSourceCadence.enabled()
        value["sourceCadenceVersion"] = RFSourceCadence.version()
        value["independentRegularClock"] = RFIndependentRegularClock.enabled()
        value["failedRetryClock"] = RFFailedRetryClock.enabled()
        value["shallowLateralContact"] = ProcessInfo.processInfo.arguments.contains("--shallow-lateral-contact-v1")
        value["compactReleaseWindow"] = ProcessInfo.processInfo.arguments.contains("--compact-release-window-v1")
        value["resolvedFloorMargin"] = ProcessInfo.processInfo.arguments.contains("--resolved-floor-margin-v1")
        value["reservedImpactGap"] = ImpactGapReservation.enabled()
        value["reservedImpactGapVersion"] = ImpactGapReservation.version()
        value["trackingDrainBudget"] = TrackingDrainBudget.enabled()
        value["poseEmptyLegacyFallback"] = PoseEmptyFallbackPolicy.enabled()
        value["stationaryGateVersion"] = StationaryCandidateGate.version()
        value["contactWindowClock"] = ContactWindowClock.enabled()
        value["observedFallAmplitude"] = ProcessInfo.processInfo.arguments.contains("--observed-fall-amplitude-v1")
        value["observedShortRise"] = ProcessInfo.processInfo.arguments.contains("--observed-short-rise-v1")
        value["observedPlateauFoot"] = ProcessInfo.processInfo.arguments.contains("--observed-plateau-foot-v1")
        value["recentMeasuredFloor"] = ProcessInfo.processInfo.arguments.contains("--recent-measured-floor-v1")
        value["directedForefoot"] = ProcessInfo.processInfo.arguments.contains("--directed-forefoot-v1")
        value["supportedToeLift"] = ProcessInfo.processInfo.arguments.contains("--supported-toe-lift-v1")
        value["observedUnarmedTurn"] = ProcessInfo.processInfo.arguments.contains("--observed-unarmed-turn-v1")
        #endif
        if #available(iOS 18.0, *) {
            value["swiftBodySupported"] = DetectHumanBodyPoseRequest.supportedRevisions.map { String(describing: $0) }
            value["swiftHandSupported"] = DetectHumanHandPoseRequest.supportedRevisions.map { String(describing: $0) }
            value["swiftTrackerSupported"] = TrackObjectRequest.supportedRevisions.map { String(describing: $0) }
            value["swiftBody3DSupported"] = DetectHumanBodyPose3DRequest.supportedRevisions.map { String(describing: $0) }
        }
        return value
    }
}

#if DEBUG
/// The counter currently owns synchronous, lazy pose requests on its serial
/// analysis queue. Bridge only this lab API, with one in-flight request and the
/// same pixels, confidence threshold, person matching and bounded cache.
/// Never fall back silently: an unavailable/timed-out arm is an invalid run.
nonisolated enum VisionBodyPoseRevision2 {
    enum Failure: Error { case requiresIOS18, requiresForeground, timeout, missingResult }
    /// Match the legacy request's lifetime: one request per serial observation
    /// store, retained across warm-up and contact frames. Do not reload a request
    /// for every cached contact frame in the async bridge.
    @available(iOS 18.0, *)
    final class Session: @unchecked Sendable {
        let request: DetectHumanBodyPoseRequest
        let configurationError: Error?
        init() {
            var request = DetectHumanBodyPoseRequest(.revision2)
            request.detectsHands = false
            do {
                try VisionPoseComputeProbe.configure(&request, device: VisionPoseComputeProbe.requested)
                configurationError = nil
            } catch { configurationError = error }
            self.request = request
        }
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
        guard !VideoWorkExecution.cpuOnly else { throw Failure.requiresForeground }
        if let error = session.configurationError { throw error }
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
#endif
