//
//  CameraSession.swift
//  kicklab
//
//  Camera capture, detection and counting - with the work OFF the main thread.
//
//  Capture/writing has its own serial queue. Live inference runs separately
//  at up to 30 fps, with one active and one replaceable pending frame. Every
//  saved frame keeps its original camera timestamp; counting judges only the
//  analysed subset. Exact saved-frame identities are retained for reusable session analysis.
//

import AVFoundation
import Combine
import CoreVideo
import Foundation

final class CameraSession: NSObject, ObservableObject {
    @MainActor @Published private(set) var touchCount = 0
    @MainActor @Published private(set) var ballScore: Double = 0
    @MainActor @Published private(set) var fps: Double = 0
    @MainActor @Published private(set) var status = "starting"
    @MainActor @Published private(set) var inputSize = "-"
    @MainActor @Published private(set) var detections = 0
    @MainActor @Published private(set) var ballBox: CGRect?
    @MainActor @Published private(set) var personBox: CGRect?
    /// Vertical velocity (frame-heights / sec) for style trails — optional.
    @MainActor @Published private(set) var ballVelocityY: Double = 0
    @MainActor @Published private(set) var modelInput: CGImage?
    /// Why the decoder produced nothing, if it produced nothing.
    @MainActor @Published private(set) var detectorError: String?
    /// Background-registration correction, in frame heights.
    @MainActor @Published private(set) var cameraShift: Double = 0
    /// The camera is moving too much to count reliably.
    @MainActor @Published private(set) var tooShaky = false
    /// Where the most recent touch landed, and a token that changes with it, so
    /// the view can fire one pulse per touch without re-firing on every frame.
    @MainActor @Published private(set) var lastTouchAt: CGPoint?
    @MainActor @Published private(set) var lastTouchToken = 0
    /// Detections thrown out as impossible - wrong size, or teleporting.
    @MainActor @Published private(set) var implausible = 0
    @MainActor @Published private(set) var isRecording = false
    @MainActor @Published private(set) var isPreparingRecording = false
    @MainActor @Published private(set) var isFinishingRecording = false
    @MainActor @Published private(set) var isReady = false
    @MainActor @Published private(set) var recordingError: String?
    @MainActor @Published private(set) var processedFrames = 0
    @MainActor @Published private(set) var recordingElapsed: Double = 0
    @MainActor @Published private(set) var recentTouchTimes: [Double] = []
    @MainActor private var previewRequest: CaptureRequest?
    @MainActor private var recordingRequest: CaptureRequest?
    @MainActor private var previewTask: Task<Void, Never>?
    /// Touches from the finished run, with times relative to the recording.
    @MainActor @Published private(set) var recordedTouches: [RecordedTouch] = []
    /// Ball position on the analysed subset of the finished run.
    @MainActor @Published private(set) var recordedTrack: [RecordedFrame] = []
    /// The finished recording, ready to review.
    @MainActor @Published private(set) var recordingURL: URL?

    private let session = AVCaptureSession()
    /// Session configuration and all detector/counter state belong to this queue.
    private let queue = DispatchQueue(label: "kicklab.camera.analysis", qos: .userInitiated)
    private let captureQueue = DispatchQueue(label: "kicklab.camera.capture", qos: .userInitiated)
    @MainActor @Published private(set) var capturePerformance = CaptureCadenceSnapshot()
    // These fields belong only to captureQueue.
    private var captureRecording: CaptureRequest?
    private var liveBuffer = LiveAnalysisBuffer<LiveFrame>()
    private var captureStats = CaptureCadenceSnapshot()
    private var captureStartSeconds: Double?
    private var capturePosition: AVCaptureDevice.Position = .back
    private struct LiveFrame {
        let pixels: CVPixelBuffer
        let sourceTime: Double
        let startTime: Double
        let captureDrops: Int
        let identity: RecordedFrameIdentity?
    }
    @MainActor @Published private(set) var performance = DetectorPerformanceSnapshot()
    private let performanceMonitor = DetectorPerformance()
    private var detector: BallDetector?
    private var counter = StreamingCounter()
    private var contactVerifier: JugglingContactVerifier?
    private var frameIndex = 0
    private var detectedFrames = 0
    private var lastFpsStamp = CFAbsoluteTimeGetCurrent()
    private var framesSinceStamp = 0
    private var lastPublish = CFAbsoluteTimeGetCurrent()
    private let recorder = Recorder()
    private let compensator = MotionCompensator()
    private var plausibility = BallPlausibility()
    private var lastBallRect: CGRect?
    /// Enabled in normal capture; disabling it is a diagnostic comparison.
    var motionCompensationEnabled = true
    private var activeRecording: CaptureRequest?
    private var touchesThisRun: [RecordedTouch] = []
    private var trackThisRun: [RecordedFrame] = []
    private var analyzedIdentities: [RecordedFrameIdentity] = []
    private var analysisEvaluations: [CaptureAnalysisEvidence.Evaluation] = []
    private var capturePipelineSignature: String?
    private var recordingStartSeconds: Double = 0
    private var currentPosition: AVCaptureDevice.Position = .back
    private var videoInput: AVCaptureDeviceInput?
    /// Keeps capture rotation correct per lens (front vs back differ).
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    @MainActor @Published private(set) var cameraPosition: AVCaptureDevice.Position = .back

    var captureSession: AVCaptureSession { session }

    @MainActor
    func start() {
        guard previewRequest == nil else { return }
        let request = CaptureRequest()
        previewRequest = request
        status = "starting camera"
        previewTask = Task {
            guard await requestAccess() else {
                guard !request.isCancelled else { return }
                previewRequest = nil
                status = "camera permission denied"
                return
            }
            guard !request.isCancelled, !Task.isCancelled else { return }
            queue.async { [weak self] in
                guard let self, !request.isCancelled else { return }
                // Opening this screen starts only the viewfinder. No model is
                // loaded and capture callbacks do no analysis until Record.
                let configured = self.configure(position: self.currentPosition)
                if configured, !request.isCancelled { self.session.startRunning() }
                Task { @MainActor in
                    guard self.previewRequest === request, !request.isCancelled else { return }
                    self.isReady = configured
                    self.status = configured ? "preview only" : "camera unavailable"
                    if !configured { self.previewRequest = nil }
                }
            }
        }
    }

    @MainActor
    func stop() {
        previewRequest?.cancel()
        previewRequest = nil
        previewTask?.cancel()
        previewTask = nil
        stopRecording()
        isReady = false
        status = "stopped"
        // Retain the queue owner until the pending stop completes.
        queue.async { [self] in session.stopRunning() }
    }

    /// Switch the preview lens while no recording is starting or active.
    @MainActor
    func flipCamera() {
        guard isReady, !isRecording, !isPreparingRecording, !isFinishingRecording,
              let request = previewRequest else { return }
        let next: AVCaptureDevice.Position = cameraPosition == .back ? .front : .back
        isReady = false
        queue.async { [weak self] in
            guard let self, !request.isCancelled else { return }
            let configured = self.configure(position: next)
            Task { @MainActor in
                guard self.previewRequest === request, !request.isCancelled else { return }
                self.isReady = configured
                self.status = configured ? "preview only" : "camera unavailable"
            }
        }
    }

    @MainActor
    func reset() {
        touchCount = 0
        detections = 0
        queue.async { [weak self] in
            let verifier = self?.contactVerifier
            verifier?.reset()
            self?.counter = StreamingCounter(rejectsHandContact: { [weak verifier] in
                verifier?.rejectsHandContact(at: $0) ?? false
            }, recordTrace: true, footContactEvidence: JugglingContactVerifier.enabled ? { [weak verifier] in
                verifier?.footEvidence(at: $0)
            } : nil)
            self?.plausibility.reset()
            self?.frameIndex = 0
            self?.detectedFrames = 0
        }
    }

    @MainActor
    func startRecording() {
        guard isReady, recordingRequest == nil, !isFinishingRecording else { return }
        let request = CaptureRequest()
        recordingRequest = request
        isPreparingRecording = true
        recordingError = nil
        detectorError = nil
        recordedTouches = []
        recordedTrack = []
        recordingURL = nil
        touchCount = 0
        detections = 0
        processedFrames = 0
        recordingElapsed = 0
        recentTouchTimes = []
        performance = DetectorPerformanceSnapshot()
        status = "preparing recording"
        queue.async { [weak self] in
            guard let self, !request.isCancelled else { return }
            do {
                let baseline = DetectorPerformance.memoryMB()
                let started = ProcessInfo.processInfo.systemUptime
                let signatureBeforeLoad = SessionAnalysisStore.pipelineSignature()
                let loaded = try BallDetector()
                guard !request.isCancelled else { return }
                self.detector = loaded
                self.capturePipelineSignature = signatureBeforeLoad == SessionAnalysisStore.pipelineSignature()
                    ? signatureBeforeLoad : nil
                self.performanceMonitor.loaded(model: loaded.modelName, baselineMB: baseline,
                    milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000)
            } catch {
                Task { @MainActor in
                    guard self.recordingRequest === request, !request.isCancelled else { return }
                    self.recordingError = "Couldn’t start detection: \(error.localizedDescription)"
                    self.stopRecording()
                }
                return
            }
            self.touchesThisRun = []
            self.trackThisRun = []
            self.analyzedIdentities = []
            self.analysisEvaluations = []
            // A fresh counter: a run's count should start at zero.
            let verifier = JugglingContactVerifier.enabled ? JugglingContactVerifier() : nil
            verifier?.warmUp()
            guard !request.isCancelled else { return }
            self.contactVerifier = verifier
            self.counter = StreamingCounter(rejectsHandContact: { [weak verifier] in
                verifier?.rejectsHandContact(at: $0) ?? false
            }, recordTrace: true, footContactEvidence: JugglingContactVerifier.enabled ? { [weak verifier] in
                verifier?.footEvidence(at: $0)
            } : nil)
            self.plausibility.reset()
            self.frameIndex = 0
            self.detectedFrames = 0
            self.lastBallRect = nil
            self.framesSinceStamp = 0
            self.lastFpsStamp = CFAbsoluteTimeGetCurrent()
            self.lastPublish = 0
            self.compensator.reset()
            self.activeRecording = request
            self.captureQueue.async {
                guard !request.isCancelled else { return }
                self.captureRecording = request
                self.liveBuffer = LiveAnalysisBuffer()
                self.captureStartSeconds = nil
                var fresh = CaptureCadenceSnapshot()
                fresh.selectedFPS = self.captureStats.selectedFPS
                fresh.width = self.captureStats.width
                fresh.height = self.captureStats.height
                fresh.position = self.captureStats.position
                self.captureStats = fresh
            }
            // isRecording becomes true when the first frame opens the writer.
        }
    }

    @MainActor
    func clearRecording() {
        recordingURL = nil
    }

    @MainActor
    func stopRecording() {
        guard let request = recordingRequest else { return }
        request.cancel()
        recordingRequest = nil
        isRecording = false
        isPreparingRecording = false
        isFinishingRecording = true
        clearLiveDetection()
        status = isReady ? "preview only" : "stopped"
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.captureRecording = nil
            self.liveBuffer.cancelPending()
            let didWriteFrames = self.recorder.writtenFrames > 0
            self.captureStats.writtenFrames = self.recorder.writtenFrames
            self.captureStats.writerDrops = self.recorder.droppedFrames
            self.captureStats.analysisOffered = self.liveBuffer.offered
            self.captureStats.analysisThrottled = self.liveBuffer.throttled
            self.captureStats.analysisReplaced = self.liveBuffer.replaced
            let capture = self.captureStats
            let ledger = self.recorder.frameIdentities
            self.recorder.stop { url in
                // Serial analysis work has completed before this cleanup runs.
                self.queue.async { self.finishRecording(request, video: url, capture: capture,
                                                      didWriteFrames: didWriteFrames, ledger: ledger) }
            }
        }
    }

    private func finishRecording(_ request: CaptureRequest, video url: URL?,
                                 capture: CaptureCadenceSnapshot, didWriteFrames: Bool, ledger: [RecordedFrameIdentity]) {
        let wasActive = activeRecording === request
        activeRecording = nil
        let late = wasActive && didWriteFrames ? counter.flush() : []
        for touch in late {
            touchesThisRun.append(RecordedTouch(index: touch.index,
                time: Double(touch.timestampMs) / 1000.0 - recordingStartSeconds,
                x: touch.x, y: touch.y))
        }
        let touches = wasActive ? touchesThisRun : []
        let track = wasActive ? trackThisRun : []
        let count = wasActive ? counter.count : 0
        if let url, didWriteFrames {
            let analyzed = analyzedIdentities
            let trace = wasActive ? counter.traceSnapshot() : nil
            let timeOrigin = recordingStartSeconds
            let signature = capturePipelineSignature
            let evidence = wasActive && signature == SessionAnalysisStore.pipelineSignature()
                ? signature.map { CaptureAnalysisEvidence(version: 1, pipelineSignature: $0,
                                                         evaluations: analysisEvaluations) } : nil
            Task.detached(priority:.utility) {
                await CaptureSessionTimeline.persist(source:url,frames:ledger,analyzed:analyzed,
                    observations:track,touches:touches,count:count, counterTrace:trace,
                    timeOriginSeconds:timeOrigin,evidence:evidence)
            }
        }
        var finalCapture = capture
        finalCapture.analysedFrames = wasActive ? frameIndex : 0
        if let url {
            let folder = URL.documentsDirectory.appendingPathComponent("CaptureCadence", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? JSONEncoder().encode(finalCapture).write(to: folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".json"))
        }
        DetectorRecordingReview.save(video: url, model: detector?.modelName ?? "Not loaded",
            threshold: detector?.activeBallThreshold ?? 0, frames: frameIndex, count: count,
            touches: touches, track: track, roiFullFrames: detector?.fullFrameCount ?? 0,
            roiCropFrames: detector?.cropFrameCount ?? 0,
            handChecks: contactVerifier?.checkedContacts ?? 0,
            rejectedHands: contactVerifier?.rejectedContacts ?? 0,
            handCheckError: contactVerifier?.lastError)
        contactVerifier = nil
        detector = nil
        capturePipelineSignature = nil
        compensator.reset()
        lastBallRect = nil
        performanceMonitor.finish()
        Task { @MainActor in
            self.isFinishingRecording = false
            self.performance.model = "Not loaded"
            self.performance.captureDrops = finalCapture.captureDrops
            self.capturePerformance = finalCapture
            self.recordedTouches = touches
            self.recordedTrack = track
            self.recordingURL = url
            self.touchCount = count
            if url == nil, wasActive, self.previewRequest != nil, self.recordingError == nil {
                self.recordingError = "No video frames were saved. Please try recording again."
            }
        }
    }

    @MainActor
    private func clearLiveDetection() {
        fps = 0
        ballScore = 0
        ballBox = nil
        personBox = nil
        ballVelocityY = 0
        modelInput = nil
        lastTouchAt = nil
        cameraShift = 0
        tooShaky = false
    }

    private func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Called on `queue`.
    private func configure(position: AVCaptureDevice.Position) -> Bool {
        session.beginConfiguration()

        if session.inputs.isEmpty {
            session.sessionPreset = .hd1280x720
        }

        if let videoInput {
            session.removeInput(videoInput)
            self.videoInput = nil
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                   position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            Task { @MainActor in self.status = "no camera" }
            return false
        }
        session.addInput(input)
        videoInput = input
        currentPosition = position
        Task { @MainActor in self.cameraPosition = position }

        // Only wire the output once.
        if session.outputs.isEmpty {
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                        kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: captureQueue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                return false
            }
            session.addOutput(output)
        }

        do {
            let configured = try CaptureFrameRate.configure(device)
            captureQueue.async {
                self.captureStats = configured
                self.capturePosition = position
            }
            Task { @MainActor in self.capturePerformance = configured }
        } catch {
            session.commitConfiguration()
            Task { @MainActor in self.recordingError = error.localizedDescription }
            return false
        }

        // Commit first, then set connection props — flipping mid-session was
        // silently dropping orientation/mirroring when applied inside the edit.
        session.commitConfiguration()

        applyOrientation(to: session.outputs.first?.connection(with: .video),
                         device: device, position: position)
        return true
    }

    /// Keep detection + recorded buffers upright for both lenses.
    ///
    /// Front and back need different rotation angles; hardcoding 90 made front
    /// clips write landscape and replay sideways.
    private func applyOrientation(to connection: AVCaptureConnection?,
                                  device: AVCaptureDevice,
                                  position: AVCaptureDevice.Position) {
        guard let connection else { return }

        // Required before isVideoMirrored can stick.
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = position == .front
        }

        rotationObservation?.invalidate()
        let coordinator = AVCaptureDevice.RotationCoordinator(
            device: device, previewLayer: nil)
        rotationCoordinator = coordinator

        let applyAngle = { [weak connection] in
            guard let connection else { return }
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
        applyAngle()
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture, options: [.new]
        ) { [weak self] _, _ in
            self?.queue.async { applyAngle() }
        }
    }
}

extension CameraSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let request = captureRecording, !request.isCancelled else { return }
        captureStats.captureDrops += 1
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let request = captureRecording, !request.isCancelled,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let sourceTime = CMTimeGetSeconds(time)
        guard sourceTime.isFinite else { return }
        captureStats.receivedFrames += 1

        // Save every delivered camera frame before offering a subset to inference.
        if !recorder.isRecording {
            do {
                let w = CVPixelBufferGetWidth(pixels)
                let h = CVPixelBufferGetHeight(pixels)
                try recorder.start(width: w, height: h, cameraPosition: capturePosition)
                captureStartSeconds = sourceTime
            } catch {
                request.cancel()
                Task { @MainActor in
                    guard self.recordingRequest === request else { return }
                    self.recordingError = "Couldn’t start recording: \(error.localizedDescription)"
                    self.stopRecording()
                }
                return
            }
            Task { @MainActor in
                guard self.recordingRequest === request, !request.isCancelled else { return }
                self.isPreparingRecording = false
                self.isRecording = true
                self.status = "recording"
            }
        }
        guard !request.isCancelled else { return }
        let identity = recorder.append(pixels, at: time)
        captureStats.duration = max(0, sourceTime - (captureStartSeconds ?? sourceTime))
        let frame = LiveFrame(pixels: pixels, sourceTime: sourceTime,
                              startTime: captureStartSeconds ?? sourceTime,
                              captureDrops: captureStats.captureDrops, identity: identity)
        if let work = liveBuffer.offer(frame, at: sourceTime) { submit(work, request: request) }
    }

    /// Invoked only on captureQueue. The callback releases the active frame
    /// before selecting the newest pending observation; there is no backlog.
    private func submit(_ frame: LiveFrame, request: CaptureRequest) {
        queue.async { [weak self] in
            guard let self else { return }
            autoreleasepool { self.analyse(frame, request: request) }
            self.captureQueue.async {
                guard self.captureRecording === request, !request.isCancelled else { return }
                if let next = self.liveBuffer.finish() { self.submit(next, request: request) }
            }
        }
    }

    private func analyse(_ frame: LiveFrame, request: CaptureRequest) {
        guard activeRecording === request, !request.isCancelled, let detector else { return }
        let pixels = frame.pixels
        let sourceTime = frame.sourceTime
        recordingStartSeconds = frame.startTime
        let stampMs = Int(sourceTime * 1000)
        let index = frameIndex
        frameIndex += 1
        var inferenceSucceeded = true
        var found = autoreleasepool { () -> FrameDetections in
            do { return try detector.detect(pixels, timestamp: sourceTime) }
            catch { inferenceSucceeded = false; return FrameDetections(ball: nil, person: nil) }
        }
        guard !request.isCancelled else { return }
        if DetectorRecordingReview.memoryGuardExceeded {
            request.cancel()
            Task { @MainActor in
                guard self.recordingRequest === request else { return }
                self.recordingError = "Experimental detector exceeded its memory test limit. Recording stopped."
                self.stopRecording()
            }
            return
        }
        let performance = performanceMonitor.observe(inferenceMS: detector.lastInferenceMS,
            preprocessMS: detector.lastPreprocessMS, totalMS: detector.lastTotalMS, recording: true, captureDrops: frame.captureDrops,
            roiFullFrames: detector.fullFrameCount, roiCropFrames: detector.cropFrameCount)
        // Drop detections that cannot be the ball we have been following. See
        // BallPlausibility: a stationary object in the room scoring 0.06 was
        // being counted as touches every time the real ball flickered.
        var rejectedByPlausibility = false
        if let ball = found.ball {
            found.ball = plausibility.accept(ball, frame: index)
            rejectedByPlausibility = found.ball == nil
        }
        if found.ball != nil { detectedFrames += 1 }
        lastBallRect = found.ball.map {
            CGRect(x: $0.x - $0.width / 2, y: $0.y - $0.height / 2,
                   width: $0.width, height: $0.height)
        }

        // Measure background motion while excluding the current ball. The
        // counter applies the same offset to ball and player geometry and
        // returns touch markers in the original video coordinates.
        compensator.excludeBall = lastBallRect
        let shift = motionCompensationEnabled ? compensator.update(pixels) : 0
        let ball = found.ball.map {
            BallObservation(frameIndex: index, timestampMs: stampMs,
                            x: $0.x, y: $0.y,
                            width: $0.width, height: $0.height,
                            confidence: $0.score)
        }
        let person = found.person.map {
            PersonBox(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }
        // Hold the count while the camera is moving too much to judge. Missing a
        // touch is recoverable; inventing one is not, and the user can see why.
        let shaky = compensator.isTooShaky
        if shaky { contactVerifier?.discardFrames() }
        else { contactVerifier?.store(pixels, frameIndex: index, timestampMs: stampMs, ball: found.ball) }
        let confirmed = counter.push(frameIndex: index, timestampMs: stampMs,
                                     ball: ball, person: person,
                                     cameraOffsetY: shift, reliable: !shaky, sourceFrameIndex: frame.identity?.index)
        if !request.isCancelled {
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
                trackThisRun.append(RecordedFrame(
                    time: Double(stampMs) / 1000.0 - recordingStartSeconds,
                    x: b.x, y: b.y, width: b.width, height: b.height, score: b.score,
                    smoothedX: judged?.x ?? b.x,
                    smoothedY: judged?.y ?? b.y,
                    vy: judged?.vy ?? 0,
                    motion: judged?.motion ?? .unknown,
                    detected: true,
                    person: person, ballMask: found.ballMask, usesBallMasks: found.usesBallMasks, identity: frame.identity))
            }
            for touch in confirmed {
                touchesThisRun.append(RecordedTouch(
                    index: touch.index,
                    time: Double(touch.timestampMs) / 1000.0 - recordingStartSeconds,
                    x: touch.x, y: touch.y))
            }
        }

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
        else { return }
        lastPublish = now
        // No consumer currently displays this snapshot; avoid a GPU readback
        // on every UI update while measuring live detector performance.
        detector.wantsModelInputSnapshot = false

        let liveTime = max(0, sourceTime - recordingStartSeconds)
        let recentTimes = touchesThisRun.suffix(8).map(\.time)
        let snapshot = (
            count: counter.count,
            score: found.ball?.score ?? 0,
            detected: detectedFrames,
            size: detector.lastInputSize,
            image: detector.lastModelInput,
            ballRect: found.ball.map {
                CGRect(x: $0.x - $0.width / 2, y: $0.y - $0.height / 2,
                       width: $0.width, height: $0.height)
            },
            personRect: found.person.map {
                CGRect(x: $0.x - $0.width / 2, y: $0.y - $0.height / 2,
                       width: $0.width, height: $0.height)
            },
            fps: measuredFps,
            error: detector.lastError,
            shift: shift,
            shaky: shaky,
            touched: confirmed.last.map { CGPoint(x: $0.x, y: $0.y) },
            dropped: plausibility.rejectedSize + plausibility.rejectedJump,
            vy: counter.lastPoint?.vy ?? 0
        )

        Task { @MainActor in
            // A stopped (or previous) take must not repopulate the idle HUD.
            guard self.recordingRequest === request, !request.isCancelled else { return }
            self.recordingElapsed = liveTime
            self.recentTouchTimes = recentTimes
            self.processedFrames = index + 1
            self.touchCount = snapshot.count
            self.ballScore = snapshot.score
            self.detections = snapshot.detected
            self.inputSize = "\(Int(snapshot.size.width))x\(Int(snapshot.size.height))"
            self.modelInput = snapshot.image
            self.ballBox = snapshot.ballRect
            self.personBox = snapshot.personRect
            self.ballVelocityY = snapshot.vy
            if let f = snapshot.fps { self.fps = f }
            self.detectorError = snapshot.error
            self.performance = performance
            self.cameraShift = snapshot.shift
            self.tooShaky = snapshot.shaky
            if let at = snapshot.touched {
                self.lastTouchAt = at
                self.lastTouchToken &+= 1
            }
            self.implausible = snapshot.dropped
        }
    }
}
