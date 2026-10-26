#if DEBUG && TOUCH_COUNTING_DEBUG
import AVFoundation
import Foundation

/// Accuracy study using real saved pixels at their original speed. The selected
/// cadence is fixed, independent of thermal state and inference wall-clock time.
/// No video, saved session, model threshold or production counter is modified.
nonisolated enum CadenceBenchmark {
    struct Configuration: Decodable {
        let clips: [Clip]
        let passes: [Pass]
        let timeAware: Bool?
        /// Feed frames on the source clock with real deadlines. The RF worker
        /// is asynchronous; an unpaced decode outruns it and loses every reply.
        let paced: Bool?
    }
    struct Clip: Decodable {
        let id, video, sha256: String
        let endSeconds: Double
        /// Read-only reuse of an already staged folder under Documents, so a
        /// multi-gigabyte corpus is not copied to the phone a second time.
        let sourceFolder: String?
    }
    struct Pass: Decodable {
        let profile: DebugFrameProfile
        let phaseFrames: Int
    }

    static func run(folder: URL, status: URL) async throws {
        let config = try JSONDecoder().decode(Configuration.self,
            from: Data(contentsOf: folder.appendingPathComponent("cadence-config.json")))
        for clip in config.clips {
            guard [clip.id, clip.video].allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && URL(fileURLWithPath: $0).lastPathComponent == $0
            }), clip.endSeconds.isFinite, clip.endSeconds > 0 else { throw failure("Invalid clip") }
            if let sourceFolder = clip.sourceFolder {
                guard !sourceFolder.isEmpty, sourceFolder == URL(fileURLWithPath: sourceFolder).lastPathComponent,
                      sourceFolder != ".", sourceFolder != ".." else { throw failure("Invalid source folder") }
            }
            let source = (clip.sourceFolder.map { URL.documentsDirectory.appendingPathComponent($0) } ?? folder)
                .appendingPathComponent(clip.video)
            guard try SessionAnalysisStore.sourceDigest(source) == clip.sha256 else { throw failure("Source mismatch") }
            for pass in config.passes {
                guard [.normal, .fps20, .fps15, .fps10].contains(pass.profile),
                      (0...4).contains(pass.phaseFrames) else { throw failure("Invalid pass") }
                let name = "\(clip.id)-\(pass.profile.rawValue)-phase\(pass.phaseFrames)" + (config.paced == true ? "-paced" : "")
                // Completed passes are durable, so a background interruption can resume.
                if FileManager.default.fileExists(atPath: folder.appendingPathComponent(name + "-summary.json").path) { continue }
                try await replay(source: source, clip: clip, pass: pass, name: name, folder: folder,
                                 status: status, timeAware: config.timeAware ?? true, paced: config.paced == true)
            }
        }
    }

    private static func replay(source: URL, clip: Clip, pass: Pass, name: String,
                               folder: URL, status: URL, timeAware: Bool, paced: Bool) async throws {
        try Data("RUNNING \(name) preparing".utf8).write(to: status, options: .atomic)
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw failure("No video") }
        let duration = try await asset.load(.duration)
        let end = min(duration.seconds, clip.endSeconds)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = try await EffectVideoGeometry.composition(track: track, duration: duration, shortEdge: 720)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        var counterConfig = CounterConfig()
        counterConfig.timeAwareTrajectory = timeAware
        let analysis = LiveJugglingAnalysis(counterConfig: counterConfig), request = CaptureRequest()
        defer { request.cancel(); analysis.release(); if reader.status == .reading { reader.cancelReading() } }
        guard try analysis.prepare(request: request) else { throw failure("Cancelled") }
        analysis.beginRecording()
        var sampling = DebugFrameSampling(profile: pass.profile)
        var buffer = LiveAnalysisBuffer<Int>()
        var index = 0, selected = [Double](), inferenceMS = [Double](), lateSkips = 0
        let thermalStart = ProcessInfo.processInfo.thermalState.rawValue
        let started = ProcessInfo.processInfo.systemUptime
        // The source clock starts at the first decoded exposure, not before the
        // reader spins up: a slow cold start must not make every frame late.
        var epoch: Double?
        guard reader.startReading() else { throw reader.error ?? failure("Reader failed") }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if epoch == nil { epoch = ProcessInfo.processInfo.systemUptime - time.seconds }
            if time.seconds >= end { break }
            guard index >= pass.phaseFrames, sampling.allows(time.seconds),
                  buffer.offer(index, at: time.seconds) != nil else { index += 1; continue }
            _ = buffer.finish()
            // Same bounded newest-frame policy as the live camera: wait for the
            // source deadline, and never catch up by feeding stale frames.
            let due = epoch! + time.seconds
            if paced {
                let wait = due - ProcessInfo.processInfo.systemUptime
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                if ProcessInfo.processInfo.systemUptime - due > 1.0/30 { lateSkips += 1; index += 1; continue }
            }
            try autoreleasepool {
                defer { index += 1 }
                guard let pixels = CMSampleBufferGetImageBuffer(sample) else { throw failure("No pixels") }
                let identity = RecordedFrameIdentity(index: index, time: time,
                    width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels),
                    coordinates: "composition-720-sdr-v1")
                let before = ProcessInfo.processInfo.systemUptime
                _ = try analysis.process(LiveAnalysisFrame(pixels: pixels, sourceTime: time.seconds,
                    startTime: 0, captureDrops: 0, identity: identity,
                    sourceDueUptime: paced ? due : ProcessInfo.processInfo.systemUptime), request: request, motionCompensationEnabled: true)
                inferenceMS.append((ProcessInfo.processInfo.systemUptime - before) * 1000)
                selected.append(time.seconds)
                if selected.count.isMultiple(of: 30) {
                    try Data("RUNNING \(name) \(String(format: "%.2f", time.seconds))/\(end)s".utf8)
                        .write(to: status, options: .atomic)
                }
            }
        }
        guard reader.status != .failed else { throw reader.error ?? failure("Decode failed") }
        let result = analysis.finish(flush: true, wasActive: true)
        guard !result.qualityFailed, let trace = result.trace, trace.complete,
              !selected.isEmpty else {
            throw failure("Analysis failed: qualityFailed=\(result.qualityFailed) trace=\(result.trace != nil) complete=\(result.trace?.complete ?? false) selected=\(selected.count) decoded=\(index) late=\(lateSkips) readerStatus=\(reader.status.rawValue) readerError=\(reader.error.map { String(describing: $0) } ?? "none")")
        }
        _ = try trace.replay()
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(trace).write(to: folder.appendingPathComponent(name + "-trace.plist"), options: .atomic)
        // The same trace as a file-mode archive, so TouchContactReplay can rerun
        // contact evidence on these inputs: composition clock, origin zero.
        try encoder.encode(CounterTraceArchive(sourceDigest: clip.sha256,
            pipelineSignature: SessionAnalysisStore.pipelineSignature(), mode: .file,
            timeOriginSeconds: 0, trace: trace))
            .write(to: folder.appendingPathComponent(name + "-archive.plist"), options: .atomic)
        let gaps = zip(selected, selected.dropFirst()).map { ($1 - $0) * 1000 }
        let report: [String: Any] = ["clip": clip.id, "profile": pass.profile.rawValue,
            "phaseFrames": pass.phaseFrames, "sourceDigest": clip.sha256, "paced": paced, "lateSourceSkips": lateSkips,
            "pipeline": SessionAnalysisStore.pipelineSignature(), "model": BallDetector.configuredResourceName,
            "timeAware": timeAware,
            "sourceEndSeconds": end, "sourceFramesRead": index, "analysisFrames": selected.count,
            "analysisFPS": Double(selected.count) / end, "selectedTimes": selected,
            "maximumGapMS": gaps.max() ?? 0, "count": result.count,
            "touchTimes": result.touches.map(\.time), "detectedFrames": result.track.count,
            "thermalStart": thermalStart, "thermalEnd": ProcessInfo.processInfo.thermalState.rawValue,
            "wallSeconds": ProcessInfo.processInfo.systemUptime - started,
            "medianProcessingMS": inferenceMS.sorted()[inferenceMS.count / 2],
            "scope": "Fixed source-time sampling, fresh live detector and contact pipeline per pass; not a hardware throughput benchmark"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent(name + "-summary.json"), options: .atomic)
    }

    private static func failure(_ message: String) -> NSError { NSError(domain: "CadenceBenchmark.\(message)", code: 1) }
}
#endif
