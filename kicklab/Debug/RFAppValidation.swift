#if DEBUG
import AVFoundation
import Foundation
import UIKit

/// Explicit local device checks. Never runs during an ordinary user launch.
nonisolated enum RFAppValidation {
    private struct Config: Decodable { let mode: String; var source: String?; var seconds: Double? }
    @MainActor static func run(folderName: String) async {
        guard folderName == URL(fileURLWithPath: folderName).lastPathComponent, folderName.hasPrefix("RFValidation-") else { return }
        let folder = URL.documentsDirectory.appendingPathComponent(folderName, isDirectory: true)
        let status = folder.appendingPathComponent("status.json")
        func save(_ state: String, _ extra: [String: Any] = [:]) {
            var row = extra; row["state"] = state; row["updated"] = ISO8601DateFormatter().string(from: Date())
            row["thermal"] = ProcessInfo.processInfo.thermalState.rawValue
            row["memory_mib"] = DetectorPerformance.memoryMB()
            if let data = try? JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: status, options: .atomic) }
        }
        let oldIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = oldIdle }
        do {
            let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: folder.appendingPathComponent("config.json")))
            save("running", ["mode": config.mode])
            if config.mode == "cooldown" {
                // Explicit lab mode: no camera, decoder or model work. Keep
                // the device awake while a long replay sweep's heat dissipates.
                let seconds = config.seconds ?? 300
                guard seconds.isFinite, (0...600).contains(seconds) else { throw NSError(domain: "Invalid cooldown duration", code: 1) }
                let end = ProcessInfo.processInfo.systemUptime + seconds
                while ProcessInfo.processInfo.thermalState != .nominal, ProcessInfo.processInfo.systemUptime < end {
                    save("cooling", ["mode": config.mode])
                    try await Task.sleep(for: .seconds(10))
                }
                save("completed", ["mode": config.mode, "nominal": ProcessInfo.processInfo.thermalState == .nominal])
                return
            }
            if config.mode == "capture" {
                let camera = CameraSession(); defer { camera.stop() }
                camera.start()
                func wait(_ condition: () -> Bool, timeout: Double = 60) async throws {
                    let end = ProcessInfo.processInfo.systemUptime+timeout
                    while !condition(), ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(100)) }
                    guard condition() else { throw NSError(domain: "RFCameraTimeout", code: 1) }
                }
                try await wait { camera.canRecord || camera.recordingError != nil }
                if let error = camera.recordingError { throw NSError(domain: error, code: 1) }
                camera.startRecording()
                try await wait { camera.isRecording }
                try await Task.sleep(for: .seconds(config.seconds ?? 15))
                camera.stopRecording()
                try await wait { !camera.isFinishingRecording }
                guard camera.recordingError == nil, let video = camera.recordingURL else { throw NSError(domain: camera.recordingError ?? "No recorded video", code: 2) }
                try FileManager.default.copyItem(at: video, to: folder.appendingPathComponent("capture.mov"))
                let capture = camera.capturePerformance
                save("completed", ["mode": config.mode, "count": camera.touchCount, "written_frames": capture.writtenFrames,
                    "writer_drops": capture.writerDrops, "capture_drops": capture.captureDrops, "analysis_replaced": capture.analysisReplaced,
                    "analysis_frames": capture.analysedFrames, "selected_fps": capture.selectedFPS, "video": "capture.mov"])
                return
            }
            guard let name = config.source, name == URL(fileURLWithPath: name).lastPathComponent else { throw NSError(domain: "Invalid source", code: 1) }
            let video = folder.appendingPathComponent(name)
            if config.mode == "paced" {
                let result = try await Task.detached(priority: .userInitiated) { try await replay(video, seconds: config.seconds ?? 30, folder: folder) }.value
                save("completed", result); return
            }
            if config.mode == "selective" || config.mode == "full-reference" {
                let result = try await SelectiveEffectsValidation.run(folder: folder, full: config.mode == "full-reference")
                save("completed", result); return
            }
            if config.mode == "effects" {
                let stored = try PropertyListDecoder().decode([StoredFrame].self, from: Data(contentsOf: folder.appendingPathComponent("track.plist")))
                let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("touches.json"))) as! [[Double]]
                let touches = rows.map { RecordedTouch(index: Int($0[0]), time: $0[1], x: $0[2], y: $0[3]) }
                let duration = try await AVURLAsset(url: video).load(.duration).seconds
                var summary = SessionSummary.make(touches: touches.count, duration: duration, bestCombo: touches.count,
                    personalBest: touches.count, videoURL: video, touchesMarked: touches, track: stored.map(\.frame))
                summary.needsVisualPreparation = true
                let preparation = SessionEffectsPreparation()
                save("preparing_masks")
                let ready = try await preparation.prepare(summary)
                guard ready.touches == summary.touches && ready.touchesMarked.map(\.time) == touches.map(\.time) else { throw NSError(domain: "Effects changed count", code: 1) }
                let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                try encoder.encode(ready.renderTrack.map(StoredFrame.init)).write(to: folder.appendingPathComponent("visual-track.plist"))
                let maskCount = ready.renderTrack.filter { $0.ballMask != nil }.count
                guard maskCount > 0 else { throw NSError(domain: "No masks prepared", code: 1) }
                var results = [[String: Any]]()
                let cases: [(String, BallStyle, BallSkin)] = [("counter", .none, .original), ("fire", .fire, .original), ("neon", .neon, .original), ("gold", .none, .gold)]
                for (label, style, skin) in cases {
                    save("rendering", ["case": label, "finished": results])
                    var overlays = ExportOverlaySettings(); overlays.counter.enabled = true; overlays.counter.style = .normal
                    overlays.showTimer = true; overlays.graph.enabled = false
                    let start = ProcessInfo.processInfo.systemUptime
                    let output = try await BallStyleBurnIn.render(source: video, track: ready.renderTrack, style: style,
                        skin: skin, intensity: style == .none ? 0 : 0.65, shortEdge: 1080,
                        counter: ExportCounterTimeline(touches: touches, total: touches.count), overlays: overlays)
                    let target = folder.appendingPathComponent(label+".mp4")
                    try FileManager.default.copyItem(at: output, to: target)
                    let asset = AVURLAsset(url: target)
                    let outputDuration = try await asset.load(.duration).seconds
                    guard abs(outputDuration-duration) < 0.15 else { throw NSError(domain: "Export duration mismatch", code: 1) }
                    let track = try await asset.loadTracks(withMediaType: .video)[0]
                    let size = try await track.load(.naturalSize)
                    results.append(["case": label, "file": target.lastPathComponent, "seconds": ProcessInfo.processInfo.systemUptime-start,
                        "duration": outputDuration, "width": size.width, "height": size.height,
                        "bytes": try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0])
                    try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("exports.json"))
                }
                save("completed", ["mode": "effects", "count_unchanged": true, "visual_frames": ready.renderTrack.count,
                    "mask_frames": maskCount, "exports": results]); return
            }
            throw NSError(domain: "Unknown validation mode", code: 1)
        } catch { save("failed", ["error": String(describing: error)]) }
    }
    private static func replay(_ source: URL, seconds: Double, folder: URL) async throws -> [String: Any] {
        let asset = AVURLAsset(url: source), request = CaptureRequest(), analysis = LiveJugglingAnalysis()
        defer { request.cancel(); analysis.release() }
        guard try analysis.prepare(request: request) else { throw NSError(domain: "Preparation cancelled", code: 1) }
        analysis.beginRecording()
        let videoTrack = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false; reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "Reader start", code: 1) }
        let epoch = ProcessInfo.processInfo.systemUptime
        let expectedEnd = min(seconds, try await asset.load(.duration).seconds)
        var index = 0, processed = 0, skipped = 0
        var previous = -Double.infinity
        var lastSourceTime = -Double.infinity
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample), t = time.seconds
            if t >= seconds { reader.cancelReading(); break }
            lastSourceTime = t
            defer { index += 1 }
            guard t-previous >= 1.0/30-0.0005 else { continue }
            previous = t
            let wait = epoch+t-ProcessInfo.processInfo.systemUptime
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            // Bounded newest-frame policy: do not catch up by accumulating old source frames.
            if ProcessInfo.processInfo.systemUptime-(epoch+t) > 1.0/30 { skipped += 1; continue }
            try autoreleasepool {
                guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
                let identity = RecordedFrameIdentity(index: index, time: time, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels), coordinates: "capture-buffer; normalized upright detector coordinates")
                _ = try analysis.process(LiveAnalysisFrame(pixels: pixels, sourceTime: t, startTime: 0, captureDrops: 0,
                    identity: identity, sourceDueUptime: epoch+t), request: request, motionCompensationEnabled: true)
                processed += 1
            }
        }
        let result = analysis.finish(flush: true, wasActive: true)
        guard reader.status != .failed else { throw reader.error ?? NSError(domain: "Reader failed", code: 1) }
        guard lastSourceTime >= expectedEnd - 0.1 else {
            throw NSError(domain: "Incomplete source interval: \(lastSourceTime) of \(expectedEnd) seconds", code: 1)
        }
        guard !result.qualityFailed, let trace = result.trace, trace.complete else { throw NSError(domain: "Incomplete counter result", code: 1) }
        let replayed = try trace.replay()
        guard replayed == trace.touches else { throw NSError(domain: "Trace replay differs", code: 1) }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(trace).write(to: folder.appendingPathComponent("counter.plist"))
        try SessionAnalysisStore.frameData(result.track).write(to: folder.appendingPathComponent("track.plist"))
        try JSONSerialization.data(withJSONObject: result.touches.map { [Double($0.index), $0.time, $0.x, $0.y] }).write(to: folder.appendingPathComponent("touches.json"))
        return ["mode": "paced", "count": result.count, "source_frames": index, "admitted_frames": processed,
            "late_source_skips": skipped, "processed_frames": result.frameCount, "trace_replay_exact": true,
            "last_source_seconds": lastSourceTime, "expected_end_seconds": expectedEnd,
            "track_frames": result.track.count, "mask_frames": result.track.filter { $0.ballMask != nil }.count,
            "elapsed_seconds": ProcessInfo.processInfo.systemUptime-epoch]
    }
}
#endif
