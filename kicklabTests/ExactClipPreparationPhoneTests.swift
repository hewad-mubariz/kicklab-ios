import AVFoundation
import Combine
import UIKit
import XCTest
@testable import kicklab

/// Opt-in measurement of the user's unchanged IMG_1529.MOV on physical phones.
/// Uses Release code and the same analyser, preparation and replay surface as the editor.
/// This measures pipeline latency, excluding Photos copying and picker animations.
@MainActor
final class ExactClipPreparationPhoneTests: XCTestCase {
    private let folder = URL.documentsDirectory.appending(path: "exact-clip-check", directoryHint: .isDirectory)
    private var report: [String: Any] = [:]
    private var reportFile = "report.json"
    private func note(_ key: String, _ value: Any) {
        report[key] = value
        print("EXACTCLIP \(key) = \(value)")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appending(path: reportFile), options: .atomic)
        }
    }
    private func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

    private func timed<T>(_ name: String, _ work: () async throws -> T) async rethrows -> T {
        note("current_stage", name)
        note("\(name)_thermal_before", ProcessInfo.processInfo.thermalState.rawValue)
        let start = uptime()
        let heartbeat = Heartbeat()
        heartbeat.start()
        defer { heartbeat.stop() }
        let value = try await work()
        note("\(name)_seconds", uptime() - start)
        note("\(name)_main_lateness_ms", heartbeat.summary)
        note("\(name)_thermal_after", ProcessInfo.processInfo.thermalState.rawValue)
        return value
    }

    func testExactClipPreparationAndPlayback() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical phones only; simulator performance is not representative")
        #endif
        PreparationPerformance.reset()
        let source = folder.appending(path: "clip.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path), "Stage IMG_1529.MOV in Documents/exact-clip-check/clip.mov")
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdle }
        // Installation may briefly leave the host inactive. Start the measured
        // foreground workflow only once UIKit reports that it is active.
        let activationDeadline = uptime() + 30
        while UIApplication.shared.applicationState != .active, uptime() < activationDeadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertEqual(UIApplication.shared.applicationState, .active)
        var system = utsname(); uname(&system)
        note("hardware", withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) })
        note("os", ProcessInfo.processInfo.operatingSystemVersionString)
        note("build", Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
        note("started_at", ISO8601DateFormatter().string(from: Date()))
        note("low_power_mode", ProcessInfo.processInfo.isLowPowerModeEnabled)
        note("lightweight_recipe", LookRecipes.prefersLightEffects)
        let asset = AVURLAsset(url: source)
        note("clip_seconds", try await asset.load(.duration).seconds)
        note("source_sha256", try await Task.detached { try SessionAnalysisStore.sourceDigest(source) }.value)

        let analyser = VideoAnalyzer()
        await timed("import") {
            analyser.analyse(url: source)
            await analyser.waitUntilFinished()
        }
        XCTAssertEqual(analyser.status, "done")
        note("import_metrics", analyser.performance)
        note("counted_touches", analyser.touchCount)
        note("import_observations", analyser.recordedTrack.count)
        var summary = SessionSummary.make(touches: analyser.touchCount, duration: analyser.videoDuration,
            bestCombo: analyser.touchCount, personalBest: analyser.touchCount, videoURL: source,
            touchesMarked: analyser.recordedTouches, track: analyser.recordedTrack)
        if !analyser.visualRecoveries.isEmpty { summary.visualTrack = analyser.renderTrack }
        summary.framesUseCompositionClock = true
        summary.needsVisualPreparation = !summary.track.isEmpty
        let base = SessionEditState(style: .none, intensity: 0.85)
        let original = BallEffectTrack(frames: summary.renderTrack, touchTimes: summary.touchesMarked.map(\.time))
        try await playback("original", source: source, edit: base, track: original, from: 3)

        // Crystal alone, before any dense replacement-ball preparation has happened.
        let crystal = SessionEditState(style: .crystal, intensity: 0.85)
        let crystalPreparation = SessionEffectsPreparation()
        let crystalReady = try await timed("crystal_effect_preparation") {
            try await crystalPreparation.prepare(summary, for: crystal)
        }
        let crystalTrack = BallEffectTrack(frames: crystalReady.renderTrack, touchTimes: summary.touchesMarked.map(\.time))
        let resources = try MetalEffectEngine.Resources.shared.get()
        note("crystal_renderer_already_ready", resources.crystal.resultIfReady != nil)
        try await playback("crystal_first", source: source, edit: crystal, track: crystalTrack, from: 3)
        try await playback("crystal_repeat", source: source, edit: crystal, track: crystalTrack, from: 3)
        _ = try await timed("crystal_preparation_repeat") {
            try await crystalPreparation.prepare(summary, for: crystal)
        }

        // The real device-specific Power-up recipe, with its sequential preparation stages.
        var powerUp = base
        let recipe = LookRecipes.make(.powerUp, base: base.baseLook, touchCount: summary.touches,
                                      lightweight: LookRecipes.prefersLightEffects)
        powerUp.lookChanges = recipe.changes
        powerUp.swapEffect = recipe.moment
        XCTAssertTrue(powerUp.usesBallMaterial, "Need enough touches to exercise Power-up")
        note("power_up_looks", recipe.changes.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value.ball.rawValue)/\($0.value.effect.rawValue)" })
        let preparation = SessionEffectsPreparation()
        let reuse = RFFramePredictionReuse.shared.cache(for: (report["source_sha256"] as! String) + "|" + SessionAnalysisStore.pipelineSignature())
        let reuseBefore = reuse.hitCount
        let prepStart = uptime()
        var crossed90: Double?
        let progress = preparation.$progress.sink { value in
            if value >= 0.9 && crossed90 == nil { crossed90 = ProcessInfo.processInfo.systemUptime - prepStart }
        }
        let computationsBefore = await SessionAnalysisStore.shared.computations
        let ready = try await timed("power_up_effect_preparation") {
            try await preparation.prepare(summary, for: powerUp)
        }
        progress.cancel()
        note("power_up_visual_computations", await SessionAnalysisStore.shared.computations - computationsBefore)
        if let crossed90 { note("power_up_preparation_reached_90pct_seconds", crossed90) }
        note("power_up_visual_observations", ready.renderTrack.count)
        note("power_up_reused_predictions", reuse.hitCount - reuseBefore)
        note("prediction_cache_bytes", reuse.retainedBytes)
        try SessionAnalysisStore.frameData(ready.renderTrack).write(to: folder.appending(path: "prepared-visual.plist"), options: .atomic)
        var effects = BallEffectTrack(frames: ready.renderTrack, touchTimes: summary.touchesMarked.map(\.time))
        let spinFolder = URL.cachesDirectory.appending(path: "SessionSpin-v3", directoryHint: .isDirectory)
        let spinFilesBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: spinFolder.path)) ?? [])
        let motion = try await timed("power_up_ball_preparation") {
            try await BallSurfaceTimeline.prepare(source: source, track: effects)
        }
        effects.surfaceMotion = motion
        note("spin_recorded_computation_seconds", motion.elapsed)
        let spinFilesAfter = Set((try? FileManager.default.contentsOfDirectory(atPath: spinFolder.path)) ?? [])
        note("spin_new_cache_files", spinFilesAfter.subtracting(spinFilesBefore).count)
        note("power_up_total_preparation_seconds", (report["power_up_effect_preparation_seconds"] as! Double) + (report["power_up_ball_preparation_seconds"] as! Double))
        _ = try await timed("power_up_repeat_same_editor") {
            let _ = try await preparation.prepare(summary, for: powerUp)
            return try await BallSurfaceTimeline.prepare(source: source, track: effects)
        }
        _ = try await timed("power_up_repeat_new_preparation_owner") {
            let _ = try await SessionEffectsPreparation().prepare(summary, for: powerUp)
            return try await BallSurfaceTimeline.prepare(source: source, track: effects)
        }
        let firstChange = recipe.changes.keys.min() ?? 0
        let start = summary.touchesMarked.indices.contains(firstChange) ? summary.touchesMarked[firstChange].time + 0.25 : 3
        try await playback("power_up", source: source, edit: powerUp, track: effects, from: start)
        try await playback("crystal_with_prepared_ball", source: source,
            edit: SessionEditState(style: .crystal, intensity: 0.85, ballSkin: .lava), track: effects, from: 3)
        note("finished_at", ISO8601DateFormatter().string(from: Date()))
        note("current_stage", "complete")
    }

    /// Follow-up after the cold measurement: controls for denser tracks and for a replacement skin.
    func testWarmClipPlaybackComparison() async throws {
        reportFile = "warm-playback.json"
        let source = folder.appending(path: "clip.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path), "Stage the exact clip first")
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdle }
        var system = utsname(); uname(&system)
        note("hardware", withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) })
        let analyser = VideoAnalyzer()
        await timed("cached_import") { analyser.analyse(url: source); await analyser.waitUntilFinished() }
        XCTAssertEqual(analyser.status, "done")
        note("import_metrics", analyser.performance)
        var summary = SessionSummary.make(touches: analyser.touchCount, duration: analyser.videoDuration,
            bestCombo: analyser.touchCount, personalBest: analyser.touchCount, videoURL: source,
            touchesMarked: analyser.recordedTouches, track: analyser.recordedTrack)
        if !analyser.visualRecoveries.isEmpty { summary.visualTrack = analyser.renderTrack }
        summary.framesUseCompositionClock = true
        summary.needsVisualPreparation = !summary.track.isEmpty
        let crystal = SessionEditState(style: .crystal, intensity: 0.85)
        let ballCrystal = SessionEditState(style: .crystal, intensity: 0.85, ballSkin: .lava)
        let ready = try await timed("cached_dense_preparation") {
            try await SessionEffectsPreparation().prepare(summary, for: ballCrystal)
        }
        var dense = BallEffectTrack(frames: ready.renderTrack, touchTimes: summary.touchesMarked.map(\.time))
        dense.surfaceMotion = try await timed("cached_spin") {
            try await BallSurfaceTimeline.prepare(source: source, track: dense)
        }
        let sparse = BallEffectTrack(frames: summary.renderTrack, touchTimes: summary.touchesMarked.map(\.time))
        try await playback("crystal_sparse", source: source, edit: crystal, track: sparse, from: 3)
        try await playback("crystal_dense_original_ball", source: source, edit: crystal, track: dense, from: 3)
        try await playback("crystal_dense_lava", source: source, edit: ballCrystal, track: dense, from: 3)
        try await playback("crystal_dense_original_ball_repeat", source: source, edit: crystal, track: dense, from: 3)
        note("current_stage", "complete")
    }

    private func playback(_ name: String, source: URL, edit: SessionEditState, track: BallEffectTrack, from time: Double) async throws {
        note("current_stage", "playback_\(name)")
        note("\(name)_playback_thermal_before", ProcessInfo.processInfo.thermalState.rawValue)
        let asset = AVURLAsset(url: source)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videos.first)
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = try await EffectVideoGeometry.composition(track: video,
            duration: try await asset.load(.duration), shortEdge: 1080)
        let player = AVPlayer(playerItem: item)
        await player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        let view = EffectVideoView()
        view.frame = window.bounds
        window.rootViewController!.view.addSubview(view)
        defer {
            player.pause(); view.stop(); view.removeFromSuperview()
            window.isHidden = true; window.rootViewController = nil; previousKey?.makeKeyAndVisible()
        }
        var failures: [String] = []; view.onFailure = { failures.append($0) }
        let heartbeat = Heartbeat(); heartbeat.start()
        defer { heartbeat.stop() }
        let started = uptime()
        view.configure(player: player, edit: edit, track: track)
        note("\(name)_configure_seconds", uptime() - started)
        player.play()
        let resources = try MetalEffectEngine.Resources.shared.get()
        var firstFrame: Double?, crystalReady: Double?, framesAtOneSecond: Int?
        while uptime() - started < 9 {
            if firstFrame == nil && view.presentedFrameCount > 0 { firstFrame = uptime() - started }
            if edit.style == .crystal && crystalReady == nil && resources.crystal.resultIfReady != nil {
                _ = try resources.crystal.resultIfReady?.get()
                crystalReady = uptime() - started
            }
            if uptime() - started >= 1 && framesAtOneSecond == nil { framesAtOneSecond = view.presentedFrameCount }
            try await Task.sleep(for: .milliseconds(10))
        }
        let elapsed = uptime() - started
        note("\(name)_submitted_frames_per_second_after_first_second", Double(view.presentedFrameCount - (framesAtOneSecond ?? 0)) / (elapsed - 1))
        note("\(name)_playhead_advance_seconds", player.currentTime().seconds - time)
        note("\(name)_main_lateness_ms", heartbeat.summary)
        note("\(name)_first_submission_seconds", firstFrame ?? -1)
        if let crystalReady { note("\(name)_crystal_renderer_ready_seconds", crystalReady) }
        note("\(name)_playback_thermal_after", ProcessInfo.processInfo.thermalState.rawValue)
        note("\(name)_failures", failures)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }

    @MainActor private final class Heartbeat {
        private var task: Task<Void, Never>?
        private var values: [Double] = []
        func start() {
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    let start = ProcessInfo.processInfo.systemUptime
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                    self?.values.append(max(0, (ProcessInfo.processInfo.systemUptime - start) * 1000 - 10))
                }
            }
        }
        func stop() { task?.cancel(); task = nil }
        var summary: [String: Double] {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return [:] }
            return ["p50": sorted[sorted.count / 2], "p95": sorted[Int(Double(sorted.count) * 0.95)],
                    "max": sorted.last!, "samples_over_50ms": Double(sorted.filter { $0 > 50 }.count)]
        }
    }
}
