//
//  VideoAnalyzer.swift
//  kicklab
//
//  Run a recorded video through the same detector and counter the camera uses.
//
//  This exists as a control. The lab scores the walking clip at 0 detections and
//  0 touches; the live camera on an empty room reports thousands of detections
//  and 30 touches. Feeding that same file through this path splits the
//  difference cleanly:
//
//    * counts ~0 here  -> the model and counter are fine on device, and the bug
//                         is in the live capture path (rotation, pixel format,
//                         buffer reuse, threading).
//    * counts high here -> the bug is in the Swift decode or counter port, and
//                         has nothing to do with the camera.
//
//  It is also a real feature: analysing a recording is useful in its own right,
//  and does not need to hit 30fps.
//

import AVFoundation
import Combine
import CoreVideo
import Foundation
import UIKit

@MainActor
final class VideoAnalyzer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var touchCount = 0
    @Published private(set) var detections = 0
    @Published private(set) var framesRead = 0
    @Published private(set) var peakScore: Double = 0
    /// Detections thrown out by the plausibility gate. If this is large, the gate
    /// is eating real balls rather than phantoms.
    @Published private(set) var dropped = 0
    @Published private(set) var status = ""
    @Published private(set) var recordedTrack: [RecordedFrame] = []
    @Published private(set) var visualRecoveries: [RecordedFrame] = []
    var renderTrack: [RecordedFrame] {
        visualRecoveries.isEmpty ? recordedTrack : (recordedTrack + visualRecoveries).sorted { $0.time < $1.time }
    }
    @Published private(set) var recordedTouches: [RecordedTouch] = []
    @Published private(set) var videoDuration: Double = 0
    @Published private(set) var performance: [String: Double] = [:]
    @Published private(set) var analyzedModel = ""
    @Published private(set) var counterTrace: CounterTrace?
    @Published private(set) var followDiagnostics: [[String: Any]] = []
    @Published private(set) var isCooling = false
    @Published private(set) var canContinueInBackground = false
    private var worker: Task<Void, Never>?

    #if DEBUG
    @Published private(set) var failureDiagnostic = ""
    #endif

    func analyse(url: URL, visualOnly: Bool = false) {
        guard !isRunning else { return }
        isRunning = true
        progress = 0
        touchCount = 0
        detections = 0
        framesRead = 0
        peakScore = 0
        status = "reading…"
        #if DEBUG
        failureDiagnostic = ""
        #endif
        dropped = 0
        recordedTrack = []
        visualRecoveries = []
        recordedTouches = []
        counterTrace = nil
        performance = [:]
        isCooling = false
        canContinueInBackground = false

        worker = Task { [weak self] in
            do {
                try await VideoBackgroundWork.shared.run(title: visualOnly ? "Preparing video" : "Importing video") { [weak self] in
                    guard let self else { return }
                    let allowed = VideoWorkExecution.lease?.canContinue == true
                    await MainActor.run { self.canContinueInBackground = allowed }
                    let task = VideoWorkExecution.detached { try await self.run(url: url, visualOnly: visualOnly) }
                    try await withTaskCancellationHandler { _ = try await task.value } onCancel: { task.cancel() }
                }
            } catch is CancellationError {
                await MainActor.run { self?.status = "cancelled" }
            } catch {
                let diagnostic = String(reflecting: error as NSError)
                await MainActor.run {
                    self?.status = "failed: \(error.localizedDescription)"
                    #if DEBUG
                    self?.failureDiagnostic = diagnostic
                    #endif
                }
            }
            await MainActor.run {
                self?.isCooling = false
                self?.worker = nil
                self?.isRunning = false
            }
        }
    }

    /// Keep isRunning true until the worker has acknowledged cancellation and
    /// released its reader/model. A new import cannot overlap that teardown.
    func cancel() { worker?.cancel() }
    func waitUntilFinished() async { await worker?.value }

    /// Rebuild only the editor's visual track from saved pixels on the same
    /// composition clock used by imported videos, replay and export. The caller
    /// retains the live counter, original track and touch markers unchanged.
    nonisolated static func replayTrack(
        source: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [RecordedFrame] {
        let task = VideoWorkExecution.detached {
            let analyzer = await VideoAnalyzer()
            try await analyzer.run(url: source, visualOnly: true, onProgress: onProgress)
            return await analyzer.renderTrack
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated func run(url: URL, visualOnly: Bool = false,
                                onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await VideoAnalysisScheduler.shared.perform {
            // A granted continued-processing job may run after auto-lock.
            // Keep the screen awake only for the foreground-only fallback.
            let wasIdleDisabled = await MainActor.run {
                let previous = UIApplication.shared.isIdleTimerDisabled
                if VideoWorkExecution.lease?.canContinue != true { UIApplication.shared.isIdleTimerDisabled = true }
                return previous
            }
            do {
                try await self.runExclusively(url: url, visualOnly: visualOnly, onProgress: onProgress)
                await MainActor.run { UIApplication.shared.isIdleTimerDisabled = wasIdleDisabled }
            } catch {
                await MainActor.run { UIApplication.shared.isIdleTimerDisabled = wasIdleDisabled }
                throw error
            }
        }
    }

    private nonisolated func runExclusively(url: URL, visualOnly: Bool,
                                onProgress: (@Sendable (Double) -> Void)?) async throws {
        try Task.checkCancellation()
        // Security-scoped access is required for files picked outside the app.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let lookupStart = ProcessInfo.processInfo.systemUptime
        let sourceDigest = try SessionAnalysisStore.sourceDigest(url)
        let pipelineSignature = SessionAnalysisStore.pipelineSignature()
        let batchRequested = BallDetector.visualBatchSize(visualOnly:visualOnly) == 2
        let asyncBatchRequested = batchRequested && ProcessInfo.processInfo.arguments.contains("--visual-async2")
        let visualSignature = SessionAnalysisStore.visualPipelineSignature()
        let recoveryRequested = DistantBallVisualRecovery.enabled()
        let fullKey = SessionAnalysisStore.digest(Data("inference|\(pipelineSignature)|\(sourceDigest)\(DistantBallVisualRecovery.signature())".utf8))
        // A visual-only result cannot masquerade as a counted import. A complete
        // import remains a valid source of visual observations in either mode.
        let cacheKey = visualOnly ? SessionAnalysisStore.digest(Data("visual-inference|\(visualSignature)|\(sourceDigest)".utf8)) : fullKey
        let bypassCache = ProcessInfo.processInfo.arguments.contains("--analysis-ignore-cache")
            || ProcessInfo.processInfo.arguments.contains("--effects-follow-review")
        let cached = bypassCache ? nil : await SessionAnalysisStore.shared.loadInference(key:cacheKey)
        let fallback = visualOnly && !batchRequested && cached == nil && !bypassCache
            ? await SessionAnalysisStore.shared.loadInference(key:fullKey) : nil
        if let stored = cached ?? fallback {
            try Task.checkCancellation()
            let frames = stored.frames.map(\.frame), touches = stored.recordedTouches
            let elapsed = ProcessInfo.processInfo.systemUptime - lookupStart
            let trace = await SessionAnalysisStore.shared.loadCounterTrace(sourceDigest: sourceDigest, mode: .file)
            let matchingTrace = trace?.pipelineSignature == pipelineSignature ? trace?.trace : nil
            await MainActor.run {
                self.counterTrace = matchingTrace
                self.recordedTrack = frames; self.recordedTouches = touches
                self.visualRecoveries = (stored.visualRecoveries ?? []).map(\.frame)
                self.touchCount = stored.count; self.detections = stored.detections
                self.dropped = stored.rejected; self.framesRead = stored.framesRead
                self.videoDuration = stored.duration; self.peakScore = stored.peak
                self.analyzedModel = stored.model; self.followDiagnostics = []
                self.performance = ["cache_hit":1,"elapsed_s":elapsed,"original_analysis_s":stored.elapsed,
                    "inference_s":0,"detector_s":0,"load_ms":0,"detection_errors":0,
                    "mask_frames":Double(frames.filter { $0.ballMask != nil }.count),
                    "mask_storage_bytes":Double(frames.reduce(0) { $0 + ($1.ballMask?.alpha.count ?? 0) })]
                self.progress = 1; self.status = "done"
            }
            onProgress?(1)
            return
        }
        #if DEBUG
        var pacer = VideoAnalysisPacer(enabled: !ProcessInfo.processInfo.arguments.contains("--thermal-unpaced"))
        #else
        var pacer = VideoAnalysisPacer()
        #endif
        _ = try await pacer.beginFrame { cooling in
            await MainActor.run { self.isCooling = cooling }
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "KickLab", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "no video track"])
        }
        let duration = try await asset.load(.duration)
        let nominalFps = try await track.load(.nominalFrameRate)
        let fps = nominalFps > 0 ? Double(nominalFps) : 30.0
        let total = max(1.0, CMTimeGetSeconds(duration) * fps)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_32BGRA])
        output.videoComposition = try await EffectVideoGeometry.composition(track: track, duration: duration, shortEdge: 720)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "KickLab", code: 11) }
        defer { reader.cancelReading() }

        let started = ProcessInfo.processInfo.systemUptime
        let beforeModel = DetectorPerformance.memoryMB()
        let detector = try BallDetector()
        let visualRecovery = recoveryRequested && detector.supportsDistantVisualRecovery ? DistantBallVisualRecovery() : nil
        var recoveredFrames: [RecordedFrame] = []
        var batchEnabled = batchRequested && detector.supportsFrameBatching
        var batchFallbacks=0, batchedFrames=0, modelCalls=0, cropCalls=0
        var peakMemory = DetectorPerformance.memoryMB()
        let loadMS = (ProcessInfo.processInfo.systemUptime-started)*1000
        var inferenceTimes: [Double] = [], totalTimes: [Double] = []
        var followRows: [[String: Any]] = [], detectionErrors=0
        let auditFollow=ProcessInfo.processInfo.arguments.contains("--effects-follow-review")
        let contactVerifier = !visualOnly && JugglingContactVerifier.enabled ? JugglingContactVerifier() : nil
        contactVerifier?.warmUp()
        try Task.checkCancellation()
        let counter = StreamingCounter(rejectsHandContact: { [weak contactVerifier] in
            contactVerifier?.rejectsHandContact(at: $0) ?? false
        }, recordTrace: !visualOnly, footContactEvidence: !visualOnly && JugglingContactVerifier.enabled ? { [weak contactVerifier] in
            contactVerifier?.footEvidence(at: $0)
        } : nil, countsTouches: !visualOnly)
        var plausibility = BallPlausibility()
        // Same compensation the live path uses, so a file analysed here can be
        // compared directly against the lab's answer on the same footage.
        let compensator = MotionCompensator()
        var index = 0
        var peak = 0.0
        var detected = 0
        var frames: [RecordedFrame] = []
        var visualRefiner = BallVisualRefiner()
        var touches: [RecordedTouch] = []
        var decodeSeconds = 0.0, preprocessSeconds = 0.0, inferenceSeconds = 0.0
        var detectorSeconds = 0.0, motionSeconds = 0.0, counterSeconds = 0.0
        var contactSeconds = 0.0, publishSeconds = 0.0

        var pendingSamples=[CMSampleBuffer](), pendingPredictions=[BallDetector.PreparedFrame]()
        while true {
            let frameStarted = try await pacer.beginFrame { cooling in
                await MainActor.run { self.isCooling = cooling }
            }
            if pendingSamples.isEmpty {
                try Task.checkCancellation()
                let readStart = ProcessInfo.processInfo.systemUptime
                for _ in 0..<(batchEnabled ? 2 : 1) {
                    guard let sample=output.copyNextSampleBuffer() else { break }
                    if CMSampleBufferGetImageBuffer(sample) != nil { pendingSamples.append(sample) }
                }
                decodeSeconds += ProcessInfo.processInfo.systemUptime-readStart
                if pendingSamples.isEmpty {
                    if reader.status == .reading { continue }
                    break
                }
                if batchEnabled {
                    do {
                        let inputs=pendingSamples.map {
                            (pixels:CMSampleBufferGetImageBuffer($0)!,time:$0.presentationTimeStamp.seconds)
                        }
                        if asyncBatchRequested { pendingPredictions = try await detector.prepareBatchAsync(inputs) }
                        else { pendingPredictions = try autoreleasepool {try detector.prepareBatch(inputs)} }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        // Preparation never advances detector history. Retain the
                        // same samples and process every one through serial detect.
                        pendingPredictions=[]; batchEnabled=false; batchFallbacks += 1
                    }
                }
            }
            let sample=pendingSamples.removeFirst()
            let prepared=pendingPredictions.isEmpty ? nil : pendingPredictions.removeFirst()
            try Task.checkCancellation()
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let stampMs = Int(CMTimeGetSeconds(
                CMSampleBufferGetPresentationTimeStamp(sample)) * 1000)

            var detectionFailed = false
            var found = autoreleasepool { () -> FrameDetections in
                do {
                    if let prepared { batchedFrames += 1; return try detector.detectPrepared(prepared) }
                    return try detector.detect(pixels, orientLandscapeAsPortrait: false,
                        timestamp: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
                }
                catch { detectionFailed = true; detectionErrors += 1; return FrameDetections(ball:nil,person:nil) }
            }
            try Task.checkCancellation()
            // Retain the original result for plausibility, motion compensation,
            // contact verification and counting. Extra crops only enter the sidecar.
            if detectionFailed { visualRecovery?.reset() }
            let visual = detectionFailed ? nil : try autoreleasepool {
                try visualRecovery?.recover(pixels: pixels,
                    time: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)),
                    baseline: found, detector: detector)
            }
            modelCalls += detector.lastFollowCalls
            cropCalls += max(0,detector.lastFollowCalls-1)
            if auditFollow {
                var row: [String: Any] = ["frame":index,"time":CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)),
                    "kind":detector.lastFollowKind,"calls":detector.lastFollowCalls,"mask":found.ballMask != nil,
                    "visual_recovery":visualRecovery?.lastKind ?? "disabled",
                    "memory_mib":DetectorPerformance.memoryMB()]
                if let b=found.ball { row["box"]=[b.x-b.width/2,b.y-b.height/2,b.x+b.width/2,b.y+b.height/2]; row["score"]=b.score }
                followRows.append(row)
            }
            inferenceTimes.append(detector.lastInferenceMS); totalTimes.append(detector.lastTotalMS)
            preprocessSeconds += detector.lastPreprocessMS / 1000
            inferenceSeconds += detector.lastInferenceMS / 1000
            detectorSeconds += detector.lastTotalMS / 1000
            peakMemory = max(peakMemory, DetectorPerformance.memoryMB())
            if let ball = found.ball {
                found.ball = plausibility.accept(ball, frame: index)
            }
            if let b = found.ball {
                detected += 1
                peak = max(peak, b.score)
            }
            compensator.excludeBall = found.ball.map {
                CGRect(x: $0.x - $0.width / 2, y: $0.y - $0.height / 2,
                       width: $0.width, height: $0.height)
            }
            let motionStart = ProcessInfo.processInfo.systemUptime
            let shift = compensator.update(pixels)
            motionSeconds += ProcessInfo.processInfo.systemUptime - motionStart
            let ball = found.ball.map {
                BallObservation(frameIndex: index, timestampMs: stampMs,
                                x: $0.x, y: $0.y,
                                width: $0.width, height: $0.height,
                                confidence: $0.score)
            }
            let person = found.person.map {
                PersonBox(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            }
            let contactStart = ProcessInfo.processInfo.systemUptime
            if compensator.isTooShaky { contactVerifier?.discardFrames() }
            else {
                contactVerifier?.store(pixels, frameIndex: index, timestampMs: stampMs,
                                       ball: found.ball, orientLandscapeAsPortrait: false)
            }
            contactSeconds += ProcessInfo.processInfo.systemUptime - contactStart
            let counterStart = ProcessInfo.processInfo.systemUptime
            let confirmed = counter.push(frameIndex: index, timestampMs: stampMs,
                ball: ball, person: person, cameraOffsetY: shift, reliable: !compensator.isTooShaky, sourceFrameIndex: index)
            counterSeconds += ProcessInfo.processInfo.systemUptime - counterStart
            if let detection = found.ball {
                let b = found.usesBallMasks ? detection : visualRefiner.refine(detection, in: pixels, at: Double(stampMs) / 1000)
                frames.append(RecordedFrame(time: Double(stampMs) / 1000, x: b.x, y: b.y,
                    width: b.width, height: b.height, score: b.score,
                    smoothedX: counter.lastPoint?.x ?? b.x, smoothedY: counter.lastPoint?.y ?? b.y,
                    vy: counter.lastPoint?.vy ?? 0, motion: counter.lastPoint?.motion ?? .unknown,
                    detected: true, person: person, ballMask: found.ballMask, usesBallMasks: found.usesBallMasks,
                    identity: RecordedFrameIdentity(index:index, time:CMSampleBufferGetPresentationTimeStamp(sample),
                        width:CVPixelBufferGetWidth(pixels),height:CVPixelBufferGetHeight(pixels),coordinates:"composition-720-sdr-v1")))
            }
            if let b = visual?.ball, let mask = visual?.ballMask {
                recoveredFrames.append(RecordedFrame(time: Double(stampMs) / 1000, x: b.x, y: b.y,
                    width: b.width, height: b.height, score: b.score,
                    smoothedX: b.x, smoothedY: b.y, vy: 0, motion: .unknown,
                    detected: true, person: person, ballMask: mask, usesBallMasks: true, isVisualRecovery: true,
                    identity: RecordedFrameIdentity(index:index,time:CMSampleBufferGetPresentationTimeStamp(sample),
                        width:CVPixelBufferGetWidth(pixels),height:CVPixelBufferGetHeight(pixels),coordinates:"composition-720-sdr-v1")))
            }
            touches.append(contentsOf: confirmed.map {
                RecordedTouch(index: $0.index, time: Double($0.timestampMs) / 1000, x: $0.x, y: $0.y)
            })

            index += 1
            try await pacer.finishFrame(started: frameStarted)
            if index % 15 == 0 {
                let publishStart = ProcessInfo.processInfo.systemUptime
                let snapshot = (index, counter.count, detected, peak,
                                plausibility.rejectedSize + plausibility.rejectedJump)
                await MainActor.run {
                    self.framesRead = snapshot.0
                    self.touchCount = snapshot.1
                    self.detections = snapshot.2
                    self.peakScore = snapshot.3
                    self.dropped = snapshot.4
                    self.progress = min(1.0, Double(snapshot.0) / total)
                    self.status = "analysing…"
                }
                VideoWorkExecution.lease?.progress(min(0.95, Double(snapshot.0) / total), subtitle: "Analysing your video")
                onProgress?(min(1.0, Double(snapshot.0) / total))
                publishSeconds += ProcessInfo.processInfo.systemUptime - publishStart
            }
        }
        if reader.status == .failed { throw reader.error ?? NSError(domain: "KickLab", code: 12) }
        touches.append(contentsOf: counter.flush().map {
            RecordedTouch(index: $0.index, time: Double($0.timestampMs) / 1000, x: $0.x, y: $0.y)
        })

        let trace = counter.traceSnapshot()
        if let trace {
            await SessionAnalysisStore.shared.saveCounterTrace(CounterTraceArchive(sourceDigest: sourceDigest,
                pipelineSignature: pipelineSignature, mode: .file, timeOriginSeconds: 0, trace: trace))
        }
        inferenceTimes.sort(); totalTimes.sort()
        func percentile(_ values: [Double], _ p: Double) -> Double {
            values.isEmpty ? 0 : values[min(values.count-1, Int(Double(values.count-1)*p))]
        }
        let metrics: [String: Double] = [
            "thermal_wait_s": pacer.waitingSeconds,
            "thermal_peak_state": Double(pacer.peakThermalState),
            "thermal_sleep_events": Double(pacer.pacingSleeps),
            "thermal_policy_version": 2,
            "contact_warmup_ms": contactVerifier?.warmUpMS ?? 0,
            "contact_check_ms": contactVerifier?.totalCheckMS ?? 0,
            "contact_checks": Double(contactVerifier?.checkedContacts ?? 0),
            "contact_rejections": Double(contactVerifier?.rejectedContacts ?? 0),
            "contact_peak_frames": Double(contactVerifier?.peakBufferedFrames ?? 0),
            "contact_error": contactVerifier?.lastError == nil ? 0 : 1,
            "foot_checks":Double(contactVerifier?.footChecks ?? 0), "foot_recoveries":Double(contactVerifier?.footRecoveries ?? 0),
            "foot_check_s":(contactVerifier?.footCheckMS ?? 0)/1000, "pose_requests":Double(contactVerifier?.poseRequests ?? 0),
            "pose_cache_hits":Double(contactVerifier?.poseCacheHits ?? 0),
            "cache_hit":0,"visual_only":visualOnly ? 1 : 0,"baseline_app_mib": beforeModel, "peak_sampled_app_mib": peakMemory,
            "batch_requested":batchRequested ? 1 : 0,"batched_frames":Double(batchedFrames),
            "async_batch_requested":asyncBatchRequested ? 1 : 0,
            "batch_fallbacks":Double(batchFallbacks),"model_calls":Double(modelCalls + (visualRecovery?.calls ?? 0)),"crop_calls":Double(cropCalls + (visualRecovery?.calls ?? 0)),
            "visual_recovery_calls":Double(visualRecovery?.calls ?? 0),"visual_recovered_frames":Double(recoveredFrames.count),
            "visual_recovery_errors":Double(visualRecovery?.errors ?? 0),"visual_recovery_s":visualRecovery?.seconds ?? 0,
            "detection_errors": Double(detectionErrors), "load_ms": loadMS, "elapsed_s": ProcessInfo.processInfo.systemUptime-started,
            "inference_median_ms": percentile(inferenceTimes,0.5), "inference_p95_ms": percentile(inferenceTimes,0.95),
            "detector_median_ms": percentile(totalTimes,0.5), "detector_p95_ms": percentile(totalTimes,0.95),
            "decode_wait_s": decodeSeconds, "preprocess_s": preprocessSeconds,
            "inference_s": inferenceSeconds, "detector_s": detectorSeconds,
            "motion_compensation_s": motionSeconds, "counter_s": counterSeconds,
            "contact_buffer_s": contactSeconds, "progress_publish_s": publishSeconds,
            "mask_frames": Double(frames.filter { $0.ballMask != nil }.count),
            "mask_storage_bytes": Double(frames.reduce(0) { $0 + ($1.ballMask?.alpha.count ?? 0) })]
        let modelName = detector.modelName
        let resultFollowRows = followRows
        let resultFrames = frames
        let resultRecoveredFrames = recoveredFrames
        let resultTouches = touches
        let finalDropped = plausibility.rejectedSize + plausibility.rejectedJump
        let finalCount = counter.count
        let finalDetections = detected
        let finalFrames = index
        let finalPeak = peak
        try Task.checkCancellation()
        #if DEBUG
        if visualOnly, let name = SessionDesignReview.argument("--effects-folder") {
            let folder = URL.documentsDirectory.appendingPathComponent(URL(fileURLWithPath:name).lastPathComponent)
            try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try? JSONSerialization.data(withJSONObject:metrics,options:[.sortedKeys,.prettyPrinted])
                .write(to:folder.appendingPathComponent("visual-analysis.json"))
            if auditFollow {
                try? JSONSerialization.data(withJSONObject:resultFollowRows,options:[.sortedKeys])
                    .write(to:folder.appendingPathComponent("visual-follow.json"))
            }
            try? SessionAnalysisStore.frameData((resultFrames + resultRecoveredFrames).sorted { $0.time < $1.time })
                .write(to:folder.appendingPathComponent("raw-visual.plist"))
        }
        #endif
        if detectionErrors == 0, (visualRecovery?.errors ?? 0) == 0, SessionAnalysisStore.canStore(frames + recoveredFrames) {
            let stored = StoredInference(frames:frames.map(StoredFrame.init),
                touches:touches.map { [Double($0.index),$0.time,$0.x,$0.y] },count:finalCount,
                detections:finalDetections,rejected:finalDropped,framesRead:finalFrames,
                duration:CMTimeGetSeconds(duration),peak:finalPeak,model:modelName,elapsed:metrics["elapsed_s"] ?? 0,
                visualRecoveries:recoveredFrames.isEmpty ? nil : recoveredFrames.map(StoredFrame.init))
            await SessionAnalysisStore.shared.saveInference(stored,key:cacheKey)
        }
        await MainActor.run {
            self.counterTrace = trace
            self.followDiagnostics = resultFollowRows
            self.performance = metrics; self.analyzedModel = modelName
            self.recordedTrack = resultFrames
            self.visualRecoveries = resultRecoveredFrames
            self.recordedTouches = resultTouches
            self.videoDuration = CMTimeGetSeconds(duration)
            self.dropped = finalDropped
            self.touchCount = finalCount
            self.detections = finalDetections
            self.framesRead = finalFrames
            self.peakScore = finalPeak
            self.progress = 1
            self.status = "done"
        }
        onProgress?(1)
    }
}
