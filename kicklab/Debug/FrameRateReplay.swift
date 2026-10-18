#if DEBUG && TOUCH_COUNTING_DEBUG
import AVFoundation
import Foundation
import UIKit

/// Re-run the live pipeline on one full-rate saved capture at several analysis
/// cadences. Outputs stay in the explicitly staged debug folder, never history.
/// Encoded video can differ from original camera pixels, so always compare a
/// fresh replay at the original cadence before attributing gains to frame rate.
nonisolated enum FrameRateReplay {
    private struct Configuration: Decodable {
        let video, trace, capture: String
        let profiles: [DebugFrameProfile]
    }

    @MainActor static func run(folderName: String) async {
        let wasIdleDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = wasIdleDisabled }
        let folder = URL.documentsDirectory.appendingPathComponent(URL(fileURLWithPath: folderName).lastPathComponent)
        let status = folder.appendingPathComponent("frame-status.txt")
        do {
            try Data("RUNNING".utf8).write(to: status, options: .atomic)
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("cadence-config.json").path) {
                try await Task.detached(priority: .userInitiated) {
                    try await CadenceBenchmark.run(folder: folder, status: status)
                }.value
                try Data("DONE".utf8).write(to: status, options: .atomic)
                return
            }
            try await Task.detached(priority: .userInitiated) {
                let config = try JSONDecoder().decode(Configuration.self,
                    from: Data(contentsOf: folder.appendingPathComponent("frame-config.json")))
                guard [config.video, config.trace, config.capture].allSatisfy({
                    !$0.isEmpty && $0 == URL(fileURLWithPath: $0).lastPathComponent && $0 != "." && $0 != ".."
                }) else { throw failure("Invalid staged filename") }
                let video = folder.appendingPathComponent(config.video)
                let archive = try PropertyListDecoder().decode(CounterTraceArchive.self,
                    from: Data(contentsOf: folder.appendingPathComponent(config.trace)))
                let capture = try PropertyListDecoder().decode(CaptureSessionTimeline.self,
                    from: Data(contentsOf: folder.appendingPathComponent(config.capture)))
                guard archive.mode == .capture, capture.sourceDigest == archive.sourceDigest,
                      try SessionAnalysisStore.sourceDigest(video) == archive.sourceDigest,
                      !capture.frames.isEmpty else { throw failure("Source and capture evidence do not match") }
                _ = try archive.trace.replay()
                for profile in config.profiles {
                    try await replay(video: video, capture: capture, origin: archive.timeOriginSeconds,
                                     profile: profile, folder: folder, status: status)
                }
            }.value
            try Data("DONE".utf8).write(to: status, options: .atomic)
        } catch {
            try? Data("FAILED: \(error)".utf8).write(to: status, options: .atomic)
        }
    }

    private static func failure(_ message: String) -> NSError { NSError(domain: message, code: 1) }

    private static func replay(video: URL, capture: CaptureSessionTimeline, origin: Double,
                               profile: DebugFrameProfile, folder: URL, status: URL) async throws {
        // Paced timings depend on heat: start each paced run no hotter than fair.
        let coolingStarted = ProcessInfo.processInfo.systemUptime
        while profile == .paced, ProcessInfo.processInfo.thermalState.rawValue > 1,
              ProcessInfo.processInfo.systemUptime - coolingStarted < 300 {
            try Data("COOLING \(profile.rawValue)".utf8).write(to: status, options: .atomic)
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        let thermalStart = ProcessInfo.processInfo.thermalState.rawValue
        let asset = AVURLAsset(url: video)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        let analysis = LiveJugglingAnalysis()
        let request = CaptureRequest()
        defer { request.cancel(); analysis.release() }
        guard try analysis.prepare(request: request) else { throw failure("Preparation cancelled") }
        analysis.beginRecording()
        var sampling = DebugFrameSampling(profile: profile)
        var buffer = LiveAnalysisBuffer<RecordedFrameIdentity>()
        let arguments = ProcessInfo.processInfo.arguments
        let study = arguments.firstIndex(of: "--rf-input-study").flatMap {
            arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "bundled"
        // Optional fixed busy time emulates another phone's measured live speed.
        let fixedPace = arguments.firstIndex(of: "--paced-ms").flatMap {
            arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil }.flatMap { $0 > 0 ? $0 / 1000 : nil }
        let name = profile.rawValue + (study == "bundled" ? "" : "-" + URL(fileURLWithPath: study).lastPathComponent)
            + (profile == .paced ? fixedPace.map { "-p\(Int(($0 * 1000).rounded()))" } ?? "" : "")
        var index = 0, processed = 0
        // Device pacing models the live queue on this phone: one frame runs, and
        // the newest offered frame waits. The analyser's busy time is its real
        // processing time, measured on the source clock.
        var freeAt = -Double.infinity, pending: LiveAnalysisFrame?, pacedMS = [Double]()
        func analyse(_ frame: LiveAnalysisFrame) throws -> Double {
            let started = ProcessInfo.processInfo.systemUptime
            _ = try analysis.process(frame, request: request, motionCompensationEnabled: true)
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            pacedMS.append(elapsed * 1000)
            processed += 1
            if processed.isMultiple(of: 30) {
                try Data("RUNNING \(name) \(index)/\(capture.frames.count)".utf8)
                    .write(to: status, options: .atomic)
            }
            return profile == .paced ? fixedPace ?? elapsed : elapsed
        }
        guard reader.startReading() else { throw reader.error ?? failure("Reader failed") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try autoreleasepool {
                defer { index += 1 }
                guard index < capture.frames.count else { throw failure("Extra decoded frame") }
                let identity = capture.frames[index]
                guard identity.index == index, identity.isValid,
                      abs(CMSampleBufferGetPresentationTimeStamp(sample).seconds - identity.seconds) < 0.002,
                      let pixels = CMSampleBufferGetImageBuffer(sample),
                      CVPixelBufferGetWidth(pixels) == identity.width,
                      CVPixelBufferGetHeight(pixels) == identity.height else { throw failure("Frame identity mismatch") }
                let sourceTime = origin + identity.seconds
                guard sampling.allows(sourceTime), buffer.offer(identity, at: sourceTime) != nil else { return }
                _ = buffer.finish()
                let frame = LiveAnalysisFrame(pixels: pixels, sourceTime: sourceTime, startTime: origin,
                                              captureDrops: 0, identity: identity)
                guard profile == .paced else { _ = try analyse(frame); return }
                // The analyser freed before this frame arrived, so the waiting frame ran then.
                if let waiting = pending, sourceTime > freeAt {
                    pending = nil
                    freeAt += try analyse(waiting)
                }
                if sourceTime >= freeAt { freeAt = sourceTime + (try analyse(frame)) }
                else { pending = frame }
            }
        }
        if let waiting = pending { _ = try analyse(waiting) }
        guard reader.status == .completed, index == capture.frames.count else {
            throw reader.error ?? failure("Incomplete decode")
        }
        let result = analysis.finish(flush: true, wasActive: true)
        guard !result.qualityFailed, let trace = result.trace, trace.complete else { throw failure("Analysis failed") }
        _ = try trace.replay()
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(trace).write(to: folder.appendingPathComponent(name + "-frames.plist"), options: .atomic)
        let sortedMS = pacedMS.sorted()
        let duration = max(0.001, capture.frames.last?.seconds ?? 0)
        let report: [String: Any] = ["profile": profile.rawValue, "count": result.count,
            "model": study, "fixedPaceMS": fixedPace.map { $0 * 1000 } ?? 0, "analysisMedianMS": sortedMS.isEmpty ? 0 : sortedMS[sortedMS.count / 2],
            "analysisFPS": Double(sortedMS.count) / duration,
            "touchTimes": result.touches.map(\.time),
            "thermalStart": thermalStart, "thermalEnd": ProcessInfo.processInfo.thermalState.rawValue,
            "sourceFrames": index, "analysisFrames": result.frameCount, "timeOrigin": origin,
            "sourceDigest": capture.sourceDigest, "pipeline": SessionAnalysisStore.pipelineSignature(),
            "rateSkipped": sampling.rateSkipped, "gapSkipped": sampling.gapSkipped]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent(name + "-summary.json"), options: .atomic)
    }
}
#endif
