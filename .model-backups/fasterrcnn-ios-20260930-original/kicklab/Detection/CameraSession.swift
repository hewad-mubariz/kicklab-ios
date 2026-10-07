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
    /// How far the gyroscope says the frame has moved, in frame heights.
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
    /// Touches from the finished run, with times relative to the recording.
    @MainActor @Published private(set) var recordedTouches: [RecordedTouch] = []
    /// Ball position on every frame of the finished run.
    @MainActor @Published private(set) var recordedTrack: [RecordedFrame] = []
    /// The finished recording, ready to review.
    @MainActor @Published private(set) var recordingURL: URL?

    private let session = AVCaptureSession()
    /// Everything below is touched only on this serial queue.
    private let queue = DispatchQueue(label: "kicklab.camera", qos: .userInitiated)
    private var detector: BallDetector?
    private var counter = StreamingCounter()
    private var frameIndex = 0
    private var detectedFrames = 0
    private var lastFpsStamp = CFAbsoluteTimeGetCurrent()
    private var framesSinceStamp = 0
    private var lastPublish = CFAbsoluteTimeGetCurrent()
    private let recorder = Recorder()
    private let compensator = MotionCompensator()
    private var plausibility = BallPlausibility()
    private var lastBallRect: CGRect?
    /// Off by default until it has been checked on real footage: an untested
    /// correction can only make a working counter worse.
    var motionCompensationEnabled = true
    private var wantsRecording = false
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
        Task {
            guard await requestAccess() else {
                status = "camera permission denied"
                return
            }
            queue.async { [weak self] in
                guard let self else { return }
                do {
                    self.detector = try BallDetector()
                } catch {
                    Task { @MainActor in self.status = "model failed: \(error.localizedDescription)" }
                    return
                }
                self.configure(position: .back)
                self.session.startRunning()
                Task { @MainActor in self.status = "running" }
            }
        }
    }

    func stop() {
        queue.async { [session] in session.stopRunning() }
    }

    /// Switch front / back. Detection keeps running on whichever lens is live.
    /// Only call while not recording — writer size is fixed for the take.
    @MainActor
    func flipCamera() {
        guard !isRecording else { return }
        let next: AVCaptureDevice.Position = cameraPosition == .back ? .front : .back
        cameraPosition = next
        queue.async { [weak self] in
            self?.configure(position: next)
        }
    }

    @MainActor
    func reset() {
        touchCount = 0
        detections = 0
        queue.async { [weak self] in
            self?.counter = StreamingCounter()
            self?.plausibility.reset()
            self?.frameIndex = 0
            self?.detectedFrames = 0
        }
    }

    @MainActor
    func startRecording() {
        recordedTouches = []
        recordingURL = nil
        isRecording = true
        queue.async { [weak self] in
            guard let self else { return }
            self.touchesThisRun = []
            self.trackThisRun = []
            // A fresh counter: a run's count should start at zero.
            self.counter = StreamingCounter()
            self.plausibility.reset()
            self.frameIndex = 0
            self.detectedFrames = 0
            self.wantsRecording = true
            self.compensator.reset()
        }
        Task { @MainActor in
            self.touchCount = 0
            self.detections = 0
        }
    }

    @MainActor
    func clearRecording() {
        recordingURL = nil
    }

    @MainActor
    func stopRecording() {
        isRecording = false
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsRecording = false
            // Judge the frames still inside the lookahead window, or a touch in
            // the last 100ms of the run would never be counted.
            let late = self.counter.flush()
            for touch in late {
                self.touchesThisRun.append(RecordedTouch(
                    index: touch.index,
                    time: Double(touch.timestampMs) / 1000.0 - self.recordingStartSeconds,
                    x: touch.x, y: touch.y))
            }
            let touches = self.touchesThisRun
            let track = self.trackThisRun
            let count = self.counter.count
            self.recorder.stop { url in
                Task { @MainActor in
                    self.recordedTouches = touches
                    self.recordedTrack = track
                    self.recordingURL = url
                    self.touchCount = count
                }
            }
        }
    }

    private func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Called on `queue`.
    private func configure(position: AVCaptureDevice.Position) {
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
            return
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
            if session.canAddOutput(output) { session.addOutput(output) }
        }

        // Commit first, then set connection props — flipping mid-session was
        // silently dropping orientation/mirroring when applied inside the edit.
        session.commitConfiguration()

        applyOrientation(to: session.outputs.first?.connection(with: .video),
                         device: device, position: position)
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
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Already on `queue`. Do the work here; publish only the results.
        guard let detector, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let stampMs = Int(CMTimeGetSeconds(
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1000)

        let index = frameIndex
        frameIndex += 1

        // Record the frames that are being judged, so review shows what was seen.
        if wantsRecording {
            if !recorder.isRecording {
                let w = CVPixelBufferGetWidth(pixels)
                let h = CVPixelBufferGetHeight(pixels)
                try? recorder.start(width: w, height: h, cameraPosition: currentPosition)
                recordingStartSeconds = CMTimeGetSeconds(
                    CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            }
            recorder.append(pixels, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }

        var found = (try? detector.detect(pixels)) ?? FrameDetections(ball: nil, person: nil)
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

        // Undo the frame's own movement before the counter sees the ball. The
        // gyroscope knows how far the phone rotated; the picture does not.
        // Tell the compensator where the ball was last frame, so it can exclude
        // it and measure the background rather than the ball.
        compensator.excludeBall = lastBallRect
        let shift = motionCompensationEnabled ? compensator.update(pixels) : 0
        let ball = found.ball.map {
            BallObservation(frameIndex: index, timestampMs: stampMs,
                            x: $0.x, y: $0.y + shift,
                            width: $0.width, height: $0.height,
                            confidence: $0.score)
        }
        let person = found.person.map {
            PersonBox(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }
        // Hold the count while the camera is moving too much to judge. Missing a
        // touch is recoverable; inventing one is not, and the user can see why.
        let shaky = compensator.isTooShaky
        let confirmed = shaky
            ? []
            : counter.push(frameIndex: index, timestampMs: stampMs,
                           ball: ball, person: person)
        if wantsRecording {
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
                    person: person))
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
        detector.wantsModelInputSnapshot = true

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
