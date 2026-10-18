#if DEBUG && BALL_DETECTION_DEBUG
import AVFoundation
import Combine
import CoreGraphics
import Foundation

/// Capture keeps one newest waiting frame while inference runs. This avoids
/// waiting for another sensor tick after each prediction and bounds latency.
/// Detector, scoring and recording state are owned by `queue`.
nonisolated final class WallTargetsCamera: NSObject, ObservableObject,
    AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Ball position for the phone overlay: normalised centre, diameter as a
    /// fraction of frame width, and whether its size says it is at wall depth.
    struct BallMark: Equatable { var x, y, width: Double; var atWall: Bool }
    struct ReferenceUpdate: Equatable { var box: Int; var progress: Double; var diameter: Double? }

    static let scoreThreshold = 0.20   // reacquisition; a measured continuation may be >= 0.08

    @MainActor @Published private(set) var status = "Starting camera…"
    @MainActor @Published private(set) var ball: BallMark?
    @MainActor @Published private(set) var trail: [CGPoint] = []
    @MainActor @Published private(set) var frameSize = CGSize(width: 16, height: 9)
    @MainActor @Published private(set) var processingFPS = 0.0
    @MainActor @Published private(set) var captureFPS = 0
    @MainActor @Published private(set) var deliveredFPS = 0.0
    @MainActor @Published private(set) var isReady = false
    @MainActor @Published private(set) var detectorMS = 0.0
    @MainActor @Published private(set) var referenceUpdate: ReferenceUpdate?
    @MainActor @Published private(set) var handState = WallHandState.unknown
    @MainActor @Published private(set) var alignmentUpdate: WallBoardAlignment.Update?
    @MainActor private var referenceRequest: UUID?
    @MainActor @Published private(set) var recordingSince: Date?
    @MainActor @Published private(set) var lastRecording: URL?
    @MainActor private var request: CaptureRequest?

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.juggledude.wall-targets", qos: .userInitiated)
    private let captureQueue = DispatchQueue(label: "com.juggledude.wall-targets.capture", qos: .userInitiated)
    private struct CapturedFrame: @unchecked Sendable {
        let pixels: CVPixelBuffer
        let time: CMTime
        let request: CaptureRequest
        let receivedFPS: Double
    }
    private let frameLock = NSLock()
    // Only accessed under frameLock, including during start/stop.
    private var frameRequest: CaptureRequest?
    private var frames = LiveAnalysisBuffer<CapturedFrame>(framesPerSecond: 60)
    private var receivedTime: Double?
    private var receivedFPS = 60.0
    private let onImpact: @MainActor (WallImpactDetector.Impact) -> Void
    private let onAlignment: @MainActor (WallBoardAlignment.Update) -> Void
    // Accessed only on queue.
    private var activeRequest: CaptureRequest?
    private var detector: BallDetector?
    private var shots = WallAlignedShotTracker()
    private var wallReference: WallBallReference?
    private var referenceCollector: WallReferenceCollector?
    private var referenceFinished = false
    private var referenceAttempt = UUID()
    private let hands = WallHandTracker()
    private var ballTracker = WallBallTracker()
    private var lastFullSearch = -Double.infinity
    private var lastPerson: (t: Double, box: Detection)?
    private var alignment: WallBoardAlignment?
    private var referenceGeometry: [CGPoint]?
    private var lastLoggedAlignment: WallBoardAlignment.Update?
    private var corners: [CGPoint] = []
    private var bufferSize = CGSize.zero
    private var lastFrameTime: Double?
    private var fps = 60.0
    private var selectedFPS = 30
    private var recorder: WallTargetsRecorder?
    private var cornerSearch: [WallCornerFinder.Frame]?
    private var liveFeed: WallTargetsLiveFeed?
    private var configured = false
    private var scoringEnabled = false
    private var device: AVCaptureDevice?
    private var focusToken: UUID?
    private var latestFrameTime: Double?
    private var focusDiagnostics: [String: Any] = [:]

    init(onImpact: @escaping @MainActor (WallImpactDetector.Impact) -> Void,
         onAlignment: @escaping @MainActor (WallBoardAlignment.Update) -> Void) {
        self.onImpact = onImpact
        self.onAlignment = onAlignment
    }

    /// Board corners, normalised to the camera frame (TL, TR, BR, BL).
    func setCorners(_ normalised: [CGPoint]) {
        queue.async { [self] in
            corners = normalised
            wallReference = nil
            alignment = nil; referenceGeometry = nil
            rebuildBoard()
        }
    }

    /// Changes of calibration or play mode always discard pending contact evidence.
    func setScoringEnabled(_ enabled: Bool) {
        queue.async { [self] in
            scoringEnabled = enabled && WallBoard.validCalibration(corners) && wallReference != nil
            if !enabled { alignment = nil }
            hands.reset()
            rebuildBoard()
        }
    }

    /// Normal markers must agree for three checks before either reference setup
    /// or gameplay. Monitoring then continues through countdown and gameplay.
    @MainActor
    func verifyAlignment() async {
        alignmentUpdate = nil
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                scoringEnabled = false
                alignment = WallBoardAlignment(corners: corners,
                    referenceCorners: wallReference == nil ? nil : referenceGeometry)
                rebuildBoard()
                if let current = activeRequest { publishAlignment(alignment!.update, request: current) }
                continuation.resume()
            }
        }
    }

    func setReference(_ reference: WallBallReference) {
        queue.async { [self] in
            wallReference = reference
            recorder?.updateMetadata(["wallBallDiametersNormalised": reference.diameters])
            rebuildBoard()
        }
    }

    @MainActor
    func beginReference(box: Int) async {
        referenceUpdate = nil
        let token = UUID()
        referenceRequest = token
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                scoringEnabled = false; shots.reset(); wallReference = nil
                alignment = nil
                if box == 1 { referenceGeometry = corners }
                referenceAttempt = token; referenceFinished = false
                if let board = makeBoard() {
                    referenceCollector = WallReferenceCollector(board: board, target: box, imageWidth: bufferSize.width)
                }
                recorder?.setPhase("reference", box: box)
                continuation.resume()
            }
        }
    }

    @MainActor func endReference() {
        referenceRequest = nil
        queue.async { [self] in
            referenceAttempt = UUID(); referenceCollector = nil; referenceFinished = false
            recorder?.setPhase("countdown")
        }
    }

    func markPlaying() { queue.async { [self] in recorder?.setPhase("playing") } }

    @MainActor
    func start() {
        guard request == nil else { return }
        let next = CaptureRequest()
        request = next
        isReady = false
        status = "Starting camera…"
        Task {
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
            default: allowed = false
            }
            guard request === next, !next.isCancelled else { return }
            guard allowed else {
                status = "Allow camera access in Settings."
                request = nil
                return
            }
            queue.async { [self] in
                guard !next.isCancelled else { return }
                activeRequest = next
                do {
                    if !configured { try configure() }
                    guard !next.isCancelled else { return }
                    if let device, (try? device.lockForConfiguration()) != nil {
                        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                        device.unlockForConfiguration()
                    }
                    frameLock.withLock {
                        frameRequest = next
                        receivedTime = nil
                        receivedFPS = Double(selectedFPS)
                    }
                    publish(status: "Loading detector…", request: next)
                    session.startRunning()
                    guard session.isRunning else { throw CameraError.unavailable }
                    if detector == nil {
                        let loaded = try BallDetector(resourceName: BallDetector.productionResourceName,
                            useROI: false, useMarginalRetry: false, useDirectConfirmation: false)
                        try loaded.warmUp()
                        detector = loaded
                    }
                    publish(status: "Watching for hits", request: next)
                    Task { @MainActor [weak self] in
                        guard let self, self.request === next, !next.isCancelled else { return }
                        self.isReady = true
                    }
                } catch {
                    session.stopRunning()
                    activeRequest = nil
                    frameLock.withLock { frameRequest = nil; frames.cancelPending() }
                    let message = error is CameraError ? "Camera unavailable" : "Unable to load the ball detector"
                    Task { @MainActor [weak self] in
                        guard let self, self.request === next, !next.isCancelled else { return }
                        self.status = message
                        self.request = nil
                        self.isReady = false
                    }
                }
            }
        }
    }

    /// Mirrors frames, state and shots to the Mac preview while it is switched on.
    func setLiveFeed(_ feed: WallTargetsLiveFeed?) {
        queue.async { [self] in liveFeed = feed }
    }

    /// Acquire on the static projected board, not on the person holding the ball.
    /// The sensor and focus-point coordinates are both native landscape-right.
    @MainActor
    func acquireFocus(near points: [CGPoint]? = nil) async -> Bool {
        guard let current = request, !current.isCancelled else { return false }
        let token = UUID()
        let point = points.flatMap { p -> CGPoint? in
            guard WallBoard.validCalibration(p) else { return nil }
            return CGPoint(x: p.map(\.x).reduce(0, +) / 4, y: p.map(\.y).reduce(0, +) / 4)
        } ?? CGPoint(x: 0.5, y: 0.5)
        let began: Bool = await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard activeRequest === current, !current.isCancelled, let device,
                      (try? device.lockForConfiguration()) != nil else { continuation.resume(returning: false); return }
                focusToken = token
                scoringEnabled = false; shots.reset()
                if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = point }
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                else if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                device.unlockForConfiguration()
                continuation.resume(returning: true)
            }
        }
        guard began else { return false }
        let started = ProcessInfo.processInfo.systemUptime
        var readiness = WallFocusReadiness(started: started)
        var acquired = false
        while !Task.isCancelled, request === current, !current.isCancelled,
              ProcessInfo.processInfo.systemUptime - started < 4 {
            let sample: (Double?, Bool, Double)? = await withCheckedContinuation { continuation in
                queue.async { [self] in
                    guard focusToken == token, activeRequest === current, let device else {
                        continuation.resume(returning: nil); return
                    }
                    continuation.resume(returning: (latestFrameTime, device.isAdjustingFocus, Double(device.lensPosition)))
                }
            }
            guard let sample else { break }
            if readiness.observe(at: ProcessInfo.processInfo.systemUptime, frameTime: sample.0,
                                 adjusting: sample.1, lens: sample.2) { acquired = true; break }
            do { try await Task.sleep(for: .milliseconds(80)) } catch { break }
        }
        let shouldLock = acquired && !Task.isCancelled && request === current && !current.isCancelled
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard focusToken == token else { continuation.resume(returning: false); return }
                focusToken = nil
                guard activeRequest === current, !current.isCancelled, let device else {
                    continuation.resume(returning: false); return
                }
                var locked = false
                if shouldLock, !device.isAdjustingFocus, (try? device.lockForConfiguration()) != nil {
                    if device.isFocusModeSupported(.locked) { device.focusMode = .locked; locked = true }
                    device.unlockForConfiguration()
                }
                focusDiagnostics = ["locked": locked, "lensPosition": Double(device.lensPosition),
                    "adjusting": device.isAdjustingFocus, "point": [Double(point.x), Double(point.y)],
                    "seconds": ProcessInfo.processInfo.systemUptime - started,
                    "exposureSeconds": device.exposureDuration.seconds, "iso": Double(device.iso)]
                recorder?.updateMetadata(["focusAcquisition": focusDiagnostics])
                continuation.resume(returning: locked)
            }
        }
    }

    /// Starts keeping small luma thumbnails for the blinking-dot corner search.
    func beginCornerSearch() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                scoringEnabled = false
                shots.reset()
                alignment = nil
                cornerSearch = []
                if let device, (try? device.lockForConfiguration()) != nil {
                    if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                    // Focus was explicitly acquired and locked before this search.
                    device.unlockForConfiguration()
                }
                continuation.resume()
            }
        }
    }

    /// Ends the search; `on`/`off` are host-clock spans (CACurrentMediaTime) when the
    /// dots were shown or hidden. Returns normalised corners TL, TR, BR, BL, or nil.
    func finishCornerSearch(on: [ClosedRange<Double>], off: [ClosedRange<Double>]) async -> [CGPoint]? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let frames = cornerSearch ?? []
                cornerSearch = nil
                if let device, (try? device.lockForConfiguration()) != nil {
                    if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                    device.unlockForConfiguration()
                }
                continuation.resume(returning: WallCornerFinder.corners(in: frames, on: on, off: off))
            }
        }
    }

    /// Starts saving video, detections and hits for review; `extra` lands in session.json.
    @MainActor
    func startRecording(extra: [String: Any]) {
        guard recordingSince == nil else { return }
        recordingSince = Date()
        queue.async { [self] in
            guard recorder == nil, bufferSize.width > 0 else {
                Task { @MainActor in self.recordingSince = nil }
                return
            }
            var metadata = extra
            metadata["frameWidth"] = Int(bufferSize.width)
            metadata["frameHeight"] = Int(bufferSize.height)
            metadata["captureFPS"] = selectedFPS
            metadata["scoreThreshold"] = Self.scoreThreshold
            metadata["cornersNormalised"] = corners.map { [Double($0.x), Double($0.y)] }
            metadata["created"] = ISO8601DateFormatter().string(from: Date())
            metadata["impactRules"] = "v8-delayed-rebound-confirmation"
            metadata["reboundConfirmationSeconds"] = WallImpactDetector.regrowWindow
            metadata["focusAcquisition"] = focusDiagnostics
            metadata["alignmentEvidenceRetentionSeconds"] = WallBoardAlignment.evidenceRetention
            metadata["timerRule"] = "countdown-completion; excludes alignment pauses"
            metadata["alignmentCheckSeconds"] = WallBoardAlignment.interval
            metadata["alignmentTolerancePixels"] = WallBoardAlignment.tolerancePixels
            metadata["borderlineRule"] = "centre uncertainty = 3 + max(3, 0.15 * diameter) pixels"
            metadata["ballTracking"] = "measured-crop-with-full-frame-fallback"
            metadata["trackedBallScoreThreshold"] = 0.08
            metadata["handContextMaxAgeSeconds"] = 0.15
            if let crop = WallBallTracker.crop(corners: corners, size: bufferSize) {
                metadata["detectionCropPixels"] = [crop.minX, crop.minY, crop.width, crop.height]
            }
            metadata["calibrationValid"] = WallBoard.validCalibration(corners)
            metadata["wallBallDiametersNormalised"] = wallReference?.diameters
            metadata["maximumExposureSeconds"] = device?.activeMaxExposureDuration.seconds
            do {
                recorder = try WallTargetsRecorder(size: bufferSize, metadata: metadata)
                lastLoggedAlignment = nil
            } catch {
                Task { @MainActor in
                    self.recordingSince = nil
                    self.status = "Recording failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// `extra` (for example round clear times) is merged into session.json.
    @MainActor
    func stopRecording(extra: [String: Any] = [:]) {
        recordingSince = nil
        queue.async { [self] in finishRecording(extra: extra) }
    }

    /// Called on queue.
    private func finishRecording(extra: [String: Any] = [:]) {
        guard let finishing = recorder else { return }
        recorder = nil
        let extra = WallTargetsSendable(extra)
        Task {
            let folder = await finishing.finish(extra: extra.value)
            await MainActor.run { self.lastRecording = folder }
        }
    }

    @MainActor
    func stop(message: String = "Camera paused") {
        request?.cancel()
        request = nil
        referenceRequest = nil
        status = message
        isReady = false
        frameLock.withLock { frameRequest = nil; frames.cancelPending() }
        ball = nil
        trail = []
        recordingSince = nil
        queue.async { [self] in
            finishRecording()
            session.stopRunning()
            activeRequest = nil
            focusToken = nil; latestFrameTime = nil
            detector = nil
            shots.reset()
            scoringEnabled = false
            wallReference = nil
            referenceCollector = nil
            referenceAttempt = UUID()
            hands.reset()
            cornerSearch = nil
            alignment = nil; referenceGeometry = nil
            lastFrameTime = nil
            rebuildBoard()
        }
    }

    private enum CameraError: Error { case unavailable }

    private func configure() throws {
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.sessionPreset = .hd1280x720
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraError.unavailable
        }
        session.addInput(input)
        self.device = device
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CameraError.unavailable
        }
        session.addOutput(output)
        // 60 fps where the lens allows it: the wall bounce lasts only a few frames.
        let cadence = try? CaptureFrameRate.configure(device)
        if (try? device.lockForConfiguration()) != nil {
            // Preserve auto ISO while limiting motion blur. Read back the actual
            // cadence on frames; selecting 60 fps alone does not guarantee it.
            let shortest = device.activeFormat.minExposureDuration.seconds
            let longest = device.activeFormat.maxExposureDuration.seconds
            device.activeMaxExposureDuration = CMTime(seconds: min(longest, max(shortest, 1.0 / 240)), preferredTimescale: 1_000_000)
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            device.unlockForConfiguration()
        }
        session.commitConfiguration()
        // The screen is locked to landscape-right, the back sensor's native
        // orientation, so buffers, preview and taps all share one unrotated frame.
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
            // A fixed wall homography must not inherit a moving stabilisation crop.
            connection.preferredVideoStabilizationMode = .off
        }
        let selected = cadence?.selectedFPS ?? 30
        selectedFPS = selected
        Task { @MainActor in self.captureFPS = selected }
        configured = true
    }

    private func makeBoard() -> WallBoard? {
        guard WallBoard.validCalibration(corners), bufferSize.width > 0 else { return nil }
        let pixels = corners.map { CGPoint(x: $0.x * bufferSize.width, y: $0.y * bufferSize.height) }
        return WallBoard(topLeft: pixels[0], topRight: pixels[1], bottomRight: pixels[2], bottomLeft: pixels[3])
    }

    private func rebuildBoard() {
        shots.reset()
        ballTracker.reset()
        lastFullSearch = -.infinity
        lastPerson = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let next = frameLock.withLock { () -> CapturedFrame? in
            guard let current = frameRequest, !current.isCancelled else { return nil }
            if let last = receivedTime, time.seconds > last {
                receivedFPS = 0.9 * receivedFPS + 0.1 / (time.seconds - last)
            }
            receivedTime = time.seconds
            return frames.offer(CapturedFrame(pixels: pixels, time: time, request: current, receivedFPS: receivedFPS), at: time.seconds)
        }
        if let next { schedule(next) }
    }

    private func schedule(_ frame: CapturedFrame) {
        queue.async { [self] in
            process(frame)
            if let next = frameLock.withLock({ frames.finish() }) { schedule(next) }
        }
    }

    private func process(_ frame: CapturedFrame) {
        let current = frame.request
        guard activeRequest === current, !current.isCancelled else { return }
        let pixels = frame.pixels, t = frame.time.seconds
        latestFrameTime = t
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        if size != bufferSize {
            bufferSize = size
            rebuildBoard()
            Task { @MainActor in self.frameSize = size }
        }
        // Capture timestamps are on the host clock, the same clock as CACurrentMediaTime.
        if cornerSearch != nil, cornerSearch!.count < 600 {
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                cornerSearch!.append(.init(t: t, luma: WallCornerFinder.thumbnail(
                    base.assumingMemoryBound(to: UInt8.self), width: Int(size.width), height: Int(size.height),
                    rowBytes: CVPixelBufferGetBytesPerRow(pixels))))
            }
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
            return   // only the blinking dots matter during calibration
        }
        guard let detector else { return }
        if alignment?.shouldCheck(at: t) == true {
            let previous = alignment!.update
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            var found: [CGPoint]?
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                let image = WallCornerTracker.Image(bgra: base.assumingMemoryBound(to: UInt8.self),
                    width: Int(size.width), height: Int(size.height), rowBytes: CVPixelBufferGetBytesPerRow(pixels),
                    near: alignment!.searchCorners)
                found = WallCornerTracker.corners(in: image, near: alignment!.searchCorners)
            }
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
            alignment!.observe(found, at: t, size: size)
            let update = alignment!.update
            if update != previous {
                if update.status == .ready { corners = update.corners }
                if update.status == .referenceRequired { wallReference = nil }
                // Ball association survives marker flicker. The shot tracker uses
                // evidenceEpoch to discard contacts only on drift or expired loss.
                if update.corners != previous.corners {
                    ballTracker.reset(); lastFullSearch = -.infinity; lastPerson = nil
                }
                publishAlignment(update, request: current)
            }
        }
        if let last = lastFrameTime, t > last { fps = 0.9 * fps + 0.1 / (t - last) }
        lastFrameTime = t

        let started = ProcessInfo.processInfo.systemUptime
        var detection: Detection?
        var person: Detection?
        var detectionSource = 0 // 0 absent, 1 full frame, 2 board crop
        do {
            if let crop = WallBallTracker.crop(corners: corners, size: size) {
                let candidates = try autoreleasepool { try detector.wallTargetCandidates(in: pixels, crop: crop) }
                detection = ballTracker.select(candidates, at: t, size: size)
                if detection != nil { detectionSource = 2 }
                // Search the rest of the room when the ball leaves the crop.
                // Bound extra model work; the detailed board view still runs on every frame.
                if detection == nil, t - lastFullSearch >= 0.12 {
                    lastFullSearch = t
                    let result = try autoreleasepool { try detector.wallTargetDetections(in: pixels, threshold: Self.scoreThreshold) }
                    person = result.person
                    lastPerson = person.map { (t, $0) }
                    detection = ballTracker.select(result.ball.map { [$0] } ?? [], at: t, size: size)
                    if detection != nil { detectionSource = 1 }
                }
            } else {
                let result = try autoreleasepool { try detector.wallTargetDetections(in: pixels, threshold: Self.scoreThreshold) }
                detection = result.ball; person = result.person
                if detection != nil { detectionSource = 1 }
            }
            ballTracker.accept(detection, at: t)
        } catch {
            publish(status: "Ball detection unavailable", request: current)
            return
        }
        var hand = WallHandState.unknown
        if let d = detection, scoringEnabled {
            hands.observe(pixels, at: t)
            if person == nil, let lastPerson, t - lastPerson.t <= 0.15 { person = lastPerson.box }
            func body(_ person: Detection?) -> CGRect? {
                person.map { CGRect(x: $0.x - $0.width / 2, y: $0.y - $0.height / 2, width: $0.width, height: $0.height) }
            }
            hand = hands.state(ball: CGPoint(x: d.x, y: d.y), diameter: (d.width * size.width + d.height * size.height) / 2 / size.height,
                               aspect: size.width / size.height, person: body(person), at: t)
            if hand == .unknown, person == nil, t - lastFullSearch >= 0.12 {
                // The person may be partly outside the board view. Recover
                // full-frame body context without replacing the detailed ball.
                lastFullSearch = t
                if let result = try? autoreleasepool(invoking: { try detector.wallTargetDetections(in: pixels, threshold: Self.scoreThreshold) }) {
                    person = result.person; lastPerson = person.map { (t, $0) }
                    hand = hands.state(ball: CGPoint(x: d.x, y: d.y), diameter: (d.width * size.width + d.height * size.height) / 2 / size.height,
                                       aspect: size.width / size.height, person: body(person), at: t)
                }
            }
        }
        let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
        var mark: BallMark?
        let observation: WallImpactDetector.Observation? = detection.map { d in
            WallImpactDetector.Observation(t: t, x: d.x * size.width, y: d.y * size.height,
                d: (d.width * size.width + d.height * size.height) / 2, hand: hand)
        }
        let found = shots.process(observation, at: t, update: alignment?.update,
            retainEvidence: scoringEnabled && alignment?.canRetainEvidence(at: t) == true,
            canScore: scoringEnabled && alignment?.canScore(at: t) == true,
            reference: wallReference, size: size, fps: fps)
        if let d = detection, let observation {
            mark = BallMark(x: d.x, y: d.y, width: observation.d / size.width, atWall: shots.isAtWall(observation))
        }
        if referenceCollector != nil, !referenceFinished {
            let sample = detection.map { WallReferenceCollector.Sample(t: t, x: $0.x * size.width, y: $0.y * size.height,
                d: ($0.width * size.width + $0.height * size.height) / 2, score: $0.score,
                aspect: $0.width * size.width / max(1, $0.height * size.height)) }
            let update = referenceCollector!.add(sample, now: t), box = referenceCollector!.target
            referenceFinished = update.diameter != nil
            let token = referenceAttempt
            if let diameter = update.diameter { recorder?.noteReference(box: box, diameter: diameter, at: t) }
            Task { @MainActor [weak self] in
                guard let self, self.request === current, self.referenceRequest == token, !current.isCancelled else { return }
                self.referenceUpdate = .init(box: box, progress: update.progress, diameter: update.diameter)
            }
        }
        let decisions = shots.takeDecisions()
        recorder?.append(pixels, at: frame.time, ball: detection, person: person, hand: hand, source: detectionSource,
                         alignment: alignment?.update,
                         retainEvidence: scoringEnabled && alignment?.canRetainEvidence(at: t) == true,
                         canScore: scoringEnabled && alignment?.canScore(at: t) == true,
                         lensPosition: device.map { Double($0.lensPosition) },
                         adjustingFocus: device?.isAdjustingFocus ?? false)
        if let update = alignment?.update, update != lastLoggedAlignment {
            recorder?.noteAlignment(update, at: t)
            lastLoggedAlignment = update
        }
        recorder?.noteDecisions(decisions)
        for impact in found { recorder?.note(impact) }
        if let feed = liveFeed {
            feed.addFrame(pixels, at: t)
            feed.setState([
                "corners": corners.map { [Double($0.x), Double($0.y)] },
                "cornersNotSet": !scoringEnabled,
                "ball": mark.map { ["x": $0.x, "y": $0.y, "w": $0.width, "atWall": $0.atWall] as Any } ?? NSNull(),
                "fps": fps, "detectMS": ms, "recording": recorder != nil, "status": "Watching for hits"])
            for impact in found { feed.addShot(impact, frameSize: size) }
        }
        let rate = fps
        let publishedMark = mark, publishedHand = hand
        Task { @MainActor [weak self] in
            guard let self, self.request === current, !current.isCancelled else { return }
            self.ball = publishedMark
            if let mark = publishedMark {
                self.trail.append(CGPoint(x: mark.x, y: mark.y))
                if self.trail.count > 24 { self.trail.removeFirst(self.trail.count - 24) }
            } else if !self.trail.isEmpty {
                self.trail.removeFirst()
            }
            self.processingFPS = rate
            self.deliveredFPS = frame.receivedFPS
            self.detectorMS = ms
            self.handState = publishedHand
            for impact in found { self.onImpact(impact) }
        }
    }

    private func publish(status message: String, request current: CaptureRequest) {
        Task { @MainActor [weak self] in
            guard let self, self.request === current, !current.isCancelled else { return }
            if self.status != message { self.status = message }
        }
    }

    private func publishAlignment(_ update: WallBoardAlignment.Update, request current: CaptureRequest) {
        Task { @MainActor [weak self] in
            guard let self, self.request === current, !current.isCancelled else { return }
            self.alignmentUpdate = update
            self.onAlignment(update)
        }
    }
}
#endif
