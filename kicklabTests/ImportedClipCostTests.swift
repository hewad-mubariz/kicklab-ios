import AVFoundation
import UIKit
import XCTest
@testable import kicklab

/// Phone check for an imported camera clip: how long each stage from import to a saved video
/// takes, and how warm the phone gets. Copy the clip to Documents/cost-check/clip.mov first;
/// results print as "PHONECHECK" lines and save to Documents/cost-check/report.json.
final class ImportedClipCostTests: XCTestCase {
    private var report: [String: Any] = [:]

    private func note(_ key: String, _ value: Any) {
        report[key] = value
        print("PHONECHECK \(key) = \(value)")
    }

    @MainActor
    func testImportToExportCostOnThisPhone() async throws {
        let folder = URL.documentsDirectory.appending(path: "cost-check", directoryHint: .isDirectory)
        let clip = folder.appending(path: "clip.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: clip.path), "Copy a clip to Documents/cost-check/clip.mov")
        let asset = AVURLAsset(url: clip)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(tracks.first)
        let seconds = try await asset.load(.duration).seconds, fps = try await video.load(.nominalFrameRate)
        let size = try await video.load(.naturalSize)
        note("clip_seconds", seconds.rounded(toPlaces: 1))
        note("clip_fps", fps)
        note("clip_size", "\(Int(size.width))x\(Int(size.height))")

        // The app keeps the screen awake during video work; without it the export waits at the lock screen.
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdle }

        // Thermal state every 5 s, so the log shows when the phone warms up and how long it stays there.
        let started = ProcessInfo.processInfo.systemUptime
        let thermal = Task.detached {
            var last = -1
            while !Task.isCancelled {
                let state = ProcessInfo.processInfo.thermalState.rawValue
                if state != last {
                    print("PHONECHECK thermal \(state) at \(Int(ProcessInfo.processInfo.systemUptime - started)) s")
                    last = state
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        defer { thermal.cancel() }
        func stage<T>(_ name: String, _ work: () async throws -> T) async rethrows -> T {
            let start = ProcessInfo.processInfo.systemUptime
            let value = try await work()
            note("\(name)_s", (ProcessInfo.processInfo.systemUptime - start).rounded(toPlaces: 1))
            note("\(name)_thermal_after", ProcessInfo.processInfo.thermalState.rawValue)
            return value
        }

        // 1. Import analysis: the same analyser and summary the record screen uses for a picked video.
        let analyzer = VideoAnalyzer()
        try await stage("analysis") {
            analyzer.analyse(url: clip)
            await analyzer.waitUntilFinished()
        }
        XCTAssertEqual(analyzer.status, "done")
        note("analysis_frames", analyzer.framesRead)
        note("touches", analyzer.touchCount)
        #if DEBUG
        for key in ["decode_s", "inference_s", "detector_s", "contact_check_s", "contact_buffer_s", "motion_s",
                    "counter_s", "thermal_wait_s"] {
            if let value = analyzer.profileMetrics[key] { note("analysis_\(key)", value.rounded(toPlaces: 1)) }
        }
        #endif
        var summary = SessionSummary.make(touches: analyzer.touchCount, duration: analyzer.videoDuration,
            bestCombo: analyzer.touchCount, personalBest: analyzer.touchCount, videoURL: clip,
            touchesMarked: analyzer.recordedTouches, track: analyzer.recordedTrack)
        if !analyzer.visualRecoveries.isEmpty { summary.visualTrack = analyzer.renderTrack }
        summary.framesUseCompositionClock = true
        summary.needsVisualPreparation = !summary.track.isEmpty

        // 2. Effects preparation for a replacement ball, as the replay starts it.
        let edit = SessionEditState(style: .fire, intensity: 0.8, ballSkin: .lava)
        let ready = try await stage("preparation") { try await SessionEffectsPreparation().prepare(summary, for: edit) }

        // 3. Ball spin, which the replay prepares once and the export reuses.
        let track = BallEffectTrack(frames: ready.renderTrack, touchTimes: ready.touchesMarked.map(\.time))
        _ = try await stage("spin") { try await BallSurfaceTimeline.prepare(source: clip, track: track) }

        // 4. Exports at 1080p with the counter: plain, Fire only, and Lava + Fire.
        let counter = ExportCounterTimeline(touches: ready.touchesMarked, total: ready.touches)
        let exports: [(String, BallStyle, BallSkin, Double)] = [
            ("export_plain", .none, .original, 0), ("export_fire", .fire, .original, 0.8), ("export_lava_fire", .fire, .lava, 0.8)]
        for (name, style, skin, intensity) in exports {
            let output = try await stage(name) {
                try await BallStyleBurnIn.render(source: clip, track: ready.renderTrack, style: style, skin: skin,
                                                 intensity: intensity, shortEdge: 1080, counter: counter)
            }
            if let track = try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first {
                let rate = try await track.load(.nominalFrameRate)
                note("\(name)_fps", rate)
            }
            let bytes = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.doubleValue ?? 0
            note("\(name)_mb", (bytes / 1_048_576).rounded(toPlaces: 1))
            try? FileManager.default.removeItem(at: output)
        }
        note("total_s", (ProcessInfo.processInfo.systemUptime - started).rounded(toPlaces: 1))
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appending(path: "report.json"))
    }
}

extension ImportedClipCostTests {
    /// The same clip counted at 30 fps and at every frame: touches are matched one to one within
    /// 0.15 s, the tolerance of the labelled reviews. Then the effect and replacement-ball preparations.
    @MainActor
    func testThirtyFrameCountAgainstEveryFrame() async throws {
        let folder = URL.documentsDirectory.appending(path: "cost-check", directoryHint: .isDirectory)
        let clip = folder.appending(path: "clip.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: clip.path), "Copy a clip to Documents/cost-check/clip.mov")
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdle; VideoAnalyzer.countingSpacing = 0.03 }
        func timed<T>(_ name: String, _ work: () async throws -> T) async rethrows -> T {
            let start = ProcessInfo.processInfo.systemUptime
            let value = try await work()
            note("\(name)_s", (ProcessInfo.processInfo.systemUptime - start).rounded(toPlaces: 1))
            note("\(name)_thermal_after", ProcessInfo.processInfo.thermalState.rawValue)
            return value
        }
        func count(every spacing: Double, _ name: String) async throws -> VideoAnalyzer {
            VideoAnalyzer.countingSpacing = spacing
            let analyzer = VideoAnalyzer()
            try await timed(name) { analyzer.analyse(url: clip); await analyzer.waitUntilFinished() }
            XCTAssertEqual(analyzer.status, "done")
            note("\(name)_frames", analyzer.framesRead)
            note("\(name)_touches", analyzer.touchCount)
            return analyzer
        }

        // Counted at 30 fps first, on a cool phone, as an import is.
        let fast = try await count(every: 0.03, "count_30fps")
        var summary = SessionSummary.make(touches: fast.touchCount, duration: fast.videoDuration,
            bestCombo: fast.touchCount, personalBest: fast.touchCount, videoURL: clip,
            touchesMarked: fast.recordedTouches, track: fast.recordedTrack)
        if !fast.visualRecoveries.isEmpty { summary.visualTrack = fast.renderTrack }
        summary.framesUseCompositionClock = true
        summary.needsVisualPreparation = !summary.track.isEmpty
        let preparation = SessionEffectsPreparation()
        let fire = try await timed("prepare_fire") {
            try await preparation.prepare(summary, for: SessionEditState(style: .fire, intensity: 0.8))
        }
        note("prepare_fire_positions_only", fire.visualTrackIsPositionsOnly)
        let lava = try await timed("prepare_lava") {
            try await preparation.prepare(summary, for: SessionEditState(style: .fire, intensity: 0.8, ballSkin: .lava))
        }
        note("prepare_lava_frames", lava.renderTrack.filter { !$0.isVisualMaskRepair && !$0.isVisualRecovery }.count)
        let track = BallEffectTrack(frames: lava.renderTrack, touchTimes: lava.touchesMarked.map(\.time))
        _ = try await timed("spin") { try await BallSurfaceTimeline.prepare(source: clip, track: track) }

        // The reference: every frame, as before.
        let full = try await count(every: 0, "count_every_frame")
        var unmatched = fast.recordedTouches.map(\.time)
        var missed: [Double] = []
        for time in full.recordedTouches.map(\.time) {
            if let match = unmatched.indices.min(by: { abs(unmatched[$0] - time) < abs(unmatched[$1] - time) }),
               abs(unmatched[match] - time) <= 0.15 {
                unmatched.remove(at: match)
            } else {
                missed.append(time)
            }
        }
        note("touches_matched", full.recordedTouches.count - missed.count)
        note("touches_only_every_frame", missed.map { ($0 * 100).rounded() / 100 })
        note("touches_only_30fps", unmatched.map { ($0 * 100).rounded() / 100 })
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appending(path: "count-report.json"))
    }
}

extension ImportedClipCostTests {
    /// The two download choices for a replacement ball: 60 fps outlines and the faster 1080p · 60 fps
    /// save, then every-frame outlines and the original size and frame rate. Frames from both videos
    /// at the same moments are written to Documents/cost-check/frames for a visual check.
    @MainActor
    func testDownloadChoicesWithAReplacementBall() async throws {
        let folder = URL.documentsDirectory.appending(path: "cost-check", directoryHint: .isDirectory)
        let clip = folder.appending(path: "clip.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: clip.path), "Copy a clip to Documents/cost-check/clip.mov")
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdle }
        func timed<T>(_ name: String, _ work: () async throws -> T) async rethrows -> T {
            let start = ProcessInfo.processInfo.systemUptime
            let value = try await work()
            note("\(name)_s", (ProcessInfo.processInfo.systemUptime - start).rounded(toPlaces: 1))
            note("\(name)_thermal_after", ProcessInfo.processInfo.thermalState.rawValue)
            return value
        }
        let analyzer = VideoAnalyzer()
        analyzer.analyse(url: clip)
        await analyzer.waitUntilFinished()
        var summary = SessionSummary.make(touches: analyzer.touchCount, duration: analyzer.videoDuration,
            bestCombo: analyzer.touchCount, personalBest: analyzer.touchCount, videoURL: clip,
            touchesMarked: analyzer.recordedTouches, track: analyzer.recordedTrack)
        summary.framesUseCompositionClock = true
        summary.needsVisualPreparation = !summary.track.isEmpty
        let edit = SessionEditState(style: .fire, intensity: 0.8, ballSkin: .lava)
        let counter = ExportCounterTimeline(touches: summary.touchesMarked, total: summary.touches)
        let choices = ExportChoice.choices(for: try await VideoProcessingInfo.load(clip))
        let original = try XCTUnwrap(choices.original)
        note("choices", "\(choices.faster.label) | \(original.label)")
        let preparation = SessionEffectsPreparation()

        let faster = try await timed("prepare_60fps") { try await preparation.prepare(summary, for: edit) }
        note("prepare_60fps_frames", faster.renderTrack.filter { !$0.isVisualMaskRepair && !$0.isVisualRecovery }.count)
        let fasterTrack = BallEffectTrack(frames: faster.renderTrack, touchTimes: faster.touchesMarked.map(\.time))
        _ = try await timed("spin_60fps") { try await BallSurfaceTimeline.prepare(source: clip, track: fasterTrack) }
        let fasterVideo = try await timed("save_faster") {
            try await BallStyleBurnIn.render(source: clip, track: faster.renderTrack, style: .fire, skin: .lava, intensity: 0.8,
                                             shortEdge: choices.faster.shortEdge, maxFrameRate: choices.faster.maxFrameRate, counter: counter)
        }
        let every = try await timed("prepare_every_frame") { try await preparation.prepare(summary, for: edit, everyFrame: true) }
        let everyTrack = BallEffectTrack(frames: every.renderTrack, touchTimes: every.touchesMarked.map(\.time))
        _ = try await timed("spin_every_frame") { try await BallSurfaceTimeline.prepare(source: clip, track: everyTrack) }
        let originalVideo = try await timed("save_original") {
            try await BallStyleBurnIn.render(source: clip, track: every.renderTrack, style: .fire, skin: .lava, intensity: 0.8,
                                             shortEdge: original.shortEdge, maxFrameRate: original.maxFrameRate, counter: counter)
        }
        defer { try? FileManager.default.removeItem(at: fasterVideo); try? FileManager.default.removeItem(at: originalVideo) }

        let frames = folder.appending(path: "frames", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: frames)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        for (name, video) in [("faster", fasterVideo), ("original", originalVideo)] {
            let asset = AVURLAsset(url: video)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let size = try await track.load(.naturalSize), rate = try await track.load(.nominalFrameRate)
            let codec = try await track.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType) ?? 0
            let bytes = (try FileManager.default.attributesOfItem(atPath: video.path)[.size] as? NSNumber)?.doubleValue ?? 0
            note("\(name)_video", "\(Int(size.width))x\(Int(size.height)) · \(Int(rate.rounded())) fps · "
                + (codec == kCMVideoCodecType_HEVC ? "HEVC" : "H.264") + " · \(Int(bytes / 1_048_576)) MB")
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            for seconds in [5.0, 15.9, 30.0] {
                let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
                let url = frames.appending(path: "\(name)-\(seconds).jpg")
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appending(path: "download-report.json"))
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
