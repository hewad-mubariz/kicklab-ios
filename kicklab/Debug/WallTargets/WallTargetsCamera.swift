#if DEBUG && BALL_DETECTION_DEBUG
import AVFoundation
import Combine
import CoreGraphics
import Foundation

/// CPU wall play retains a bounded batch of actual frames during inference.
/// Intermediate frames use pixel matching, corroborated by the next RF result.
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
    @MainActor @Published private(set) var recordingState: WallRecordingState = .idle
    @MainActor @Published private(set) var runtime = WallRuntimeSample()
    @MainActor private var runtimeTask: Task<Void, Never>?
    @MainActor private var captureIsResting = false
    @MainActor private var lastInferencePublished = -Double.infinity
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
    private var frames = WallTrackingFrameBuffer<CapturedFrame>()
    // Capture-queue-only owned pool: never exhaust AVCapture's camera surfaces.
    private var trackingPool: CVPixelBufferPool?
    private var trackingPoolSize = CGSize.zero
    private var receivedTime: Double?
    private var receivedFPS = 60.0
    private let onImpact: @MainActor (WallImpactDetector.Impact) -> Bool
    private let onContactPreview: @MainActor (WallImpactDetector.Impact?) -> Void
    private let onAlignment: @MainActor (WallBoardAlignment.Update) -> Void
    private let onPhysicalBall: @MainActor (PhysicalBallSample?,Double) -> PhysicalKeeperTelemetry?
    // Accessed only on queue.
    private var activeRequest: CaptureRequest?
    private var detector: BallDetector?
    private var shots = WallAlignedShotTracker()
    private var targetLayout = WallTargetLayout.sixTargets
    private var wallReference: WallBallReference?
    private var referenceCollector: WallReferenceCollector?
    private var referenceFinished = false
    private var referenceAttempt = UUID()
    private let hands = WallHandTracker()
    private var ballTracker = WallBallTracker()
    private var pixelTracker = WallBallPixelTracker()
    private var gameplayCadence = WallGameplayInferenceCadence()
    private var sceneActivity = WallSceneActivity()
    private struct PixelEvidence {
        let observation: WallImpactDetector.Observation
        let update: WallBoardAlignment.Update?
        let retain: Bool
    }
    private var pixelEvidence: [PixelEvidence] = []
    private var pixelResetTime = -Double.infinity
    private var usesPixelTracking: Bool {
        scoringEnabled && gameplayInputEnabled && detector?.modelUsesCPUOnly == true && !inspectionEnabled
    }
    private func resetPixelTracking() {
        pixelTracker.reset(); pixelEvidence = []
        gameplayCadence.reset()
        sceneActivity.reset()
        pixelResetTime = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        frameLock.withLock { frames.setBuffered(usesPixelTracking); frames.cancelPending() }
    }
    private var lastFullSearch = -Double.infinity
    private var modelSearch = WallModelSearch()
    private var motionSearch = WallBallMotionSearch()
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
    private var recordingFinishTask: Task<Void, Never>?
    private var cornerSearch: [WallCornerFinder.Frame]?
    private var lastSetupPreview = -Double.infinity
    private var mappingFrames: [WallMappingCheck.Frame]?
    private var mappingCorners: [CGPoint] = []
    private var mappingSize = CGSize.zero
    private var liveFeed: WallTargetsLiveFeed?
    private var configured = false
    private var scoringEnabled = false
    private var gameplayInputEnabled = true
    private var inspectionEnabled = false
    private var physicalReferenceCorners: [CGPoint] = []
    private var physicalReferenceGate: PhysicalCalibrationHold?
    private var visualAuditState: [String:Any]?
    private var physicalMinimumDiameter=0.0
    private var device: AVCaptureDevice?
    private var focusToken: UUID?
    private var latestFrameTime: Double?
    private var focusDiagnostics: [String: Any] = [:]
    private var wantsCaptureRest = false
    private var framingPreviewOnly = false
#if WALL_GAMES_PREVIEW
    // Owned by the camera processing queue; never runs alongside ball inference.
    private var delayProbe: (@MainActor @Sendable (WallDelayObservation) -> Void)?
    private var delayProbePoint = CGPoint(x: 0.5, y: 0.5)
    private var delayExposure: (mode: AVCaptureDevice.ExposureMode, duration: CMTime, iso: Float)?
#endif
    private var inferenceCadence = WallInferenceCadence()
    private var workMeter = WallWorkMeter(at: ProcessInfo.processInfo.systemUptime)

    init(onImpact: @escaping @MainActor (WallImpactDetector.Impact) -> Bool,
         onAlignment: @escaping @MainActor (WallBoardAlignment.Update) -> Void,
         onContactPreview: @escaping @MainActor (WallImpactDetector.Impact?) -> Void = { _ in },
         onPhysicalBall: @escaping @MainActor (PhysicalBallSample?,Double) -> PhysicalKeeperTelemetry? = { _,_ in nil }) {
        self.onImpact = onImpact
        self.onAlignment = onAlignment
        self.onContactPreview = onContactPreview
        self.onPhysicalBall = onPhysicalBall
    }

    /// Read-only camera review, enabled solely by the explicit debug launch flag.
    /// Rendering uses a separate model; this path never runs ball inference/scoring.
    func setVisualAuditState(_ state: [String:Any]) {
        guard ProcessInfo.processInfo.arguments.contains("--wall-visual-audit") else { return }
        queue.async { [self] in visualAuditState=state;scoringEnabled=false;inspectionEnabled=false }
    }
    @MainActor func lockVisualAuditCamera() async {
        guard ProcessInfo.processInfo.arguments.contains("--wall-visual-audit") else { return }
        _=await acquireFocus(near:[CGPoint(x:0.18,y:0.42),CGPoint(x:0.63,y:0.42),CGPoint(x:0.63,y:0.8),CGPoint(x:0.18,y:0.8)])
        let arguments=ProcessInfo.processInfo.arguments
        func value(_ key: String) -> Double? {
            arguments.first { $0.hasPrefix(key+"=") }.flatMap { Double($0.dropFirst(key.count+1)) }
        }
        let requestedExposure=value("--wall-audit-exposure")
        let requestedISO=value("--wall-audit-iso")
        let requestedFocus=value("--wall-audit-focus")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in
            queue.async { [self] in
                if let device,(try? device.lockForConfiguration()) != nil {
                    if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                    if let requestedExposure,let requestedISO,requestedExposure.isFinite,requestedISO.isFinite,
                       device.isExposureModeSupported(.custom) {
                        let seconds=min(device.activeFormat.maxExposureDuration.seconds,
                                        max(device.activeFormat.minExposureDuration.seconds,requestedExposure))
                        let iso=min(device.activeFormat.maxISO,max(device.activeFormat.minISO,Float(requestedISO)))
                        device.setExposureModeCustom(duration:CMTime(seconds:seconds,preferredTimescale:1_000_000),iso:iso)
                    }
                    if let requestedFocus,requestedFocus.isFinite,device.isLockingFocusWithCustomLensPositionSupported {
                        device.setFocusModeLocked(lensPosition:Float(min(1,max(0,requestedFocus))))
                    }
                    if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                    device.unlockForConfiguration()
                }
                continuation.resume()
            }
        }
    }

    /// Board corners, normalised to the camera frame (TL, TR, BR, BL).
    func setCorners(_ normalised: [CGPoint]) {
        queue.async { [self] in
            corners = normalised
            recorder?.updateMetadata(["cornersNormalised": normalised.map { [Double($0.x), Double($0.y)] },
                                      "calibrationValid": WallBoard.validCalibration(normalised)])
            wallReference = nil
            alignment = nil; referenceGeometry = nil
            rebuildBoard()
        }
    }

    /// Changes of calibration or play mode always discard pending contact evidence.
    func setScoringEnabled(_ enabled: Bool) {
        queue.async { [self] in
            scoringEnabled = enabled && WallBoard.validCalibration(corners) && wallReference != nil
            lastFrameTime = nil
            inferenceCadence.reset()
            if scoringEnabled { fps = Double(selectedFPS) }
            if !enabled { alignment = nil }
            hands.reset()
            rebuildBoard()
        }
    }

    /// WATCH/interlude suspend inference without disturbing alignment, recording
    /// or the game clock. Discard contact evidence crossing this input boundary.
    func setGameplayInputEnabled(_ enabled: Bool) {
        queue.async { [self] in
            guard gameplayInputEnabled != enabled else { return }
            gameplayInputEnabled = enabled
            shots.reset(); resetPixelTracking(); ballTracker.reset(); modelSearch.reset(); motionSearch.reset()
            hands.reset(); lastPerson = nil; lastFullSearch = -.infinity
            lastFrameTime = nil; inferenceCadence.reset()
            let current = activeRequest
            Task { @MainActor [weak self] in
                guard let self, self.request === current, current?.isCancelled == false else { return }
                self.ball = nil; self.trail = []; self.onContactPreview(nil)
            }
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

    /// Only the same capture session, pixel geometry and locked lens may reuse
    /// a measured ball. Fresh corner observations are still required afterwards.
    @MainActor
    func restoreSetup(_ setup: WallSetupReuse, reference: WallBallReference) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let activeRequest, !activeRequest.isCancelled, let device,
                      configured, session.isRunning, bufferSize == setup.frameSize,
                      device.focusMode == .locked, !device.isAdjustingFocus,
                      let lens = focusDiagnostics["lensPosition"] as? Double,
                      abs(Double(device.lensPosition) - lens) < 0.005 else {
                    continuation.resume(returning: false); return
                }
                corners = setup.corners; referenceGeometry = setup.corners
                wallReference = reference; scoringEnabled = false
                shots.reset(); resetPixelTracking(); rebuildBoard()
                continuation.resume(returning: true)
            }
        }
    }

    func setTargetLayout(_ layout: WallTargetLayout) {
        queue.async { [self] in targetLayout = layout; shots.reset(); resetPixelTracking() }
    }

    func setReference(_ reference: WallBallReference) {
        queue.async { [self] in
            wallReference = reference
            recorder?.updateMetadata(["wallBallDiametersNormalised": reference.diameters,
                                      "ballReferenceMode": reference.diameters.count == 1
                                        ? (detector?.modelUsesCPUOnly == true ? "single-centre-detail-v2" : "single-centre-hold-v1")
                                        : "legacy-six-point-v1"])
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
                resetPixelTracking(); ballTracker.reset(); modelSearch.reset(); motionSearch.reset()
                alignment = nil
                if box == WallReferenceCollector.wallCentre || box == 1 { referenceGeometry = corners }
                referenceAttempt = token; referenceFinished = false
                inferenceCadence.reset()
                lastFrameTime = nil
                fps = WallRuntimePolicy.referenceFPS
                if let board = makeBoard() {
                    referenceCollector = WallReferenceCollector(board: board, target: box, imageWidth: bufferSize.width)
                }
                recorder?.setPhase("reference", box: box)
                continuation.resume()
            }
        }
    }

    @MainActor func endReference(beginCountdown: Bool = false) {
        referenceRequest = nil
        queue.async { [self] in
            referenceAttempt = UUID(); referenceCollector = nil; referenceFinished = false
            if beginCountdown { recorder?.setPhase("countdown") }
        }
    }

    func markPlaying() { queue.async { [self] in recorder?.setPhase("playing") } }

    @MainActor
    func start() {
        startRuntimeMonitoring()
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
                        frameRequest = wantsCaptureRest ? nil : next
                        receivedTime = nil
                        receivedFPS = Double(selectedFPS)
                    }
                    publish(status: "Loading detector…", request: next)
                    writeDetectorStartup(state: "loading")
                    if !wantsCaptureRest {
                        session.startRunning()
                        guard session.isRunning else { throw CameraError.unavailable }
                    }
                    if detector == nil {
                        let loaded = try BallDetector(resourceName: BallDetector.productionResourceName,
                            useROI: false, useMarginalRetry: false, useDirectConfirmation: false)
                        try loaded.warmUp()
                        detector = loaded
                    }
                    writeDetectorStartup(state: "ready")
                    if ProcessInfo.processInfo.arguments.contains("--wall-pixel-benchmark") {
                        Task.detached(priority: .userInitiated) {
                            let folder = WallTargetsRecorder.root.deletingLastPathComponent().appendingPathComponent("WallPixelBenchmark")
                            do {
                                try await WallPixelTrackingReplay.run(folder: folder, output: folder.appendingPathComponent("result.json"))
                            } catch {
                                try? String(describing: error).write(to: folder.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8)
                            }
                        }
                    }
                    publish(status: "Watching for hits", request: next)
                    Task { @MainActor [weak self] in
                        guard let self, self.request === next, !next.isCancelled else { return }
                        self.isReady = true
                    }
                } catch {
                    writeDetectorStartup(state: "failed", error: error)
                    session.stopRunning()
                    activeRequest = nil
                    frameLock.withLock { frameRequest = nil; frames.cancelPending() }
                    let missingModel = Bundle.main.url(forResource: BallDetector.productionResourceName, withExtension: "mlmodelc") == nil
                    let message = error is CameraError ? "Camera unavailable" : missingModel
                        ? "Ball detector missing · reinstall the app" : "Unable to load the ball detector"
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

    /// One startup report, including the actual Core ML error, for device diagnosis.
    /// A ready report is written only after model construction and warm-up succeed.
    private func writeDetectorStartup(state: String, error: Error? = nil) {
        var report: [String: Any] = ["state": state, "timestamp": Date().timeIntervalSince1970,
            "resource": BallDetector.productionResourceName,
            "bundled": Bundle.main.url(forResource: BallDetector.productionResourceName, withExtension: "mlmodelc") != nil]
        if let detector {
            report["model"] = detector.modelName
            report["compute"] = detector.modelComputeDescription
            report["acceleratedLoadFailure"] = detector.modelAcceleratedLoadFailure
            report["searchPolicy"] = WallModelSearch.policy
            report["ballTracking"] = WallBallPixelTracker.policy
            report["inputWidth"] = Int(detector.modelInputSize.width)
            report["inputHeight"] = Int(detector.modelInputSize.height)
            report["warmupSucceeded"] = state == "ready"
        }
        if let error {
            let detail = error as NSError
            report["error"] = detail.localizedDescription
            report["errorDomain"] = detail.domain
            report["errorCode"] = detail.code
        }
        do {
            let folder = WallTargetsRecorder.root
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                .write(to: folder.appendingPathComponent("detector-startup.json"), options: .atomic)
        } catch { /* Diagnostic failure must not block camera startup. */ }
    }

    /// Keep the loaded model available, but stop capture entirely between rounds.
    /// Readiness means setup can begin; resuming is queued before its focus work.
    @MainActor
    func setCaptureResting(_ resting: Bool, previewOnly: Bool = false) {
        queue.async { [self] in
            wantsCaptureRest = resting
            framingPreviewOnly = !resting && previewOnly
            frameLock.withLock {
                frameRequest = resting ? nil : activeRequest
                frames.cancelPending()
                receivedTime = nil
            }
            if resting {
                resetPixelTracking()
                session.stopRunning()
                captureQueue.async { [self] in trackingPool = nil }
                liveFeed?.clearFrameCache()
            }
            else if let activeRequest, !activeRequest.isCancelled, configured {
                session.startRunning()
                if !session.isRunning {
                    Task { @MainActor [weak self] in
                        guard let self, self.request === activeRequest, !activeRequest.isCancelled else { return }
                        self.stop(message: "Camera unavailable · reopen Wall targets")
                    }
                }
            }
            lastFrameTime = nil
            Task { @MainActor [weak self] in
                self?.captureIsResting = resting
                if resting {
                    self?.ball = nil
                    self?.trail = []
                    self?.processingFPS = 0
                    self?.deliveredFPS = 0
                }
            }
        }
    }

    /// Manual framing uses the real capture layer, without running the detector,
    /// alignment, scoring or recorder. Only used before a round starts.
    @MainActor
    func setFramingPreview(_ enabled: Bool) {
        setCaptureResting(!enabled, previewOnly: enabled)
    }

#if WALL_GAMES_PREVIEW
    @MainActor func setDelayProbe(at point: CGPoint,
        receive: (@MainActor @Sendable (WallDelayObservation) -> Void)?) {
        queue.async { [self] in
            delayProbe = receive
            delayProbePoint = point
            if receive == nil { restoreDelayExposure() }
        }
    }

    @MainActor func lockDelayExposure() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard delayProbe != nil, let device, device.isExposureModeSupported(.locked),
                      (try? device.lockForConfiguration()) != nil else {
                    continuation.resume(returning: false); return
                }
                if delayExposure == nil {
                    delayExposure = (device.exposureMode, device.exposureDuration, device.iso)
                }
                device.exposureMode = .locked
                device.unlockForConfiguration()
                continuation.resume(returning: true)
            }
        }
    }

    private func restoreDelayExposure() {
        guard let previous = delayExposure else { return }
        delayExposure = nil
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        if previous.mode == .custom {
            device.setExposureModeCustom(duration: previous.duration, iso: previous.iso)
        } else if device.isExposureModeSupported(previous.mode) { device.exposureMode = previous.mode }
        device.unlockForConfiguration()
    }

    private func sampleDisplayDelay(_ frame: CapturedFrame) {
        guard let receive = delayProbe, let clock = session.synchronizationClock else { return }
        let host = CMSyncConvertTime(frame.time, from: clock, to: CMClockGetHostTimeClock()).seconds
        guard host.isFinite else { return }
        let pixels = frame.pixels
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0
        // A small patch (4% × 4% of the sensor), sampled at 100 points.
        for row in 0..<10 { for column in 0..<10 {
            let x = min(w-1, max(0, Int((delayProbePoint.x + (Double(column)/9-0.5)*0.04)*Double(w))))
            let y = min(h-1, max(0, Int((delayProbePoint.y + (Double(row)/9-0.5)*0.04)*Double(h))))
            let offset = y*stride+x*4
            sum += 0.0722*Double(bytes[offset])+0.7152*Double(bytes[offset+1])+0.2126*Double(bytes[offset+2])
        } }
        let observation = WallDelayObservation(captureTime: host,
            receivedTime: CMClockGetTime(CMClockGetHostTimeClock()).seconds,
            brightness: sum/100, exposure: device?.exposureDuration.seconds ?? 0,
            iso: Double(device?.iso ?? 0))
        Task { @MainActor in receive(observation) }
    }
#endif

    @MainActor
    private func startRuntimeMonitoring() {
        guard runtimeTask == nil else { return }
        runtimeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                let memory = DetectorPerformance.memoryMB()
                let peak = max(self.runtime.peakMemoryMiB ?? 0, memory)
                let capture = self.frameLock.withLock {
                    now - (self.receivedTime ?? -.infinity) < 1.5 ? self.receivedFPS : 0
                }
                let analysing = now - self.lastInferencePublished < 1.5 && !self.captureIsResting
                let sample = WallRuntimeSample(uptime: now, memoryMiB: memory > 0 ? memory : nil,
                    peakMemoryMiB: peak > 0 ? peak : nil,
                    thermalState: ProcessInfo.processInfo.thermalState.rawValue,
                    analysisFPS: analysing ? self.processingFPS : 0, captureFPS: capture,
                    inferenceMS: analysing ? self.detectorMS : 0, cameraResting: self.captureIsResting,
                    wallTime: Date().timeIntervalSince1970, power: WallPowerMonitor.shared.readPower())
                let wasHot = self.runtime.thermalState >= 2
                self.runtime = sample
                WallPowerMonitor.shared.updateRuntime(sample)
                self.queue.async { [self] in
                    var loggedSample = sample
                    loggedSample.work = self.workMeter.take(at: ProcessInfo.processInfo.systemUptime)
                    self.recorder?.noteResources(loggedSample)
                    if sample.thermalState >= 2 && !wasHot { self.liveFeed?.clearFrameCache() }
                    // A small current snapshot remains readable from the Mac
                    // even while the camera is resting between recordings.
                    let folder = WallTargetsRecorder.root
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    if let data = try? JSONEncoder().encode(loggedSample) {
                        try? data.write(to: folder.appendingPathComponent("runtime-latest.json"), options: .atomic)
                    }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    /// Mirrors frames, state and shots to the Mac preview while it is switched on.
    func setLiveFeed(_ feed: WallTargetsLiveFeed?) {
        queue.async { [self] in liveFeed = feed }
    }

    /// Runs raw ball detection for the physical-goal camera check, without
    /// enabling wall-game hit evidence, scoring, reference collection or cues.
    func setInspectionEnabled(_ enabled: Bool) {
        queue.async { [self] in
            inspectionEnabled=enabled
            physicalReferenceCorners=[]
            physicalReferenceGate=nil
            physicalMinimumDiameter=0
            resetPixelTracking(); ballTracker.reset();modelSearch.reset();motionSearch.reset()
            lastFrameTime=nil
            fps=Double(selectedFPS)
            inferenceCadence.reset()
        }
    }

    /// Use the wall games' detailed crop and reference cadence only for the
    /// stationary goal hold. Restore full-frame approach tracking afterwards.
    func setPhysicalReferenceCorners(_ points: [CGPoint], ballGate: PhysicalCalibrationHold? = nil) {
        queue.async { [self] in
            let next=WallBoard.validCalibration(points) ? points:[]
            let gate=next.isEmpty ? nil:ballGate
            guard next != physicalReferenceCorners || (gate == nil) != (physicalReferenceGate == nil) else { return }
            physicalReferenceCorners=next
            physicalReferenceGate=gate
            physicalMinimumDiameter=0
            resetPixelTracking(); ballTracker.reset();modelSearch.reset();motionSearch.reset();hands.reset();lastPerson=nil;lastFullSearch = -.infinity
            lastFrameTime=nil;inferenceCadence.reset()
            fps=next.isEmpty ? Double(selectedFPS):WallRuntimePolicy.referenceFPS
        }
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
                recorder?.setPhase("corner_search")
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
                let found = WallCornerFinder.corners(in: frames, on: on, off: off)
                saveCornerSearch(frames, on: on, off: off, found: found)
                continuation.resume(returning: found)
            }
        }
    }

    /// Retain the actual blink evidence even when setup never reaches a game.
    /// Small averaged images keep failed calibration diagnosable without holding
    /// full camera buffers or recording an unbounded background video.
    private func saveCornerSearch(_ frames: [WallCornerFinder.Frame], on: [ClosedRange<Double>],
                                  off: [ClosedRange<Double>], found: [CGPoint]?) {
        guard !on.isEmpty, !off.isEmpty else { return } // cancelled attempt
        let report: [String: Any] = ["algorithm": "scene-noise-corner-contrast-v3",
            "timestamp": Date().timeIntervalSince1970,
            "cornersNormalised": found.map { $0.map { [Double($0.x), Double($0.y)] } } as Any? ?? NSNull(),
            "on": on.map { [$0.lowerBound, $0.upperBound] }, "off": off.map { [$0.lowerBound, $0.upperBound] },
            "onFrames": on.map { span in frames.filter { span.contains($0.t) }.count },
            "offFrames": off.map { span in frames.filter { span.contains($0.t) }.count }]
        recorder?.updateMetadata(["cornerSearch": report])
        do {
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("WallTargets/SetupChecks/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("corners.json"), options: .atomic)
            for (kind, spans) in [("on", on), ("off", off)] {
                for (index, span) in spans.enumerated() {
                    guard let values = WallCornerFinder.average(frames, in: [span]) else { continue }
                    var data = Data("P5\n\(WallCornerFinder.width) \(WallCornerFinder.height)\n255\n".utf8)
                    data.append(contentsOf: values.map { UInt8(clamping: Int($0.rounded())) })
                    try data.write(to: root.appendingPathComponent("\(kind)-\(index).pgm"), options: .atomic)
                }
            }
        } catch {
            NSLog("Wall corner diagnostics could not be saved: %@", error.localizedDescription)
        }
    }

    /// Keep independent observations of points inside the map. No inference or
    /// scoring runs during this short check, but its video is retained for review.
    func beginMappingCheck() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                scoringEnabled = false; shots.reset(); alignment = nil
                mappingCorners = corners; mappingSize = bufferSize; mappingFrames = []
                recorder?.setPhase("mapping_check")
                if let device, (try? device.lockForConfiguration()) != nil {
                    if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                    device.unlockForConfiguration()
                }
                continuation.resume()
            }
        }
    }

    func finishMappingCheck(on: [ClosedRange<Double>], off: [ClosedRange<Double>]) async -> WallMappingCheck.Report {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let report = WallMappingCheck.check(mappingFrames ?? [], on: on, off: off,
                                                    corners: mappingCorners, size: mappingSize)
                mappingFrames = nil
                recorder?.noteMapping(report)
                if let device, (try? device.lockForConfiguration()) != nil {
                    if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                    device.unlockForConfiguration()
                }
                continuation.resume(returning: report)
            }
        }
    }

    /// Persist the result before any presentation delay or scene interruption.
    @MainActor
    func updateRecordingMetadata(_ metadata: [String: Any]) {
        let metadata = WallTargetsSendable(metadata)
        queue.async { [self] in recorder?.updateMetadata(metadata.value) }
    }

    /// Starts saving video, detections and hits for review; `extra` lands in session.json.
    @MainActor
    func startRecording(extra: [String: Any]) {
        guard recordingSince == nil, recordingState != .saving else { return }
        recordingSince = Date()
        recordingState = .recording
        queue.async { [self] in
            guard recorder == nil, bufferSize.width > 0 else {
                Task { @MainActor in
                    self.recordingSince = nil
                    self.recordingState = .failed("Camera has no video frames yet")
                }
                return
            }
            var metadata = extra
            metadata["frameWidth"] = Int(bufferSize.width)
            metadata["frameHeight"] = Int(bufferSize.height)
            metadata["captureFPS"] = selectedFPS
            metadata["scoreThreshold"] = Self.scoreThreshold
            metadata["modelInputWidth"] = detector.map { Int($0.modelInputSize.width) }
            metadata["modelCompute"] = detector?.modelComputeDescription
            metadata["modelSearchPolicy"] = WallModelSearch.policy
            metadata["cornersNormalised"] = corners.map { [Double($0.x), Double($0.y)] }
            metadata["created"] = ISO8601DateFormatter().string(from: Date())
            metadata["impactRules"] = "v17-candidate-cadence-size-outliers"
            metadata["feedbackRules"] = "queued-audio-feedback-v3; provisional-contact-ring-v1; projector-brick-cues-v2"
            metadata["feedbackTimingVersion"] = "host-clock-delivery-v1"
            metadata["feedbackReportedTimeBasis"] = "evidence-frame-presentation-time; not dispatch time"
            metadata["resourcePolicy"] = "reference-15fps-v1; idle-camera-rest-v1; active-contact-cadence-unchanged; critical-save-and-stop"
            metadata["gameplayInferencePolicy"] = inspectionEnabled ? "continuous-model" :
                detector?.modelUsesCPUOnly == true ? WallGameplayInferenceCadence.policy : WallGameplayInferenceCadence.acceleratedPolicy
            metadata["gamePhaseInferencePolicy"] = "memory-recall-only-v1; alignment-and-recording-continue"
            metadata["analysisFPSMeaning"] = "active model cadence; intentional idle skips excluded; work stage calls report actual inference count"
            metadata["referenceAnalysisFPS"] = WallRuntimePolicy.referenceFPS
            metadata["workTimingVersion"] = "queue-stage-elapsed-v1"
            metadata["inferenceRanColumn"] = "1=analysed; 0=intentionally skipped; -1=unspecified"
            metadata["reboundConfirmationSeconds"] = WallImpactDetector.regrowWindow
            metadata["focusAcquisition"] = focusDiagnostics
            metadata["alignmentEvidenceRetentionSeconds"] = WallBoardAlignment.evidenceRetention
            metadata["alignmentRevalidationAllowanceSeconds"] = WallBoardAlignment.revalidationAllowance
            metadata["alignmentRecoveryRules"] = "tight-three-check-recovery-v4"
            metadata["alignmentRecoveryCheckSeconds"] = WallBoardAlignment.recoveryInterval
            metadata["alignmentUnchangedConfirmationSeconds"] = WallBoardAlignment.unchangedConfirmationSpan
            metadata["alignmentUnchangedTolerancePixels"] = WallBoardAlignment.unchangedTolerancePixels
            metadata["timerRule"] = "countdown-completion; excludes alignment pauses"
            metadata["alignmentCheckSeconds"] = WallBoardAlignment.interval
            metadata["alignmentTolerancePixels"] = WallBoardAlignment.tolerancePixels
            metadata["cornerTracking"] = "contrast-checked-subpixel-centroid-v2"
            metadata["borderlineRule"] = targetLayout.continuousSurface
                ? "outer wall boundary only; internal brick joints accept continuous impacts"
                : "centre uncertainty = 3 + max(3, 0.15 * diameter) pixels; empty tile margins allowed only for an inside centre with no neighbouring target ambiguity"
            metadata["ballTracking"] = WallBallPixelTracker.policy
            metadata["ballAssociation"] = "weak-stationary-reacquisition-v1"
            metadata["ballSourceValues"] = "0=absent; 1=full frame; 2=board crop; 3=CPU ball-follow crop; 4=CPU motion-guided model crop; 5=provisional pixel match (score is image correlation)"
            metadata["trackedBallScoreThreshold"] = 0.08
            metadata["pixelTrackingEnabled"] = detector?.modelUsesCPUOnly == true && !inspectionEnabled
            metadata["pixelTrackingMaximumGapSeconds"] = WallBallPixelTracker.maximumFrameGap
            metadata["pixelTrackingMaximumSeedAgeSeconds"] = WallBallPixelTracker.maximumSeedAge
            metadata["pixelTrackingPendingFrameLimit"] = WallTrackingFrameBuffer<CapturedFrame>.capacity
            metadata["pixelTrackingRule"] = "actual pixels; NCC >= 0.80; next RF >= 0.20 must agree; no predicted contacts; RF cadence governs sparse rules"
            metadata["handContextMaxAgeSeconds"] = 0.15
            if let crop = WallBallTracker.crop(corners: corners, size: bufferSize) {
                metadata["detectionCropPixels"] = [crop.minX, crop.minY, crop.width, crop.height]
            }
            metadata["calibrationValid"] = WallBoard.validCalibration(corners)
            metadata["wallBallDiametersNormalised"] = wallReference?.diameters
            metadata["maximumExposureSeconds"] = device?.activeMaxExposureDuration.seconds
            do {
                recorder = try WallTargetsRecorder(size: bufferSize, metadata: metadata)
                recordingFinishTask = nil
                lastLoggedAlignment = nil
            } catch {
                Task { @MainActor in
                    self.recordingSince = nil
                    self.recordingState = .failed(error.localizedDescription)
                    self.status = "Recording failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// `extra` (for example round clear times) is merged into session.json.
    @MainActor
    func stopRecording(extra: [String: Any] = [:]) async {
        if recordingSince != nil { recordingState = .saving }
        recordingSince = nil
        let pending: Task<Void, Never>? = await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: finishRecording(extra: extra)) }
        }
        await pending?.value
    }

    /// Called on queue.
    @discardableResult
    private func finishRecording(extra: [String: Any] = [:]) -> Task<Void, Never>? {
        guard let finishing = recorder else { return recordingFinishTask }
        recorder = nil
        finishing.setPhase("finished")
        let extra = WallTargetsSendable(extra)
        let task = Task {
            await MainActor.run { self.recordingState = .saving }
            let result = await finishing.finish(extra: extra.value)
            await MainActor.run {
                if result.succeeded {
                    self.lastRecording = result.folder
                    self.recordingState = .saved
                } else {
                    self.recordingState = .failed(result.error ?? "Recording failed")
                }
            }
        }
        recordingFinishTask = task
        return task
    }

    @MainActor
    func stop(message: String = "Camera paused") {
        WallPowerMonitor.shared.clearRuntime()
        runtimeTask?.cancel()
        runtimeTask = nil
        request?.cancel()
        request = nil
        referenceRequest = nil
        status = message
        isReady = false
        frameLock.withLock { frameRequest = nil; frames.cancelPending() }
        ball = nil
        trail = []
        if recordingSince != nil { recordingState = .saving }
        recordingSince = nil
        queue.async { [self] in
            finishRecording()
#if WALL_GAMES_PREVIEW
            delayProbe = nil
            restoreDelayExposure()
#endif
            session.stopRunning()
            captureQueue.async { [self] in trackingPool = nil }
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
            mappingFrames = nil
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
        resetPixelTracking(); ballTracker.reset();modelSearch.reset();motionSearch.reset()
        lastFullSearch = -.infinity
        lastPerson = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let buffered = frameLock.withLock { frames.buffered && frameRequest != nil }
        guard let captured = buffered ? copyTrackingFrame(pixels) : pixels else { return }
        let next = frameLock.withLock { () -> CapturedFrame? in
            guard let current = frameRequest, !current.isCancelled else { return nil }
            if let last = receivedTime, time.seconds > last {
                receivedFPS = 0.9 * receivedFPS + 0.1 / (time.seconds - last)
            }
            receivedTime = time.seconds
            return frames.offer(CapturedFrame(pixels: captured, time: time, request: current, receivedFPS: receivedFPS), at: time.seconds)
        }
        if let next { schedule([next]) }
    }

    // Only touched by captureQueue. At most two batches plus one active frame.
    private func copyTrackingFrame(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let size = CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
        if trackingPool == nil || trackingPoolSize != size {
            trackingPool = nil; trackingPoolSize = size
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, [
                kCVPixelBufferWidthKey: Int(size.width), kCVPixelBufferHeightKey: Int(size.height),
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &trackingPool)
        }
        guard let trackingPool else { return nil }
        var copy: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, trackingPool,
            [kCVPixelBufferPoolAllocationThresholdKey: 14] as CFDictionary, &copy) == kCVReturnSuccess,
              let copy else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly); CVPixelBufferLockBaseAddress(copy, [])
        defer { CVPixelBufferUnlockBaseAddress(copy, []); CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard let src = CVPixelBufferGetBaseAddress(source), let dst = CVPixelBufferGetBaseAddress(copy) else { return nil }
        let sourceStride = CVPixelBufferGetBytesPerRow(source), targetStride = CVPixelBufferGetBytesPerRow(copy)
        for y in 0..<Int(size.height) { memcpy(dst.advanced(by: y * targetStride), src.advanced(by: y * sourceStride), Int(size.width) * 4) }
        return copy
    }

    private func schedule(_ batch: [CapturedFrame]) {
        queue.async { [self] in
            for (index, frame) in batch.enumerated() {
                autoreleasepool { process(frame, trackingOnly: index < batch.count - 1) }
            }
            let next = frameLock.withLock { frames.finish() }
            if !next.isEmpty { schedule(next) }
        }
    }

    private func process(_ frame: CapturedFrame, trackingOnly bufferedOnly: Bool = false) {
        let current = frame.request
        guard activeRequest === current, !current.isCancelled, !wantsCaptureRest else { return }
#if WALL_GAMES_PREVIEW
        if framingPreviewOnly, delayProbe != nil { sampleDisplayDelay(frame); return }
#endif
        if bufferedOnly && !usesPixelTracking { return }
        if usesPixelTracking && frame.time.seconds < pixelResetTime { return }
        let frameStarted = ProcessInfo.processInfo.systemUptime
        defer { workMeter.note(.frame, milliseconds: (ProcessInfo.processInfo.systemUptime - frameStarted) * 1000) }
        let pixels = frame.pixels, t = frame.time.seconds
        latestFrameTime = t
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        if size != bufferSize {
            bufferSize = size
            rebuildBoard()
            Task { @MainActor in self.frameSize = size }
        }
        if framingPreviewOnly { return }
        if let audit=visualAuditState {
            if t-lastSetupPreview>=0.12 {
                lastSetupPreview=t
                liveFeed?.addFrame(pixels,at:t)
                liveFeed?.setState(["captureTime":t,"frameWidth":size.width,"frameHeight":size.height,
                    "mode":"projection-visual-audit","audit":audit,"recording":false,
                    "thermalState":ProcessInfo.processInfo.thermalState.rawValue,
                    "camera":["exposureSeconds":device?.exposureDuration.seconds ?? 0,
                              "iso":Double(device?.iso ?? 0),"lensPosition":Double(device?.lensPosition ?? 0),
                              "focusLocked":device?.focusMode == .locked,
                              "exposureLocked":device?.exposureMode == .locked || device?.exposureMode == .custom,
                              "whiteBalanceGains":[Double(device?.deviceWhiteBalanceGains.redGain ?? 0),
                                                   Double(device?.deviceWhiteBalanceGains.greenGain ?? 0),
                                                   Double(device?.deviceWhiteBalanceGains.blueGain ?? 0)],
                              "whiteBalanceLocked":device?.whiteBalanceMode == .locked]])
            }
            return
        }
        // Capture timestamps are on the host clock, the same clock as CACurrentMediaTime.
        if mappingFrames != nil {
            if size != mappingSize { mappingSize = .zero }
            if mappingFrames!.count < 180, t - (mappingFrames!.last?.t ?? -.infinity) >= 1.0 / 30 {
                CVPixelBufferLockBaseAddress(pixels, .readOnly)
                if let base = CVPixelBufferGetBaseAddress(pixels) {
                    mappingFrames!.append(.init(t: t, luma: WallMappingCheck.thumbnail(
                        base.assumingMemoryBound(to: UInt8.self), width: Int(size.width), height: Int(size.height),
                        rowBytes: CVPixelBufferGetBytesPerRow(pixels))))
                }
                CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
            }
            if let recorder {
                measure(.recording) {
                    recorder.append(pixels, at: frame.time, ball: nil, person: nil, hand: .unknown,
                        lensPosition: device.map { Double($0.lensPosition) },
                        adjustingFocus: device?.isAdjustingFocus ?? false, inferenceRan: false)
                }
            }
            return
        }
        if cornerSearch != nil, cornerSearch!.count < 600 {
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                cornerSearch!.append(.init(t: t, luma: WallCornerFinder.thumbnail(
                    base.assumingMemoryBound(to: UInt8.self), width: Int(size.width), height: Int(size.height),
                    rowBytes: CVPixelBufferGetBytesPerRow(pixels))))
            }
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
            if let recorder {
                measure(.recording) {
                    recorder.append(pixels, at: frame.time, ball: nil, person: nil, hand: .unknown,
                        lensPosition: device.map { Double($0.lensPosition) },
                        adjustingFocus: device?.isAdjustingFocus ?? false, inferenceRan: false)
                }
            }
            if inspectionEnabled,t-lastSetupPreview>=0.12 {
                lastSetupPreview=t
                Task { @MainActor [weak self] in
                    guard let self,self.request === current,!current.isCancelled else { return }
                    self.ball=nil
                    if let telemetry=self.onPhysicalBall(nil,t) {
                        self.queue.async { [self] in self.liveFeed?.setKeeperState(telemetry) }
                    }
                }
                liveFeed?.addFrame(pixels,at:t)
                liveFeed?.setState(["captureTime":t,"frameWidth":size.width,"frameHeight":size.height,
                    "ball":NSNull(),"recording":recorder != nil,"status":"Finding goal markers",
                    "thermalState":ProcessInfo.processInfo.thermalState.rawValue])
            }
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
                    resetPixelTracking(); ballTracker.reset();modelSearch.reset();motionSearch.reset(); lastFullSearch = -.infinity; lastPerson = nil
                }
                publishAlignment(update, request: current)
            }
        }
        let physicalReference=inspectionEnabled && !physicalReferenceCorners.isEmpty
        if !bufferedOnly && !inferenceCadence.admit(at: t, scoring: scoringEnabled || (inspectionEnabled && !physicalReference),
                collectingReference: referenceCollector != nil || physicalReference,
                referenceFinished: referenceFinished && !physicalReference,
                gameplayInputEnabled: gameplayInputEnabled || inspectionEnabled) {
            if (referenceCollector != nil && !referenceFinished) || physicalReference { workMeter.skippedReferenceFrame() }
            if scoringEnabled && !gameplayInputEnabled && !inspectionEnabled { workMeter.skippedGamePhaseFrame() }
            // Keep real frames, but never invent a detection or feed a skipped
            // analysis frame to the reference hold as a missing observation.
            if let recorder {
                measure(.recording) {
                    recorder.append(pixels, at: frame.time, ball: nil, person: nil, hand: .unknown,
                        alignment: alignment?.update, lensPosition: device.map { Double($0.lensPosition) },
                        adjustingFocus: device?.isAdjustingFocus ?? false, inferenceRan: false)
                    if let update = alignment?.update, update != lastLoggedAlignment {
                        recorder.noteAlignment(update, at: t)
                        lastLoggedAlignment = update
                    }
                }
            }
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        var detection: Detection?
        var person: Detection?
        var detectionSource = 0 // 5 = provisional pixel match, not an RF confidence
        var pixelImage = usesPixelTracking && pixelTracker.hasSeed
            ? measure(.pixelTracking) { WallBallPixelTracker.Image(pixels) } : nil
        let pixelMatch = pixelImage.flatMap { image in measure(.pixelTracking) { pixelTracker.update(image, at: t) } }
        let boardCrop = WallBallTracker.crop(corners: physicalReference ? physicalReferenceCorners : corners, size: size)
        let measuredMotion: WallBallMotionSearch.Hint?
        if scoringEnabled, detector.modelUsesCPUOnly, boardCrop != nil {
            measuredMotion = measure(.motionSearch) { motionSearch.crop(in: pixels, at: t) }
        } else { motionSearch.reset(); measuredMotion = nil }
        let trackingOnly: Bool
        if usesPixelTracking {
            trackingOnly = !gameplayCadence.admit(at: t, motion: measuredMotion != nil,
                tracked: pixelMatch != nil, modelFrame: !bufferedOnly)
            if trackingOnly && !bufferedOnly {
                workMeter.skippedIdleModelFrame()
                // Report active model cadence without treating a deliberate
                // between-shot rest as slow inference during the next shot.
                lastFrameTime = nil
            }
        } else if scoringEnabled && !inspectionEnabled && !detector.modelUsesCPUOnly {
            let motion = measure(.motionSearch) { sceneActivity.hasMotion(in: pixels, at: t) }
            workMeter.observedSceneMotion(motion)
            trackingOnly = !gameplayCadence.admit(at: t, motion: motion, tracked: false, modelFrame: !bufferedOnly)
            if trackingOnly && !bufferedOnly { workMeter.skippedIdleModelFrame(); lastFrameTime = nil }
        } else { trackingOnly = bufferedOnly }
        if !trackingOnly {
            if let last = lastFrameTime, t > last { fps = 0.9 * fps + 0.1 / (t - last) }
            lastFrameTime = t
        }
        func physicalSample(_ d: Detection, hand: WallHandState = .unknown) -> PhysicalBallSample {
            .init(time:t,x:d.x,y:d.y,diameter:(d.width+d.height*size.height/size.width)/2,
                  confidence:d.score,aspect:d.width*size.width/max(1,d.height*size.height),
                  held:hand == .held,imageAspect:size.width/size.height,released:hand == .clear)
        }
        func eligible(_ d: Detection) -> Bool {
            guard physicalReference,let physicalReferenceGate else { return true }
            return physicalReferenceGate.contains(physicalSample(d))
        }
        if trackingOnly {
            detection = pixelMatch
            if detection != nil { detectionSource = 5 }
        } else { do {
            let reacquireStationary = scoringEnabled && !inspectionEnabled
            var currentTracker = ballTracker
            if let pixelMatch { currentTracker.accept(pixelMatch, at: t - 0.000001) }
            let referenceCrop = detector.modelUsesCPUOnly && !physicalReference
                && referenceCollector?.target == WallReferenceCollector.wallCentre
                ? WallBallTracker.referenceCrop(corners: corners, size: size) : nil
            // The paused keeper experiment retains its existing view.
            // Ordinary CPU wall games follow the measured ball.
            let followCrop=scoringEnabled && detector.modelUsesCPUOnly && boardCrop != nil
                ? currentTracker.followCrop(at:t,size:size,motionRegion:measuredMotion?.region,
                    allowStationaryReacquisition:reacquireStationary):nil
            let motionHint = followCrop == nil ? measuredMotion : nil
            let crop=referenceCrop ?? followCrop ?? motionHint?.crop ?? boardCrop
            let fullFrame=modelSearch.useFullFrame(hasCrop:crop != nil,cpuOnly:detector.modelUsesCPUOnly,
                                                  at:t,lastFullSearch:lastFullSearch) && motionHint == nil && referenceCrop == nil
            if let crop,!fullFrame {
                let candidates = try measure(.boardModel) {
                    try autoreleasepool { try detector.wallTargetCandidates(in: pixels, crop: crop) }.filter {
                        ($0.width+$0.height*size.height/size.width)/2>=physicalMinimumDiameter && eligible($0)
                            && (motionHint?.contains($0, size: size,
                                minimumDiameter: (wallReference?.diameters.min() ?? 0) * size.width * 0.65) ?? true)
                    }
                }
                detection = currentTracker.select(candidates, at: t, size: size,
                    allowStationaryReacquisition: reacquireStationary)
                    ?? ballTracker.select(candidates, at: t, size: size,
                        allowStationaryReacquisition: reacquireStationary)
                if detection != nil { detectionSource = followCrop != nil ? 3:motionHint != nil ? 4:2 }
                // CPU mode defers the room search to the next fresh frame.
                // Accelerated mode retains the existing immediate recovery.
                // One weak frame at contact must not replace the next detailed
                // rebound measurement with a room-wide search. The follow view
                // expires after 200 ms without a real measured box.
                if detection == nil, followCrop == nil,
                   modelSearch.requestFullFrame(cpuOnly:detector.modelUsesCPUOnly,
                                                                 at:t,lastFullSearch:lastFullSearch) {
                    lastFullSearch = t
                    let result = try measure(.fullFrameModel) {
                        try autoreleasepool { try detector.wallTargetDetections(in:pixels,threshold:Self.scoreThreshold,minimumBallDiameter:physicalMinimumDiameter) }
                    }
                    person = result.person
                    lastPerson = person.map { (t, $0) }
                    detection = ballTracker.select((result.ball.map { [$0] } ?? []).filter(eligible), at: t, size: size,
                        allowStationaryReacquisition: reacquireStationary)
                    if detection != nil { detectionSource = 1 }
                }
            } else {
                lastFullSearch=t
                let result = try measure(.fullFrameModel) {
                    try autoreleasepool { try detector.wallTargetDetections(in:pixels,threshold:Self.scoreThreshold,minimumBallDiameter:physicalMinimumDiameter) }
                }
                detection = crop == nil ? result.ball
                    : ballTracker.select((result.ball.map {[$0]} ?? []).filter(eligible),at:t,size:size,
                        allowStationaryReacquisition:reacquireStationary)
                person = result.person
                lastPerson=person.map { (t,$0) }
                if detection != nil { detectionSource = 1 }
            }
            ballTracker.accept(detection, at: t)
            if detection != nil { gameplayCadence.observedBall(at: t) }
        } catch {
            publish(status: "Ball detection unavailable", request: current)
            pixelTracker.reset(); pixelEvidence = []
            return
        } }
        var hand = WallHandState.unknown
        if let d = detection, scoringEnabled || (inspectionEnabled && !physicalReference) {
            let poseStarted = ProcessInfo.processInfo.systemUptime
            if hands.observe(pixels, at: t) {
                workMeter.note(.bodyPose, milliseconds: (ProcessInfo.processInfo.systemUptime - poseStarted) * 1000)
            }
            if person == nil, let lastPerson, t - lastPerson.t <= 0.15 { person = lastPerson.box }
            func body(_ person: Detection?) -> CGRect? {
                person.map { CGRect(x: $0.x - $0.width / 2, y: $0.y - $0.height / 2, width: $0.width, height: $0.height) }
            }
            hand = hands.state(ball: CGPoint(x: d.x, y: d.y), diameter: (d.width * size.width + d.height * size.height) / 2 / size.height,
                               aspect: size.width / size.height, person: body(person), at: t)
            if !trackingOnly, hand == .unknown, person == nil, t - lastFullSearch >= 0.12,
               modelSearch.requestFullFrame(cpuOnly:detector.modelUsesCPUOnly,at:t,lastFullSearch:lastFullSearch) {
                // The person may be partly outside the board view. Recover
                // full-frame body context without replacing the detailed ball.
                lastFullSearch = t
                if let result = try? measure(.fullFrameModel, {
                    try autoreleasepool { try detector.wallTargetDetections(in: pixels, threshold: Self.scoreThreshold) }
                }) {
                    person = result.person; lastPerson = person.map { (t, $0) }
                    hand = hands.state(ball: CGPoint(x: d.x, y: d.y), diameter: (d.width * size.width + d.height * size.height) / 2 / size.height,
                                       aspect: size.width / size.height, person: body(person), at: t)
                }
            }
        }
        let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
        if inspectionEnabled {
            let sample=detection.map { physicalSample($0,hand:hand) }
            // Dispatch before recording/JPEG work. The controller rejects stale
            // delivery and never waits for a rebound-confirmed wall hit.
            Task { @MainActor [weak self] in
                guard let self,self.request === current,!current.isCancelled else { return }
                if let telemetry=self.onPhysicalBall(sample,t) {
                    self.queue.async { [self] in
                        self.physicalMinimumDiameter=self.inspectionEnabled && telemetry.armed ? (telemetry.wallDiameter ?? 0)*0.75:0
                        self.liveFeed?.setKeeperState(telemetry)
                    }
                }
            }
        }
        var mark: BallMark?
        let observation: WallImpactDetector.Observation? = detection.map { d in
            WallImpactDetector.Observation(t: t, x: d.x * size.width, y: d.y * size.height,
                d: (d.width * size.width + d.height * size.height) / 2, hand: hand, confidence: d.score)
        }
        let previousPreview = shots.contactPreview
        var found: [WallImpactDetector.Impact] = []
        if usesPixelTracking {
            if trackingOnly {
                if let observation {
                    pixelEvidence.append(.init(observation: observation, update: alignment?.update,
                        retain: alignment?.canRetainEvidence(at: t) == true))
                } else { pixelEvidence = [] }
                if pixelEvidence.count > WallTrackingFrameBuffer<CapturedFrame>.capacity { pixelEvidence = [] }
            } else {
                // No intermediate point enters the shot history until an
                // independent model measurement agrees at this batch's endpoint.
                let confirmed = WallBallPixelTracker.agrees(pixelMatch, model: detection, size: size)
                if !pixelEvidence.isEmpty {
                    recorder?.notePixelBridge(from: pixelEvidence.first!.observation.t, through: t,
                                              count: pixelEvidence.count, confirmed: confirmed)
                }
                if confirmed {
                    for item in pixelEvidence {
                        _ = shots.process(item.observation, at: item.observation.t, update: item.update,
                            retainEvidence: item.retain, canScore: false,
                            reference: wallReference, size: size, fps: fps, layout: targetLayout,
                            usesSparseDepthConsistency: true)
                    }
                }
                pixelEvidence = []
                if let detection, detection.score >= 0.20 {
                    if pixelImage == nil { pixelImage = measure(.pixelTracking) { WallBallPixelTracker.Image(pixels) } }
                    if let pixelImage { pixelTracker.seed(detection, image: pixelImage, at: t) }
                    else { pixelTracker.reset() }
                } else { pixelTracker.reset() }
            }
        }
        // Pixel-only frames remain provisional. Maturity and scoring run when
        // the next model result has accepted or discarded their whole bridge.
        if !trackingOnly { found = shots.process(observation, at: t, update: alignment?.update,
            retainEvidence: scoringEnabled && alignment?.canRetainEvidence(at: t) == true,
            canScore: scoringEnabled && alignment?.canScore(at: t) == true,
            reference: wallReference, size: size, fps: fps, layout: targetLayout,
            usesSparseDepthConsistency: detector.modelUsesCPUOnly) }
        let contactPreview = shots.contactPreview
        // Deliver scores before writer appends, metadata serialization, optional
        // JPEG/shot-strip generation and camera-overlay telemetry. None of that
        // diagnostic work should hold up a confirmed hit or its sound request.
        let decisionReady = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        if contactPreview != previousPreview || !found.isEmpty {
            let deliveryRecorder = recorder
            Task { @MainActor [weak self] in
                guard let self, self.request === current, !current.isCancelled else { return }
                let received = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                self.onContactPreview(contactPreview)
                for impact in found {
                    let accepted = self.onImpact(impact)
                    let completed = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                    self.queue.async { [self] in
                        guard let deliveryRecorder, self.recorder === deliveryRecorder else { return }
                        deliveryRecorder.noteFeedbackDelivery(impact, evidenceFrame: t, decisionReady: decisionReady,
                            mainActorReceived: received, callbackCompleted: completed, accepted: accepted)
                    }
                }
            }
        }
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
        let recordingStarted = ProcessInfo.processInfo.systemUptime
        let wasRecording = recorder != nil
        recorder?.append(pixels, at: frame.time, ball: detection, person: person, hand: hand, source: detectionSource,
                         alignment: alignment?.update,
                         retainEvidence: scoringEnabled && alignment?.canRetainEvidence(at: t) == true,
                         canScore: scoringEnabled && alignment?.canScore(at: t) == true,
                         lensPosition: device.map { Double($0.lensPosition) },
                         adjustingFocus: device?.isAdjustingFocus ?? false, inferenceRan: !trackingOnly)
        if let update = alignment?.update, update != lastLoggedAlignment {
            recorder?.noteAlignment(update, at: t)
            lastLoggedAlignment = update
        }
        recorder?.noteDecisions(decisions)
        if let contactPreview, contactPreview != previousPreview {
            recorder?.noteFeedback(contactPreview, at: t, kind: "preview")
        }
        for impact in found { recorder?.noteFeedback(impact, at: t, kind: "confirmed") }
        for impact in found { recorder?.note(impact) }
        if wasRecording {
            workMeter.note(.recording, milliseconds: (ProcessInfo.processInfo.systemUptime - recordingStarted) * 1000)
        }
        if let feed = liveFeed, ProcessInfo.processInfo.thermalState.rawValue < 2 {
            let previewStarted = ProcessInfo.processInfo.systemUptime
            feed.addFrame(pixels, at: t)
            feed.setState([
                "corners": corners.map { [Double($0.x), Double($0.y)] },
                "cornersNotSet": !scoringEnabled,
                "ball": mark.map { ["x": $0.x, "y": $0.y, "w": $0.width, "atWall": $0.atWall] as Any } ?? NSNull(),
                "fps": fps, "detectMS": ms, "recording": recorder != nil, "status": "Watching for hits",
                "captureTime": t, "frameWidth": size.width, "frameHeight": size.height,
                "thermalState": ProcessInfo.processInfo.thermalState.rawValue])
            for impact in found { feed.addShot(impact, frameSize: size) }
            workMeter.note(.macPreview, milliseconds: (ProcessInfo.processInfo.systemUptime - previewStarted) * 1000)
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
            if !trackingOnly { self.processingFPS = rate; self.detectorMS = ms }
            self.lastInferencePublished = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            self.deliveredFPS = frame.receivedFPS
            self.handState = publishedHand
        }
    }

    private func measure<T>(_ stage: WallWorkMeter.Stage, _ operation: () throws -> T) rethrows -> T {
        let start = ProcessInfo.processInfo.systemUptime
        defer { workMeter.note(stage, milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000) }
        return try operation()
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
