import CoreVideo
import CoreGraphics
import Foundation

/// One delivered capture frame, with its original recording identity and clock.
nonisolated struct LiveAnalysisFrame {
    let pixels: CVPixelBuffer
    let sourceTime: Double
    let startTime: Double
    let captureDrops: Int
    let identity: RecordedFrameIdentity?
    var sourceDueUptime: Double = ProcessInfo.processInfo.systemUptime
}

/// UI publication is throttled independently from capture and inference.
nonisolated struct LiveAnalysisUpdate {
    let liveTime: Double
    let recentTimes: [Double]
    let processedFrames: Int
    let diagnostic: TouchDebugEvent?
    let performance: DetectorPerformanceSnapshot
    let count: Int
    let score: Double
    let detected: Int
    let size: CGSize
    let image: CGImage?
    let ballRect: CGRect?
    let personRect: CGRect?
    let fps: Double?
    let error: String?
    let shift: Double
    let shaky: Bool
    let touched: CGPoint?
    let dropped: Int
    let vy: Double
    var players: [ActiveJugglerTracker.Player] = []
    var player: ActivePlayerSelection? = nil
}

/// Owns live inference and numeric session results. All methods run on the
/// camera's serial analysis queue; this service never configures the camera,
/// writes video or publishes SwiftUI state.
nonisolated final class RFAppCounterCore {
    struct Result {
        let touches: [RecordedTouch]
        let track: [RecordedFrame]
        let count: Int
        let diagnostics: [TouchDebugEvent]
        let trace: CounterTrace?
        let evidence: CaptureAnalysisEvidence?
        let analyzed: [RecordedFrameIdentity]
        let timeOrigin: Double
        let frameCount: Int
        let qualityFailed: Bool
    }

    private let performanceMonitor = DetectorPerformance()
    private let counterConfig: CounterConfig
    private var detector: RFFrameMetrics?
    private var evidence: ContactRecheckEvidence?
    private var counterEvidence: (any ContactEvidenceProviding)? { evidence ?? contactVerifier as (any ContactEvidenceProviding)? }
    private var trackingBaselineMB = 0.0
    private var trackingPreparationMS = 0.0
    private var counter = StreamingCounter()
    private var contactVerifier: JugglingContactVerifier?
    private var frameIndex = 0
    private var detectedFrames = 0
    private var analysisFailed = false
    private var lastFpsStamp = CFAbsoluteTimeGetCurrent()
    private var framesSinceStamp = 0
    private var lastPublish = 0.0
    private let compensator = MotionCompensator()
    private var plausibility = BallPlausibility()
    private var playerTracker = ActiveJugglerTracker()
    private var lastBallRect: CGRect?
    private var touchesThisRun: [RecordedTouch] = []
    private var trackThisRun: [RecordedFrame] = []
    private var analyzedIdentities: [RecordedFrameIdentity] = []
    private var analysisEvaluations: [CaptureAnalysisEvidence.Evaluation] = []
    private var capturePipelineSignature: String?
    private var recordingStartSeconds: Double = 0
    private var cadence = LiveAnalysisCadence()
    private var retainedMaskBytes = 0
    private(set) var notificationLatencies: [Double] = []
    private var notificationEpoch = 0.0
    private var completedRecheckEvents: [[String: Any]] = []
    var recommendedFramesPerSecond: Double { 30 }

    #if DEBUG
    var finalTestFiles: FinalTestFiles?
    #endif

    var isPrepared: Bool { detector != nil }
    var recheckEvents: [[String: Any]] { evidence?.events ?? completedRecheckEvents }
    func markFailed() { analysisFailed = true }

    init(counterConfig: CounterConfig = CounterConfig()) {
        self.counterConfig = counterConfig
    }

    func prepare(request: CaptureRequest, worker: RFWorker) throws -> Bool {
        let baseline = DetectorPerformance.memoryMB()
        let started = ProcessInfo.processInfo.systemUptime
        let signature = SessionAnalysisStore.pipelineSignature()
        let loaded = RFFrameMetrics(compute: worker.computeDescription)
        guard !request.isCancelled else { return false }
        // RF model warmed on its owning worker before this call.
        guard !request.isCancelled else { return false }
        let observations = ContactObservationStore()
        let verifier = JugglingContactVerifier.enabled ? JugglingContactVerifier(observations: observations) : nil
        evidence = verifier.map { ContactRecheckEvidence(observations: observations, verifier: $0, worker: worker, enabled: true, backlogGuard: false) }
        verifier?.warmUp()
        guard !request.isCancelled else { return false }
        if let error = verifier?.lastError {
            throw NSError(domain: "CameraPreparation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: error])
        }
        detector = loaded
        plausibility = BallPlausibility(policy: loaded.plausibilityPolicy)
        contactVerifier = verifier
        capturePipelineSignature = signature == SessionAnalysisStore.pipelineSignature() ? signature : nil
        trackingBaselineMB = baseline
        trackingPreparationMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
        return true
    }

    /// Release heavy resources when leaving capture, retaining numeric results.
    func release() {
        detector = nil
        contactVerifier = nil
        evidence = nil
        capturePipelineSignature = nil
    }

    func resetCounter() {
        contactVerifier?.reset()
        evidence?.reset()
        counter = ContactCounterFactory.make(verifier: counterEvidence, config: counterConfig)
        plausibility.reset()
        playerTracker.reset()
        frameIndex = 0
        detectedFrames = 0
    }

    func beginRecording() {
        if let detector {
            performanceMonitor.loaded(model: detector.modelName, baselineMB: trackingBaselineMB,
                                      milliseconds: trackingPreparationMS, computeBackend: detector.modelComputeDescription)
        }
        touchesThisRun = []
        trackThisRun = []
        analyzedIdentities = []
        analysisEvaluations = []
        // A fresh counter: a run's count should start at zero.
        let verifier = contactVerifier
        verifier?.reset()
        evidence?.reset()
        counter = ContactCounterFactory.make(verifier: counterEvidence, config: counterConfig)
        #if DEBUG
        if let files = finalTestFiles {
            counter.debugDiagnosticObserver = { [weak self] event in
                guard let self else { return }
                files.append(event.relative(to: self.recordingStartSeconds), to: "live-contacts.jsonl")
            }
        }
        #endif
        plausibility.reset()
        playerTracker.reset()
        frameIndex = 0
        detectedFrames = 0
        analysisFailed = false
        lastBallRect = nil
        framesSinceStamp = 0
        lastFpsStamp = CFAbsoluteTimeGetCurrent()
        lastPublish = 0
        cadence = LiveAnalysisCadence()
        notificationLatencies = []
        completedRecheckEvents = []
        notificationEpoch = 0
        retainedMaskBytes = 0
        compensator.reset()
    }

    func finish(flush: Bool, wasActive: Bool) -> Result {
        let flushStarted = ProcessInfo.processInfo.systemUptime
        evidence?.beginFlush(operation: frameIndex)
        let late = flush ? counter.flush() : []
        if flush { performanceMonitor.recordLiveFlush(milliseconds: (ProcessInfo.processInfo.systemUptime - flushStarted) * 1000) }
        completedRecheckEvents = evidence?.events ?? []
        for touch in late {
            notificationLatencies.append((ProcessInfo.processInfo.systemUptime-notificationEpoch)*1000-Double(touch.timestampMs))
            touchesThisRun.append(RecordedTouch(index: touch.index,
                time: Double(touch.timestampMs) / 1000.0 - recordingStartSeconds,
                x: touch.x, y: touch.y))
        }
        let qualityFailed = analysisFailed || contactVerifier?.lastError != nil || evidence?.error != nil
        let touches = wasActive ? touchesThisRun : []
        let track = wasActive ? trackThisRun : []
        let count = wasActive ? counter.count : 0
        let diagnostics = wasActive ? (counter.traceSnapshot()?.diagnostics ?? []).map {
            $0.relative(to: recordingStartSeconds)
        } : []
        let trace = wasActive ? counter.traceSnapshot() : nil
        let signature = capturePipelineSignature
        let evidence = wasActive && signature == SessionAnalysisStore.pipelineSignature()
            ? signature.map { CaptureAnalysisEvidence(version: 1, pipelineSignature: $0,
                                                     evaluations: analysisEvaluations) } : nil
        let result = Result(touches: touches, track: track, count: count, diagnostics: diagnostics,
            trace: trace, evidence: evidence, analyzed: analyzedIdentities,
            timeOrigin: recordingStartSeconds, frameCount: wasActive ? frameIndex : 0,
            qualityFailed: qualityFailed)
        #if DEBUG
        if wasActive { finalTestFiles?.save(performanceMonitor.liveSummary, as: "live-performance.json") }
        #endif
        release()
        compensator.reset()
        lastBallRect = nil
        performanceMonitor.finish()
        return result
    }

    func process(_ output: RFTrackedFrame, motionCompensationEnabled: Bool) throws -> LiveAnalysisUpdate? {
        notificationEpoch = output.frame.due-output.frame.time
        let frame = output.liveFrame
        var detector = output.metrics
        let frameStarted = ProcessInfo.processInfo.systemUptime
        let pixels = frame.pixels
        let sourceTime = frame.sourceTime
        recordingStartSeconds = frame.startTime
        let stampMs = output.frame.timestampMs
        let index = frameIndex
        frameIndex += 1
        let inferenceSucceeded = true
        var found = output.found
        if contactVerifier?.lastError != nil || evidence?.error != nil {
            analysisFailed = true
            throw VideoSafetyPolicy.Failure.analysis
        }
        // Model-specific association keeps an unrelated object from replacing
        // the ball during a brief detection gap.
        let hadBall = found.ball != nil
        cadence.observe(time: sourceTime, hasBall: hadBall, hasPerson: found.person != nil,
                        thermal: ProcessInfo.processInfo.thermalState)
        found = plausibility.filter(found, frame: index, timestampMs: stampMs)
        let rejectedByPlausibility = hadBall && found.ball == nil
        if found.ball != nil { detectedFrames += 1 }
        lastBallRect = found.ball.map {
            CGRect(x: $0.x - $0.width / 2, y: $0.y - $0.height / 2,
                   width: $0.width, height: $0.height)
        }

        // Measure background motion while excluding the current ball. The
        // counter applies the same offset to ball and player geometry and
        // returns touch markers in the original video coordinates.
        compensator.excludeBall = lastBallRect
        let motionStarted = ProcessInfo.processInfo.systemUptime
        let shift = motionCompensationEnabled ? compensator.update(pixels) : 0
        let motionMS = (ProcessInfo.processInfo.systemUptime - motionStarted) * 1000
        let ball = found.ball.map {
            BallObservation(frameIndex: index, timestampMs: stampMs,
                            x: $0.x, y: $0.y,
                            width: $0.width, height: $0.height,
                            confidence: $0.score)
        }
        let candidates = found.people.isEmpty ? found.person.map { [$0] } ?? [] : found.people
        let player = playerTracker.update(people: candidates.map {
            PersonBox(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }, ball: ball, timestampMs: stampMs)
        let person = player.canMatchPose ? player.box : nil
        // Hold the count while the camera is moving too much to judge. Missing a
        // touch is recoverable; inventing one is not, and the user can see why.
        let shaky = compensator.isTooShaky
        let bufferStarted = ProcessInfo.processInfo.systemUptime
        if shaky { contactVerifier?.discardFrames() }
        else { contactVerifier?.store(pixels, frameIndex: index, timestampMs: stampMs, ball: found.ball, player: player) }
        let contactBufferMS = (ProcessInfo.processInfo.systemUptime - bufferStarted) * 1000
        evidence?.arrive(output.frame, index: index, ball: found.ball, reliable: !shaky)
        let counterStarted = ProcessInfo.processInfo.systemUptime
        let confirmed = counter.push(frameIndex: index, timestampMs: stampMs,
                                     ball: ball, person: person,
                                     cameraOffsetY: shift, reliable: !shaky, sourceFrameIndex: frame.identity?.index, player: player)
        let counterMS = (ProcessInfo.processInfo.systemUptime - counterStarted) * 1000
        for touch in confirmed {
            notificationLatencies.append((ProcessInfo.processInfo.systemUptime-output.frame.due)*1000 + Double(stampMs-touch.timestampMs))
        }
        do {
            if let identity = frame.identity {
                analyzedIdentities.append(identity)
                analysisEvaluations.append(.init(identity: identity, outcome: .classify(
                    succeeded: inferenceSucceeded, hasBall: found.ball != nil,
                    hasMask: found.ballMask != nil, maskModel: detector.hasMaskOutputs,
                    rejected: rejectedByPlausibility,
                    direct: detector.lastFollowKind == "detector" && detector.lastFollowCalls == 1)))
            }
            let judged = counter.lastPoint
            if let b = found.ball {
                let retainedMask = found.ballMask?.compacted()
                retainedMaskBytes += retainedMask?.storageByteCount ?? 0
                trackThisRun.append(RecordedFrame(
                    time: Double(stampMs) / 1000.0 - recordingStartSeconds,
                    x: b.x, y: b.y, width: b.width, height: b.height, score: b.score,
                    smoothedX: judged?.x ?? b.x,
                    smoothedY: judged?.y ?? b.y,
                    vy: judged?.vy ?? 0,
                    motion: judged?.motion ?? .unknown,
                    detected: true,
                    person: person, ballMask: retainedMask, usesBallMasks: found.usesBallMasks, identity: frame.identity))
            }
            for touch in confirmed {
                touchesThisRun.append(RecordedTouch(
                    index: touch.index,
                    time: Double(touch.timestampMs) / 1000.0 - recordingStartSeconds,
                    x: touch.x, y: touch.y))
            }
        }

        var performance = performanceMonitor.observe(inferenceMS: detector.lastInferenceMS,
            preprocessMS: detector.lastPreprocessMS, totalMS: detector.lastTotalMS, recording: true,
            captureDrops: frame.captureDrops, roiFullFrames: detector.fullFrameCount, roiCropFrames: detector.cropFrameCount,
            live: LiveFramePerformance(totalMS: (ProcessInfo.processInfo.systemUptime - frameStarted) * 1000,
                motionMS: motionMS, contactBufferMS: contactBufferMS, counterMS: counterMS,
                poseRequests: contactVerifier?.poseRequests ?? 0, handPoseRequests: contactVerifier?.handPoseRequests ?? 0,
                poseCacheHits: contactVerifier?.poseCacheHits ?? 0))
        performance.analysisTargetFPS = 30
        performance.analysisIdle = cadence.isIdle
        performance.retainedMaskBytes = retainedMaskBytes
        framesSinceStamp += 1
        let now = CFAbsoluteTimeGetCurrent()
        var measuredFps: Double?
        if now - lastFpsStamp >= 1.0 {
            measuredFps = Double(framesSinceStamp) / (now - lastFpsStamp)
            framesSinceStamp = 0
            lastFpsStamp = now
        }

        // Publish at ~8Hz. Thirty SwiftUI updates a second, each redrawing the
        // whole view tree, competes with the capture pipeline for no benefit -
        // nobody reads a counter faster than this.
        guard now - lastPublish >= 0.125 || measuredFps != nil || !confirmed.isEmpty
        else { return nil }
        lastPublish = now
        // No consumer currently displays this snapshot; avoid a GPU readback
        // on every UI update while measuring live detector performance.
        detector.wantsModelInputSnapshot = false

        let liveTime = max(0, sourceTime - recordingStartSeconds)
        let recentTimes = touchesThisRun.suffix(8).map(\.time)
        let diagnostic = counter.latestDiagnostic?.relative(to: recordingStartSeconds)
        return LiveAnalysisUpdate(
            liveTime: liveTime, recentTimes: recentTimes, processedFrames: index + 1,
            diagnostic: diagnostic, performance: performance,
            count: counter.count,
            score: found.ball?.score ?? 0,
            detected: detectedFrames,
            size: detector.lastInputSize,
            image: detector.lastModelInput,
            ballRect: found.ball.map {
                CGRect(x: $0.x - $0.width / 2, y: $0.y - $0.height / 2,
                       width: $0.width, height: $0.height)
            },
            personRect: person.map {
                CGRect(x: $0.x - $0.width / 2, y: $0.y - $0.height / 2,
                       width: $0.width, height: $0.height)
            },
            fps: measuredFps,
            error: detector.lastError,
            shift: shift,
            shaky: shaky,
            touched: confirmed.last.map { CGPoint(x: $0.x, y: $0.y) },
            dropped: plausibility.rejectedSize + plausibility.rejectedJump,
            vy: counter.lastPoint?.vy ?? 0,
            players: playerTracker.players, player: player
        )

    }
}
