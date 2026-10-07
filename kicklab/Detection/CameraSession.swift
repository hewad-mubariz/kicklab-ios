//
//  CameraSession.swift
//  kicklab
//
//  Camera capture, detection and counting - with the work OFF the main thread.
//
//  A first version ran detection inside a @MainActor hop per frame. CoreML plus
//  a 3234-anchor decode on the main thread froze the UI outright: the tab bar
//  stopped responding and the fps readout sat at 0, because the thread that was
//  supposed to draw it was busy doing inference. Everything heavy now stays on
//  the capture queue, and only the finished numbers cross to the main actor.
//
//  Frames are dropped rather than queued when inference falls behind. A live
//  counter that buffers under load drifts further behind the player, which is
//  worse than missing a frame; the counter treats a gap as a gap, not as an
//  absent ball.
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
    /// Ball position on every frame of the finished run.
    @MainActor @Published private(set) var recordedTrack: [RecordedFrame] = []
    /// The finished recording, ready to review.
    @MainActor @Published private(set) var recordingURL: URL?

    private let session = AVCaptureSession()
    /// Everything below is touched only on this serial queue.
    private let queue = DispatchQueue(label: "kicklab.camera", qos: .userInitiated)
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
        queue.async { [session] in session.stopRunning() }
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
            })
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
                let loaded = try BallDetector()
                guard !request.isCancelled else { return }
                self.detector = loaded
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
            // A fresh counter: a run's count should start at zero.
            let verifier = JugglingContactVerifier.enabled ? JugglingContactVerifier() : nil
            self.contactVerifier = verifier
            self.counter = StreamingCounter(rejectsHandContact: { [weak verifier] in
                verifier?.rejectsHandContact(at: $0) ?? false
            })
            self.plausibility.reset()
            self.frameIndex = 0
            self.detectedFrames = 0
            self.lastBallRect = nil
            self.framesSinceStamp = 0
            self.lastFpsStamp = CFAbsoluteTimeGetCurrent()
            self.lastPublish = 0
            self.compensator.reset()
            self.activeRecording = request
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
        queue.async { [weak self] in
            guard let self else { return }
            let wasActive = self.activeRecording === request
            self.activeRecording = nil
            // Judge the frames still inside the lookahead window, or a touch in
            // the last 100ms of the run would never be counted.
            let late = wasActive && self.recorder.isRecording ? self.counter.flush() : []
            for touch in late {
                self.touchesThisRun.append(RecordedTouch(
                    index: touch.index,
                    time: Double(touch.timestampMs) / 1000.0 - self.recordingStartSeconds,
                    x: touch.x, y: touch.y))
            }
            let touches = wasActive ? self.touchesThisRun : []
            let track = wasActive ? self.trackThisRun : []
            let count = wasActive ? self.counter.count : 0
            let reviewModel = self.detector?.modelName ?? "Not loaded"
            let reviewThreshold = self.detector?.activeBallThreshold ?? 0
            let reviewFrames = self.frameIndex
            let roiFull = self.detector?.fullFrameCount ?? 0
            let roiCrops = self.detector?.cropFrameCount ?? 0
            let handChecks = self.contactVerifier?.checkedContacts ?? 0
            let rejectedHands = self.contactVerifier?.rejectedContacts ?? 0
            let handCheckError = self.contactVerifier?.lastError
            self.contactVerifier = nil
            self.detector = nil
            self.compensator.reset()
            self.lastBallRect = nil
            self.performanceMonitor.finish()
            self.recorder.stop { url in
                DetectorRecordingReview.save(video: url, model: reviewModel,
                    threshold: reviewThreshold, frames: reviewFrames, count: count,
                    touches: touches, track: track, roiFullFrames: roiFull, roiCropFrames: roiCrops,
                    handChecks: handChecks, rejectedHands: rejectedHands, handCheckError: handCheckError)
                Task { @MainActor in
                    self.isFinishingRecording = false
                    self.performance.model = "Not loaded"
                    self.recordedTouches = touches
                    self.recordedTrack = track
                    self.recordingURL = url
                    self.touchCount = count
                    if url == nil, wasActive, self.previewRequest != nil,
                       self.recordingError == nil {
                        self.recordingError = "No video frames were saved. Please try recording again."
                    }
                }
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
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                return false
            }
            session.addOutput(output)
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
        guard let request = activeRecording, !request.isCancelled else { return }
        performanceMonitor.droppedFrame()
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Already on `queue`. Do the work here; publish only the results.
        guard let request = activeRecording, !request.isCancelled,
              let detector, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let sourceTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let stampMs = Int(sourceTime * 1000)

        let index = frameIndex
        frameIndex += 1

        // Record the frames that are being judged, so review shows what was seen.
        if !recorder.isRecording {
            do {
                let w = CVPixelBufferGetWidth(pixels)
                let h = CVPixelBufferGetHeight(pixels)
                try recorder.start(width: w, height: h, cameraPosition: currentPosition)
                recordingStartSeconds = CMTimeGetSeconds(
                    CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
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
        recorder.append(pixels, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

        var found = autoreleasepool { (try? detector.detect(pixels, timestamp: sourceTime)) }
            ?? FrameDetections(ball: nil, person: nil)
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
            preprocessMS: detector.lastPreprocessMS, totalMS: detector.lastTotalMS, recording: recorder.isRecording,
            roiFullFrames: detector.fullFrameCount, roiCropFrames: detector.cropFrameCount)
        // Drop detections that cannot be the ball we have been following. See
        // BallPlausibility: a stationary object in the room scoring 0.06 was
        // being counted as touches every time the real ball flickered.
        if let ball = found.ball {
            found.ball = plausibility.accept(ball, frame: index)
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
                                     cameraOffsetY: shift, reliable: !shaky)
        if !request.isCancelled {
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
                    person: person, ballMask: found.ballMask, usesBallMasks: found.usesBallMasks))
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
