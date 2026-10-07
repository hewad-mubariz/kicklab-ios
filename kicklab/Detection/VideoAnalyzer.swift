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
    @Published private(set) var recordedTouches: [RecordedTouch] = []
    @Published private(set) var videoDuration: Double = 0
    @Published private(set) var performance: [String: Double] = [:]
    @Published private(set) var analyzedModel = ""
    @Published private(set) var followDiagnostics: [[String: Any]] = []

    func analyse(url: URL) {
        guard !isRunning else { return }
        isRunning = true
        progress = 0
        touchCount = 0
        detections = 0
        framesRead = 0
        peakScore = 0
        status = "reading…"
        dropped = 0
        recordedTrack = []
        recordedTouches = []

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await self?.run(url: url)
            } catch {
                await MainActor.run { self?.status = "failed: \(error.localizedDescription)" }
            }
            await MainActor.run { self?.isRunning = false }
        }
    }

    private nonisolated func run(url: URL) async throws {
        // Security-scoped access is required for files picked outside the app.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

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

        let started = ProcessInfo.processInfo.systemUptime
        let beforeModel = DetectorPerformance.memoryMB()
        let detector = try BallDetector()
        var peakMemory = DetectorPerformance.memoryMB()
        let loadMS = (ProcessInfo.processInfo.systemUptime-started)*1000
        var inferenceTimes: [Double] = [], totalTimes: [Double] = []
        var followRows: [[String: Any]] = [], detectionErrors=0
        let auditFollow=ProcessInfo.processInfo.arguments.contains("--effects-follow-review")
        let contactVerifier = JugglingContactVerifier.enabled ? JugglingContactVerifier() : nil
        let counter = StreamingCounter(rejectsHandContact: { [weak contactVerifier] in
            contactVerifier?.rejectsHandContact(at: $0) ?? false
        })
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

        while let sample = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let stampMs = Int(CMTimeGetSeconds(
                CMSampleBufferGetPresentationTimeStamp(sample)) * 1000)

            var found = autoreleasepool { () -> FrameDetections in
                do { return try detector.detect(pixels, orientLandscapeAsPortrait: false,
                    timestamp: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))) }
                catch { detectionErrors += 1; return FrameDetections(ball:nil,person:nil) }
            }
            if auditFollow {
                var row: [String: Any] = ["frame":index,"time":CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)),
                    "kind":detector.lastFollowKind,"calls":detector.lastFollowCalls,"mask":found.ballMask != nil,
                    "memory_mib":DetectorPerformance.memoryMB()]
                if let b=found.ball { row["box"]=[b.x-b.width/2,b.y-b.height/2,b.x+b.width/2,b.y+b.height/2]; row["score"]=b.score }
                followRows.append(row)
            }
            inferenceTimes.append(detector.lastInferenceMS); totalTimes.append(detector.lastTotalMS)
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
            let shift = compensator.update(pixels)
            let ball = found.ball.map {
                BallObservation(frameIndex: index, timestampMs: stampMs,
                                x: $0.x, y: $0.y,
                                width: $0.width, height: $0.height,
                                confidence: $0.score)
            }
            let person = found.person.map {
                PersonBox(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            }
            if compensator.isTooShaky { contactVerifier?.discardFrames() }
            else {
                contactVerifier?.store(pixels, frameIndex: index, timestampMs: stampMs,
                                       ball: found.ball, orientLandscapeAsPortrait: false)
            }
            let confirmed = counter.push(frameIndex: index, timestampMs: stampMs,
                ball: ball, person: person, cameraOffsetY: shift, reliable: !compensator.isTooShaky)
            if let detection = found.ball {
                let b = found.usesBallMasks ? detection : visualRefiner.refine(detection, in: pixels, at: Double(stampMs) / 1000)
                frames.append(RecordedFrame(time: Double(stampMs) / 1000, x: b.x, y: b.y,
                    width: b.width, height: b.height, score: b.score,
                    smoothedX: counter.lastPoint?.x ?? b.x, smoothedY: counter.lastPoint?.y ?? b.y,
                    vy: counter.lastPoint?.vy ?? 0, motion: counter.lastPoint?.motion ?? .unknown,
                    detected: true, person: person, ballMask: found.ballMask, usesBallMasks: found.usesBallMasks))
            }
            touches.append(contentsOf: confirmed.map {
                RecordedTouch(index: $0.index, time: Double($0.timestampMs) / 1000, x: $0.x, y: $0.y)
            })

            index += 1
            if index % 15 == 0 {
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
            }
        }
        if reader.status == .failed { throw reader.error ?? NSError(domain: "KickLab", code: 12) }
        touches.append(contentsOf: counter.flush().map {
            RecordedTouch(index: $0.index, time: Double($0.timestampMs) / 1000, x: $0.x, y: $0.y)
        })

        inferenceTimes.sort(); totalTimes.sort()
        func percentile(_ values: [Double], _ p: Double) -> Double {
            values.isEmpty ? 0 : values[min(values.count-1, Int(Double(values.count-1)*p))]
        }
        let metrics: [String: Double] = ["baseline_app_mib": beforeModel, "peak_sampled_app_mib": peakMemory,
            "detection_errors": Double(detectionErrors), "load_ms": loadMS, "elapsed_s": ProcessInfo.processInfo.systemUptime-started,
            "inference_median_ms": percentile(inferenceTimes,0.5), "inference_p95_ms": percentile(inferenceTimes,0.95),
            "detector_median_ms": percentile(totalTimes,0.5), "detector_p95_ms": percentile(totalTimes,0.95),
            "mask_frames": Double(frames.filter { $0.ballMask != nil }.count),
            "mask_storage_bytes": Double(frames.reduce(0) { $0 + ($1.ballMask?.alpha.count ?? 0) })]
        let modelName = detector.modelName
        let resultFollowRows = followRows
        let resultFrames = frames
        let resultTouches = touches
        let finalDropped = plausibility.rejectedSize + plausibility.rejectedJump
        let finalCount = counter.count
        let finalDetections = detected
        let finalFrames = index
        let finalPeak = peak
        await MainActor.run {
            self.followDiagnostics = resultFollowRows
            self.performance = metrics; self.analyzedModel = modelName
            self.recordedTrack = resultFrames
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
    }
}
