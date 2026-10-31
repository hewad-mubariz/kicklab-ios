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
    nonisolated enum Pipeline: Sendable { case juggling, videoOnly }
    private let pipeline: Pipeline

    init(pipeline: Pipeline = .juggling) {
        self.pipeline = pipeline
        super.init()
    }

    /// Plain video capture needs neither a detector nor a floor estimate.
    @MainActor var canRecord: Bool {
        isReady && (pipeline == .videoOnly || isTrackingReady) &&
            recordingRequest == nil && !isFinishingRecording
    }
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
    @MainActor @Published private(set) var touchDiagnostic: TouchDebugEvent?
    #if DEBUG
    @MainActor @Published private(set) var activePlayers: [ActiveJugglerTracker.Player] = []
    @MainActor @Published private(set) var activePlayer: ActivePlayerSelection?
    #endif
    @MainActor private(set) var recordedDiagnostics: [TouchDebugEvent] = []
    /// Detections thrown out as impossible - wrong size, or teleporting.
    @MainActor @Published private(set) var implausible = 0
    @MainActor @Published private(set) var isRecording = false
    @MainActor @Published private(set) var isPreparingRecording = false
    @MainActor @Published private(set) var isFinishingRecording = false
    /// Preview readiness is separate from tracking so lens switching stays available during warmup.
    @MainActor @Published private(set) var isReady = false
    @MainActor @Published private(set) var isPreparingTracking = false
    @MainActor @Published private(set) var isTrackingReady = false
    @MainActor @Published private(set) var trackingPreparationError: String?
    @MainActor private var trackingRequest: CaptureRequest?
    /// A reopen during writer finalization should prepare once cleanup completes.
    @MainActor private var wantsPreparedPreview = false
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
    /// Camera configuration never waits behind Core ML loading or inference.
    private let sessionQueue = DispatchQueue(label: "kicklab.camera.session", qos: .userInitiated)
    /// All detector/counter state belongs to this queue.
    private let queue = DispatchQueue(label: "kicklab.camera.analysis", qos: .userInitiated)
    private let captureQueue = DispatchQueue(label: "kicklab.camera.capture", qos: .userInitiated)
    @MainActor @Published private(set) var capturePerformance = CaptureCadenceSnapshot()
    // These fields belong only to captureQueue.
    private var captureRecording: CaptureRequest?
    private var liveBuffer = LiveAnalysisBuffer<LiveAnalysisFrame>()
    private var captureStats = CaptureCadenceSnapshot()
    private var captureStartSeconds: Double?
    private var capturePosition: AVCaptureDevice.Position = .back
    #if DEBUG
    private var lastDebugCapturePublish = 0.0 // captureQueue, wall clock
    #endif
    #if DEBUG && TOUCH_COUNTING_DEBUG
    @MainActor @Published private(set) var debugFrameProfile = DebugFrameProfile.normal
    @MainActor @Published private(set) var debugFrameTest = DebugFrameTestSnapshot()
    private var debugFrameRun = DebugFrameTestRun(profile: .normal) // captureQueue
    private var finishedDebugFrameTest = DebugFrameTestSnapshot() // analysis queue

    @MainActor func setDebugFrameProfile(_ profile: DebugFrameProfile) {
        guard recordingRequest == nil, !isFinishingRecording else { return }
        debugFrameProfile = profile
        debugFrameTest = .init(profile: profile)
    }
    #endif
    @MainActor @Published private(set) var performance = DetectorPerformanceSnapshot()
    private let liveAnalysis = LiveJugglingAnalysis()
    private let recorder = Recorder()
    /// Enabled in normal capture; disabling it is a diagnostic comparison.
    var motionCompensationEnabled = true
    private var activeRecording: CaptureRequest?
    private var currentPosition: AVCaptureDevice.Position = .back
    private var videoInput: AVCaptureDeviceInput?
    /// Keeps capture rotation correct per lens (front vs back differ).
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    // Session-queue only. A video's pixel dimensions cannot change mid-file.
    private var holdsVideoOrientation = false

    @MainActor @Published private(set) var cameraPosition: AVCaptureDevice.Position = .back

    var captureSession: AVCaptureSession { session }

    @MainActor
    func start() {
        wantsPreparedPreview = true
        if previewRequest != nil {
            prepareTracking()
            return
        }
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
            sessionQueue.async { [weak self] in
                guard let self, !request.isCancelled else { return }
                // Show the viewfinder first. Preparation runs independently;
                // capture callbacks still do no analysis until an explicit Record.
                let configured = self.configure(position: self.currentPosition)
                if configured, !request.isCancelled { self.session.startRunning() }
                Task { @MainActor in
                    guard self.previewRequest === request, !request.isCancelled else { return }
                    self.isReady = configured
                    self.status = configured ? "preview only" : "camera unavailable"
                    if configured { self.prepareTracking() }
                    else { self.previewRequest = nil }
                }
            }
        }
    }

    @MainActor
    func stop() {
        wantsPreparedPreview = false
        previewRequest?.cancel()
        previewRequest = nil
        previewTask?.cancel()
        previewTask = nil
        trackingRequest?.cancel()
        trackingRequest = nil
        isPreparingTracking = false
        isTrackingReady = false
        trackingPreparationError = nil
        stopRecording()
        isReady = false
        status = "stopped"
        // Retain the queue owner until the pending stop completes.
        sessionQueue.async { [self] in session.stopRunning() }
        queue.async { [self] in
            // Finalization owns a detector that has actually recorded frames.
            if activeRecording == nil { releaseTracking() }
        }
    }

    /// Switch the preview lens while no recording is starting or active.
    @MainActor
    func flipCamera() {
        guard isReady, !isRecording, !isPreparingRecording, !isFinishingRecording,
              let request = previewRequest else { return }
        let next: AVCaptureDevice.Position = cameraPosition == .back ? .front : .back
        isReady = false
        sessionQueue.async { [weak self] in
            guard let self, !request.isCancelled else { return }
            let configured = self.configure(position: next)
            Task { @MainActor in
                guard self.previewRequest === request, !request.isCancelled else { return }
                self.isReady = configured
                self.status = configured ? "preview only" : "camera unavailable"
            }
        }
    }

    /// One bounded warmup while framing the shot; never a continuous preview-analysis loop.
    /// Repeated calls (including lens changes) do not reload a ready or in-flight model.
    @MainActor
    func prepareTracking() {
        guard pipeline == .juggling, isReady, previewRequest != nil, trackingRequest == nil,
              recordingRequest == nil, !isFinishingRecording else { return }
        let request = CaptureRequest()
        trackingRequest = request
        isPreparingTracking = true
        isTrackingReady = false
        trackingPreparationError = nil
        queue.async { [weak self] in
            guard let self, !request.isCancelled else { return }
            autoreleasepool {
                do {
                    guard try self.liveAnalysis.prepare(request: request) else { return }
                    Task { @MainActor in
                        guard self.trackingRequest === request, !request.isCancelled else { return }
                        self.isPreparingTracking = false
                        self.isTrackingReady = true
                    }
                } catch {
                    guard !request.isCancelled else { return }
                    self.releaseTracking()
                    Task { @MainActor in
                        guard self.trackingRequest === request, !request.isCancelled else { return }
                        self.trackingRequest = nil
                        self.isPreparingTracking = false
                        self.isTrackingReady = false
                        self.trackingPreparationError = error.localizedDescription
                    }
                }
            }
        }
    }

    /// Analysis-queue only. Do not retain the model on home, in the editor or in the background.
    private func releaseTracking() {
        liveAnalysis.release()
    }

    @MainActor
    func reset() {
        touchCount = 0
        touchDiagnostic = nil
        #if DEBUG
        activePlayers = []; activePlayer = nil
        #endif
        recordedDiagnostics = []
        detections = 0
        queue.async { [weak self] in
            self?.liveAnalysis.resetCounter()
        }
    }

    @MainActor
    func startRecording() {
        guard canRecord else { return }
        let trackingRequest = trackingRequest
        if pipeline == .juggling {
            guard let trackingRequest, !trackingRequest.isCancelled else { return }
        }
        let request = CaptureRequest()
        recordingRequest = request
        wantsPreparedPreview = false
        isPreparingRecording = true
        isTrackingReady = false
        recordingError = nil
        detectorError = nil
        recordedTouches = []
        recordedTrack = []
        recordingURL = nil
        touchCount = 0
        touchDiagnostic = nil
        #if DEBUG
        activePlayers = []; activePlayer = nil
        #endif
        recordedDiagnostics = []
        detections = 0
        processedFrames = 0
        recordingElapsed = 0
        recentTouchTimes = []
        performance = DetectorPerformanceSnapshot()
        #if DEBUG && TOUCH_COUNTING_DEBUG
        let frameProfile = debugFrameProfile
        debugFrameTest = .init(profile: frameProfile)
        #endif
        #if DEBUG
        let finalTestFiles = pipeline == .juggling ? FinalTestCoordinator.shared.beginCapture(self) : nil
        #endif
        status = "preparing recording"
        queue.async { [weak self] in
            guard let self, !request.isCancelled else { return }
            if self.pipeline == .juggling {
                guard let trackingRequest, !trackingRequest.isCancelled, self.liveAnalysis.isPrepared else { return }
            }
            #if DEBUG
            self.liveAnalysis.finalTestFiles = finalTestFiles
            #endif
            self.liveAnalysis.beginRecording()
            self.activeRecording = request
            let beginCapture = {
                guard !request.isCancelled else { return }
                self.captureRecording = request
                self.liveBuffer = LiveAnalysisBuffer()
                #if DEBUG && TOUCH_COUNTING_DEBUG
                self.debugFrameRun = .init(profile: frameProfile)
                #endif
                self.captureStartSeconds = nil
                var fresh = CaptureCadenceSnapshot()
                fresh.selectedFPS = self.captureStats.selectedFPS
                fresh.width = self.captureStats.width
                fresh.height = self.captureStats.height
                fresh.position = self.captureStats.position
                self.captureStats = fresh
            }
            if self.pipeline == .videoOnly {
                self.sessionQueue.async {
                    guard !request.isCancelled else { return }
                    self.holdsVideoOrientation = true
                    self.captureQueue.async(execute: beginCapture)
                }
            } else {
                self.captureQueue.async(execute: beginCapture)
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
        #if DEBUG
        FinalTestCoordinator.shared.captureStopping(self)
        #endif
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
            #if DEBUG && TOUCH_COUNTING_DEBUG
            let debugTest = self.debugFrameRun.snapshot
            #endif
            let ledger = self.recorder.frameIdentities
            self.recorder.stop { result in
                self.sessionQueue.async {
                    self.holdsVideoOrientation = false
                    if self.pipeline == .videoOnly { self.updateCaptureOrientation() }
                }
                // Serial analysis work has completed before this cleanup runs.
                self.queue.async {
                    #if DEBUG && TOUCH_COUNTING_DEBUG
                    self.finishedDebugFrameTest = debugTest
                    #endif
                    self.finishRecording(request, result: result, capture: capture,
                                         didWriteFrames: didWriteFrames, ledger: ledger)
                }
            }
        }
    }

    private func finishRecording(_ request: CaptureRequest, result: Result<URL, Error>,
                                 capture: CaptureCadenceSnapshot, didWriteFrames: Bool, ledger: [RecordedFrameIdentity]) {
        let url = try? result.get()
        let wasActive = activeRecording === request
        activeRecording = nil
        let analysis = liveAnalysis.finish(flush: pipeline == .juggling && wasActive && didWriteFrames,
                                           wasActive: wasActive)
        if pipeline == .juggling, let url, didWriteFrames, !analysis.qualityFailed {
            Task.detached(priority: .utility) {
                await CaptureSessionTimeline.persist(source: url, frames: ledger, analyzed: analysis.analyzed,
                    observations: analysis.track, touches: analysis.touches, count: analysis.count,
                    counterTrace: analysis.trace, timeOriginSeconds: analysis.timeOrigin, evidence: analysis.evidence)
            }
        }
        var finalCapture = capture
        finalCapture.analysedFrames = analysis.frameCount
        #if DEBUG && TOUCH_COUNTING_DEBUG
        var debugTest = finishedDebugFrameTest
        debugTest.captureDrops = capture.captureDrops
        debugTest.writerDrops = capture.writerDrops
        debugTest.replaced = capture.analysisReplaced
        if pipeline == .juggling, wasActive, didWriteFrames {
            let report = DebugFrameTestReport(recordedAt: Date(), videoFile: url?.lastPathComponent,
                test: debugTest, capture: finalCapture, touches: analysis.count, analysisFailed: analysis.qualityFailed)
            DispatchQueue.global(qos: .utility).async { report.save() }
        }
        #endif
        Task { @MainActor in
            self.trackingRequest?.cancel()
            self.trackingRequest = nil
            self.isTrackingReady = false
            self.isFinishingRecording = false
            self.recordedDiagnostics = analysis.diagnostics
            self.performance.model = "Not loaded"
            self.performance.captureDrops = finalCapture.captureDrops
            self.capturePerformance = finalCapture
            #if DEBUG && TOUCH_COUNTING_DEBUG
            self.debugFrameTest = debugTest
            #endif
            if analysis.qualityFailed, self.recordingError == nil {
                self.recordingError = VideoSafetyPolicy.Failure.analysis.localizedDescription
            }
            self.recordedTouches = analysis.touches
            self.recordedTrack = analysis.track
            self.recordingURL = url
            self.touchCount = analysis.count
            if url == nil, wasActive, self.previewRequest != nil, self.recordingError == nil {
                if case .failure(let error) = result { self.recordingError = error.localizedDescription }
            }
            #if DEBUG
            FinalTestCoordinator.shared.captureFinished(self, trace: analysis.trace, timeOrigin: analysis.timeOrigin,
                touches: analysis.touches)
            #endif
            if self.wantsPreparedPreview { self.prepareTracking() }
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

    /// Called on `sessionQueue`.
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

        updateCaptureOrientation()
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture, options: [.new]
        ) { [weak self] _, _ in
            self?.sessionQueue.async { self?.updateCaptureOrientation() }
        }
    }

    private func updateCaptureOrientation() {
        guard !holdsVideoOrientation, let coordinator = rotationCoordinator,
              let connection = session.outputs.first?.connection(with: .video) else { return }
        let angle = coordinator.videoRotationAngleForHorizonLevelCapture
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
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
                try recorder.start(width: w, height: h, cameraPosition: capturePosition,
                                   pixelsAreUpright: pipeline == .videoOnly)
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
        let identity: RecordedFrameIdentity?
        do { identity = try recorder.append(pixels, at: time) }
        catch {
            request.cancel()
            liveBuffer.cancelPending()
            Task { @MainActor in
                guard self.recordingRequest === request else { return }
                self.recordingError = error.localizedDescription
                self.stopRecording()
            }
            return
        }
        captureStats.duration = max(0, sourceTime - (captureStartSeconds ?? sourceTime))
        #if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDebugCapturePublish >= 1 {
            lastDebugCapturePublish = now
            var snapshot = captureStats
            snapshot.writtenFrames = recorder.writtenFrames
            snapshot.writerDrops = recorder.droppedFrames
            snapshot.analysisOffered = liveBuffer.offered
            snapshot.analysisThrottled = liveBuffer.throttled
            snapshot.analysisReplaced = liveBuffer.replaced
            Task { @MainActor in
                guard self.recordingRequest === request, !request.isCancelled else { return }
                self.capturePerformance = snapshot
            }
        }
        #endif
        if pipeline == .videoOnly {
            // Capture cadence is independent of tracking. No model is loaded for this flow.
            if captureStats.receivedFrames % 6 == 0 {
                let elapsed = captureStats.duration
                Task { @MainActor in
                    guard self.recordingRequest === request, !request.isCancelled else { return }
                    self.recordingElapsed = elapsed
                }
            }
            return
        }
        #if DEBUG && TOUCH_COUNTING_DEBUG
        let shouldAnalyze = debugFrameRun.allows(sourceTime)
        if let stats = debugFrameRun.observe(at: sourceTime, capture: captureStats,
                                            writerDrops: recorder.droppedFrames, replaced: liveBuffer.replaced) {
            Task { @MainActor in
                guard self.recordingRequest === request, !request.isCancelled else { return }
                self.debugFrameTest = stats
            }
        }
        guard shouldAnalyze else { return }
        #endif
        let hostClock = CMClockGetHostTimeClock()
        let exposure = session.synchronizationClock.map { CMSyncConvertTime(time, from: $0, to: hostClock) } ?? time
        let exposureAge = CMTimeSubtract(CMClockGetTime(hostClock), exposure).seconds
        let due = ProcessInfo.processInfo.systemUptime - (exposureAge.isFinite ? max(0, exposureAge) : 0)
        let frame = LiveAnalysisFrame(pixels: pixels, sourceTime: sourceTime,
                              startTime: captureStartSeconds ?? sourceTime,
                              captureDrops: captureStats.captureDrops, identity: identity, sourceDueUptime: due)
        if let work = liveBuffer.offer(frame, at: sourceTime) { submit(work, request: request) }
    }

    /// Invoked only on captureQueue. The callback releases the active frame
    /// before selecting the newest pending observation; there is no backlog.
    private func submit(_ frame: LiveAnalysisFrame, request: CaptureRequest) {
        #if DEBUG && TOUCH_COUNTING_DEBUG
        debugFrameRun.submitted(at: frame.sourceTime)
        #endif
        queue.async { [weak self] in
            guard let self else { return }
            autoreleasepool { self.analyse(frame, request: request) }
            let targetFPS = self.liveAnalysis.recommendedFramesPerSecond
            self.captureQueue.async {
                guard self.captureRecording === request, !request.isCancelled else { return }
                self.liveBuffer.setFramesPerSecond(targetFPS)
                if let next = self.liveBuffer.finish() { self.submit(next, request: request) }
            }
        }
    }

    private func analyse(_ frame: LiveAnalysisFrame, request: CaptureRequest) {
        guard activeRecording === request, !request.isCancelled else { return }
        let snapshot: LiveAnalysisUpdate
        do {
            guard let update = try liveAnalysis.process(frame, request: request,
                motionCompensationEnabled: motionCompensationEnabled) else { return }
            snapshot = update
        } catch {
            request.cancel()
            Task { @MainActor in
                guard self.recordingRequest === request else { return }
                self.recordingError = error.localizedDescription
                self.stopRecording()
            }
            return
        }

        Task { @MainActor in
            // A stopped (or previous) take must not repopulate the idle HUD.
            guard self.recordingRequest === request, !request.isCancelled else { return }
            self.recordingElapsed = snapshot.liveTime
            self.recentTouchTimes = snapshot.recentTimes
            self.processedFrames = snapshot.processedFrames
            self.touchCount = snapshot.count
            self.touchDiagnostic = snapshot.diagnostic
            #if DEBUG
            self.activePlayers = snapshot.players; self.activePlayer = snapshot.player
            #endif
            self.ballScore = snapshot.score
            self.detections = snapshot.detected
            self.inputSize = "\(Int(snapshot.size.width))x\(Int(snapshot.size.height))"
            self.modelInput = snapshot.image
            self.ballBox = snapshot.ballRect
            self.personBox = snapshot.personRect
            self.ballVelocityY = snapshot.vy
            if let f = snapshot.fps { self.fps = f }
            self.detectorError = snapshot.error
            self.performance = snapshot.performance
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
